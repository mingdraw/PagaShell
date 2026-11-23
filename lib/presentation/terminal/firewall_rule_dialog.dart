import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/firewall.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_radio_card_field.dart';
import '../components/app_select_field.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';

/// 创建 Linux 防火墙 TCP/UDP 端口规则的表单弹窗。
class FirewallRuleDialog extends StatefulWidget {
  const FirewallRuleDialog({
    required this.backend,
    required this.onSubmit,
    super.key,
  });

  final FirewallBackend backend;
  final Future<void> Function(List<FirewallRuleInput> inputs) onSubmit;

  @override
  State<FirewallRuleDialog> createState() => _FirewallRuleDialogState();
}

class _FirewallRuleDialogState extends State<FirewallRuleDialog> {
  final _form = GlobalKey<FormState>();
  FirewallAction _action = FirewallAction.allow;
  FirewallProtocol _protocol = FirewallProtocol.tcp;
  final List<TextEditingController> _ipControllers = [TextEditingController()];
  final List<TextEditingController> _portControllers = [
    TextEditingController(),
  ];
  final TextEditingController _priorityController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _showPriority => widget.backend.supportsPriority;
  bool get _showComment => widget.backend.supportsComment;

  @override
  void dispose() {
    for (final c in _ipControllers) {
      c.dispose();
    }
    for (final c in _portControllers) {
      c.dispose();
    }
    _priorityController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  void _addIpRow() {
    if (_busy || _ipControllers.length >= 16) return;
    setState(() => _ipControllers.add(TextEditingController()));
  }

  void _removeIpRow(int index) {
    if (_busy) return;
    if (_ipControllers.length == 1) {
      _ipControllers.first.clear();
      setState(() {});
      return;
    }
    final removed = _ipControllers.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  void _addPortRow() {
    if (_busy || _portControllers.length >= 16) return;
    setState(() => _portControllers.add(TextEditingController()));
  }

  void _removePortRow(int index) {
    if (_busy) return;
    if (_portControllers.length == 1) {
      _portControllers.first.clear();
      setState(() {});
      return;
    }
    final removed = _portControllers.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  List<String>? _collectSources() {
    final normalized = <String>[];
    for (final controller in _ipControllers) {
      final raw = controller.text.trim();
      if (raw.isEmpty) continue;
      for (final part in raw.split(RegExp(r'[,，]'))) {
        final piece = part.trim();
        if (piece.isEmpty) continue;
        final value = FirewallRuleInput.normalizeSource(piece);
        if (value == null) return null;
        if (!normalized.contains(value)) normalized.add(value);
      }
    }
    return normalized.isEmpty ? const [''] : normalized;
  }

  List<String>? _collectPorts() {
    final specs = <String>[];
    for (final controller in _portControllers) {
      final raw = controller.text.trim();
      if (raw.isEmpty) continue;
      final parsed = FirewallRuleInput.parsePortSpecs(raw);
      if (parsed == null) return null;
      for (final spec in parsed) {
        if (!specs.contains(spec)) specs.add(spec);
      }
    }
    return specs.isEmpty ? null : specs;
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    final sources = _collectSources();
    final ports = _collectPorts();
    if (sources == null || ports == null) return;
    final priority = _showPriority && _priorityController.text.trim().isNotEmpty
        ? int.tryParse(_priorityController.text.trim())
        : null;
    final comment = _showComment ? _commentController.text.trim() : '';

    final inputs = <FirewallRuleInput>[
      for (final source in sources)
        for (final port in ports)
          FirewallRuleInput(
            action: _action,
            protocol: _protocol,
            port: port,
            source: source,
            priority: priority,
            comment: comment,
          ),
    ];
    if (inputs.length > 64) {
      setState(() => _error = '单次最多创建 64 条防火墙规则');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(inputs);
      if (mounted) {
        setState(() => _busy = false);
        AppNavigation.closeDialog(result: true);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is SshEngineException
              ? error.message
              : '防火墙规则操作失败，请刷新列表检查',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validateIpField(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;
    for (final part in raw.split(RegExp(r'[,，]'))) {
      final piece = part.trim();
      if (piece.isEmpty) return 'IP 或网段格式无效，请检查后重试'.tr;
      if (FirewallRuleInput.normalizeSource(piece) == null) {
        return 'IP 或网段格式无效，请检查后重试'.tr;
      }
    }
    return null;
  }

  String? _validatePortField(int index, String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) {
      final hasAny = _portControllers.any((c) => c.text.trim().isNotEmpty);
      if (!hasAny && index == 0) {
        return '请输入端口号或端口段'.tr;
      }
      return null;
    }
    if (FirewallRuleInput.parsePortSpecs(raw) == null) {
      return '端口格式无效，请输入 1-65535 的端口、逗号列表或端口段'.tr;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Text('创建规则'.tr),
        scrollable: true,
        maxWidth: AppTheme.dialogMaxWidth,
        content: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppRadioCardField<FirewallAction>(
                key: const ValueKey('firewall-rule-action'),
                label: '动作'.tr,
                initialValue: _action,
                items: [
                  AppRadioCardOption(
                    value: FirewallAction.allow,
                    icon: AppIcons.circleCheck,
                    child: Text('允许'.tr),
                  ),
                  AppRadioCardOption(
                    value: FirewallAction.deny,
                    icon: AppIcons.circleX,
                    child: Text('拒绝'.tr),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _action = value),
              ),
              const SizedBox(height: 16),
              AppSelectField<FirewallProtocol>(
                key: const ValueKey('firewall-rule-protocol'),
                label: '协议'.tr,
                initialValue: _protocol,
                items: [
                  for (final protocol in FirewallProtocol.values)
                    AppSelectOption(
                      value: protocol,
                      child: Text(protocol.label),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) setState(() => _protocol = value);
                      },
              ),
              const SizedBox(height: 16),
              _sectionLabel('IP'.tr),
              const SizedBox(height: 6),
              for (var i = 0; i < _ipControllers.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: AppTextFormField(
                        key: ValueKey('firewall-rule-ip-$i'),
                        controller: _ipControllers[i],
                        enabled: !_busy,
                        enableSuggestions: false,
                        autocorrect: false,
                        smartPunctuation: false,
                        validator: _validateIpField,
                        decoration: AppInputDecoration(
                          hintText: '例如：172.16.10.11、172.16.0.0/24、2001:db8::1 或 2001:db8::/64'
                              .tr,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: AppIconButton(
                        key: ValueKey('firewall-rule-ip-remove-$i'),
                        semanticLabel: '清空或移除 IP'.tr,
                        tooltip: '清空或移除 IP'.tr,
                        onPressed: _busy ? null : () => _removeIpRow(i),
                        icon: const AppIcon(AppIcons.trash2, size: 15),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: shadcn.OutlineButton(
                  key: const ValueKey('firewall-rule-ip-add'),
                  leading: const AppIcon(AppIcons.plus, size: 16),
                  onPressed: _busy || _ipControllers.length >= 16
                      ? null
                      : _addIpRow,
                  child: Text('添加'.tr),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '留空表示应用于任何位置（IPv4 与 IPv6）'.tr,
                style: TextStyle(fontSize: 12, color: colors.mutedForeground),
              ),
              const SizedBox(height: 16),
              _sectionLabel('端口'.tr),
              const SizedBox(height: 6),
              for (var i = 0; i < _portControllers.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: AppTextFormField(
                        key: ValueKey('firewall-rule-port-$i'),
                        controller: _portControllers[i],
                        enabled: !_busy,
                        autofocus: i == 0,
                        enableSuggestions: false,
                        autocorrect: false,
                        smartPunctuation: false,
                        validator: (value) => _validatePortField(i, value),
                        onFieldSubmitted: (_) => unawaited(_submit()),
                        decoration: AppInputDecoration(
                          hintText: '例如：80、80,443 或 8080-8089'.tr,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: AppIconButton(
                        key: ValueKey('firewall-rule-port-remove-$i'),
                        semanticLabel: '清空或移除端口'.tr,
                        tooltip: '清空或移除端口'.tr,
                        onPressed: _busy ? null : () => _removePortRow(i),
                        icon: const AppIcon(AppIcons.trash2, size: 15),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: shadcn.OutlineButton(
                  key: const ValueKey('firewall-rule-port-add'),
                  leading: const AppIcon(AppIcons.plus, size: 16),
                  onPressed: _busy || _portControllers.length >= 16
                      ? null
                      : _addPortRow,
                  child: Text('添加'.tr),
                ),
              ),
              if (_showPriority) ...[
                const SizedBox(height: 16),
                AppTextFormField(
                  key: const ValueKey('firewall-rule-priority'),
                  controller: _priorityController,
                  enabled: !_busy,
                  enableSuggestions: false,
                  autocorrect: false,
                  smartPunctuation: false,
                  validator: (value) {
                    if (!FirewallRuleInput.isValidPriority(value ?? '')) {
                      return '优先级范围需在 -32768 到 32767 之间'.tr;
                    }
                    return null;
                  },
                  decoration: AppInputDecoration(
                    labelText: '优先级'.tr,
                    hintText: '-32768 ~ 32767',
                    helperText: '留空使用默认规则；填写优先级或限制 IP/拒绝时使用富规则'.tr,
                  ),
                ),
              ],
              if (_showComment) ...[
                const SizedBox(height: 16),
                AppTextFormField(
                  key: const ValueKey('firewall-rule-comment'),
                  controller: _commentController,
                  enabled: !_busy,
                  enableSuggestions: false,
                  autocorrect: false,
                  smartPunctuation: false,
                  validator: (value) =>
                      FirewallRuleInput.validateComment(value ?? '')?.tr,
                  decoration: AppInputDecoration(
                    labelText: '描述'.tr,
                    hintText: '可选，用于备注规则用途'.tr,
                  ),
                ),
              ],
            ],
          ),
        ),
        feedback: _busy
            ? Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: shadcn.CircularProgressIndicator(),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('正在创建防火墙规则…'.tr)),
                ],
              )
            : _error == null
            ? null
            : Text(
                AppTranslations.error(_error!),
                style: TextStyle(color: colors.destructive),
              ),
        actions: [
          shadcn.OutlineButton(
            onPressed: _busy
                ? null
                : () => AppNavigation.closeDialog(result: false),
            child: Text('取消'.tr),
          ),
          shadcn.PrimaryButton(
            key: const ValueKey('firewall-rule-submit'),
            onPressed: _busy ? null : _submit,
            child: Text('创建'.tr),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) => Text(
    label,
    style: const TextStyle(
      fontSize: AppTheme.inputFontSize,
      fontWeight: FontWeight.w500,
    ),
  );
}
