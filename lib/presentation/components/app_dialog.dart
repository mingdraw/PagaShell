import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

/// GetX 管理模态路由，shadcn Card 管理外观；内容滚动而操作按钮保持可见。
class AppDialog extends StatelessWidget {
  const AppDialog({
    required this.title,
    required this.content,
    this.feedback,
    this.actions = const [],
    this.scrollable = false,
    this.maxWidth = AppTheme.dialogMaxWidth,
    super.key,
  });

  final Widget title;
  final Widget content;
  final Widget? feedback;
  final List<Widget> actions;
  final bool scrollable;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24) + MediaQuery.viewInsetsOf(context),
    child: Align(
      alignment: Alignment.center,
      child: shadcn.Card(
        theme: const shadcn.CardTheme(padding: EdgeInsets.all(24)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DefaultTextStyle.merge(
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                child: title,
              ),
              const SizedBox(height: 20),
              Flexible(
                child: scrollable
                    ? SingleChildScrollView(
                        // 为输入框外侧的焦点边框和桌面滚动条保留空间。
                        padding: AppTheme.dialogScrollPadding(context),
                        child: content,
                      )
                    : content,
              ),
              if (feedback != null) ...[const SizedBox(height: 16), feedback!],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
