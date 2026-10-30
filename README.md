# PagaShell

> 🚧 设计/开发早期阶段 · Early design stage

现代、开源、本地优先的桌面端 SSH/SFTP、RDP/VNC 客户端，基于 Flutter 构建，支持 Windows / macOS / Linux。

A modern, open-source, local-first SSH/SFTP and RDP/VNC client for desktop (Windows / macOS / Linux), built with Flutter.

## ✨ 功能状态 Feature Status

| 功能 | 当前实现 |
|---|---|
| 🗂 主机管理 | 嵌套文件夹、拖拽归档、标签字段、名称/地址/标签子串搜索 |
| 💾 本地持久化 | 元数据存 SQLite；macOS 凭据存 AES-256-GCM 保险库，主密钥存钥匙串；其他平台存系统安全存储 |
| 💻 SSH 终端 | 密码/私钥认证、多标签、批量执行命令、xterm-256color、CJK/emoji、可折叠 Linux/macOS 服务状态 |
| ⇄ 端口转发 | 网关右键打开、多组目标地址映射随网关保存、SSH / Page TCP 通道、手动启停 |
| 🌐 动态代理 | 网关独立标签、HTTP / HTTPS CONNECT / SOCKS5、规则/全局/直连、IPv4/IPv6/CIDR 和域名规则 |
| 🖥 RDP 桌面 | IronRDP、Windows 密码认证、证书确认、多种分辨率、自适应窗口、原生全屏、双向文字/文件剪贴板 |
| 🖥 VNC 桌面 | RFB 3.3/3.7/3.8、VNC 密码认证、键鼠操作、按窗口缩放、原生全屏 |
| 🔑 凭证分类 | SSH / RDP / VNC 独立类型、按服务协议筛选、旧共享凭证自动拆分并保留绑定 |
| 🌐 网关 | SSH 跳板、Page TCP 中转；支持 SSH、RDP 与 VNC 服务，SSH/RDP 目标身份独立核验 |
| 📁 SFTP | 远程目录浏览与文件操作、上传/下载、传输进度与取消 |
| 🔐 安全 | 首次主机指纹确认、可信记录持久化、后续严格校验、系统钥匙串保护、macOS 加密保险库 |
| 🤖 AI Agent | 右侧折叠/拖宽聊天面板、Markdown 回复、PagaShell/SSH/RDP 技能、@ 选择会话、SSH 输出读取、请求批准/完全访问；OpenAI/Anthropic 兼容 API、思考强度、本机加密对话历史与续聊 |

主机、凭据和配置保存在本机，无账号、同步或遥测。可选 AI Agent 使用用户配置的外部 API，发送消息、测试连接或在设置中刷新模型时发起请求；聊天和主动共享的上下文会发送给所选服务商。界面支持简体中文与 English，通过左下角「设置 → 通用」切换主题与语言；当前语言选择仅在本次运行生效。表中“当前实现”描述源码能力，不代表三个平台均已完成运行验收。

### AI Agent 与设置 / AI Agent and settings

左下角设置打开独立弹窗，用「通用 / AI 设置」Tabs 分类。通用设置保留自动/浅色/深色主题与语言；AI 设置直接填写 API 协议（OpenAI Chat Completions / OpenAI Responses / Anthropic Messages）、API 地址、API Key 和默认模型 ID。API 地址初始为空，示例仅作占位提示；接受根路径、`/v1` 或完整接口地址，远程地址使用 HTTPS，本机 HTTP 代理可用。默认模型 ID 标签右侧的刷新按钮按当前地址和 Key 获取模型列表，既可下拉选择，也可手动输入；刷新失败仍可手动保存。底部「测试连接」直接测试当前表单，显示成功或失败结果，无需先保存。已有 API Key 留空保留并复用旧值，数据库仅存密文引用；替换后清理旧密文。旧版本配置与密钥引用保留，以原先选中项作为当前 API。没有最大输出 Token 配置，OpenAI 两种格式不发送输出上限；Anthropic 的必填上限自动采用服务商模型接口返回的最大值。

点击工作区右上角的右栏按钮展开独立 Agent 区域，右栏顶部按钮可收起，拖动左边缘调整宽度；收放使用与左侧服务栏相同的滑动宽度动画，收起不留竖条。显隐、宽度和 API 设置重启后恢复。Agent 标题旁显示设置中的默认模型 ID，面板无需刷新或下拉选模型。输入框内提供思考强度，默认「自动」，按协议和服务商报告的模型能力发送参数；思考强度与审核模式均保存为全局偏好，新建、恢复历史和重启均沿用。窄窗口暂时收起左栏，让主区域与 Agent 并排显示，关闭 Agent 或加宽窗口后恢复左栏；折叠不会清空聊天与未发送输入。Enter 发送、Shift+Enter 换行，保留 Cmd/Ctrl+Enter；会话候选打开时 Enter/Tab 先选择，输入法组词确认不发送。

内置三项按需读取的技能：PagaShell 使用、SSH 运维、RDP 运维。输入 `@` 打开独立宽度、按来源分组的 Popover，当前为会话分组，显示「名称 · 终端 / 远程桌面」；可继续输入名称或地址实时筛选，支持空格分词与中文组词并保留输入焦点，点击或按 Enter/Tab 选择。可在输入框内同时插入多个高亮的 `@服务名` 引用，删改引用任意字符后取消该处高亮与关联；不会在输入框上方显示标签。引用 SSH 后分别自动读取近期屏幕和回滚输出，可继续调用读取工具，无需手动粘贴；输出最多 200 行、16000 字符。服务名称、地址、协议、状态与所选输出会发送至配置的 API，不读取其他页签、凭据保险库、主机备注或 RDP 画面。右上角「历史对话」支持找回、继续和删除记录；新建保留旧对话，历史在本机加密保存，重启后仍可查看。恢复时使用设置默认模型，需重新选择会话，审核模式沿用全局偏好，旧命令只读展示。

思考强度旁提供审核模式：默认「请求批准」，每次 SSH 输入先显示卡片，确认固定目标及完整命令后发送；「完全访问」无需逐次确认，直接向本轮引用中明确指定的一个 SSH 会话发送。多引用时工具必须提供目标会话 ID，不广播，也不能操作未引用的会话。发送后观察新输出并返回模型继续分析，长任务可再次读取；排入输入及观察到输出均不代表远端执行成功。切换页签不改变操作目标，关闭/重连后需重新选择会话，切换目标仍沿用已保存的审核模式。RDP 提供排障建议和可复制 PowerShell，不自动操作远程桌面。停止解除批准/输出等待、中止后续工具并丢弃迟到回复，已发出的 HTTP 请求可能仍由服务商处理，已发送的终端输入不会撤回。第三方模型需支持所选格式的文本聊天与工具调用。

The Agent has an independent, collapsible and resizable right sidebar. General and AI settings live in separate tabs. Configure an OpenAI Chat Completions / Responses or Anthropic Messages API, URL, key and default model, then test or save. Keys stay encrypted locally. Models are managed in settings; the Agent uses that default and shows its ID beside the title. Type `@` for a grouped popover with its own width; session names follow the tab list. Insert multiple highlighted `@service` references directly in the input to share their recent SSH screen/scrollback with the configured API. Editing any character removes that reference's highlight and association. Tools target one referenced session ID at a time; they cannot target unreferenced sessions or broadcast commands. Enter sends, Shift+Enter adds a line, and Enter/Tab selects an open suggestion; IME composition does not send. Choose Ask approval (the default) or Full access beside reasoning effort. Both preferences persist across new chats and restarts. Both modes bind inputs to the selected connection and return observed output for continued analysis; full access skips per-input approval. Output does not prove completion or success. Reconnecting requires a new selection. RDP assistance remains advisory. Chat history is encrypted locally and can be reopened, continued or deleted from the top-right history manager after restarting. New chat preserves the previous record; reopening clears session selection while retaining global modes, and archived commands are read only. See [AI Agent design and verification](docs/ai-agent.md).

### 批量执行命令 / Run commands on multiple terminals

在页签下拉菜单选择「批量执行命令」，勾选已连接的 SSH 终端（支持全选/清空），输入单行或多行命令后点击「执行命令」。命令发送到所选终端的当前会话，输出仍显示在各自页签；文件传输、端口转发及未连接页签不参与。Enter 只在输入框中换行，点击执行才发送。命令仅保留在本次弹窗内，不额外保存。

执行前请确保所选终端处于 shell 命令提示符。发送提示表示输入已提交至终端通道，不代表远端命令执行成功；关闭或断开的目标会跳过。

Choose **Run command on multiple terminals** from the tab dropdown, select connected SSH terminals, and enter a single-line or multiline command. Press Enter to add a line; click **Run command** to send it to the selected terminal sessions. Output remains in each tab. SFTP, forwarding, and disconnected tabs are excluded. Commands are not saved by this dialog. The send notification does not confirm remote command completion.

### 终端服务状态 / Terminal service status

终端右侧的“服务状态”默认收起为右上角悬浮按钮，不占终端宽度；展开后占用右侧空间，每 3 秒采集 Linux/macOS 远端的 CPU、内存、磁盘容量、网络收发与磁盘读写速率。收起、切换页签或关闭终端后停止定时采集；空间不足时自动收起为悬浮按钮。首次采样建立 I/O 速率基线；Linux CPU 也需要两次采样，macOS CPU 使用 1 秒间隔的两次 `top` 采样。采集失败时明确标记上次数据，可手动刷新。

采集使用当前已认证 SSH 连接上的独立只读命令通道，不使用交互 shell，不安装代理或要求 sudo。Linux 需能读取 `/proc`、`/sys/block` 并运行 `df`；macOS 使用系统内置的 `top`、`vm_stat`、`sysctl`、`netstat`、`ioreg` 与 `df`。其他远端系统显示暂不支持。内存使用量扣除可用/可回收页，macOS 压缩器占用计为已用；I/O 按设备列出，不累加分区或虚拟映射的重复计数。

macOS 磁盘容量仅显示启动磁盘 `/` 一项，以总容量减可用空间计算整体占用，避免 APFS 辅助卷重复展示；Linux 继续按挂载点展示。APFS 卷共享空间的说明见 [Apple 支持](https://support.apple.com/en-euro/guide/mac-help/sysp560a2952/27/mac/27)。

Service status collapses to a floating button at the terminal's top right without reserving space. When expanded, the panel occupies the terminal's right side and samples Linux/macOS CPU, memory, filesystem capacity, network throughput and disk throughput every 3 seconds while expanded in the active tab. Collection uses a separate read-only SSH channel and pauses when collapsed, hidden or closed. No remote agent or sudo is required. macOS uses two CPU samples one second apart; I/O throughput requires two snapshots. macOS capacity shows only the startup disk, using total minus available space for usage. Other remote operating systems are currently unsupported.

统计字段参考：[Linux I/O statistics](https://www.kernel.org/doc/html/latest/admin-guide/iostats.html)、[Apple top](https://github.com/apple-oss-distributions/top/blob/main/top.1)。

### 主机指纹校验

首次连接会在会话标签内展示服务器密钥类型与 SHA-256 指纹。请通过可信渠道核对，点击“信任并连接”后才进行密码或公钥认证；后续连接按服务器地址与端口自动校验。

服务器密钥变化时展示新旧指纹并阻止认证，不提供直接覆盖可信记录的按钮。可信记录独立于主机名称保存；重命名或删除后重建主机不会清除信任记录。当前不导入 OpenSSH `known_hosts`，也暂未提供可信记录管理界面。确认等待超时、取消或关闭标签会释放待认证连接。

系统钥匙串不可用时明确提示操作失败，不静默保存，也不打印可能含敏感信息的平台异常。

### macOS 钥匙串授权

macOS 由钥匙串托管一把随机主密钥，服务、网关和凭证的密码、私钥及口令统一存入本机 AES-256-GCM 保险库。每次运行解锁一次后即可复用，不再为已迁移的每个服务分别读取钥匙串。旧版条目首次使用时自动迁移；旧条目的系统访问权限仍需逐项授权，不能由应用绕过。迁移成功后，后续更新只涉及主密钥一项。

临时签名构建更新后仍可能要求授权主密钥；正式发布应保持稳定的签名身份。迁移、备份边界与验证方法见 [macOS 凭据保险库](docs/macos-keychain.md)。

### 本地端口转发

右键 SSH / Page 网关选择「端口转发」打开配置页签，在页签内维护多组「本地端口 → 目标地址:目标端口」映射。目标地址可填写内网 IP 或域名，由该 SSH 网关或 Page Client 访问；默认 `127.0.0.1` 指网关或 Client 本机。转发不需要创建 SSH 服务或登录目标的 SSH。映射随网关配置自动保存，每个网关复用一个转发页签；打开页签不会读取凭据或建立连接。本地端口和目标端口都为空的行不保存，未填完整或无效的映射需修正后才保存。升级会清除旧服务上的端口映射，请在网关下重新配置。

点击「启动转发」时保存当前映射并读取最新网关配置和凭据。本地监听 `*:本地端口`（所有 IPv4 网卡），客户端通过本机 IP 与映射端口访问目标。SSH 网关只校验并认证网关，通过 `direct-tcpip` 连接目标；Page 网关为每条本地连接建立独立中转流，目标须被 Client 的 `allowed_targets` 允许（`["*"]` 表示不限制）。Page 的「正在监听」表示本地端口就绪，目标连接错误在收到本地连接时报告，可修正目标网络或权限后重试。连接及停止期间保留映射内容，仅操作按钮显示加载状态。任一本地端口被占用时，本次启动整体失败。停止、关闭标签或删除网关会释放全部监听、活动连接及专用网关连接，其他终端和文件传输不受影响。重启应用后需手动启动；编辑运行中的映射前需先停止。

### 网关动态代理

右键 SSH / Page 网关选择「动态代理」，勾选 HTTP(S)、SOCKS5 并设置端口后手动启动。HTTP(S) 通过一个开关和端口同时代理 HTTP 与 HTTPS。默认监听 `127.0.0.1`，HTTP(S) 端口为 `18080`，SOCKS5 默认 `1080`。HTTPS 使用 CONNECT 隧道，保留目标网站的域名和 TLS，无需本地代理证书，适合通过网关访问按域名分流的 HTTPS 服务。

支持全局（全部走网关）、直连（全部由本机连接）和规则（匹配走网关，其余直连）。规则支持 IPv4、IPv6、CIDR，以及域名前缀、后缀和全匹配。配置自动保存，运行中先停止再编辑；关闭标签或删除网关会清理监听与连接。使用方法、DNS 匹配和浏览器配置见 [动态代理](docs/dynamic-proxy.md)。

### Windows RDP 远程桌面

服务支持 SSH/RDP/VNC 类型。RDP 服务可直接或通过 SSH / Page 网关连接 Windows，在独立标签中显示远程桌面并接收键鼠输入。分辨率默认为自适应窗口，也可在工具栏选择固定分辨率；可通过全屏按钮或 Ctrl+Alt+Enter 全屏显示，顶部悬浮框退出全屏；支持 macOS、Windows 和 Linux 的原生窗口接口。详见 [RDP 服务配置与验证范围](docs/rdp-service.md)。

RDP 支持双向 Unicode 文字、文件及目录复制粘贴，macOS 的 Command+C/X/V 自动映射到 Windows 的 Ctrl+C/X/V。远端文件接收完成后可在本机文件管理器粘贴，接收时显示进度并可取消；跨机文件操作按复制处理。只同步活动页签，要求 Windows 允许剪贴板重定向。RDP supports bidirectional Unicode text, files and directories over CLIPRDR, with macOS Command shortcuts and cancellable background file reception. Text and file round trips have been verified between macOS Debug and Windows; native Windows/Linux hosts still require platform testing.

### VNC 远程桌面与凭证类型

新建服务选择「VNC」，默认端口为 5900，使用 VNC 密码，不填写用户名或 Windows 域。支持直连和 SSH / Page 网关，桌面在独立页签内显示，提供键鼠、滚轮、Ctrl+Alt+Del、全屏及按窗口缩放；显示远端原有分辨率。支持标准 VNC 认证或服务端关闭认证的 RFB 3.3/3.7/3.8 服务；不支持 TLS/VeNCrypt、Apple 专有认证或动态分辨率。详见 [VNC 服务](docs/vnc-service.md)。

新建凭证时选择 SSH / RDP / VNC 类型，服务只能选择相同类型的凭证。SSH 支持密码和私钥，RDP 使用用户名与密码，VNC 只使用密码。升级时按现有服务及 SSH 网关的使用情况分类；原来同时用于 SSH/RDP 的凭证自动拆为两份并保留各自绑定，之后修改或删除一份不会影响另一份的密文。

### SSH / Page 网关

「网关」支持 SSH 与 **Page** 两种类型，在服务高级选项中绑定，用于连接内网 SSH、RDP 或 VNC 服务。SSH 使用 `direct-tcpip` 跳板。旧 RDP 网关继续停用，可改选 SSH / Page 网关，或明确取消绑定后直连。网关不可用时阻止连接。

**Page** 使用独立项目 [PagaGateway](https://github.com/mingdraw/PagaGateway)：Server 部署在本机与内网跳板都能访问的中转机，Client 放在内网跳板并主动连接 Server。链路为「PagaShell → Server ← Client → 目标服务」，支持 TLS 加密 TCP 和无证书 TCP；本机无需额外安装 Go Client。网关表单填写 Server 地址/端口、Client ID、可选证书 SHA-256 指纹和访问令牌，服务地址仍填写内网目标。Server 不配置证书/私钥时，Client 与网关指纹均留空，可通过 IP 使用未加密 TCP，英文风险提示仅在 PagaGateway Server 启动时输出。访问令牌经本机保险库保存；SSH 密钥和 RDP 证书仍在隧道内独立核验。部署步骤和对应关系见 [Page 网关](docs/page-gateway.md) 及 [PagaGateway README](https://github.com/mingdraw/PagaGateway#readme)。

### 私钥认证

在“凭证”组新建凭证，选择“私钥”，导入文件或粘贴内容；加密私钥需同时填写口令。保存前会在本机解析校验，主机可通过“已有凭证”绑定并复用。连接弹窗也支持即时提供私钥，默认不保存，勾选“保存为凭证”后才写入本地安全存储。

支持 OpenSSH、常见 PEM（PKCS#1/PKCS#8）与 PPK 私钥，文本大小最多 1 MiB；PPK 支持未加密和 `aes256-cbc` 格式。私钥只在本机用于签名，服务器接收公钥与签名。RSA 使用 SHA-2 签名；无协商信息时尝试 SHA-256，不降级到 SHA-1。

私钥与口令经本地安全存储加密保存，数据库仅保留引用。编辑时敏感字段不会预填，留空保持原私钥和口令；更换口令需重新导入私钥。密钥替换校验失败会保留原值，数据库写入失败会尝试恢复原密文并明确报告失败。

## 📦 下载与发布

从 [GitHub Releases](https://github.com/mingdraw/PagaShell/releases) 下载，Windows、macOS 和 Linux 均提供 amd64（x86_64）与 arm64（AArch64）版本。

版本更新记录见 [CHANGELOG.md](CHANGELOG.md)。

| 平台 | 安装方式 |
|---|---|
| Windows | 解压完整 `.zip`，运行 `pagashell.exe`，保留同目录的 DLL 和 data 文件夹 |
| macOS | 打开 `.dmg`，将 PagaShell 拖入 Applications |
| Linux | 解压 `.tar.gz`，运行 `pagashell`；需要 GTK 3 和 libsecret |

每次发布附带 `checksums.txt` 供 SHA-256 校验。macOS 包采用临时签名，尚未经过 Apple 公证；Windows 包未使用代码签名证书。

推送 `v*` 标签后，GitHub Actions 使用 Flutter `3.47.8` 在对应平台与架构的 runner 上构建六个包，全部成功后创建 Release；也可在 Release 工作流中指定已有标签重新构建。

## 🛠 本地开发

安装 Flutter stable 3.47+（Dart `^3.13.0`）、Rust 和目标平台工具链，然后执行：

```bash
flutter pub get
flutter run -d macos   # 也可使用 windows / linux
flutter analyze
flutter test
```

Rust 检查与代码生成命令见 [CONTRIBUTING.md](CONTRIBUTING.md)。

macOS、Windows、Linux 的应用图标由同一原图生成，资源位置与更新命令见 [应用图标](assets/branding/README.md)。

### GetX 开发约定

- 状态：主机、文件夹、凭证、会话、传输和 SFTP 浏览由 `GetxController` 与 Rx 管理，界面通过 `Obx` 订阅；短期表单和焦点状态保留在组件内。
- 路由：`ShadcnApp` 通过 `Get.key`、`GetObserver` 与 `GetPageRoute` 接入 `AppRoutes.pages`，工作区入口为 `/workspace`；对话框通过 `AppNavigation.dialog` 使用 `Get.generalDialog`，以 `AppNavigation.closeDialog(result: ...)` 返回结果，`AppNotice` 使用 shadcn Toast。
- 网络：直接使用 GetX `GetConnect` 的 `get/post/put/patch/delete`、JSON 编解码和 `Response<T>`；通过 `response.isOk`、`response.statusCode` 判断结果。`AppConnect` 仅配置 15 秒超时、不跟随重定向以及关闭时释放客户端；`AppBinding` 延迟注册 `GetConnect`，业务控制器通过构造函数注入。已移除 `JsonClient`、`NetworkException` 和旧包装；只有明确调用时才联网，无默认远程端点。
- 国际化：业务文案统一放在 `AppTranslations`，使用 GetX `.tr` / `.trParams` 和 `Get.updateLocale`；默认与回退语言为 `zh_CN`，英文为 `en_US`。中文原文作为键，动态内容用 `@name` 等参数，用户数据和未知诊断不翻译。shadcn 内置控件使用包自带的本地化委托，不使用 ARB 或 `flutter_localizations`。
- SSH/SFTP：仍通过 `SshEngine` 使用 Rust 协议栈；GetConnect 仅处理 HTTP。SFTP 浏览控制器随面板释放，关闭面板不关闭 SSH 会话。

### UI 组件与风格

界面使用 [shadcn_flutter](https://pub.dev/packages/shadcn_flutter) 的 Zinc 深色主题、Geist 字体、Lucide 图标以及按钮、输入框、卡片和徽章。欢迎页提供快速连接、新建主机和快捷键提示；侧边栏、会话标签、SFTP 工具栏及连接表单采用统一边框、间距和状态色。

应用直接以 `ShadcnApp` 启动，已移除原有 Material 主题、组件和字体配置。按钮、输入框、选择框、单选/复选、菜单、提示与进度组件统一使用 shadcn；路由和业务国际化继续由 GetX 管理。`AppTextFormField` 和 `AppSelectField` 对接 Flutter 核心 Form 校验，`AppDialog` 支持内容滚动并固定操作区。原生窗口操作和 xterm 终端保留，配色和尺寸集中在 `AppTheme`。

## 📐 设计文档

完整架构与技术选型见 [docs/DESIGN.md](docs/DESIGN.md)。

## 🛠 技术栈

Flutter · Rust SSH 引擎（[russh](https://crates.io/crates/russh) + [russh-sftp](https://crates.io/crates/russh-sftp)，[flutter_rust_bridge](https://pub.dev/packages/flutter_rust_bridge) FFI）· [xterm.dart](https://pub.dev/packages/xterm) · GetX · shadcn_flutter · drift(SQLite) · flutter_secure_storage

## 📄 License

[MIT](LICENSE)
