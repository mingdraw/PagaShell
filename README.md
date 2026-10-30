# PagaShell

PagaShell 是一个开源桌面客户端，用来连接服务器、传输文件和使用远程桌面，支持 Windows、macOS 和 Linux。

SSH、SFTP、RDP 和 VNC 会话可以分别打开标签。主机、凭据和网关集中管理，既能直连服务器，也能通过 SSH 跳板机或 Page 网关访问内网。

[下载最新版](https://github.com/mingdraw/PagaShell/releases/latest) · [更新记录](CHANGELOG.md) · [问题反馈](https://github.com/mingdraw/PagaShell/issues)

## 功能

| 功能 | 说明 |
|---|---|
| SSH 终端 | 多标签会话、密码和私钥登录、批量执行命令，查看 Linux/macOS 服务器状态 |
| SFTP 文件传输 | 浏览本地和远程文件，拖放上传、下载，查看进度或取消传输 |
| RDP 远程桌面 | 连接 Windows 桌面，自适应分辨率、全屏，双向复制粘贴文字、文件和文件夹 |
| VNC 远程桌面 | 键鼠操作、画面缩放和全屏 |
| 主机与凭据 | 用文件夹、标签和搜索整理服务，按协议保存和复用凭据 |
| 网关 | 通过 SSH 跳板机或 Page 网关连接内网的 SSH、RDP、VNC 服务 |
| 端口转发 | 在网关下设置多组端口映射，访问内网数据库等服务 |
| 动态代理 | HTTP(S) 和 SOCKS5 代理，支持全局代理及按域名、IP 规则分流 |

界面支持简体中文和 English，提供浅色、深色主题。

### 网关与内网访问

已有 SSH 跳板机时，可以直接将它添加为网关。Page 网关配合 [PagaGateway](https://github.com/mingdraw/PagaGateway) 使用，由内网客户端主动连接中转服务器，再通过网关访问内网服务。

右键网关可打开端口转发或动态代理。端口转发适合数据库等固定地址的服务；动态代理适合浏览器和其他应用访问内网站点。

### AI 助手（可选）

配置自己的 OpenAI 或 Anthropic 兼容 API 后，可以在侧边栏使用 AI 助手。输入 `@` 选择 SSH 会话，让助手结合终端输出分析问题、给出命令建议；执行 SSH 命令默认需要确认。

## 数据与隐私

- 无需注册账号，主机、凭据和聊天记录保存在本机。
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

## 使用文档

- [Page 网关部署与连接](docs/page-gateway.md)
- [动态代理](docs/dynamic-proxy.md)
- [RDP 远程桌面](docs/rdp-service.md)
- [VNC 远程桌面](docs/vnc-service.md)
- [配置导入与导出](docs/configuration-transfer.md)
- [AI 助手](docs/ai-agent.md)

## 反馈与贡献

问题和建议请提交到 [Issues](https://github.com/mingdraw/PagaShell/issues)。参与开发请阅读 [贡献指南](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)
