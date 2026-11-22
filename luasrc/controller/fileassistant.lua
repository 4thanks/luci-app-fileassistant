module("luci.controller.fileassistant", package.seeall)

require("nixio.fs")

local ALLOWED_PATHS = {
    "/mnt",
    "/etc",
    "/root",
    "/tmp",
    "/www"
}

local MAX_UPLOAD_SIZE = 500 * 1024 * 1024

function index()
    -- luci 23.05+ 已通过 menu.d JSON 注册菜单，无需重复注册菜单项
    if not nixio.fs.access("/usr/share/luci/menu.d/luci-app-fileassistant.json") then
        entry({"admin", "nas"}, firstchild(), _("NAS"), 44).dependent = false

        local page
        page = entry({"admin", "nas", "fileassistant"}, template("fileassistant"), _("文件助手"), 1)
        page.i18n = "base"
        page.dependent = true
        page.acl_depends = { "luci-app-fileassistant" }
    end

    -- API 路由在新旧版本均需注册（fb.js 的 AJAX 请求依赖这些路由）
    entry({"admin", "nas", "fileassistant", "list"}, call("fileassistant_list"), nil)
    entry({"admin", "nas", "fileassistant", "open"}, call("fileassistant_open"), nil)
    entry({"admin", "nas", "fileassistant", "delete"}, post("fileassistant_delete"), nil)
    entry({"admin", "nas", "fileassistant", "rename"}, post("fileassistant_rename"), nil)
    entry({"admin", "nas", "fileassistant", "upload"}, post("fileassistant_upload"), nil)
    entry({"admin", "nas", "fileassistant", "install"}, call("fileassistant_install"), nil)
end

local function has_write_access()
    local sid = luci.dispatcher.context.authsession
    local acl = sid and luci.util.ubus("session", "access", {
        ubus_rpc_session = sid, scope = "access-group",
        object = "luci-app-fileassistant", ["function"] = "write"
    })
    return acl and acl.access == true or false
end

function list_response(path, success, error_msg)
    luci.http.prepare_content("application/json")
    local result
    if success then
        local rv, scan_error = scandir(path)
        result = {
            ec = rv and 0 or 1,
            data = rv,
            error = scan_error,
            managed = is_path_allowed(path),
            writable = rv ~= nil and has_write_access() and nixio.fs.access(path, "w") == true
        }
    else
        result = {
            ec = 1,
            error = error_msg or "Operation failed"
        }
    end
    luci.http.write_json(result)
end

function is_path_allowed(path)
    if not path or path == "" then
        return false
    end
    local realpath = nixio.fs.realpath(path)
    if not realpath then
        return false
    end
    for _, allowed in ipairs(ALLOWED_PATHS) do
        if realpath:sub(1, #allowed + 1) == allowed .. "/" or realpath == allowed then
            return true, realpath
        end
    end
    return false, realpath
end

function sanitize_path(path)
    if not path then
        return nil
    end
    -- Bug fix: 原代码将 "<>" 替换为 "/"，应为 "\\"（Windows 路径反斜杠）
    path = path:gsub("\\\\", "/"):gsub("//+", "/"):gsub("/$", "")
    if path == "" then
        return "/"
    end
    return path
end

function fileassistant_list()
    local path = sanitize_path(luci.http.formvalue("path")) or "/"
    if path:sub(1, 1) ~= "/" then
        list_response(path, false, "请输入绝对路径")
        return
    end
    list_response(path, true)
end

function fileassistant_open()
    local path = sanitize_path(luci.http.formvalue("path")) or "/"
    local filename = luci.http.formvalue("filename") or ""
    local allowed, realpath = is_path_allowed(path)
    if not allowed then
        luci.http.status(403, "Forbidden")
        return
    end
    if filename:match("[\\/]") or filename:match("%..*%.") then
        luci.http.status(400, "Invalid filename")
        return
    end
    local filepath = realpath .. "/" .. filename
    if not nixio.fs.stat(filepath) then
        luci.http.status(404, "File not found")
        return
    end
    local mime = to_mime(filename)
    local fp = io.open(filepath, "r")
    if not fp then
        luci.http.status(500, "Cannot open file")
        return
    end
    luci.http.header('Content-Disposition', 'inline; filename="' .. filename .. '"')
    luci.http.prepare_content(mime)
    luci.ltn12.pump.all(luci.ltn12.source.file(fp), luci.http.write)
    fp:close()
end

-- Resolve the parent, not the final entry: new names do not exist yet,
-- and operations on a symlink must affect the link, not its target.
local function existing_directory(path)
    if not path or path:sub(1, 1) ~= "/" then return end
    local dir = nixio.fs.realpath(path)
    if dir and nixio.fs.stat(dir, "type") == "dir" then return dir end
end

local function entry_path(path)
    if not path or path:sub(1, 1) ~= "/" then return end
    local parent, name = path:match("^(.*)/([^/]+)$")
    if not parent or name == "." or name == ".." then return end
    local dir = existing_directory(parent == "" and "/" or parent)
    if dir then return (dir == "/" and "" or dir) .. "/" .. name, dir end
end

local function writable_session()
    if has_write_access() then return true end
    list_response("/", false, "当前 LuCI 会话没有文件助手写权限")
end

function fileassistant_delete()
    if not writable_session() then return end
    local path = sanitize_path(luci.http.formvalue("path"))
    local isdir = luci.http.formvalue("isdir")
    if not path then
        list_response("/", false, "Invalid path")
        return
    end
    local realpath, parent = entry_path(path)
    if not realpath then
        list_response(path, false, "Path not allowed")
        return
    end
    local success, err, message
    local kind = nixio.fs.lstat(realpath, "type")
    if kind == "lnk" then
        success, err, message = nixio.fs.unlink(realpath)
    elseif isdir == "1" then
        if kind == "dir" then
            success, err, message = rmtree(realpath)
        else
            success = false
            err = "Not a directory"
        end
    else
        if kind == "reg" then
            success, err, message = nixio.fs.unlink(realpath)
        else
            success = false
            err = "Not a regular file"
        end
    end
    list_response(parent, success, message or (err and tostring(err)))
end

function rmtree(path)
    local handle = nixio.fs.dir(path)
    if handle then
        for entry in handle do
            if entry ~= "." and entry ~= ".." then
                local subpath = path .. "/" .. entry
                local remove = nixio.fs.lstat(subpath, "type") == "dir" and rmtree or nixio.fs.unlink
                local ok, errno, message = remove(subpath)
                if not ok then return false, errno, message end
            end
        end
    end
    return nixio.fs.rmdir(path)
end

function fileassistant_rename()
    if not writable_session() then return end
    local filepath = luci.http.formvalue("filepath")
    local newpath = luci.http.formvalue("newpath")
    if not filepath or not newpath then
        list_response("/", false, "Invalid parameters")
        return
    end
    local old_realpath, parent = entry_path(filepath)
    local new_realpath, dest_parent = entry_path(newpath)
    if not old_realpath or not new_realpath or parent ~= dest_parent then
        list_response(filepath, false, "Path not allowed")
        return
    end
    if not nixio.fs.lstat(old_realpath) then
        list_response(filepath, false, "Source file not found")
        return
    end
    if nixio.fs.lstat(new_realpath) then
        list_response(parent, false, "目标名称已存在")
        return
    end
    local success, errno, message = nixio.fs.rename(old_realpath, new_realpath)
    list_response(parent, success, message or tostring(errno))
end

function fileassistant_install()
    local filepath = luci.http.formvalue("filepath")
    local isdir = luci.http.formvalue("isdir")
    if not filepath then
        list_response("/", false, "Invalid filepath")
        return
    end
    local allowed, realpath = is_path_allowed(filepath)
    if not allowed then
        list_response(filepath, false, "Path not allowed")
        return
    end
    if isdir == "1" then
        list_response(realpath, false, "Cannot install directory")
        return
    end
    local ext = filepath:match("%.(%w+)$")
    if ext ~= "ipk" then
        list_response(realpath, false, "Only ipk files allowed")
        return
    end
    local success, err = installIPK(realpath)
    list_response(nixio.fs.dirname(realpath), success, err)
end

function installIPK(filepath)
    -- Security fix: 用单引号包裹路径，防止命令注入
    local safe_path = filepath:gsub("'", "'\\''")
    local output = luci.sys.exec("opkg --force-depends install '" .. safe_path .. "' 2>&1")
    luci.sys.exec('rm -rf /tmp/luci-*')
    if output:match("Installing") and output:match("completed") then
        return true
    end
    return false, output
end

function fileassistant_upload()
    if not writable_session() then return end
    local uploaddir = sanitize_path(luci.http.formvalue("upload-dir"))
    local realpath = existing_directory(uploaddir)
    if not realpath then
        list_response(uploaddir, false, "Invalid directory")
        return
    end
    local filename
    local filepath
    local uploaded_size = 0
    local fp, failure, complete, created
    luci.http.setfilehandler(function(meta, chunk, eof)
        if failure or complete or not meta or meta.name ~= "upload-file" then return end
        if not fp then
            filename = sanitize_filename(meta.file)
            if not filename then
                failure = "Invalid filename"
                return
            end
            filepath = realpath .. "/" .. filename
            local errno, message
            fp, errno, message = nixio.open(filepath, nixio.open_flags("creat", "excl", "wronly"), 420)
            if not fp then
                failure = message or tostring(errno)
                return
            end
            created = true
        end
        if fp and chunk then
            uploaded_size = uploaded_size + #chunk
            if uploaded_size > MAX_UPLOAD_SIZE then
                failure = "文件超过上传大小限制"
                return
            end
            if #chunk > 0 and fp:write(chunk) ~= #chunk then
                failure = "文件写入失败"
                return
            end
        end
        if fp and eof then
            complete = fp:close()
            fp = nil
            if not complete then failure = "文件关闭失败" end
        end
    end)
    if fp then fp:close() end
    if created and not complete then nixio.fs.unlink(filepath) end
    list_response(uploaddir, complete == true and not failure, failure or "未收到完整文件")
end

function sanitize_filename(filename)
    if not filename or filename == "" then
        return nil
    end
    filename = filename:gsub("[^%w%-_.]", "_"):gsub("_+", "_")
    if #filename > 255 or filename:match("^%.") then
        return nil
    end
    return filename
end

function scandir(directory)
    local results = {}
    local realpath = nixio.fs.realpath(directory)
    if not realpath or nixio.fs.stat(realpath, "type") ~= "dir" then
        return nil, "目录不存在或无法访问"
    end
    local dir = nixio.fs.dir(realpath)
    if not dir then
        return nil, "无法读取目录"
    end
    local entries = {}
    for entry in dir do
        if entry ~= "." and entry ~= ".." then
            table.insert(entries, entry)
        end
    end
    table.sort(entries)
    for _, name in ipairs(entries) do
        local fullpath = realpath .. "/" .. name
        local stat = nixio.fs.stat(fullpath)
        if stat then
            local filetype = stat.type
            local size = stat.size or 0
            local mtime = stat.mtime or 0
            local perms = stat.modedec or "---------"

            local line
            if filetype == "dir" then
                line = string.format("drwxr-xr-x %6d %-8s %-8s %10d %s %s",
                    1, stat.uid or "root", stat.gid or "root", size,
                    os.date("%b %d %H:%M", mtime), name)
            elseif filetype == "lnk" then
                local target = nixio.fs.readlink(fullpath)
                local linktype = "l"
                if target then
                    local target_real = nixio.fs.realpath(fullpath)
                    if target_real then
                        local target_stat = nixio.fs.stat(target_real)
                        if target_stat and target_stat.type == "dir" then
                            linktype = "z"
                        end
                    end
                end
                line = string.format("%srwxr-xr-x %6d %-8s %-8s %10d %s %s -> %s",
                    linktype, 1, stat.uid or "root", stat.gid or "root", size,
                    os.date("%b %d %H:%M", mtime), name, target or "")
            else
                line = string.format("-rw-r--r-- %6d %-8s %-8s %10d %s %s",
                    1, stat.uid or "root", stat.gid or "root", size,
                    os.date("%b %d %H:%M", mtime), name)
            end
            table.insert(results, line)
        end
    end
    return results
end

MIME_TYPES = {
    ["txt"]   = "text/plain",
    ["conf"]  = "text/plain",
    ["ovpn"]  = "text/plain",
    ["log"]   = "text/plain",
    ["js"]    = "text/javascript",
    ["json"]  = "application/json",
    ["css"]   = "text/css",
    ["htm"]   = "text/html",
    ["html"]  = "text/html",
    ["patch"] = "text/x-patch",
    ["c"]     = "text/x-csrc",
    ["h"]     = "text/x-chdr",
    ["o"]     = "text/x-object",
    ["ko"]    = "text/x-object",
    ["bmp"]   = "image/bmp",
    ["gif"]   = "image/gif",
    ["png"]   = "image/png",
    ["jpg"]   = "image/jpeg",
    ["jpeg"]  = "image/jpeg",
    ["svg"]   = "image/svg+xml",
    ["webp"]  = "image/webp",
    ["ico"]   = "image/x-icon",
    ["zip"]   = "application/zip",
    ["pdf"]   = "application/pdf",
    ["xml"]   = "application/xml",
    ["xsl"]   = "application/xml",
    ["doc"]   = "application/msword",
    ["ppt"]   = "application/vnd.ms-powerpoint",
    ["xls"]   = "application/vnd.ms-excel",
    ["odt"]   = "application/vnd.oasis.opendocument.text",
    ["odp"]   = "application/vnd.oasis.opendocument.presentation",
    ["pl"]    = "application/x-perl",
    ["sh"]    = "application/x-shellscript",
    ["bash"]  = "application/x-shellscript",
    ["zsh"]   = "application/x-shellscript",
    ["php"]   = "application/x-php",
    ["deb"]   = "application/x-deb",
    ["ipk"]   = "application/x-ipkg",
    ["iso"]   = "application/x-cd-image",
    ["tar"]   = "application/x-tar",
    ["gz"]    = "application/gzip",
    ["tgz"]   = "application/x-compressed-tar",
    ["xz"]    = "application/x-xz",
    ["bz2"]   = "application/x-bzip2",
    ["7z"]    = "application/x-7z-compressed",
    ["rar"]   = "application/vnd.rar",
    ["bin"]   = "application/octet-stream",
    ["img"]   = "application/octet-stream",
    ["apk"]   = "application/vnd.android.package-archive",
    ["mp3"]   = "audio/mpeg",
    ["ogg"]   = "audio/x-vorbis+ogg",
    ["wav"]   = "audio/x-wav",
    ["flac"]  = "audio/flac",
    ["aac"]   = "audio/aac",
    ["mpg"]   = "video/mpeg",
    ["mpeg"]  = "video/mpeg",
    ["mp4"]   = "video/mp4",
    ["avi"]   = "video/x-msvideo",
    ["mkv"]   = "video/x-matroska",
    ["webm"]  = "video/webm",
    ["mov"]   = "video/quicktime"
}

function to_mime(filename)
    if type(filename) == "string" then
        local ext = filename:match("%.([^%.]+)$")
        if ext and MIME_TYPES[ext:lower()] then
            return MIME_TYPES[ext:lower()]
        end
    end
    return "application/octet-stream"
end
