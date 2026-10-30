import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/proxy/clash_extension_script.dart';
import '../../domain/entities/proxy_config.dart';
import '../components/app_dialog.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';

class ClashExtensionDialog extends StatefulWidget {
  const ClashExtensionDialog({required this.script, super.key});

  final ClashExtensionScript script;

  @override
  State<ClashExtensionDialog> createState() => _ClashExtensionDialogState();
}

class _ClashExtensionDialogState extends State<ClashExtensionDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.script.source));
      if (mounted) setState(() => _copied = true);
    } on Object {
      AppNotice.error('复制失败，请重试'.tr);
    }
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text('Clash 扩展脚本'.tr),
    maxWidth: AppTheme.clashScriptDialogMaxWidth,
    scrollable: true,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('订阅 → 右键当前订阅 → 编辑扩展脚本。已有自定义脚本时，请合入原来的 main 函数。'.tr),
        const SizedBox(height: 8),
        Text(
          (widget.script.mode == ProxyMode.global
                  ? '全局模式：Clash 原有规则未匹配的其余流量通过 PagaShell 网关。'
                  : widget.script.rules.isEmpty
                  ? '尚未配置代理规则，脚本仅添加节点。可先在规则模式下添加规则，再重新生成。'
                  : '规则模式：命中已配置规则的请求通过 PagaShell 网关，其余流量沿用 Clash 原有分流。')
              .tr,
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surface(context),
            border: Border.all(color: AppTheme.border(context)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: shadcn.SelectableText(
              widget.script.source,
              key: const ValueKey('clash-extension-code'),
              style: const TextStyle(
                fontFamily: 'FiraCode Nerd Font Mono',
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ),
        ),
      ],
    ),
    actions: [
      shadcn.OutlineButton(
        onPressed: () => AppNavigation.closeDialog<void>(),
        child: Text('关闭'.tr),
      ),
      shadcn.PrimaryButton(
        key: const ValueKey('clash-extension-copy'),
        onPressed: _copy,
        leading: Icon(
          _copied ? shadcn.LucideIcons.check : shadcn.LucideIcons.copy,
          size: 16,
        ),
        child: Text((_copied ? '已复制' : '复制脚本').tr),
      ),
    ],
  );
}
