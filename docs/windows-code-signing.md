# Windows 代码签名政策（Code signing policy）

## 当前状态

截至 2026-11-01，PagaShell 处于测试阶段，Windows 发布包未进行 Authenticode 代码签名，暂不申请签名服务，也尚未取得 SignPath Foundation 的签名资格。本页记录当前运行方式及后续可选的免费签名方案。

SmartScreen 会判断下载文件及发布者的信誉。可信签名有助于验证发布者身份和积累信誉，但新签名程序仍可能显示提示；无法承诺首次下载立即免提示。详见 [Microsoft：SmartScreen reputation for Windows app developers](https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation)。

程序版本资源中的产品名与文件描述使用 `PagaShell`。这些字段便于识别文件及设置签名约束，本身不构成可信签名。

## 测试阶段首次运行

从项目的 GitHub Releases 下载并核对 `checksums.txt` 后，解压完整 ZIP，运行 `pagashell.exe`。出现 SmartScreen 提示时，点击 **更多信息 → 仍要运行** 手动放行。该选项受 Windows 管理策略约束。参见 [Microsoft：Publish your first Windows app](https://learn.microsoft.com/windows/apps/package-and-deploy/publish-first-app)。

## 后续可选的免费签名方案

后续需要代码签名时，可考虑申请 [SignPath Foundation](https://signpath.org/apply) 的免费开源代码签名服务，当前暂不申请。申请需要审核；基金会以自身名义提供证书，不代表开发者已获得以个人名义签发的证书。

申请条件包括开源组件许可、项目维护与信誉、可验证的构建来源、团队角色、双重验证和发布时人工批准。仅为项目自有构建产物申请签名，第三方组件按其来源及原有签名处理。完整要求以 [Foundation 条件](https://signpath.org/terms) 为准。

## 可用于申请的项目信息

| 项目 | 内容 |
|---|---|
| 项目名称 | PagaShell |
| 源码仓库与主页 | <https://github.com/mingdraw/PagaShell> |
| 正式下载 | <https://github.com/mingdraw/PagaShell/releases/latest> |
| 项目许可证 | [MIT](../LICENSE)；依赖许可证仍需逐项核对 |
| 程序形式 | Flutter 与 Rust 构建的 Windows 桌面客户端，以 ZIP 发布 |
| 目标平台 | Windows amd64、arm64；两种架构的签名配置需由服务方确认 |
| 拟申请的自有二进制 | `pagashell.exe`、`rust_lib_pagashell.dll`；最终范围由审核确认 |

英文项目说明草稿：

> PagaShell is an open-source desktop client for SSH, SFTP, RDP and VNC. It manages connections and credentials locally, supports user-configured gateways and proxies, and offers an optional AI assistant using an API selected by the user. Windows releases are built from the public repository using GitHub-hosted runners and distributed as portable ZIP archives.

如果后续申请，提交前需维护者完成：

- 确认作者、代码审阅者和签名批准人的实际账号与职责，并在本页公布经确认的成员信息。
- 确认相关 GitHub、SignPath 账号均已启用双重验证。
- 审核所有随包组件的许可证及自有、第三方二进制边界。
- 补齐安装、卸载与隐私说明，结合默认自动检查更新的行为接受服务方审核。
- 为拟签名二进制补齐并验证服务方要求的产品名、版本等属性；Rust DLL 的资源属性尚待配置。
- 由仓库所有者提交申请、接受服务条款并完成身份及项目控制权核验。

## 数据与网络行为

主机、凭据和聊天记录保存在本机。连接服务器、传输文件及代理流量涉及用户选择的远端系统；使用 AI 助手时，消息与主动分享的会话内容会发送到用户配置的 API 服务。参见 [README：数据与隐私](../README.md#数据与隐私) 和 [AI 助手](ai-agent.md)。

软件默认在启动时向 GitHub 检查正式发布版本，用户确认后下载更新。可以在设置中关闭自动更新并使用手动检查。参见 [软件更新](software-updates.md)。不能将当前行为表述为“启动时完全不联网”。

## 获批后的发布接入

当前发布工作流仍生成未签名 Windows 包。获批后按以下顺序接入 [SignPath 官方 GitHub Actions 集成](https://docs.signpath.io/trusted-build-systems/github)：

1. 在 GitHub 托管 runner 上构建、运行现有测试并校验二进制架构。
2. 将获批范围内的原始构建产物上传为 Actions artifact，保留源码与构建来源关联。
3. 通过 SignPath 官方 action 提交请求，由指定批准人确认，再下载签名结果。
4. 对下载结果执行 Authenticode 信任、签名者、时间戳和架构校验。配置了签名的发布如签名失败，应中止发布。
5. 用签名后的文件生成最终 ZIP 和 SHA-256 校验和，然后发布；签名后不再修改二进制资源。

接入时需要服务方分配的 organization ID、project slug、signing policy、artifact configuration，以及具有提交权限的 API token。API token 应保存在 GitHub Actions Secret，不能写入源码或申请文档。

Windows 验证分支统一使用 `test/windows`。在取得上述账号配置并完成实际签名验证前，发布页继续标明 Windows 包未签名；本页也不宣称已获得基金会签名支持。
