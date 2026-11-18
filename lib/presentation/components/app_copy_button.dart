import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../theme/app_theme.dart';
import 'app_icon.dart';
import 'app_icon_button.dart';

/// 通用图标复制按钮，点击后短暂显示成功对勾与「已复制」提示。
class AppCopyButton extends StatefulWidget {
  const AppCopyButton({
    required this.text,
    this.size = 13,
    this.semanticLabel,
    super.key,
  });

  final String text;
  final double size;
  final String? semanticLabel;

  @override
  State<AppCopyButton> createState() => _AppCopyButtonState();
}

class _AppCopyButtonState extends State<AppCopyButton> {
  static const _feedbackDuration = Duration(milliseconds: 1500);

  Timer? _resetTimer;
  bool _copied = false;

  @override
  void didUpdateWidget(covariant AppCopyButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text && _copied) {
      _resetTimer?.cancel();
      _resetTimer = null;
      _copied = false;
    }
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.text)));
    _resetTimer?.cancel();
    setState(() => _copied = true);
    _resetTimer = Timer(_feedbackDuration, () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.semanticLabel ?? '复制'.tr;
    return AppIconButton(
      semanticLabel: label,
      tooltip: _copied ? '已复制'.tr : label,
      icon: AppIcon(
        _copied ? AppIcons.check : AppIcons.copy,
        size: widget.size,
        color: _copied ? StatusColors.ready : null,
      ),
      onPressed: _copy,
    );
  }
}
