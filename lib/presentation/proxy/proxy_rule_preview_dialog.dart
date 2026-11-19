import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/entities/proxy_config.dart';
import '../../domain/proxy/proxy_rule_preview.dart';
import '../components/app_dialog.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';

class ProxyRulePreviewDialog extends StatefulWidget {
  const ProxyRulePreviewDialog({required this.config, super.key});

  final ProxyConfig config;

  @override
  State<ProxyRulePreviewDialog> createState() => _ProxyRulePreviewDialogState();
}

class _ProxyRulePreviewDialogState extends State<ProxyRulePreviewDialog> {
  final _target = TextEditingController();
  final _dns = TextEditingController();
  ProxyRulePreview? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _target.addListener(_clearFeedback);
    _dns.addListener(_clearFeedback);
  }

  @override
  void dispose() {
    _target.dispose();
    _dns.dispose();
    super.dispose();
  }

  void _evaluate() {
    setState(() {
      _result = null;
      _error = null;
      try {
        _result = previewProxyRules(
          widget.config,
          _target.text,
          dnsAddresses: _dns.text
              .split(RegExp(r'[,，\s]+'))
              .where((ip) => ip.isNotEmpty),
        );
      } on StateError catch (error) {
        _error = error.message.toString();
      }
    });
  }

  void _clearFeedback() {
    if (_result != null || _error != null) {
      setState(() {
        _result = null;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final result = _result;
    return AppDialog(
      title: Text('测试代理规则'.tr),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextFormField(
              key: const ValueKey('proxy-preview-target'),
              controller: _target,
              autofocus: true,
              smartPunctuation: false,
              decoration: AppInputDecoration(labelText: '目标域名或 IP'.tr),
              onFieldSubmitted: (_) => _evaluate(),
            ),
            const SizedBox(height: 12),
            AppTextFormField(
              controller: _dns,
              smartPunctuation: false,
              decoration: AppInputDecoration(
                labelText: 'DNS 解析 IP（可选）'.tr,
                hintText: '192.0.2.10, 2001:db8::1',
              ),
              onFieldSubmitted: (_) => _evaluate(),
            ),
          ],
        ),
      ),
      feedback: _error != null
          ? Text(_error!.tr, style: TextStyle(color: colors.destructive))
          : result == null
          ? null
          : Text(switch (result.route) {
              ProxyPreviewRoute.gateway =>
                result.rule == null
                    ? '通过网关（全局模式）'.tr
                    : '通过网关 · 命中 @rule'.trParams({'rule': result.rule!.value}),
              ProxyPreviewRoute.direct => '直接连接（未命中规则）'.tr,
              ProxyPreviewRoute.needsDns =>
                '没有命中域名规则。请填写 DNS 解析 IP，以判断是否命中 IP 规则。'.tr,
            }, key: const ValueKey('proxy-preview-result')),
      actions: [
        shadcn.OutlineButton(
          onPressed: AppNavigation.closeDialog<void>,
          child: Text('关闭'.tr),
        ),
        shadcn.PrimaryButton(
          key: const ValueKey('proxy-preview-evaluate'),
          onPressed: _evaluate,
          child: Text('测试'.tr),
        ),
      ],
    );
  }
}
