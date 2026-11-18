import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';

/// 终端右侧运维面板共用的搜索框，支持 Esc 清空与右侧一键清除按钮。
class TerminalSearchField extends StatefulWidget {
  const TerminalSearchField({
    required this.fieldKey,
    required this.clearKey,
    required this.controller,
    required this.semanticLabel,
    required this.hintText,
    super.key,
  });

  final Key fieldKey;
  final Key clearKey;
  final TextEditingController controller;
  final String semanticLabel;
  final String hintText;

  @override
  State<TerminalSearchField> createState() => _TerminalSearchFieldState();
}

class _TerminalSearchFieldState extends State<TerminalSearchField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _clear() {
    widget.controller.clear();
    _focus.requestFocus();
  }

  void _handleEscape() {
    if (widget.controller.text.isNotEmpty) {
      _clear();
    } else {
      _focus.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): _handleEscape},
    child: Semantics(
      label: widget.semanticLabel,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.controller,
        builder: (context, value, _) => AppTextFormField(
          key: widget.fieldKey,
          controller: widget.controller,
          focusNode: _focus,
          compact: true,
          decoration: AppInputDecoration(
            hintText: widget.hintText,
            suffixIcon: value.text.isEmpty
                ? const AppIcon(AppIcons.search, size: 14)
                : SizedBox.square(
                    dimension: 18,
                    child: AppIconButton.text(
                      key: widget.clearKey,
                      semanticLabel: '清空搜索'.tr,
                      tooltip: '清空搜索'.tr,
                      density: shadcn.ButtonDensity.compact,
                      onPressed: _clear,
                      icon: const AppIcon(AppIcons.x, size: 12),
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
}
