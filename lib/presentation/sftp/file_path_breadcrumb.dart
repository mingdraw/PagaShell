import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_menu.dart';

/// 远程路径使用 POSIX 规则；本地路径同时支持盘符和 UNC 共享根目录。
class FilePathBreadcrumb extends StatelessWidget {
  const FilePathBreadcrumb({
    required this.path,
    required this.remote,
    required this.onNavigate,
    super.key,
  });

  final String path;
  final bool remote;
  final ValueChanged<String>? onNavigate;

  @override
  Widget build(BuildContext context) {
    final windows =
        !remote &&
        (RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(path) ||
            path.startsWith(r'\\') ||
            path.startsWith('//'));
    final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
    final parts = paths.split(path);
    return Semantics(
      label: path,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const separatorWidth = 20.0;
          const overflowWidth = 24.0;
          final style = DefaultTextStyle.of(context).style
              .copyWith(fontSize: 12, fontWeight: FontWeight.w500);
          final widths = [
            for (var index = 0; index < parts.length; index++)
              _textWidth(context, parts[index], style) +
                  (index == parts.length - 1 ? 0 : 8),
          ];
          final visible = List.generate(parts.length, (index) => index);
          final hidden = <int>[];
          double requiredWidth() =>
              visible.fold(0.0, (sum, index) => sum + widths[index]) +
              (hidden.isEmpty ? 0 : overflowWidth) +
              math.max(0, visible.length + (hidden.isEmpty ? 0 : 1) - 1) *
                  separatorWidth;

          // 优先折叠远离当前目录的中间层，始终保留最后两层。
          while (requiredWidth() > constraints.maxWidth && visible.length > 3) {
            hidden.add(visible.removeAt(1));
          }
          if (requiredWidth() > constraints.maxWidth && visible.length == 3) {
            hidden.insert(0, visible.removeAt(0));
          }
          if (requiredWidth() > constraints.maxWidth && visible.isNotEmpty) {
            final budget = math.max(
              0.0,
              constraints.maxWidth -
                  (hidden.isEmpty ? 0 : overflowWidth) -
                  (visible.length + (hidden.isEmpty ? 0 : 1) - 1) *
                      separatorWidth,
            );
            if (visible.length == 1) {
              widths[visible.last] = budget;
            } else {
              final parent = visible[visible.length - 2];
              final current = visible.last;
              // 长目录名也各留一个可见位置；较短的一侧让出剩余空间。
              widths[parent] = math.min(
                widths[parent],
                budget - math.min(widths[current], budget / 2),
              );
              widths[current] = math.min(
                widths[current],
                budget - widths[parent],
              );
            }
          }

          Widget segment(int index) {
            final label = Text(
              parts[index],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            );
            if (index == parts.length - 1) {
              return SizedBox(width: widths[index], child: label);
            }
            final target = paths.joinAll(parts.take(index + 1));
            return SizedBox(
              width: widths[index],
              child: shadcn.TextButton(
                key: ValueKey('sftp-path-segment-$target'),
                size: shadcn.ButtonSize.small,
                density: shadcn.ButtonDensity.compact,
                onPressed: onNavigate == null
                    ? null
                    : () => onNavigate!(target),
                child: SizedBox(
                  width: math.max(0, widths[index] - 8),
                  child: label,
                ),
              ),
            );
          }

          Widget overflow() => SizedBox(
            width: overflowWidth,
            child: Builder(
              builder: (anchor) => Semantics(
                label: '其他上级目录'.tr,
                child: shadcn.TextButton(
                  key: const ValueKey('sftp-path-overflow'),
                  onPressed: onNavigate == null
                      ? null
                      : () => shadcn.showDropdown<void>(
                          context: anchor,
                          follow: false,
                          builder: (_) => shadcn.DropdownMenu(
                            children: appMenuItems([
                              for (final index in hidden)
                                (
                                  paths.joinAll(parts.take(index + 1)),
                                  parts[index],
                                ),
                            ], (target) => onNavigate!(target)),
                          ),
                        ),
                  child: const Icon(shadcn.LucideIcons.ellipsis, size: 16),
                ),
              ),
            ),
          );

          return shadcn.ButtonStyleOverride(
            padding: (_, _, _) =>
                const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: shadcn.Breadcrumb(
              key: ValueKey('sftp-path-$path'),
              separator: const SizedBox(
                width: separatorWidth,
                child: Icon(shadcn.LucideIcons.chevronRight, size: 12),
              ),
              children: [
                for (final index in visible) ...[
                  if (hidden.isNotEmpty && index == hidden.last + 1) overflow(),
                  segment(index),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }
}
