# Repository Guidelines（仓库贡献指南）

## 项目结构与模块划分

PagaShell 是基于 Flutter 和 Rust 引擎的纯本地桌面 SSH/SFTP 客户端，支持 macOS、Windows 和 Linux。

- `lib/presentation/`：组件与桌面界面；`lib/application/`：GetX 控制器与依赖装配。
- `lib/domain/`：纯 Dart 实体与接口；`lib/infrastructure/`：数据库、SSH 与凭据存储实现。
- `rust/src/api/`：Rust 引擎接口；`rust_builder/`：原生构建集成。
- `test/`：单元测试与组件测试，公共辅助代码放在 `test/support/`；`integration_test/`：平台集成测试。
- `assets/fonts/`：内置终端字体及许可证；`macos/`、`windows/`、`linux/`：平台宿主工程。
- `docs/DESIGN.md`：架构与路线图。部分规划与实现存在差异，需结合当前代码和配置判断。

## 构建、测试与开发命令

安装 Flutter stable 3.47+、兼容的 Dart SDK（`^3.13.0`）、Rust 及目标桌面平台工具链。在仓库根目录执行：

```bash
flutter pub get                       # 安装 Dart 依赖
flutter run -d macos                   # 本地运行，可替换为 windows 或 linux
flutter analyze                       # 执行 Dart 类型与代码规范检查
flutter test                          # 运行单元测试与组件测试
dart format lib test integration_test  # 格式化 Dart 代码
flutter build macos --release          # 构建目标桌面平台的发布版本
```

在 `rust/` 目录执行 `cargo fmt --check` 和 `cargo clippy -- -D warnings`，与 CI 检查保持一致。Flutter 构建通过 cargokit 自动编译 Rust 库。

## 代码风格与命名约定

Dart 使用两空格缩进，文件名采用 `snake_case.dart`，类型名采用 `UpperCamelCase`，成员名采用 `lowerCamelCase`。遵循 `analysis_options.yaml`：启用 Flutter lints 和严格类型检查，使用单引号、显式返回类型与尾随逗号。

保持单向依赖 `presentation → application → domain ← infrastructure`，领域层不得依赖 Flutter。控制器通过构造函数注入依赖。`*.g.dart`、`lib/src/rust/` 和 `rust/src/frb_generated.rs` 属于生成代码，应重新生成，禁止手工修改。

状态、路由、HTTP 与业务国际化统一使用 GetX。HTTP 直接注入 `GetConnect`，检查 `Response.isOk` 和状态码；翻译在 `AppTranslations` 补齐中英文，中文原文作为键，通过 `.tr` 或 `.trParams` 展示，不引入 ARB 或独立客户端包装。

界面统一使用 `shadcn_flutter`，以 `ShadcnApp` 为入口，不引入 Material/Cupertino 组件或主题。GetX 通过 `Get.key`、`GetObserver` 管理导航，弹窗使用 `AppNavigation.dialog` 与 `AppDialog`，提示使用 `AppNotice`。表单使用 `AppTextFormField`、`AppSelectField` 对接 Flutter 核心 Form 校验；配色与尺寸集中在 `AppTheme`。长表单需可滚动，并保证操作按钮可见。

## 测试规范

单元测试与组件测试使用 `flutter_test`，平台行为测试使用 `integration_test`。测试文件命名为 `*_test.dart`，目录对应被测代码的分层。行为变更需补充回归测试；当前未配置覆盖率数值门槛。平台测试需单独执行，例如 `flutter test integration_test/secret_store_test.dart -d macos`。

## 提交与 Pull Request 规范

当前检出的仓库尚无提交历史。遵循 `CONTRIBUTING.md` 中的 Conventional Commits 约定，例如 `feat: ...`、`fix: ...`、`docs: ...`。每个 PR 聚焦一件事，说明行为变更、关联相关 Issue、列出验证结果；界面变更附截图。提交前运行静态分析和测试。

## 安全与配置

密码、私钥等敏感信息只能存入凭据保险库或系统钥匙串，不得进入普通存储、日志或错误信息。禁止引入遥测或云服务依赖。安全漏洞按 `SECURITY.md` 指引私下报告。
