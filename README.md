# PagaShell

PagaShell 是一款开源的服务器管理桌面应用，支持 Windows、macOS 和 Linux，提供 SSH 终端、SFTP 文件传输和 RDP/VNC 远程桌面。

你可以在多个标签和分屏中同时操作服务器，查看资源占用、管理进程和 Docker 容器，也可以通过网关访问内网服务。主机、凭据和配置保存在本机，无需注册账号。

[下载最新版](https://github.com/mingdraw/PagaShell/releases/latest) · [更新记录](CHANGELOG.md) · [问题反馈](https://github.com/mingdraw/PagaShell/issues)

## 主要功能

| 功能 | 说明 |
|---|---|
| SSH 终端 | 密码和私钥登录，多标签、左右/上下分屏，支持批量执行命令 |
| SFTP 文件传输 | 浏览本地和远程文件，拖放上传、下载，查看进度或取消传输 |
| RDP 远程桌面 | 连接 Windows 桌面，自适应分辨率、全屏，双向复制粘贴文字、文件和文件夹 |
| VNC 远程桌面 | 键鼠操作、画面缩放和全屏 |
| 服务器状态与进程 | 查看 Linux/macOS 服务器资源占用，搜索、排序和结束进程 |
| 网络端口 | 查看 TCP 监听与 UDP 绑定端口、IPv4/IPv6 地址及进程，支持搜索、协议筛选和确认后结束端口的全部关联进程 |
| Docker 管理 | 查看 Compose 编排、容器、镜像、网络和存储卷；启停、重建和删除编排，管理容器、打开容器终端，清理未使用镜像 |
| 主机与凭据 | 用文件夹、标签和搜索整理服务，按协议保存和复用凭据 |
| 网关 | 通过 SSH 跳板机或 Page 网关连接内网的 SSH、RDP、VNC 服务 |
| 端口转发 | 在网关下设置多组端口映射，访问内网数据库等服务 |
| 动态代理 | HTTP(S) 和 SOCKS5 代理，支持全局代理及按域名、IP 规则分流 |

界面支持简体中文和英文，提供浅色、深色主题。

### 网关与内网访问

已有 SSH 跳板机时，可以直接将它添加为网关。Page 网关配合 [PagaGateway](https://github.com/mingdraw/PagaGateway) 使用，通过部署在内网的客户端连接中转服务器，访问内网的 SSH、远程桌面和其他服务。

端口转发适合访问数据库等固定地址的服务；动态代理可供浏览器和其他应用访问内网站点，支持按域名、IP 配置分流规则。

### AI 助手（可选）

配置自己的 OpenAI 或 Anthropic 兼容 API 后，可以使用 AI 助手分析终端输出、排查问题和执行服务器命令。输入 `@` 可引用 SSH 会话，支持连续对话和消息排队；执行 SSH 命令默认需要确认。

## 数据与隐私

- 主机配置、凭据和聊天记录保存在本机。
- 密码、私钥和 API Key 加密保存，SSH 连接支持主机指纹校验。
- 支持配置导入导出，导出时可设置密码加密。
- 使用 AI 助手时，消息和主动分享的会话内容会发送到你配置的 API 服务。

## 下载与安装

在 [GitHub Releases](https://github.com/mingdraw/PagaShell/releases/latest) 下载对应系统和处理器架构的安装包。Windows、macOS 和 Linux 均提供 amd64（x86_64）与 arm64（AArch64）版本。

| 平台 | 安装方式 |
|---|---|
| Windows | 解压完整 `.zip`，运行 `pagashell.exe`，保留同目录的 DLL 和 `data` 文件夹 |
| macOS | 打开 `.dmg`，将 PagaShell 拖入 Applications |
| Linux | 解压 `.tar.gz`，运行 `pagashell`；需要 GTK 3 和 libsecret |

发布页附带 `checksums.txt`，可用于 SHA-256 校验。macOS 版本尚未经过 Apple 公证，Windows 版本未使用代码签名证书。

Windows 首次运行可能出现 SmartScreen 的“无法识别的应用”提示。确认下载来源并核对校验和后，可点击 **更多信息 → 仍要运行**。

### 软件更新

支持检查 GitHub 发布的新版本，确认后自动下载、安装并重启，保留本机配置和凭据。在 **设置 → 关于** 中可手动检查更新，也可选择是否在启动时自动检查。

## 使用文档

- [Page 网关部署与连接](docs/page-gateway.md)
- [动态代理](docs/dynamic-proxy.md)
- [RDP 远程桌面](docs/rdp-service.md)
- [VNC 远程桌面](docs/vnc-service.md)
- [配置导入与导出](docs/configuration-transfer.md)
- [软件更新](docs/software-updates.md)
- [AI 助手](docs/ai-agent.md)

## 反馈与贡献

问题和建议请提交到 [Issues](https://github.com/mingdraw/PagaShell/issues)。参与开发请阅读 [贡献指南](CONTRIBUTING.md)。

## 致谢

终端界面参考并改造自 [TerminalStudio/xterm.dart](https://github.com/TerminalStudio/xterm.dart/tree/25bc19e49d9e948ba45bdb185d534c26bb3df9b2)，终端内核使用 `alacritty_terminal`。组件说明与参考来源见 [终端组件文档](docs/terminal-component.md)。

## 许可证

[MIT](LICENSE)
