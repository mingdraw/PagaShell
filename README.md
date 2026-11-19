# PagaShell

PagaShell 是一款面向 macOS、Windows 和 Linux 的开源服务器管理工具。在同一个桌面应用里连接 SSH、传输文件、查看服务器状态，也可以打开 RDP 和 VNC 远程桌面。服务和凭据保存在本机，无需注册账号。

[下载最新版](https://github.com/mingdraw/PagaShell/releases/latest) · [使用指南](docs/user-guide.md) · [更新记录](CHANGELOG.md) · [问题反馈](https://github.com/mingdraw/PagaShell/issues)

## 下载安装

从 [GitHub Releases](https://github.com/mingdraw/PagaShell/releases/latest) 选择对应系统和架构的安装包：`amd64` 对应 64 位 Intel/AMD，`arm64` 对应 Apple 芯片和其他 64 位 ARM。

| 系统 | 安装方式 |
|---|---|
| macOS | 打开 `.dmg`，将 PagaShell 拖入「应用程序」。 |
| Windows | 将 `.zip` 完整解压到独立文件夹，运行 `pagashell.exe`，保留同目录的 DLL 和 `data`。 |
| Linux | 解压 `.tar.gz` 后运行 `./pagashell`，系统需安装 GTK 3 和 libsecret。 |

发布页提供 `checksums.txt`，可核对安装包的 SHA-256。macOS 发布包尚未公证，Windows 发布包未签名。Windows 首次运行如遇 SmartScreen 提示，请先确认下载来源和校验和，再选择「更多信息 → 仍要运行」。

已安装的版本可在「设置 → 关于」检查更新。详细步骤见[软件更新](docs/software-updates.md)。

## 第一次连接

1. 在左侧「服务」组的菜单中选择「新建服务」。
2. 选择 SSH、RDP 或 VNC，填写目标地址和登录信息。需要复用密码或私钥时，可先在左侧「凭证」组创建对应类型的凭证。
3. 点击「保存并连接」。首次 SSH 连接时，核对主机指纹后再选择「信任并连接」。

临时连接 SSH 可按 `⌘K`（macOS）或 `Ctrl+Shift+K`（Windows/Linux）打开命令面板，直接输入 `user@host` 或 `user@host:port`。

## 主要功能

| 场景 | 可以做什么 |
|---|---|
| SSH 终端 | 多标签、左右或上下分屏，拖入其他 SSH 服务，在同一标签内同步输入，查找回滚输出。 |
| SFTP 文件传输 | 双栏浏览、筛选、拖放上传和下载，新建目录、查看或编辑小文本文件，查看传输速率和剩余时间。 |
| 远程桌面 | RDP 支持分辨率调整、全屏及双向复制文字和文件；VNC 支持键鼠、缩放和全屏。 |
| 服务器运维 | 查看服务状态、进程和网络端口；管理 Docker 资源、打开容器终端或查看实时日志。 |
| 服务与内网访问 | 用文件夹、标签和搜索整理服务，复用凭证，使用 SSH 或 Page 网关、端口转发和动态代理。 |
| Agent（可选） | 使用自配的 OpenAI 或 Anthropic 兼容 API，引用会话分析终端输出，流式接收回复，审阅后发送 SSH 命令。 |

界面支持简体中文和英文，可切换浅色、深色主题，或跟随系统。

## 使用文档

第一次使用可从[使用指南](docs/user-guide.md)开始，里面有连接步骤、常用快捷键，以及终端、SFTP 和运维侧板的操作说明。

| 专题 | 文档 |
|---|---|
| 远程桌面 | [RDP](docs/rdp-service.md) · [VNC](docs/vnc-service.md) |
| 内网访问 | [Page 网关](docs/page-gateway.md) · [动态代理](docs/dynamic-proxy.md) |
| AI 助手 | [Agent 配置、会话引用与命令审批](docs/ai-agent.md) |
| 本机管理 | [配置导入和导出](docs/configuration-transfer.md) · [软件更新](docs/software-updates.md) |

## 数据与隐私

- 服务配置保存在本机，密码、私钥和 API Key 通过本机凭据保险库加密保存。Agent 聊天记录也在本机加密保存。
- 使用 Agent 时，消息和所引用会话的相关上下文会发送到你配置的 API 服务。默认「请求批准」模式下，SSH 命令须经确认才会发送。
- 配置导出可包含已保存的密码和私钥。迁移到其他设备时，建议勾选加密。

## 反馈与贡献

欢迎在 [Issues](https://github.com/mingdraw/PagaShell/issues) 提交问题和建议。开发环境、构建和测试命令见[贡献指南](CONTRIBUTING.md)，项目结构见[设计文档](docs/DESIGN.md)。

终端界面参考并改造自 [TerminalStudio/xterm.dart](https://github.com/TerminalStudio/xterm.dart/tree/25bc19e49d9e948ba45bdb185d534c26bb3df9b2)，终端内核使用 `alacritty_terminal`。详见[终端组件文档](docs/terminal-component.md)。

## 许可证

[MIT](LICENSE)
