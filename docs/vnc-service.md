# VNC 远程桌面

[返回使用指南](user-guide.md#远程桌面) · [RDP 远程桌面](rdp-service.md)

## 配置与连接

1. 新建服务，类型选择 **VNC**，填写地址与端口（默认 `5900`）。
2. 填写 VNC 密码，或绑定 VNC 类型凭证。VNC 不使用用户名或 Windows 域；密码留空时可在连接时输入。
3. 可在高级选项中绑定 SSH / Page 网关；网关使用其自身凭据，目标 VNC 密码单独认证。
4. 点击「保存并连接」，或双击已保存的服务。支持键盘、鼠标、滚轮和工具栏的 Ctrl+Alt+Del；点击全屏按钮或按 `Ctrl+Alt+Enter` 切换全屏。

显示采用远端原有分辨率并按窗口缩放，保留宽高比。服务端改变桌面尺寸时更新画面；当前不请求服务端动态分辨率，不提供 RDP 分辨率菜单、SFTP 或 SSH 端口转发入口。

## 支持范围

- 支持 [RFB 3.3 / 3.7 / 3.8](https://www.rfc-editor.org/rfc/rfc6143) 的标准 VNC 密码认证和无认证模式。
- 标准 VNC 直连不加密画面和输入。SSH 网关仍核验 SSH 主机密钥；[Page 网关](page-gateway.md)可用 TLS 保护对应中转连接。
- 暂不支持 VNC TLS / VeNCrypt、Apple 远程桌面专有认证、Tight/JPEG、剪贴板同步或文件传输。请确认服务端启用了兼容的 RFB 和认证方式。

<details>
<summary>协议实现、配置迁移和开发验证</summary>

### 协议实现

- Rust 引擎使用 [vnc-rs 0.6.0](https://docs.rs/crate/vnc-rs/0.6.0)，经 flutter_rust_bridge 接入。
- 协商 ZRLE、CopyRect、Raw、光标及桌面尺寸扩展；帧在 Rust 侧合并变更区域，跨 FFI 发送 RGBA 更新。
- 键盘使用 X11 keysym，失焦与关闭时释放已按键及鼠标按钮。
- 支持直连、SSH `direct-tcpip` 和 Page TCP 通道；每个桌面独立建立、取消和释放连接。

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
