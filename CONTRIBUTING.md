# 参与贡献 Contributing

感谢你对 PagaShell 的关注！

## 开发环境

- Flutter stable ≥ 3.47 / Dart ≥ 3.13（`flutter --version`）；shadcn_flutter 组件需要此工具链
- Rust stable（`cargo --version`）；cargokit 随 Flutter 构建编译 SSH 引擎
- 平台工具链：Windows 需 Visual Studio C++ 工作负载；macOS 需 Xcode；Linux 需 `ninja-build libgtk-3-dev`

```bash
flutter pub get
./script/build_and_run.sh  # macOS Debug，保留 Flutter 的 r / R 交互
# Windows / Linux：flutter run -d windows / flutter run -d linux
```

### macOS 调试连接与热重载

启动脚本合并 `no_proxy` 和 `NO_PROXY`，补齐 `localhost`、`127.0.0.1` 和 IPv6 本机地址，避免 VM Service / DDS 的 WebSocket 被 HTTP 代理转发；外部代理和已有绕过项仍保留。它会先结束当前检出目录的旧 Debug 应用，再交给 `flutter run` 构建和启动。请先结束旧 Debug 应用中需要保留的连接。

- 出现 `Flutter run key commands` 后，按 `r` 热重载、按 `R` 热重启（会清空 Dart 会话状态）、按 `q` 退出。连接 VM Service 的等待阶段尚未监听这些按键；卡在这里时先按 `Ctrl+C`，若应用仍在运行，再关闭该 Debug 窗口。
- Flutter 参数直接透传，例如 `./script/build_and_run.sh --verbose`。使用特定 SDK 时可设置 `FLUTTER_BIN=/path/to/flutter`。
- 若直接运行 `flutter run -d macos`，请确保终端的 `no_proxy` 和 `NO_PROXY` 都包含本机地址；小写变量优先，不能只补大写。把绕过项设为终端启动时自动导出，不要只放在尚未执行的代理开关函数里。修改 `~/.zshrc` 后，已经打开的终端需要先执行 `source ~/.zshrc`，或新开一个终端标签页。
- Swift 或 Rust 原生代码、FFI 接口发生变化时，需要完整退出并重建；原生代码不能通过 Dart 热重载更新。修改 FFI 接口仍须按下面的版本生成桥接代码。
- `Failed to foreground app; open returned 1` 是 Flutter 调用 macOS 前台化失败的提示；需结合后续 VM Service 是否连接成功判断，不能单凭这一行认定应用崩溃。

代理绕过与重启范围的回归检查：`python3 -m unittest discover -s script/tests -p '*_test.py'`。实际调试验收仍需启动 Debug 应用，确认 VM Service 连接以及 `r` / `R` 的执行结果。

## 代码生成与检查

修改数据库表后，在仓库根目录重新生成 Drift 代码：

```bash
dart run build_runner build
```

修改 Rust FFI 接口后，使用与依赖一致的生成器版本，禁止手工修改桥接产物：

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter_rust_bridge_codegen generate
```

确保 Cargo 的可执行目录已加入 `PATH`。在 `rust/` 目录执行 `cargo fmt --check`、`cargo clippy -- -D warnings` 和 `cargo test`。Rust 测试仅在本机回环地址启动临时 SSH 服务，验证指纹门禁与认证取消，无需真实服务器或凭据。

## 提交约定

- 提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/)：`feat: ...` / `fix: ...` / `docs: ...` / `refactor: ...` / `test: ...` / `chore: ...`
- 一个 PR 只做一件事，保持 diff 聚焦
- 提交前本地跑通：`flutter analyze && flutter test`

## 架构约束

请先阅读 [docs/DESIGN.md](docs/DESIGN.md)。核心规则：

1. 分层单向依赖：`presentation → application → domain ← infrastructure`，`domain` 层禁止依赖 Flutter
2. 凭据（密码/私钥）只能进加密 Vault，禁止出现在普通存储、日志或错误信息中
3. 不引入任何遥测、云服务依赖

## 报告问题

- Bug / 功能建议请走 [Issues](../../issues)
