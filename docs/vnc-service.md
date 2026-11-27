# VNC 远程桌面

[返回使用指南](user-guide.md#远程桌面) · [RDP 远程桌面](rdp-service.md)

## 配置与连接

1. 新建服务，类型选择 **VNC**，填写地址与端口（默认 `5900`）。
2. 填写密码，或绑定 VNC 类型凭证：
   - **连接 macOS 屏幕共享 / 远程管理**：在目标 Mac 打开「系统设置 → 通用 → 共享 → 屏幕共享」，填写可选的 **macOS 系统用户名**与密码（无需开启旧版 VNC 密码）；若留空用户名且目标 Mac 仅启用 macOS 账号认证，连接时会自动弹出登录框要求输入系统用户名与密码。
   - **连接标准 VNC（Linux / Windows / 旧版 macOS VNC 密码）**：用户名留空，仅填写 VNC 密码即可（密码留空时可在连接时输入）。
3. 可在高级选项中绑定 SSH / Page 网关；网关使用其自身凭据，目标 VNC 账号/密码单独认证。
4. 点击「保存并连接」，或双击已保存的服务。支持键盘、鼠标、滚轮、双向文本剪贴板同步、本机输入法/远端键盘切换、动态分辨率（服务端支持 `ExtendedDesktopSize` 时生效；macOS 屏幕共享等不支持动态调整的服务端自动静默保留原分辨率）、信号/延迟状态与自适应画质切换，以及工具栏的 Ctrl+Alt+Del；点击全屏按钮或按 `Ctrl+Alt+Enter` 切换全屏。连接 macOS 时自动将 `Option/Alt` 与 `Command/Win` 分别映射到远端 macOS 的 `Option (⌥)` 和 `Command (⌘)`，并保留原生 `Cmd+C/V` 快捷键。

显示默认按窗口缩放并保留宽高比（支持最高 5K/6K Retina 及 2400 万像素画面）。在网络延迟较高、丢包或带宽受限时，自适应画质可自动降低刷新节奏并动态切换至 16-bit RGB565 以维持操作流畅，也可在顶部工具栏或展开后的全屏固定栏手动切换「自动 / 高画质 / 均衡 / 流畅」。VNC 不提供 SFTP 或 SSH 端口转发入口。

## 支持范围

- 支持 [RFB 3.3 / 3.7 / 3.8](https://www.rfc-editor.org/rfc/rfc6143) 与 macOS 屏幕共享（`RFB 3.889`）。
- 支持 **Apple Remote Desktop（ARD，安全类型 30）** Diffie-Hellman + AES-128 账号密码认证、标准 VNC 密码认证（安全类型 2）和无认证模式（安全类型 1）。
- 支持 RFB `ExtendedDesktopSize (-308)` 动态分辨率协商、`ServerCutText` / `ClientCutText` 双向文本剪贴板同步（含 UTF-8 / Latin-1 兼容与回环抑制）、实时网络信号/延迟监测与自适应画质（动态 `SetPixelFormat` RGB565 + 帧率节奏调节）。
- 标准 VNC 与 ARD 会话画面及输入本身不经 TLS 加密；公网或跨网段访问建议搭配 SSH 网关（核验主机密钥）或[Page 网关](page-gateway.md)（支持 TLS）。
- 暂不支持 VNC TLS / VeNCrypt、Tight/JPEG 或文件剪贴板/文件传输。请确认服务端启用了兼容的 RFB 或 macOS 屏幕共享方式。

<details>
<summary>协议实现、配置迁移和开发验证</summary>

### 协议实现

- Rust 引擎基于本地补丁版 `vnc-rs 0.6.0`（见 `rust/vendor/vnc-rs`），经 flutter_rust_bridge 接入。
- 兼容 `RFB 003.889` 握手并协商 `RFB 003.008`，实现 Apple ARD 安全类型 `30`（DH + MD5 + AES-128-ECB）、原生 32-bit 像素格式直通（含 LE BGRA / BE xRGB 客户端转 RGBA）、16-bit RGB565 动态画质切换（含 16-bit 光标解码）、`SetColorMapEntries` 忽略及 macOS `Option` / `Command` 键位映射。
- 协商 ZRLE、CopyRect、Raw、光标及 `DesktopSize` / `ExtendedDesktopSize (-308)` 扩展；ZRLE 使用 32 KiB 缓冲流解压并按矩形合并 tile，基于 `FrameComplete` 驱动 RFB 帧管线，支持最高 2400 万像素（覆盖 5K / 6K Retina 屏）；启用 `PAGASHELL_RDP_GPU=1` 时复用原生桌面纹理直传（macOS Metal / Windows D3D11 / Linux OpenGL），并与 RDP 共享全局桌面会话 ID 空间。
- 键盘与鼠标输入采用无锁通道 + 批量 FFI（`vnc_input_batch`）+ socket 写缓冲合并，支持「远端键盘」与「本机输入法」切换，失焦与关闭时释放已按键及鼠标按钮。
- 实时采集内核 TCP RTT / 丢包、接收吞吐与实际交付帧率，在标签标题栏、顶部工具栏和全屏展开固定栏显示信号图标与延迟（收起态全屏提示条保持简洁），并在自动模式下基于迟滞策略调整刷新周期与 16-bit RGB565 画质。
- 支持直连、SSH `direct-tcpip` 和 Page TCP 通道；每个桌面独立建立、取消和释放连接。
- Windows 上直连、SSH 网关与 Page 网关 VNC 会话均运行在独立子进程中（SSH 隧道通过本机单实例匿名命名管道桥接，不暴露本地 TCP 端口），子进程崩溃或无响应可限时关闭并在当前页签重连，回归见 `integration_test/rdp_worker_windows_test.dart`。

### 凭证与升级

凭证区分 SSH / RDP / VNC，创建后协议固定，服务列表只显示匹配协议的凭证。SSH 可使用密码或私钥；RDP 使用用户名和密码；VNC 只保存密码。敏感内容仍通过 SecretStore 存储。

数据库升级至 schema 11 时，原凭证按服务及网关实际绑定分类；未使用项默认 SSH，同时用于 SSH/RDP 的项目拆分为两份并保留绑定。拆分项目初始共用密文引用，编辑时写入独立引用，删除一份时保留其他项目仍使用的密文。支持的导入版本见[配置迁移](configuration-transfer.md)。

### 验证边界

Rust 本机 RFB 测试覆盖三个版本的无认证与密码握手、画面更新、CopyRect、键鼠、滚轮、断开和无效矩形；Flutter 测试覆盖表单、凭证筛选、旧数据迁移、配置往返、桌面页签、重连与取消。原生桥接回路可执行：

```bash
flutter test integration_test/vnc_connection_test.dart -d macos
```

该回路使用一次性的本机 RFB 服务，不读取用户保存的服务或凭据。真实 VNC 服务端、实际 SSH / Page 网关、跨平台运行与长时间连接仍需分别验收。

</details>
