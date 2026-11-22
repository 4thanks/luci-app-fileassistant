# luci-app-fileassistant

OpenWrt LuCI 文件管理器插件，提供 Web 界面进行文件浏览、上传、下载和管理。

## 功能特性

- **文件浏览**: 浏览目录结构，支持文件夹导航
- **文件上传**: 选择文件上传，最大 500 MiB，不覆盖同名文件
- **文件下载**: 点击文件名直接预览/下载
- **文件管理**: 重命名、删除文件/文件夹
- **ipk 安装**: 支持直接从文件管理器安装 .ipk 包
- **访问范围**: 从 `/` 浏览目录；有文件助手写权限的 LuCI 会话可在可写目录（包括 `/usr`）管理文件
- **响应式设计**: 支持移动端和平板设备

## 系统要求

- OpenWrt 18.06 或更高版本
- LuCI Web 界面
- 浏览器: Chrome, Firefox, Safari, Edge 现代版本

## 安装

### 使用本 fork 的 GitHub Actions

在 **Actions → Build Packages → Run workflow** 选择 `main`。工作流在 `ubuntu-24.04` 上使用 `aarch64_cortex-a53-openwrt-24.10` SDK 编译本 fork 的源码。完成后，从 [Releases](https://github.com/4thanks/luci-app-fileassistant/releases) 下载标题含对应提交短哈希的 `.ipk` 安装。

### 从源码编译

```bash
# 克隆到 OpenWrt SDK
git clone https://github.com/4thanks/luci-app-fileassistant.git

# 放入 packages 目录
mv luci-app-fileassistant /path/to/openwrt/package/feeds/luci/

# 编译
make package/luci-app-fileassistant/compile
```

### 在线安装

通过 OpenWrt Web 界面或命令行:

```bash
opkg update
opkg install luci-app-fileassistant
```

## 配置

### 预览、下载和 IPK 安装的路径白名单

文件预览、下载和 IPK 安装仍使用以下目录及其子目录。目录浏览、上传、重命名和删除不使用此白名单。

| 路径 | 用途 |
|------|------|
| `/mnt` | 挂载存储 |
| `/etc` | 系统配置 |
| `/root` | 用户目录 |
| `/tmp` | 临时文件 |
| `/www` | Web 根目录 |

如需修改白名单，编辑 `luasrc/controller/fileassistant.lua`:

```lua
local ALLOWED_PATHS = {
    "/mnt",
    "/etc",
    "/root",
    "/tmp",
    "/www"
}
```

### 上传限制

默认最大上传文件大小: **500MB**

修改 `luasrc/controller/fileassistant.lua`:

```lua
local MAX_UPLOAD_SIZE = 500 * 1024 * 1024  -- 500MB
```

## 使用方法

1. 登录 LuCI 管理界面
2. 进入 **NAS → 文件助手**
3. 使用顶部路径栏导航目录
4. 点击文件夹进入，单击 `..` 返回上级
5. 使用右侧按钮进行重命名/删除操作
6. 点击文件名预览/下载文件

## 目录结构

```
luci-app-fileassistant/
├── htdocs/
│   └── luci-static/
│       └── resources/
│           └── fileassistant/
│               ├── fb.css          # 样式表
│               ├── fb.js           # 前端脚本
│               ├── file-icon.png   # 文件图标
│               ├── folder-icon.png # 文件夹图标
│               └── link-icon.png   # 链接图标
├── luasrc/
│   ├── controller/
│   │   └── fileassistant.lua      # 后端控制器
│   └── view/
│       └── fileassistant.htm      # 模板
├── root/
│   └── usr/
│       └── share/
│           └── rpcd/
│               └── acl.d/
│                   └── luci-app-fileassistant.json  # ACL 权限
└── Makefile
```

## 安全说明

- 上传、重命名和删除通过带令牌的 POST 请求执行，并校验当前 LuCI 会话的文件助手写权限。授予此权限后，用户可以修改或删除可写系统目录中的文件。
- 文件名经过严格过滤，禁止特殊字符
- 前端输出经过 HTML 转义，防止 XSS 攻击
- 上传文件大小受限

## 更新日志

### 2026-11-22 · 4thanks fork

- `77a853b`：上传、重命名和删除扩展至 `/usr` 等可写目录。上传不覆盖同名文件；只读会话不显示写操作按钮。
- `12d3907`：首页列出真实根目录 `/`，可从列表进入 `/usr/bin` 等子目录。
- `ac17f8b`：修复重命名时因目标尚不存在而被拒绝，以及删除目录时误关闭迭代函数的问题。重命名和删除改用带令牌的 POST 请求并校验会话写权限。
- `e1f6055`：增加常用目录快捷入口，修复嵌套目录点击 `..` 时返回错误层级的问题。
- `cf1aa78`：针对 QWRT R26.11.8 的列表空白问题，修复 `nixio.fs.dir()` 迭代函数被当作句柄关闭的错误，改用浏览器 `fetch()` 加载列表。新增 GitHub Actions 工作流，编译本 fork 并发布 IPK。

### v2.0.0 (2026-03-22)

- 重构后端代码，使用 `nixio.fs` 替代 `popen` 调用
- 添加路径白名单安全机制
- 添加上传文件大小限制 (500MB)
- 修复 XSS 安全漏洞
- 修复资源泄漏问题
- 添加上传进度显示
- 优化文件列表渲染性能
- 完善 MIME 类型支持
- 添加响应式布局支持

### v1.x

- 初始版本，基于 luci-app-filebrowser

## 许可证

Apache License 2.0

## 致谢

- 原始项目: [luci-app-filebrowser](https://github.com/DarkDean89/luci-app-filebrowser)
- 灵感来源: [oh-my-openwrt](https://github.com/stuarthua/oh-my-openwrt)

## 反馈

- Issue: [GitHub Issues](https://github.com/kenzok78/luci-app-fileassistant/issues)
- 邮件: 请通过 GitHub Issues 联系
