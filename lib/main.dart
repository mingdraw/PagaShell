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
  // 两项初始化互不依赖，并行执行以缩短首帧前的等待。
  final (_, homeDirectory) = await (
    // 加载 Rust 引擎动态库并初始化 FFI 桥。
    RustLib.init(),
    // 沙盒内 HOME 是容器目录；由系统账号记录取得真实用户目录。
    Platform.isMacOS
        ? const MethodChannel('pagashell/files')
              .invokeMethod<String>('getUserHomeDirectory')
        : Future<String?>.value(),
  ).wait;

  final window = WindowManager.instance.getCurrent();
  if (window != null) {
    window.titleBarStyle = TitleBarStyle.hidden;
    window.isWindowControlButtonsVisible = true;
    if (window.isFullScreen) window.isFullScreen = false;
    if (window.isMaximized) window.unmaximize();
    if (window.isMinimized) window.restore();
    window.setSize(const Size(1200, 760).toNative(), false);
    window.center();
    window.minimumSize = const Size(860, 540).toNative();
    window.title = 'PagaShell';
  }
  if (Platform.isMacOS) {
    await const MethodChannel('pagashell/window').invokeMethod<void>(
      'setTitleBarHeight',
      {'height': AppTheme.windowHeaderHeight},
    );
  }
  window?.show();
  window?.focus();

  runApp(PagaShellApp(binding: AppBinding(localHomeDirectory: homeDirectory)));
}
