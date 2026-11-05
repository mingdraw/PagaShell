import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'application/app_binding.dart';
import 'presentation/theme/app_theme.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 三项初始化互不依赖，并行执行以缩短首帧前的等待。
  final (_, _, homeDirectory) = await (
    // 加载 Rust 引擎动态库并初始化 FFI 桥。
    RustLib.init(),
    // 交给 ShellPage 等待本地对话写入后再关闭原生窗口。
    windowManager.ensureInitialized().then(
      (_) => windowManager.setPreventClose(true),
    ),
    // 沙盒内 HOME 是容器目录；由系统账号记录取得真实用户目录。
    Platform.isMacOS
        ? const MethodChannel('pagashell/files')
              .invokeMethod<String>('getUserHomeDirectory')
        : Future<String?>.value(),
  ).wait;

  const windowOptions = WindowOptions(
    size: Size(1200, 760),
    minimumSize: Size(860, 540),
    center: true,
    title: 'PagaShell',
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (Platform.isMacOS) {
      await const MethodChannel('pagashell/window').invokeMethod<void>(
        'setTitleBarHeight',
        {'height': AppTheme.windowHeaderHeight},
      );
    }
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(PagaShellApp(binding: AppBinding(localHomeDirectory: homeDirectory)));
}
