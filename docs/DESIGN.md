# PagaShell 设计文档

> 一款基于 Flutter 的开源桌面端 SSH/SFTP 管理工具（Windows / macOS / Linux）。
>
> 状态：设计阶段 · 2026-07

---

## 1. 产品定位

**一句话定位**：本地优先、颜值在线、开箱即用的现代 SSH/SFTP 客户端，把「主机管理 + 终端 + 文件传输 + 端口转发」整合进一个跨平台桌面应用。

**核心原则**：

1. **本地优先**：主机、凭据与设置存本地，无账号或云同步；AI Agent 可按用户配置调用外部 API，仅发送聊天和主动共享的上下文。跨设备迁移通过配置文件导出/导入（可选密码加密）。
2. **安全默认（Secure by default）**：凭据加密存储、严格的主机指纹校验，私钥不进入普通存储或日志；用户主动导出私钥文件时仅写入所选位置。
3. **Rust 内核**：SSH/SFTP 协议栈用 Rust 实现（russh），经 flutter_rust_bridge FFI 接入，三平台行为一致、性能与内存安全兼得。
4. **开源透明**：所有网络行为可审计，除更新检查外不产生任何遥测。

**目标用户**：后端/运维工程师、需要频繁管理多台服务器的开发者、觉得 Termius 收费太贵/Xshell 不跨平台/Tabby 太重的用户。

### 1.1 竞品对照

| 产品 | 平台 | 开源 | 痛点 |
|---|---|---|---|
| Termius | 全平台 | ❌ | 同步/SFTP 等核心功能订阅制，数据走云端 |
| Xshell/Xftp | 仅 Windows | ❌ | 不跨平台，商用收费 |
| FinalShell | 三平台 | ❌ | 闭源，UI 过时，安全性存疑 |
| Tabby | 三平台 | ✅ | Electron，内存占用高，SFTP 弱 |
| WindTerm | 三平台 | 部分 | 半开源，作者停更风险 |
| electerm | 三平台 | ✅ | Electron，性能一般 |

**PagaShell 的差异化**：Flutter 原生渲染（启动快、内存低于 Electron 系）、SSH + SFTP + 转发一体、完全免费开源、本地优先。

---

## 2. 功能设计

### 2.1 MVP（v0.1 ~ v0.3）

**主机管理**
- 主机 CRUD：地址、端口、用户名、备注、标签、颜色标记
- 侧边栏三个内置根组：「服务」「凭证」「网关」；网关右键打开端口转发页签，映射保存在网关配置内。凭证、网关使用独立目录空间，组间不可互相拖入；内置组不可重命名、不可删除，仅可折叠
- 可嵌套文件夹组织主机（侧边栏树形展示、展开/折叠、右键新建子文件夹/重命名/删除，删除时内容上移父级）+ 标签双维度组织，全局模糊搜索（搜索时回退平铺列表）
- 同级下不允许重名：同一父级内文件夹名唯一、同一文件夹内主机名唯一（表单就地报错；删除文件夹内容上移遇冲突自动追加「 (2)」后缀）
- 树形整理：同级文件夹与主机共用可自由调整的顺序，新增项追加到同级末尾；拖到行的上下边缘调整顺序，拖到文件夹中间移入其中（放下后自动展开），拖到「主机」组头移到根级末尾。文件夹移动时保留整棵子树；拒绝同级重名、自身与子文件夹落点；顺序与层级一同持久化
- 凭证树沿用相同的嵌套、排序、追加与文件夹菜单交互，独立存储凭证文件夹；拖到「凭证」组头回到根级末尾，主机和凭证不能互相拖入。文件夹使用 `LucideIcons.folderKey`，凭证使用 `LucideIcons.fileKey`。删除文件夹将内容上移并处理同级重名；移动和编辑保留密文引用及主机绑定
- 认证方式：已实现密码 / 私钥（OpenSSH、PEM、PPK 导入，支持口令解锁）；keyboard-interactive 与 SSH agent 尚未接入。RSA 仅使用 SHA-2 签名
- 登录方式二选一：主机自有「账号密码」（密码按主机存系统钥匙串，仅本机使用），或绑定「已有凭证」（Identity，同一份「用户名+密码/密钥」多台主机复用）
- 主机的新建/编辑不含文件夹选择，归属由入口上下文决定（根组/文件夹右键「在此新建主机」）
- 服务支持 SSH / RDP / VNC 类型，旧服务默认为 SSH。RDP 服务通过 IronRDP 显示和操作 Windows 桌面，使用账号密码及可选 Windows 域；通过 Display Control 动态通道切换预设分辨率或自适应窗口。VNC 使用 vnc-rs 处理标准 RFB 3.3/3.7/3.8，提供密码认证、画面、键鼠与按窗口缩放，不改变远端分辨率。两种桌面均复用原生全屏与悬浮退出，直连无需配套程序。功能与边界见 [RDP 远程桌面](rdp-service.md) 和 [VNC 远程桌面](vnc-service.md)。
- 凭证分 SSH / RDP / VNC 类型，服务与凭证必须协议一致；SSH 支持密码和私钥，RDP 只使用账号密码，VNC 只使用密码。旧凭证按实际绑定升级，同时用于 SSH/RDP 时拆分并保留绑定；拆分密文引用在修改时独立分配，删除时保留其他凭证仍使用的密文。
- 网关支持 SSH / Page。SSH 使用账号密码或密码/私钥凭证，通过 `direct-tcpip` 跳转；Page 通过独立 Go 项目 PagaGateway 的 Server / Client 进行可选 TLS 的 TCP 中转，Client 从内网主动连接 Server。指纹为空时使用未加密 TCP，英文风险提示仅由 PagaGateway Server 在启动时输出。SSH/RDP 目标独立核验身份并认证，VNC 按服务端提供的标准认证方式连接。服务表单「高级选项」可选网关或恢复直连；SSH 终端、SFTP、状态、端口转发及 RDP/VNC 桌面按标签独立持有和释放连接。网关不可用时拒绝连接；被引用网关需先解除绑定再删除。部署和信任模型见 [Page 网关](page-gateway.md)。

**SSH 终端**
- 基于 xterm.dart 的完整终端模拟（VT100/xterm-256color、CJK、emoji）
- 多标签 + 同一窗口内水平/垂直分屏
- 标签策略：默认每台主机一个标签；双击主机聚焦已有标签（无则新建连接）；同一主机多开会话走右键菜单「新建会话」；shell 结束（exit/断网）自动关闭标签
- 复制粘贴（右键/快捷键/选中即复制可选）、查找、滚动回放、字体字号调节
- 连接保活（keepalive）、断线提示与一键重连
- 终端主题（内置若干配色 + 自定义）
- 终端右侧可折叠 Linux/macOS 服务状态，收起时仅显示右上角悬浮按钮且不占终端宽度，展开后占用右侧空间：活动页签展开时每 3 秒通过独立 SSH exec 通道只读采集 CPU、内存、磁盘容量、网络与磁盘 I/O。CPU 可展开查看各逻辑核心的占用率；Linux 读取 `/proc/stat`，macOS 通过系统自带 JXA 调用 Mach 读取核心累计计数，使用相邻采样增量计算，首次采样及计数重置时等待下一次采样。I/O 同样使用增量基线，macOS CPU 汇总仍使用两次间隔 1 秒的 top 采样。收起、隐藏或关闭时暂停，空间不足时自动收起为悬浮按钮。采集失败保留并标记上次数据，不向交互 shell 写入命令

**SFTP 文件管理**
- 主机右键「新建文件传输」打开独立 SFTP 标签，可重复新建；使用独立 SSH 连接，不启动 shell，终端退出不会中断文件传输
- 双栏视图：左侧本地目录，右侧远程目录（均从家目录起步，上级/进入/刷新；本地可通过系统选择器切换目录）
- 文件可在两侧双向拖放，落到空白区域传入该侧当前目录，落到文件夹行传入该文件夹；双击文件或行菜单也可上传/下载，同名文件需确认覆盖。当前传输对象为文件，目录支持浏览和作为落点
- 保留系统文件选择器多选上传、远程新建目录/重命名/递归删除；传输核心在 Rust 侧（64KB 分块、进度节流上报、可取消、取消/失败自动清理半成品文件）
- 标签底部传输条显示进度、取消和清除已完成；传输结束刷新目标侧列表，关闭标签先取消该连接在途任务再断开连接
- 规划：系统文件管理器拖入、目录递归上传/下载、传输队列并发数控制与失败重试、权限修改（chmod）/软链接查看、路径栏直接输入跳转、隐藏文件开关

**本地端口转发**
- 每个 SSH / Page 网关保存多组「本地端口 → 目标地址:目标端口」映射；在网关右键「端口转发」打开的页签内添加、编辑及删除，修改后自动保存。本地端口不可重复，配置可以为空，两端口都空的行不保存，不完整或无效输入不覆盖已存配置；启动时至少需要一组有效映射
- 每条映射配置目标 IP 或域名，由 SSH 网关或内网 Page Client 访问；默认 `127.0.0.1` 指该网关或 Client 本机。只使用网关凭据，无需目标 SSH 服务、账号或主机密钥
- 本地固定监听 `*`（`0.0.0.0`，所有 IPv4 网卡），每条本地连接使用独立 SSH `direct-tcpip` 通道或 Page 中转流；全部端口绑定成功才启动，任一端口被占用则整体回滚。Page 启动仅表示本地监听就绪，接收连接后按目标独立鉴权、校验允许列表和建立中转，单次目标失败保留监听供重试
- 每个网关复用一个转发页签，打开时不读取凭据或建立连接；点击启动时先保存映射，再读取最新网关和凭据，不启动 shell，不依赖终端或 SFTP 的生命周期
- 运行页的地址及端口输入区域随窗口宽度铺满，删除按钮位于每行右侧；展示监听状态与错误，可停止及重新启动；连接和停止期间保留内容，仅操作按钮显示加载状态，SSH 网关首次指纹确认内嵌在运行页。侧栏图标保持原色。停止、关闭标签或 SSH 断线时释放全部监听、活动 TCP 连接与专用网关连接。运行中需先停止再编辑映射，删除网关时同时删除映射并关闭该转发页签
- 配置持久化，应用重启后不自动启动；远程转发与自动启动仍为后续规划

**网关动态代理**
- 每个 SSH / Page 网关独立保存 `ProxyConfig`，右键「动态代理」打开唯一的配置页签，不读取凭据。HTTP(S)、SOCKS5 CONNECT 可独立勾选和配置端口；HTTP(S) 共用一个开关和端口，同时处理 HTTP 请求与 HTTPS CONNECT；相同端口共用监听，固定绑定本机 `127.0.0.1`
- `DynamicProxyEngine` 创建独立代理会话：全局全部走网关，规则模式按 IPv4/IPv6/CIDR 或域名前缀/后缀/全匹配选路，未匹配直连；旧直连模式归并为规则模式。域名先匹配域名规则，未命中且存在 IP 规则时用本机 DNS 结果匹配，解析失败报错；网关目标仍使用原始域名，网关失败绝不自动回退直连
- Rust 使用 Hyper 流式转发 HTTP 请求和响应，HTTPS 通过 CONNECT 双向透传网站 TLS，SOCKS5 支持 IPv4/IPv6/域名的无认证 TCP CONNECT。SSH 仅认证专用网关连接，Page 每次建立自己的中转流；不登录目标 SSH，不改 hosts
- 启动按钮旁提供「自动设置系统网络代理」，默认关闭并随网关保存。macOS 通过 SystemConfiguration/Authorization Services 设置当前主网络服务，Windows 通过 WinINet 设置当前用户默认 LAN 代理，Linux 支持 GNOME GSettings 与 KDE 5/6 KConfig。应用内互斥所有权，已有代理/PAC/WPAD 时拒绝覆盖；监听成功后设置、失败回滚，停止及正常退出先条件恢复再关闭监听。其他应用接管时保留其设置；恢复失败保留标签和监听供重试并取消退出。macOS GitHub 构建取消 App Sandbox，数据库与保险库沿用各自已有容器路径
- 全部端口绑定成功才 ready，失败整体回滚；停止、关闭、删除网关时取消协商、活动隧道和 HTTP 驱动并等待监听释放。启动中可停止，同一网关再次启动等待旧任务清理；代理、端口转发和终端生命周期互相独立。配置自动保存，运行中不可编辑，重启应用后手动启用。详情见 [动态代理](dynamic-proxy.md)

**安全与存储**
- 元数据（文件夹 / 主机 / 凭证 / 端口转发配置）持久化到 drift(SQLite)，库文件位于系统应用支持目录
- macOS 以系统钥匙串托管单个随机主密钥，密码 / 私钥 / 私钥口令存本机 AES-256-GCM 保险库；Windows / Linux 直接使用系统安全存储（DPAPI / Secret Service）。绝不明文入库或日志；私钥与口令共享一个 `secretRef`，编辑留空保留原值，替换前进行本机解析校验
- 凭证与主机解耦：凭证可在相同协议的服务间复用，主机绑定后自动读取本机密文连接
- 主机指纹校验已接入：可信摘要按协议、地址与端口存 SQLite，SSH 主机密钥与 RDP TLS 证书分别记录。SSH 首次连接在会话内确认，密钥变化时拒绝认证；连接错误页提供「清除指纹并重试」，仅清除发生变化的目标或 SSH 网关的旧记录，重连后仍须明确确认新指纹；旧记录已被并发更新时不会误删。RDP 通过本机信任根检查证书链、有效期与地址，首次连接、证书变化或验证失败时弹框提示并可查看指纹；用户可取消或明确确认本次例外后连接，例外不覆盖已保存证书，下次仍提示。暂未提供完整可信记录管理界面或 OpenSSH known_hosts 导入
- 可选应用主密码（不设则用系统钥匙串静默解锁）

**配置迁移与私钥导出**
- 左侧栏展开时，左下角设置按钮旁提供导入、导出配置按钮。服务、凭证、SSH / Page 网关及其文件夹、混合排序、绑定关系和端口映射可迁移，密码、私钥和私钥口令一同进入 `.pagashell` 文件。默认不加密，勾选“加密”后显示密码框并加密导出。
- 导入自动识别格式：未加密文件校验后直接写入，加密文件输入密码后校验、写入。同 ID 更新，本机独有项保留，同级同名的不同 ID 自动编号。新凭据在本机分配新密文引用，绝不采用文件提供的钥匙串引用。
- 私钥凭证支持导出当前填写或已保存的原始私钥文件，保留原格式及加密状态，不附加口令。详见 [配置迁移](configuration-transfer.md)。

**AI Agent 与设置**
- 形成左侧服务树、中间完整会话卡片、右侧独立 Agent 栏的布局；Agent 位于会话卡片外侧，与左栏使用相同的滑动宽度过渡，收起零占宽，聊天可拖宽。窄窗口展开 Agent 时临时收起左栏，中间与右栏保持并排；关闭 Agent 或加宽窗口后恢复左栏，保留原显隐偏好、聊天与输入。
- 独立设置弹窗以「通用 / AI 设置」Tabs 分类。通用保留主题与语言，AI 直接配置一组外部 API 协议、地址、Key、默认模型 ID，并测试当前填写的连接。模型目录刷新和选择均在设置内完成；Agent 标题旁显示默认模型 ID，所有聊天使用当前设置。
- 使用 GetConnect 直接访问 OpenAI Chat Completions / Responses 或 Anthropic Messages 兼容 API，内置 PagaShell、SSH 运维、RDP 运维三种按需技能和有界工具循环。模型地址为空默认值，模型 ID 支持刷新下拉与手动输入；无需配置输出 Token 上限。
- 输入 `@` 使用独立宽度、按来源分组的 Popover，当前提供会话分组，命名与页签列表一致（名称 · 终端/远程桌面）。选择已连接会话后绑定该连接，自动读取近期 SSH 终端输出；切换页签不改变目标，关闭或重连后需重新选择。默认请求批准后才向该终端发送输入，可切换完全访问直接发送；两种模式均将随后观察到的输出返回模型继续分析，RDP 无自动操作。
- 输入框内提供思考强度，默认自动；按 OpenAI Chat Completions、Responses 或 Anthropic 的能力映射参数，工具往返保留原始思考块与签名。Enter 发送，Shift+Enter 换行，候选打开时 Enter/Tab 先选择；输入法组词确认不发送。
- API Key 进入 SecretStore，非敏感 API 配置、面板宽度/显隐、思考强度与审核模式存现有 app_settings，不增加 schema。两项模式为全局偏好，新建、恢复、切换目标和重启均沿用。历史对话整体加密保存，数据密钥进入 SecretStore；右上角历史管理支持重启后找回、继续和删除，新建保留旧记录。恢复对话不恢复会话绑定或待批准命令句柄，命令卡片只读。兼容并保留旧版配置及密钥引用，详见 [AI Agent](ai-agent.md)。

### 2.2 v1.0

- **端口转发扩展**：远程转发（-R）、随网关自动启动；本地转发及网关 HTTP/HTTPS/SOCKS5 动态代理已实现
- **跳板机**：已支持独立网关的单级跳转；多级链式跳转仍为后续规划
- **代码片段（Snippets）**：常用命令库，支持变量占位符，一键发送到当前/多个会话
- **本地终端**：flutter_pty 打开本机 shell（PowerShell / zsh / bash），与 SSH 标签统一管理
- **密钥管理器**：生成 Ed25519/RSA 密钥对、一键部署公钥到服务器（ssh-copy-id 等价物）
- **导入扩展**：解析 `~/.ssh/config` 导入主机；配置文件迁移已实现，支持可选密码加密
- **批量操作**：多选主机同时打开、向多个会话广播输入

### 2.3 v1.x+（远期）

- SSH Agent 集成（Pageant / ssh-agent / 1Password agent socket）
- 端到端会话录制与回放（asciinema 格式）
- 串口 / Telnet / Mosh 支持
- 插件系统与主题市场

**明确不做**：Web 版、移动端、任何形式的云同步或自建账号体系。数据完全本地保存和维护，跨设备迁移通过「配置文件导出/导入（可选密码加密）」完成。

---

## 3. 技术选型

| 领域 | 选择 | 理由 |
|---|---|---|
| 框架 | Flutter 3.47+ (stable) / Dart 3.13+ | 三平台单代码库，满足 shadcn_flutter 工具链要求 |
| UI 组件 | shadcn_flutter | ShadcnApp 直接提供 Zinc 浅色/深色主题、Geist 字体、Lucide 图标及页面/弹窗组件；移除 Material 兼容层 |
| SSH/SFTP 引擎 | Rust：[russh](https://crates.io/crates/russh) + [russh-sftp](https://crates.io/crates/russh-sftp)，经 [flutter_rust_bridge](https://pub.dev/packages/flutter_rust_bridge) FFI 接入（cargokit 随 flutter build 自动编译） | 内存安全、性能强、协议实现活跃维护；密集 IO 在 Rust 侧 tokio 运行时处理，不占用 Dart isolate；域接口 `SshEngine` 隔离，UI/应用层零感知 |
| 终端模拟 | [xterm](https://pub.dev/packages/xterm) ^3.2+ | 与 dartssh2 同团队，60fps、CJK/emoji、可换主题，官方有 SSH 示例 |
| 本地终端 | flutter_pty | 同团队的 PTY 封装 |
| 状态管理 | GetX (get) | Rx/Obx 响应式状态与 Bindings 依赖装配；SFTP 浏览按面板生命周期创建控制器。控制器通过构造函数注入依赖，不在内部 Get.find |
| HTTP 网络请求 | GetX GetConnect | 直接使用原生 HTTP 方法、JSON 和 `Response<T>`；`AppConnect` 仅负责超时、重定向配置与释放，延迟注册、构造注入，无默认远程端点，SSH/SFTP 仍由 Rust 处理 |
| 数据库 | drift (SQLite) + drift_flutter | 类型安全、支持迁移、桌面端成熟；存文件夹/主机/凭证元数据，连接惰性打开 |
| 密钥托管 | flutter_secure_storage + cryptography | macOS 钥匙串只托管保险库主密钥，本地文件只保存 AES-256-GCM 密文；Windows / Linux 密文直接存 DPAPI / Secret Service。macOS 用传统 login keychain（`usesDataProtectionKeychain: false`）：默认的 Data Protection Keychain 需要 keychain-access-groups 授权 + 证书签名，无证书开发构建会报 -34018 |
| 加密 | cryptography / pointycastle | AES-256-GCM 字段加密、Argon2id 派生主密码 |
| 窗口 | window_manager + tray_manager + hotkey_manager | 自定义标题栏、托盘、全局快捷键 |
| 布局 | multi_split_view | 终端分屏、SFTP 双栏 |
| 拖拽/文件 | desktop_drop + file_selector | 拖拽上传、本地文件选择/另存为（官方桌面实现，避开 win32 版本冲突） |
| 路由 | GetX GetPage / Get.generalDialog | ShadcnApp 使用 Get.key、GetObserver 与 GetPageRoute 接入 `/workspace`；AppNavigation 封装对话框与结果返回，多会话标签由 SessionController 管理 |
| 国际化 | GetX Translations | `AppTranslations` 管理中英文，`.tr` / `.trParams` 解析文案，`Get.updateLocale` 即时切换，默认/回退为中文；shadcn 内置控件使用包自带 delegates，不使用 ARB 或 flutter_localizations |
| CI/CD | GitHub Actions | 三平台矩阵构建 + Release 产物 |

**风险与对策**：

| 风险 | 对策 |
|---|---|
| Rust FFI 增加构建链复杂度（三平台交叉编译、贡献者需装 Rust） | cargokit 已把 Rust 编译并入 flutter build；CI 缓存 cargo 产物；CONTRIBUTING 写明工具链要求 |
| 首次连接的主机身份需用户独立核验 | 同一条连接先握手获取指纹，经用户确认并持久化后才发送密码；后续严格匹配，重协商拒绝替换密钥 |
| xterm.dart 大量输出时性能 | 限制 scrollback 行数（默认 10k 可调）；输出节流合并渲染 |
| Linux 无桌面钥匙串（headless/精简发行版） | 回退到主密码派生密钥的纯文件加密方案 |
| PPK / OpenSSH 新格式私钥解析 | 内置格式转换层，必要时引导用户用 ssh-keygen 转换并给出确切命令 |

---

## 4. 架构设计

分层架构 + 单向依赖（UI → Application → Domain ← Infrastructure）：

```
┌─────────────────────────────────────────────────────┐
│  Presentation (Flutter Widgets)                     │
│  主机列表 / 终端视图 / SFTP 面板 / 转发面板 / 设置       │
├─────────────────────────────────────────────────────┤
│  Application (GetX Controllers, AppBinding 装配)     │
│  SessionController · TransferQueue                  │
│  HostController · SettingsController                │
├─────────────────────────────────────────────────────┤
│  Domain (纯 Dart，无 Flutter 依赖)                    │
│  实体: Host / Identity / Snippet / ForwardPort …    │
│  接口: SshEngine / VaultRepository / HostRepository  │
├─────────────────────────────────────────────────────┤
│  Infrastructure                                     │
│  RustSshEngine (FFI 适配) · DriftDatabase            │
│  SecureVault (钥匙串+AES-GCM) · SshConfigImporter    │
├─────────────────────────────────────────────────────┤
│  Rust Engine (rust/, russh + russh-sftp, tokio)     │
│  连接/认证 · shell+PTY · SFTP · 本地多端口转发         │
└─────────────────────────────────────────────────────┘
```

### 4.1 核心运行时对象

- **`SessionController`**：全局 GetX 控制器，持有所有活动会话。以 `SessionKind` 区分终端、文件传输、端口转发与远程桌面标签；只有 SSH 终端启动 shell。RDP / VNC 服务分别使用 `RdpEngine` / `VncEngine`，共享桌面帧、指针与显示组件，VNC 键盘使用 X11 keysym。双击聚焦已有桌面、右键「新建会话」新开标签。SSH 文件传输与网关端口转发保持独立连接；端口转发由 `GatewayForwardEngine` 创建网关连接，桌面服务不提供 SSH 文件传输入口。所有标签统一关闭、取消与释放资源。
- **`Session` 状态机**：`connecting → authenticating → hostkeyPending → ready → reconnecting → closed`，UI 按状态渲染（指纹确认弹窗即 `hostkeyPending`）。
- **`TransferQueue`**：全局传输队列，任务持久化（应用崩溃后可恢复未完成任务），并发 worker 数可配，单任务支持进度流、暂停、重试。
- **`GatewayController`**：网关的端口映射经网关树仓库事务保存，只更新最新网关记录中的映射字段；运行连接及启停清理由 `SessionController` 管理，本地端口绑定和 TCP 转发由 Rust 执行。

### 4.2 连接建立时序（含跳板机）

```
用户点击主机
 → SessionController.open(host)
 → 若配置 SSH 网关：网关握手 → 网关指纹确认 → 网关认证 → direct-tcpip 目标通道
 → 若配置 Page 网关：指纹非空时固定指纹验证 Server TLS，空时用未加密 TCP → 访问令牌 → 内网 Client TCP 目标通道
 → SSHClient 握手 → 校验 host key（对照本地 known_hosts 库）
     ├─ 未知指纹 → UI 弹窗确认 → 存库
     └─ 指纹变化 → 红色强警告，默认拒绝
 → 认证（密钥优先 → 密码 → keyboard-interactive）
 → 按标签类型启动 shell 或 SFTP
 → 会话 ready；各标签使用独立连接

网关端口转发：打开网关页签 → 保存映射 → 读取网关凭据
 → SSH：握手、确认网关指纹、认证；Page：创建中转配置句柄
 → 绑定全部本地端口 → ready
 → 每条本地连接经网关访问配置的目标地址和端口
```

---

## 5. 数据模型

```
Identity(id, name, username, serviceType[ssh|rdp|vnc]=ssh, authType[password|key|agent],
         secretRef→Vault, folderId?, sortOrder, keyRef→Vault, createdAt)

Host(id, name, hostname, port=22, identityId?, groupId?,
     tags[], color, gatewayId?, charset, note,
     startupSnippetId?, sortOrder, lastConnectedAt, forwardPorts[],
     serviceType[ssh|rdp|vnc]=ssh, gatewayType[ssh|page]=ssh, rdpDomain?,
     pageClientId, pageServerFingerprint)

Group(id, name, parentId?, sortOrder)

Gateway: 复用 Host 元数据；Hosts/Folders 的 isGateway 区分独立网关目录空间，
         gatewayType 支持 ssh/page，服务协议由独立的 serviceType 维护，
         服务的 gatewayId 引用网关；网关自身不配置上级网关，密文仍存 SecretStore

IdentityFolder(id, name, parentId?, sortOrder)  // 与主机文件夹独立

KnownHostKey(id, hostPattern, keyType, fingerprintSha256, addedAt)

Snippet(id, name, command, variables[], scopeTags[])

ForwardPort(localPort, targetHost='127.0.0.1', targetPort)
// 映射保存在网关的 Host.forwardPorts 内，随网关编辑、移动、复制与删除

TransferTask(id, sessionHostId, direction[up|down], localPath,
             remotePath, size, transferred, status, error?)

Settings(theme, terminalFont, fontSize, scrollback, keepaliveSec,
         locale, confirmOnExit, reuseConnection, ...)
```

当前数据库 schema 为 13：新增 `proxy_config_json` 保存网关动态代理配置；从 12 升级保留网关端口映射，从更早版本升级仍按原有规则清除旧服务映射。保留历史 `gateway_type` 列，服务按 `serviceType` 读写 SSH/RDP/VNC 协议，网关加载和写入 SSH/Page。凭证新增 `service_type`，升级根据服务和网关的绑定分类，跨协议共享凭证拆分并重绑；无绑定凭证默认 SSH。`pageClientId` 与 `pageServerFingerprint` 默认为空，Page 访问令牌仍存 SecretStore。Windows 域只用于 RDP 服务。旧 RDP 网关继续停用、隐藏并保留服务引用；需改选 SSH/Page 或明确取消绑定后直连。可信记录主键包含协议，隔离 RDP 证书和 SSH 密钥；标准 VNC 不提供目标证书或主机密钥校验。映射按顺序存于 `forwardPortsJson`；历史升级中移除旧独立转发表，不迁移未发布转发配置。服务、网关、凭证及其他配置保留。桌面功能见 [RDP 远程桌面](rdp-service.md) 和 [VNC 远程桌面](vnc-service.md)，中转部署和验证边界见 [Page 网关](page-gateway.md)。

**加密边界**：密码、私钥、passphrase 一律不进 `Host`/`Identity` 表，只保留 `SecretStore` 引用。macOS 已实现 *钥匙串中的随机 256 位主密钥 → AES-256-GCM 加密文件*：`credentials.vault` 位于应用支持目录，版本作为认证数据，每次写入使用独立随机 nonce；进程内排队、进程间文件锁以及同文件系统原子替换保护并发写入。主密钥仅在本次运行中缓存，旧版逐项钥匙串条目按需迁移。可选主密码及 Argon2id 尚未实现。细节见 [macOS 凭据保险库](macos-keychain.md)。

---

## 6. UI 设计

单窗口左中右布局：左侧为无外层圆角和留白、直接填满窗口高度的侧栏，中间为会话工作区，右侧为可折叠 Agent，不显示独立标题栏和底部状态栏（window_manager 隐藏系统标题）：

当前界面直接使用 ShadcnApp 与 shadcn_flutter Zinc 浅色/深色风格，使用细边框、紧凑间距和绿色连接状态。欢迎页提供快速连接、新建主机与快捷键卡片；侧边栏搜索、会话操作、SFTP 工具栏以及主机/凭证表单使用统一组件。`AppTheme` 管理令牌，`AppTextFormField` 与 `AppSelectField` 对接 Flutter 核心 Form 校验，`AppDialog` 固定操作区并滚动长内容。选择框、单选/复选、菜单与 Toast 使用 shadcn 组件；GetX 继续负责路由和业务翻译，窗口管理与 xterm 终端独立于 UI 组件库。

SSH/SFTP 与端口转发会话在右侧工作区使用 shadcn `TabPane`，采用组件默认标签栏高度（当前桌面主题为 32），提供圆角标签、切换、关闭、会话列表与快速连接入口。没有会话时保留标签栏，在下方显示欢迎页。内容继续通过带稳定会话 key 的 `IndexedStack` 保持挂载。主机嵌套使用自定义树形列表，展开状态由 `FolderController` 管理；混合同级顺序、边缘排序、移入文件夹与拖动预览由应用的树控制器和拖放组件负责。应用图标统一采用 shadcn 自带的 Lucide 图标。

```
┌──────────────────────────────────────────────────────────────┐
│ [侧栏开关] │ [标签1: web-01] [标签2: db-02] [＋]     ─ □ ✕ │
├────────────┬─────────────────────────────────────────────────┤
│ 侧边栏      │  当前标签：终端或独立文件传输                    │
│ 🔍搜索      │  ┌─ 文件传输标签 ───────────────────────────┐   │
│ ▾ 主机      │  │ 本地 ~/proj       │ 远程 /var/www       │   │
│  ▸ 生产环境 │  │ ...本地文件...    │ ...远程文件...      │   │
│   • web-01 │  │                  ⇄                    │   │
│ ▾ 凭证      │  │                                       │   │
│  🔑 root   │  │                                       │   │
│ ⇅ 传输队列  │  │ 传输进度 / 取消 / 清除已完成           │   │
│   ⇄ 数据库  │  └───────────────────────────────────────┘   │
│ ⚙ 设置     │  工作区内容延伸到底部                            │
└────────────┴─────────────────────────────────────────────────┘
```

**交互要点**：
- `Cmd/Ctrl+K` 全局命令面板：模糊搜主机直接回车连接（最高频操作 ≤2 次按键）
- 主机右键「新建文件传输」打开双栏 SFTP 标签；终端与文件传输标签独立切换和关闭
- 侧栏顶部提供收起按钮，收起后工作区顶部显示展开入口。侧栏使用宽度过渡，隐藏时右侧主内容区占满窗口，树与会话保持挂载，显隐状态在重启后恢复。
- macOS 左侧保留系统红黄绿按钮，与紧凑标签栏垂直对齐；Windows 右上角窗口按钮始终融入标签栏。顶部预留区域支持拖动与双击缩放。
- 侧边栏「服务 / 凭证 / 网关」根组及各级文件夹的展开状态保存至本地设置，启动时恢复；拖入文件夹后的自动展开也会记录。
- 侧栏左下角设置按钮打开独立弹窗，以 Tabs 切换通用和 AI 设置，入口随侧栏隐藏。主题提供「自动 / 浅色 / 深色」，默认自动跟随系统亮度；主题和 AI 配置存于本地 SQLite，重启后恢复。终端保持独立的深色配色。
- 关闭窗口可选最小化到托盘（服务端口转发常驻场景）

---

## 7. 项目结构

```
PagaShell/
├── lib/
│   ├── main.dart
│   ├── app.dart                 # 根 Widget、主题、路由
│   ├── core/                    # 通用工具、常量、扩展、日志
│   ├── domain/
│   │   ├── entities/            # Host, Identity, Snippet ...
│   │   └── repositories/        # 抽象接口
│   ├── infrastructure/
│   │   ├── ssh/                 # DartSsh2Engine、known_hosts、密钥解析
│   │   ├── db/                  # drift 表定义与迁移
│   │   ├── vault/               # 加密存储
│   │   └── import/              # ssh_config 导入
│   ├── application/             # GetX controllers + AppBinding 装配
│   │   ├── session/
│   │   └── transfer/
│   └── presentation/
│       ├── shell/               # 窗口框架、标题栏、侧边栏
│       ├── terminal/
│       ├── sftp/
│       ├── hosts/
│       ├── forward/
│       └── settings/
├── test/                        # 单测（domain/application 层为主）
├── integration_test/
├── docs/                        # 本文档、截图、架构图
├── .github/workflows/           # ci.yaml, release.yaml
├── linux/ macos/ windows/       # 平台壳工程
└── pubspec.yaml
```

---

## 8. 开源与工程规范

- **License**：MIT
- **分支模型**：`main` 保护分支 + PR，Conventional Commits，语义化版本
- **CI（GitHub Actions）**：
  - `ci.yaml`：push/PR 触发 → `flutter analyze` + `flutter test` + 三平台矩阵 `flutter build`
  - `release.yaml`：打 tag 触发 → 构建产物（Windows: zip；macOS: dmg；Linux: AppImage/tar.gz）→ 自动挂 GitHub Release。暂不上架任何应用商店（Store/winget/Flathub 等后续再议）
- **社区文件**：README（中英）、CONTRIBUTING.md、CODE_OF_CONDUCT.md、SECURITY.md（漏洞私下报告渠道）、issue/PR 模板
- **质量**：`very_good_analysis` lint 规则；domain/application 层单测覆盖；SSH 层用 Docker 起 openssh-server 跑集成测试

---

## 9. 里程碑

| 里程碑 | 内容 | 目标 |
|---|---|---|
| **M0 骨架**（~1 周） | 工程脚手架、窗口框架、CI 跑通三平台构建 | 空壳应用三平台可运行 |
| **M1 能连**（~2 周） | 主机 CRUD + 明文存储、dartssh2 + xterm 打通、多标签 | 能日常连服务器敲命令 |
| **M2 可用**（~3 周） | 加密 Vault、known_hosts 校验、密钥认证、SFTP 双栏 + 传输队列 | 达到 MVP，发 v0.1 预览版 |
| **M3 好用**（~3 周） | 分屏、搜索/命令面板、主题、ssh_config 导入、断线重连 | v0.3 公开推广 |
| **M4 完整**（~4 周） | 端口转发、跳板机、片段、本地终端、密钥生成部署 | v1.0 |

---

## 10. 已定决策

- [x] 名称：**PagaShell**
- [x] License：**MIT**
- [x] 分发：仅 GitHub Release，暂不上架任何应用商店
- [x] 同步：**不做**。数据完全本地保存和维护，迁移靠配置文件导出/导入，支持可选密码加密
