# Rust 终端内核

## 数据链路

```
russh 字节 → rust/src/terminal / 官方 alacritty_terminal 0.26.0
           → 现有 FRB 桥接 → 增量 TerminalFrame → lib/terminal / Flutter TerminalPane
```

Flutter 继续处理输入法、键盘、鼠标、滚动视口、选区和复制。键鼠编码及批量粘贴
读取 Rust 帧中的模式；AI 读屏读取同一显示镜像并监听变更。设备状态仍走独立
exec 通道。光标位置、设备属性、颜色和尺寸查询由 Rust 在原 SSH 通道中应答。
远端 OSC 52 不读写本机剪贴板。

## 增量更新与释放

- SSH shell owner task 持有解析器，不引入额外全局终端句柄表。
- 每个终端最多一帧等待确认。Dart 完整执行 `Terminal.applyFrame` 及其同步
  监听器后，通过 `acknowledgeTerminalFrame(frameId)` 确认；不等待 Flutter 绘制，
  隐藏页签同样处理帧。
- 等待 ack 期间 Rust 继续解析 SSH 输出、处理输入和 resize，脏行在内核中累积；
  匹配 ack 放行后才生成下一增量帧。帧序号在发送前登记，重复、错误或迟到
  ack 不放行其他帧，也没有超时自动放行。
- 相邻出帧尝试保持最短 16 ms 间隔，空闲不发帧。同步输出等待结束或其自身
  超时；正常通道关闭时由 `finish()` 结束同步输出，末帧仍须等待前帧 ack。
- Rust 保留最多 10,000 行回滚；Dart 缓冲是显示镜像，不解析、不独立重排或
  决定回滚内容。
- 主屏幕和备用屏幕分别应用“移除头部、保留前缀、追加行 ID”和变更行。
  行对象复用，选择锚点随文本移动，已淘汰行解除绑定。
- 每个单元以四个 u32 传输属性；组合字符使用稀疏文本簇。
- resize 通知 Rust 和远端 PTY，显示等待 Rust 重排帧；启动前尺寸仍由
  `pending_terminal_size` 保存。
- 行 ID 由 Rust 内核通过 VTE 公共语义回调跟踪。仅改变高度
  保留存活行身份；改变宽度重排时重建行身份，解除旧选区锚点。
- 关闭页签取消帧订阅、释放 Flutter 镜像并断开连接；原有 shell task 的取消
  同时释放 Rust 解析器和回滚，不等待尚未返回的 ack。帧应用或确认失败时关闭
  对应会话，避免 Rust 留在永久等待中。

`TerminalScreenSource` 与帧协议定义在 `lib/domain/terminal/terminal_frame.dart`，保持纯 Dart。
应用终端要求 SSH 实现提供该帧流能力；SSH shell 统一使用终端帧流。
运行与测试均不再引入 xterm 包。UI/应用测试直接构造屏幕帧，ANSI/Unicode/重排
语义由 Rust 核心测试和原生生成的共享 fixture 覆盖，不保留 Dart 输出解析器。

Rust 内核位于 `rust/src/terminal/`，作为项目现有 Rust 工程的内部模块编译；
Flutter 显示与输入组件位于 `lib/terminal/`，与应用共用依赖配置。
终端帧经现有 FRB DTO 与原生运行时传输，FRB 绑定由固定的 2.13.0 生成器生成。
参考来源与接入示例见[终端组件说明](terminal-component.md)。

## 验证

Rust 测试覆盖解析、组合字符、颜色、应答、回滚上限与行身份、备用屏幕、重排和
同步输出；回环 SSH 测试覆盖字节到帧、输入、应答、resize、独立状态通道、
等待 ack 时合并脏行、严格确认门控、末帧和等待期间关闭。Dart 测试覆盖桥接
帧序号、应用后确认、串行消费、确认失败及关闭后的迟到结果。
共享 fixture `test/fixtures/native_terminal_frames.json` 由 Rust 实际解析生成，
在 Rust golden test 中核对，Flutter 使用同一帧验证绘制、选区和输入模式。
更新 fixture：

```bash
PAGASHELL_UPDATE_TERMINAL_FIXTURE=1 cargo test \
  --manifest-path rust/Cargo.toml \
  --lib terminal::tests::flutter_render_fixture_matches_native_parser
```

终端测试已纳入根目录的 `flutter test` 与 `rust/` 工程的 `cargo test`，具体命令见组件说明。
本阶段沿用 Flutter 绘制。
性能收益须在 Profile/Release 中对比日志吞吐、多终端及 Vim 场景。
