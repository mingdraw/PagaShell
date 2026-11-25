# RDP 远程桌面

RDP 用于连接 Windows 桌面。请先在目标机器启用远程桌面，并确认账号具有远程登录权限。连接成功后，桌面会在独立标签中打开。

[返回使用指南](user-guide.md#远程桌面) · [VNC 远程桌面](vnc-service.md)

## 配置与连接

1. 新建服务，将「服务类型」切换为 RDP。默认端口自动从 22 改为 3389，默认用户名从 root 改为 administrator；已经填写的自定义端口和用户名保持不变。
2. 填写 Windows 地址、用户名和密码，按需填写 Windows 域。也可绑定 RDP 密码凭证；新建 RDP 凭证同样默认使用 administrator，并支持可选 Windows 域。连接优先使用凭证填写的域，凭证未填写时沿用服务的域。SSH 私钥不能用于 RDP；切换服务类型后需重新选择协议一致的凭证。
3. 点「保存并连接」，或保存后双击服务。若弹出证书确认，详情默认折叠；可点「显示证书」查看并复制指纹。核对后点「继续连接」才会提交 Windows 登录凭据。点击「取消」会停止连接。

PagaShell 会检查证书链、有效期和连接地址。首次连接、证书变更或验证失败可能需要核对证书。验证失败或证书变更时的继续连接仅对当次有效；首次确认有效证书后会保存指纹。

## 显示、全屏和键盘

| 控件 | 用途 |
|---|---|
| 分辨率 | 调整 Windows 桌面尺寸。默认「自适应窗口」，也可选固定分辨率。需要远端支持动态分辨率；调整失败时保留当前画面。工具栏显示实际收到的尺寸。 |
| 画面缩放 | 「适应窗口」等比缩放；「1:1 原尺寸」按原始像素显示，画面大于窗口时可滚动查看，并暂停自动分辨率调整。 |
| 全屏 | 点击全屏图标或按 `Ctrl+Alt+Enter` 切换。顶部工具栏会自动收起，将鼠标移到顶部中央的小条上可重新显示，支持固定。选择「退出全屏」或再次按快捷键退出，连接保持不变。 |
| Ctrl+Alt+Del | 点击工具栏中的同名按钮，将组合键发给远端。 |

单击画面后可以使用键盘、鼠标和滚轮。`Esc` 会发给远端；切换标签或窗口失焦时，应用释放已按下的按键。

## 网关与会话

在 RDP 服务的「高级选项 → 网关」中，可选择 SSH 网关或 [Page 网关](page-gateway.md)：

- SSH 网关先独立确认主机密钥并认证，再以 `direct-tcpip` 承载目标 RDP 连接。
- Page 网关由内网 Client 连接目标地址和端口，目标须在 Client 的访问范围内。
- 目标 RDP 服务始终独立核验证书并使用自己的 Windows 凭据。网关失败时拒绝连接，不回退直连。

旧 RDP 网关配置已停用。若原有绑定提示不可用，可改选 SSH 或 Page 网关；目标能直连时也可取消绑定。

每个远程桌面标签持有独立目标连接；关闭标签会取消在途认证并释放连接及网关资源。断线后标签显示失败，可点击重试。Windows 对同一账号的并发会话策略可能使旧会话断开。

Windows 上的直连 RDP 会为每个会话启动独立进程。会话进程崩溃或长期无响应时，可以在该页签重连；结束一个会话不会终止其他会话。经网关连接的 RDP 和 VNC 保持现有连接方式。

密码沿用本机 SecretStore 存储，不进入 SQLite 或日志。RDP 与 SSH 的可信记录按协议隔离。RDP 服务不显示 SSH 文件传输和端口转发入口。

## 证书确认后仍无法连接

「继续连接」只允许本次证书例外，之后仍需完成 Windows 认证与 RDP 会话初始化。直连与网关均区分这两个失败阶段：

- 「RDP NLA 认证失败」保留 Windows 返回的 NTSTATUS、SSPI 状态名和十六进制代码。例如 `STATUS_LOGON_FAILURE / 0xC000006D` 表示 Windows 拒绝登录，单凭该代码不能断定是密码错误；权限、账号锁定或密码过期会按服务器给出的具体状态提示。
- 「RDP 会话初始化失败」表示 RDP 协议、许可或桌面能力协商阶段失败；已选择 NLA 时，此阶段发生在 NLA 通过后。普通 TLS 模式在此阶段提交 Windows 登录信息。
- 邮箱用户名、域留空是受支持的格式，不会自动改写账号或补充域。排查时保留 Windows App 中能成功连接的账号配置，并提供完整失败提示中的阶段及状态码，不需要提供密码。
- 认证成功后的断开会保留后台会话原因，包括数据接收、图形/会话处理、响应发送以及 Windows 主动结束会话的原因；取帧和输入失败使用同一个终止原因，避免只显示通用断开提示。原生任务异常退出会唤醒等待中的取帧，不将异常载荷暴露到界面。

诊断只输出固定原因与类型化状态码，不输出 SSPI 错误中的自由文本、凭据或报文内容。状态码定义见 [Microsoft NTSTATUS](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/596a1078-e883-4972-9bbc-49e60bebca55)。

## 双向复制粘贴

RDP 会话通过 CLIPRDR 虚拟通道同步 Unicode 文字、多个文件和目录，无需在 Windows 安装配套程序。Windows/Linux 使用 Ctrl+C、Ctrl+X、Ctrl+V；macOS 在远程画面内也支持 Command+C、Command+X、Command+V，自动转换为 Windows 的 Ctrl 组合键，其他 Command 组合仍按原有键盘映射发送。

- 本机复制文字后，在远程应用中粘贴；在 Windows 复制文字后，可在本机应用中粘贴。粘贴按键会等待最新格式列表发送完成，避免粘贴到上一次复制的内容。
- 在 Finder、Explorer 或 Linux 文件管理器复制文件/目录后，可在远程 Windows 的文件夹中粘贴；远端根据需要分块读取本机文件。Windows 复制文件/目录后，客户端先在应用临时目录接收完整文件，再发布到本机文件剪贴板，随后可在本机文件管理器粘贴。传输时显示进度并提供取消按钮，取消不关闭桌面。跨机器文件操作始终按复制处理，不删除源文件。
- 只对当前选中的 RDP 页签启用剪贴板通道。切到本机其他应用时暂停本机剪贴板轮询和发布，继续接收尚未返回的远端文字和文件，避免网关延迟较大时丢失复制结果；窗口被遮挡或最小化时也保留远端接收；切换页签、应用挂起或断开后停用通道。新的本机复制优先，系统剪贴板版本检查防止旧响应覆盖新复制的内容。同步失败后再次粘贴可重试原内容，无需重新复制；定时轮询不会反复弹错。剪贴板错误单独提示，不结束远程桌面。
- 文字上限为 16 MiB；每次最多 4096 个文件/目录条目，远端文件总量最多 16 GiB。文件名必须兼容 Windows，不导出符号链接、特殊文件或不安全路径。文件传输按约 1 MiB 分块处理，不把完整文件搬入 Flutter 内存。失败或取消会清理不完整缓存；已完成缓存保留供断开后粘贴，24 小时前的缓存在下次激活剪贴板时清理。
- 目标 Windows 必须允许剪贴板重定向及文件剪贴板能力；组策略或远程桌面服务器禁用时无法绕过。剪贴板通道迟迟未完成协商会单独提示检查 Windows 重定向设置或重新连接，不把超时直接归因为网关过滤或组策略。直连、SSH 网关和 Page 网关共用同一 CLIPRDR 实现。当前不支持图片、富文本、磁盘映射或 VNC 剪贴板。
- 如需把本机剪贴板里的纯文本作为键盘输入发送，先聚焦远端的目标输入框，再点「键入剪贴板文本」。文本含换行或制表符时会提示确认。

## 支持范围

- 支持 TLS 和 NLA/CredSSP 的密码认证。暂不支持仅 Kerberos、智能卡或需要额外桌面交互的认证，也不启用旧式标准 RDP 安全模式。
- 目前未接入音频、磁盘映射、多显示器或本机输入法直接映射。操作系统保留的快捷键可能由本机处理。

<details>
<summary>协议、渲染与开发验证</summary>

### Windows 直连会话隔离

- 安装目录中的 PagaShell 可执行文件以子进程模式运行 Rust，在创建 Flutter 引擎之前进入会话处理。主窗口保留证书确认和渲染，用户确认后才经私有管道传递密码；命令行不携带目标或凭据。子进程负责 RDP 连接、解码、键鼠和协议剪贴板。
- 控制和像素分开传输。像素用一份按需扩容的匿名共享内存，每个会话只保留当前缓冲，主程序读完才请求下一帧。帧内容不经管道序列化。
- 健康检查由 RDP 会话循环应答，静止画面不会触发超时。关闭会话时先尝试正常断开，1.2 秒内没有应答就终止该子进程。主进程异常退出后由 Windows Job Object 回收子进程。
- Windows 原生回归：`flutter test -d windows integration_test/rdp_worker_windows_test.dart`。覆盖握手无应答时限时关闭、子进程被终止后唤醒等待，以及另一个会话进程继续工作。Windows 实机还需在保持 SSH 页签连接的同时，验证高负载桌面卡死时仍能切换标签和重连；若 Flutter 渲染本身卡住，则另行定位。

### 剪贴板验证

```bash
flutter test test/application/rdp_clipboard_controller_test.dart test/infrastructure/system_clipboard_test.dart test/rdp_clipboard_test.dart
cargo test --manifest-path rust/Cargo.toml --locked desktop_clipboard
```

协议测试使用固定版本 IronRDP 的 CLIPRDR 编解码及 ActiveStage，覆盖格式协商、文字、目录、多分块下载、锁定/未锁定文件快照、后台禁止读取、超时与取消清理；组件测试覆盖三平台快捷键、初始化竞争、剪贴板版本冲突、进度取消和视口尺寸保持。这些本地测试不代表真实 Windows、系统文件管理器或 Windows/Linux 原生宿主已经完成端到端验收。

2026-10-29：66 项 Flutter 相关回归、70 项 Rust 回归通过（4 项环境测试跳过），静态分析、Rust 格式检查和严格 Clippy 通过，macOS Debug 完整重建并启动。该构建直连真实 Windows，验证了双向中文、换行和 emoji 文本；在 Finder 与 Windows 文件资源管理器之间往返复制包含中文文件名与嵌套目录的测试文件夹，41 字节 UTF-8 文件及 2,097,408 字节二进制文件回传后的 SHA-256 均与源文件一致。测试文件由本机生成，仅在双方临时目录中传输和保存。自动化按键注入未向 Flutter 传递修饰键，因此实机复制使用系统菜单；Command/Ctrl 组合键由组件回归覆盖，仍需真实物理键盘验收。Windows/Linux 原生宿主、远端策略禁止、大文件长时间传输与跨网关剪贴板尚未实机验证。

经网关复制回本机的延迟回归：通过组件测试复现原实现切换本机应用后取消远端响应，以及发布失败后无法用相同内容再次粘贴的问题；修复后 71 项 Flutter 相关回归、12 项 Rust 剪贴板回归通过，静态分析、Rust 格式检查和严格 Clippy 通过。macOS Debug 已完整重建，并核对应用内嵌的 Rust framework 含本次通道协商超时处理。延迟文字/文件、窗口失焦/隐藏、恢复、较新本机复制保护及原内容重试均有回归；这些结果不能单独证明实际公司网关的策略或协商状态。

### 显示与协议实现

- 握手初始桌面为 1280×800，收到首帧后默认按窗口可用区域的逻辑像素调整。窗口连续调整后等待 350 毫秒再发送，调整期间合并后续变化。固定模式只在用户选择时调整远端。动态分辨率遵循 [MS-RDPEDISP 显示布局规范](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/ea2de591-9203-42cd-9908-be7a55237d1c)，客户端像素上限为 16,777,216。
- IronRDP 声明 TLS 与 NLA/CredSSP，按服务端选择建立加密连接；NLA 使用 NTLM 密码认证。协议声明见[微软 RDP 协商规范](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/902b090b-9cb3-4efc-92bf-ee13373371e3)。
- Rust 按显示端需求累计精确变化区域，以 128×128 分块打包；相距较远的小更新不会复制中间未变化的画面。RDP 和 VNC 的 RGBA 通过 FRB DCO 以原生字节缓冲交给 Dart，跳过 SSE 的逐字节编码；生成像素快照和上传 GPU 仍各有成本。快照在复制时一次补齐不透明 alpha；整屏更新以连续画面发送，无需分块元数据。RDP 在请求和更新都就绪时交付，持续更新间隔至少 16 毫秒，空闲后首个更新无需等周期 tick。
- RDP 建连后等待有效图形。EGFX 重置后保留旧画面，等有像素内容的 `EndFrame` 再替换完整画面；尺寸不变的重置也会刷新全部内容。可恢复的传统位图丢弃或 EGFX 解码丢弃会按服务器能力请求重绘，每个会话最多两秒一次。
- 鼠标形状与桌面像素分开传递，在本地显示指针。输入队列合并尚未发送的连续移动，将就绪的 RDP 键鼠事件成批发送，保留按下、释放及剪贴板同步顺序。解码一个网络包后优先处理一批就绪输入，然后恢复公平轮询。直连 TCP 启用 `TCP_NODELAY`；主动断开前释放原生会话记录的按键和按钮。
- Flutter 整帧直接绘制单张图像，局部更新使用 `drawRawAtlas` 按图集批量提交 GPU 绘制，保留未变分块。缩放统一使用[双线性采样](https://api.flutter.dev/flutter/dart-ui/FilterQuality.html)，匹配一像素补边。图集超过 16 张或保留像素超过桌面的三倍时压实；压实期间会额外生成一张完整图像。后台标签或应用暂停时停止请求和上传。
- 桌面协商 32 位位图、RemoteFX 与 64 KB bulk compression，并注册 EGFX 动态图形通道。H.264 AVC420 由 IronRDP 的 OpenH264 后端在 Rust 侧软件解码；解码器无法初始化时不声明 AVC 能力，保留非 AVC 回退。仅声明已实现的 V8.1/V8 能力，不声明 AVC444。实际编码由 Windows 协商决定；当前没有接入 VideoToolbox 等硬件解码或原生零拷贝纹理。
- 性能体验应使用 Release 构建。Debug 模式也单独优化 Rust 图像处理依赖，便于调试，但不能代替 Release 性能验收。变化区域大小、Windows 实际选择的编码、网络时延与远端负载都会影响帧率；约 60 次/秒是客户端交付上限，不是实际帧率保证。原生库与桥接接口变更后必须退出应用并完整重建，Dart 热重载无法载入新的 Rust 库。
- 回归覆盖服务类型、默认端口、密码凭证保留、复制与持久化、证书门禁、标签取消/关闭/重试、缩放坐标、键鼠顺序、分块像素合成与图集压实、独立光标和后台暂停；Rust 使用本地生成的 H.264 压缩帧验证 EGFX 能力协商、解码像素和帧确认。初始与 EGFX 重置画面共用 16,777,216 像素上限。
- 已在 macOS Debug 直连 Windows 验证桌面显示和上述画面变化；本次未测量真实帧率、操作时延或与 Windows App 的性能差距，长期稳定性、网关穿透和断网重连仍需实际部署环境验证。

### Windows Progressive 解码兼容性

2026-10-20 实机诊断在认证成功后捕获到 `Srl(MissingTerminator)`，发生于 EGFX `WireToSurface2` 的 RemoteFX Progressive 细化解码。Windows 会省略 SRL 数据末尾的零字节和零位，旧解码器将其视为缺失终止符并结束会话。

IronRDP 统一固定到 `1f69e124e6bf85608efce3495c12eaf5f6b5a95d`，包含[上游 SRL 兼容修复](https://github.com/Devolutions/IronRDP/pull/2134)，并保留此前的密码库兼容更新。解码器按所需系数数量处理尾部零位，仍拒绝非法幅值位数；没有通过关闭 EGFX 或 Progressive 来回避问题。会话内诊断只截取 EGFX 解码错误字段，最多 1024 字符，不采集报文、图像或凭据，也不安装全局日志订阅器。

本地回归覆盖省略尾零的 SRL、空 SRL 的有限零系数输出、非法幅值位数及实际 Progressive 系数细化；现有 H.264 像素与帧确认回归同时通过。Rust 测试 55 项通过、1 项需手动设置目标地址的握手探测跳过，`cargo fmt --check` 与 `cargo clippy --locked --all-targets -- -D warnings` 通过。macOS Debug 与 Release 构建通过；Debug 实机连接同一台 Windows 后已显示真实桌面，窗口最小化、恢复及普通按键输入、取消输入后的画面均能更新，本次验证未复现该解码断开。

### 分辨率与全屏回归

```bash
flutter test test/rdp_display_controls_test.dart test/rdp_service_test.dart test/window_header_test.dart
flutter test integration_test/rdp_display_controls_test.dart -d macos
```

2026-10-21：上述 22 项组件/单元测试和 1 项 macOS 原生窗口集成测试通过。组件测试覆盖三平台窗口指令、进出全屏时组件与画面保活、悬浮退出、快捷键和按键释放、原生退出事件、失败重试、标签关闭/失活/断开自动退出、分辨率确认/拒绝/超时、防抖及英文小窗口。原生集成测试使用内存会话和合成像素，验证真实 macOS 窗口全屏、悬浮退出和快捷键，并检查截图；不访问保存的服务、密码或真实 Windows。

Rust 回归 54 项通过、1 项环境握手探测跳过，`cargo fmt --check` 和严格 Clippy 通过。分辨率测试覆盖服务端 caps、编码与尺寸上限、等待期间输入不阻塞、断开和异常唤醒。不代表真实 Windows 已接受动态分辨率调整；Windows/Linux 原生全屏和真实 Windows 分辨率切换仍需对应运行环境验证。

### 本地渲染基准

`integration_test/rdp_rendering_performance_test.dart` 在原生 Flutter 引擎比较旧的局部更新后整屏合成与当前渲染路径。固定桌面 1280×800，覆盖局部、滚动、整屏、稀疏、缩小滚动和轮换分块更新；每种路径预热 4 次后分 4 轮交错测量共 80 次。两种路径都包含最终离屏绘制。日志记录每帧耗时的 P50 / P95、像素字节数和触发图集压实的帧耗时。

```bash
flutter test integration_test/rdp_rendering_performance_test.dart -d macos
```

该命令运行 Debug 引擎，使用本地合成像素，不包含 Windows 编码、网络或 RDP 解码耗时，结果不代表真实远程桌面 FPS。

2026-11-25 本机 macOS arm64 的合成基准中，当前路径的整屏 P95 为 782 µs、缩小滚动为 400 µs，轮换分块触发压实 5 次，压实帧最慢 566 µs。单独测量 Rust 整帧快照，在 1080p / 1440p 下把复制和补 alpha 合成一遍后，P50 分别从 477 / 692 µs 降到 166 / 216 µs。以上均为本机数据，不含 Windows 网络、解码或 GPU 呈现耗时。

2026-10-20 本机 macOS arm64 的一次测量（UTC 13:58:35.827118 至 13:58:36.206647）：

| 场景 | 旧路径总耗时 / 80 次 | 新路径总耗时 / 80 次 | 耗时变化 | 每次像素字节：旧 → 新 |
| --- | ---: | ---: | ---: | ---: |
| 128×128 局部更新 | 36,969 µs | 28,551 µs | 降低 22.8% | 65,536 → 67,600 |
| 1024×512 滚动区域 | 42,815 µs | 44,135 µs | 增加 3.1% | 2,097,152 → 2,163,200 |
| 1280×800 整屏更新 | 51,184 µs | 53,060 µs | 增加 3.7% | 4,096,000 → 4,096,000 |
| 两处相距较远的小更新 | 54,857 µs | 23,164 µs | 降低 57.8% | 3,511,724 → 135,200 |

耗时变化为 `(新路径总耗时 / 旧路径总耗时 - 1) × 100%`；该稀疏更新示例的像素量减少 96.1%。测试保留了滚动和整屏场景的少量额外开销，没有将局部更新收益推广到所有场景。GPU 工作可能异步排队，离屏图像完成时间不能直接作为屏幕呈现时间；H.264 解码收益和真实 Windows App 对比仍需远端实测。

### Windows GPU 与现场验收

- 目标 Flutter SDK 已默认启用 Windows [Impeller](https://docs.flutter.dev/perf/impeller)。`drawImage` 和 `drawRawAtlas` 已走引擎渲染；切换引擎或在 Dart 加着色器都不会减少 OpenH264 软件解码和 RGBA 上传成本。定位渲染后端时可以用 `flutter run -d windows --profile --no-enable-impeller` 做对照。
- 原生 `Texture` 可以省去 Dart 像素桥接、图集管理和 `decodeImageFromPixels`。`PixelBufferTexture` 仍会[整张上传 CPU 像素](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/windows/external_texture_pixelbuffer.cc)。后续可以由 Rust 或原生宿主把脏矩形更新到可共享的 D3D11 纹理，再由 [Windows Texture Registrar](https://api.flutter.dev/windows-embedder/flutter__texture__registrar_8h.html) 导入。若接入硬件 H.264 解码，再评估在 GPU 上做颜色转换并交付纹理。需要验证多标签、设备丢失、分辨率切换和释放，保留现有图集作为回退。
- Windows 使用同一台远端主机、相同连线及 1080p / 1440p 分辨率对照 Release 版本，检查首次画面、调整大小、拖动窗口、连续滚动及键鼠延迟。Flutter DevTools 看 raster 帧时间，Windows 性能跟踪看原生解码线程和纹理上传。上游 ClearCodec 的局部合成、未实现的 codec、服务器端帧流控及本机 IME 需要分别验证；重绘只覆盖能被检测到的丢弃。

### 仅探测握手

在仓库根目录执行以下命令可查看 RDP 安全协议协商、TLS 或证书解析阶段的错误，不发送登录凭据，也不创建 Windows 登录会话：

```bash
PAGASHELL_RDP_PROBE_HOST=windows.example.com cargo test --manifest-path rust/Cargo.toml --locked desktop_handshake_probe -- --ignored --nocapture
```

自定义端口可额外设置 `PAGASHELL_RDP_PROBE_PORT`。该测试默认跳过，需显式指定 `--ignored` 并设置环境变量。

</details>
