import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

class ProxyExportCode extends StatelessWidget {
  const ProxyExportCode(this.source, {required this.codeKey, super.key});

  final String source;
  final Key codeKey;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppTheme.surface(context),
      border: Border.all(color: AppTheme.border(context)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: shadcn.SelectableText(
        source,
        key: codeKey,
        style: const TextStyle(
          fontFamily: 'FiraCode Nerd Font Mono',
          fontSize: 12,
          height: 1.6,
        ),
      ),
    ),
  );
}
