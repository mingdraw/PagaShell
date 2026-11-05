# paga_terminal

PagaShell 内部终端组件，Flutter 显示与输入代码位于 `lib/terminal/`，Rust 内核位于项目现有的 `rust/src/terminal/`。

## 职责与目录

```text
SSH / PTY bytes → rust/src/terminal → FRB → TerminalFrame → Terminal → TerminalPane
                 ANSI / UTF-8             domain protocol  mirror     Flutter rendering
                 grid / scrollback                                  IME / keyboard / selection
```

- `lib/domain/terminal/terminal_frame.dart`：纯 Dart 的帧协议与 `TerminalScreenSource` 接口。
- `lib/terminal/paga_terminal.dart`：内部组件入口；`core.dart` 提供显示模型与输入编码。
- `lib/terminal/src/terminal.dart`：`Terminal` 显示镜像、输入编码和生命周期。
- `lib/terminal/src/terminal_pane.dart`：`TerminalPane`，提供终端视图、拖选、滚动延伸选择和视口裁剪。
- `lib/terminal/src/ui/`：Flutter 绘制、键鼠、输入法、主题与选区控制器。
- `rust/src/terminal/`：Rust 终端模块；依赖统一在 `rust/Cargo.toml` 声明，通过 crates.io 引入官方 `alacritty_terminal =0.26.0`，关闭默认平台事件循环特性。
- `test/terminal/terminal_test.dart`：显示镜像、模式、行身份、选区锚点与生命周期测试。
- `test/fixtures/native_terminal_frames.json`：由真实 Rust 解析器生成的共享屏幕帧，用于 Flutter 回归测试。

Rust 负责输出解析、屏幕内容、回滚和重排，Flutter 负责绘制。Dart 侧已移除输出 ANSI 解析器、字符集解析、独立重排及相关调试工具；键位配置解析仍用于输入编码。当前没有 Rust 渲染器或额外 GPU 后端。

## Flutter 接入

在页面中持有终端及 FocusNode，并连接会话提供的输入、尺寸与帧通道：

```dart
import 'package:flutter/widgets.dart';
import 'package:pagashell/terminal/paga_terminal.dart';

final terminal = Terminal(
  onOutput: sendToPty,
  onResize: (columns, rows, pixelWidth, pixelHeight) {
    resizeNativeCoreAndPty(columns, rows);
  },
);
final focus = FocusNode();
final subscription = frames.asyncMap((frame) async {
  terminal.applyFrame(frame);
  await source.acknowledgeTerminalFrame(frame.frameId);
}).listen((_) {}, onDone: closeSession, onError: (Object error) => closeSession());

// 放入有界布局。active 随页签可见状态更新。
final view = TerminalPane(terminal, focusNode: focus, active: true);
```

示例中的 `sendToPty`、`resizeNativeCoreAndPty` 和 `frames` 连接到项目的 SSH 会话，`source` 为其 `TerminalScreenSource`，`closeSession` 负责取消订阅并关闭会话。`Terminal` 接受屏幕帧，没有原始输出 `write(String)` 接口。`onOutput` 是键盘、鼠标和粘贴产生的**待发送输入**。`resize` 请求发往 Rust 内核和远端 PTY，显示尺寸与重排结果等到下一帧后生效；`requestedSize` 可读取最近请求的网格尺寸。

项目控制器在应用前及确认前还检查终端是否已释放或被替换；关闭期间的迟到帧不再应用或确认。确认发生在同步显示镜像更新完成后，不依赖 Flutter 的绘制回调，因此隐藏页签也能继续消费帧。

低层接入可使用 `TerminalView`、`TerminalController`、`TerminalStyle` 和 `TerminalTheme`；`TerminalPane` 提供 PagaShell 使用的滚动拖选行为。页面包装 `AppTerminalView` 负责项目字体、主题与焦点配置。

移除视图并关闭会话时，取消帧订阅、释放 `Terminal` 和自行创建的 FocusNode / 控制器，同时结束对应的 Rust 内核任务；迟到帧会被已释放的 `Terminal` 丢弃。

## Rust 与原生桥接

```rust
use crate::terminal::TerminalCore;

let mut terminal = TerminalCore::new(80, 24, 10_000);
let replies = terminal.feed(b"hello\r\n"); // 写回同一 PTY 的设备应答
let frame = terminal.frame();             // 发送给 Flutter 的增量帧
terminal.resize(120, 40);
```

`rust/src/terminal/` 作为 `rust_lib_pagashell` 内部模块编译，通过现有 FRB 2.13.0 绑定向 Flutter 发送帧。Dart 侧通过屏幕帧更新显示，原始字节交给 Rust `feed(bytes)` 处理。

每个 SSH / PTY 会话独占一个 `TerminalCore`。SSH shell 任务负责：

1. 将字节交给 `feed`，并把返回的设备查询应答写回同一 PTY。不要把这些应答回显到屏幕。
2. 在有待处理输出且没有未确认帧时生成并发送 `frame()`；相邻尝试间隔最短 16 ms，空闲不轮询绘制。发送前登记 `frameId`，只接受该序号的 ack；等待期间继续解析并累积脏行，放行后合成一帧，不排队生成多帧或超时放行。
3. 出帧时调用 `expire_sync()`，处理同步输出超时返回的应答；正常通道关闭时调用 `finish()`，最后一帧仍通过相同 ack 门控发送。
4. resize 同时更新内核和远端 PTY；页签关闭、断开或任务取消时丢弃内核，无需等待 ack。Rust 保留最多 10,000 行回滚。

## 帧与选区约定

帧必须按会话有序、完整地送达，不能跳帧。原生桥接为每个发送帧分配非零 `frameId`；纯内核及共享 fixture 不依赖该传输字段，Dart 合成测试帧默认使用零。主屏幕与备用屏幕各自维护镜像：先更新 `lines` 中的行数据，再从旧行序列删除 `trimFront` 行、保留 `keepRows` 行前缀、追加 `appendRows`。行 ID 只在同一个内核生命周期内有效。

每格传输四个 `u32`：前景色、背景色、属性和打包的码点/宽度；组合字符通过稀疏 `clusters` 传输。`wrapped` 表示本行接续上一行。`modes` 目前对应固定版本 `alacritty_terminal` 的 `TermMode` 位，用于应用光标键、粘贴、鼠标等输入编码。

行身份与变更标记由 Rust 模块的 `tracking.rs` 通过 VTE 公共语义回调维护，终端操作交给 `Term`。滚动、区域内移行和仅改变高度时保留存活行的身份，选择锚点随文本移动；淘汰行解除绑定。改变宽度可能拆分或合并行，因此重建行身份并清除原选区。没有使用内存地址、文本哈希或私有行布局来猜测行身份。

远端 OSC 52 剪贴板请求当前忽略。屏幕镜像保存在本机，不引入遥测或云服务。

## 参考来源

- Flutter 绘制、输入法、键鼠编码、主题、选区及基础数据结构参考并改造自 [TerminalStudio/xterm.dart 4.0.0](https://github.com/TerminalStudio/xterm.dart/tree/25bc19e49d9e948ba45bdb185d534c26bb3df9b2)，原作者 xuty，参考修订为 `25bc19e49d9e948ba45bdb185d534c26bb3df9b2`。
- Rust 终端解析、网格、回滚和重排使用 [alacritty_terminal 0.26.0](https://crates.io/crates/alacritty_terminal/0.26.0)，来自 [Alacritty](https://github.com/alacritty/alacritty) 项目。

Rust 封装、帧协议、行身份跟踪、Flutter 屏幕镜像与滚动选择适配由 PagaShell 维护。

相对 xterm.dart，组件移除了 Dart 输出解析与重排，改用 Rust 帧驱动缓冲，增加组合字符显示、稳定行 ID、滚动选区裁剪和释放处理；保留参考修订的 Windows `TextInputConfiguration.viewId` 适配，以及应用光标键独立于小键盘模式的编码修正。

PagaShell 的运行、测试均无需引入 `xterm` Dart 包。应用/UI 测试直接构造纯文本、颜色和模式的屏幕帧；ANSI、Unicode、重排等内核语义使用真实 Rust 测试及其生成的共享 fixture 验证。

升级官方 Rust 依赖时，应同步核验 VTE Handler 转发、行身份跟踪和 `TermMode` 位定义，再运行下述测试；不要直接放宽固定版本。

## 验证

从仓库根目录执行：

```bash
flutter pub get
flutter analyze
flutter test
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
```

终端的 Dart 与 Rust 测试均随项目测试运行，CI 和发版流程使用相同入口。

Rust 测试将增量帧镜像逐行对照官方原始网格，覆盖重复文本、整轮回滚淘汰、局部滚动区域、宽字符/组合字符、清屏、备用屏幕和尺寸变化。共享 fixture 同时用于 Flutter 的光标、绘制、输入模式和选区测试。

需要更新共享 fixture 时，在仓库根目录执行：

```bash
PAGASHELL_UPDATE_TERMINAL_FIXTURE=1 cargo test \
  --manifest-path rust/Cargo.toml \
  --lib terminal::tests::flutter_render_fixture_matches_native_parser
```

性能收益仍需使用 Profile / Release 对照测试；单元测试和构建不能替代真实远端 Vim、平台输入法与多终端负载验收。
