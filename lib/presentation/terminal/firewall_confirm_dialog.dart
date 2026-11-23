import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/firewall.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';

/// 删除单条防火墙规则前的确认弹窗；涉及 SSH 或在用服务时提示风险。
class FirewallDeleteRuleDialog extends StatefulWidget {
  const FirewallDeleteRuleDialog({
    required this.rule,
    required this.onConfirm,
    super.key,
  });

  final FirewallRule rule;
  final Future<void> Function() onConfirm;

  @override
  State<FirewallDeleteRuleDialog> createState() =>
      _FirewallDeleteRuleDialogState();
}

class _FirewallDeleteRuleDialogState extends State<FirewallDeleteRuleDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm();
      if (mounted) {
        setState(() => _busy = false);
        AppNavigation.closeDialog(result: true);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is SshEngineException
              ? error.message
              : '删除防火墙规则失败，请刷新列表检查',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final rule = widget.rule;
    final actionText = (rule.action == FirewallAction.allow ? '允许' : '拒绝').tr;
    final sourceText = rule.isAnySource
        ? '${rule.source.isEmpty ? '0.0.0.0/0, ::/0' : rule.source} (${'任何位置'.tr})'
        : rule.source;
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Text('删除防火墙规则'.tr),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('确认删除以下防火墙规则？此操作会立即生效。'.tr),
            const SizedBox(height: 12),
            shadcn.OutlineBadge(
              child: Text(
                '$actionText · ${rule.protocol.label} ${rule.port} · $sourceText',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (rule.usedProcesses.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '当前关联进程：@processes'.trParams({
                  'processes': rule.usedProcesses.map((p) => p.label).join('、'),
                }),
                style: TextStyle(fontSize: 12, color: colors.mutedForeground),
              ),
            ],
            if (rule.coversSsh && rule.action == FirewallAction.allow) ...[
              const SizedBox(height: 12),
              Text(
                '注意：此规则涉及 SSH 端口或 sshd 服务，删除后可能导致无法新建 SSH 连接。'.tr,
                key: const ValueKey('firewall-delete-ssh-warning'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: colors.destructive,
                ),
              ),
            ],
          ],
        ),
        feedback: _busy
            ? Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: shadcn.CircularProgressIndicator(),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('正在删除防火墙规则…'.tr)),
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
          shadcn.DestructiveButton(
            key: const ValueKey('firewall-confirm-delete'),
            onPressed: _busy ? null : _submit,
            child: Text('删除'.tr),
          ),
        ],
      ),
    );
  }
}

/// 防火墙服务启停或重载前的确认弹窗。
class FirewallServiceActionDialog extends StatefulWidget {
  const FirewallServiceActionDialog({
    required this.backend,
    required this.action,
    required this.onConfirm,
    super.key,
  });

  final FirewallBackend backend;
  final FirewallServiceAction action;
  final Future<void> Function() onConfirm;

  @override
  State<FirewallServiceActionDialog> createState() =>
      _FirewallServiceActionDialogState();
}

class _FirewallServiceActionDialogState
    extends State<FirewallServiceActionDialog> {
  bool _busy = false;
  String? _error;

  String get _title => switch (widget.action) {
    FirewallServiceAction.enable => '开启防火墙',
    FirewallServiceAction.disable => '关闭防火墙',
    FirewallServiceAction.reload => '重载防火墙',
  };

  String get _confirmLabel => switch (widget.action) {
    FirewallServiceAction.enable => '开启',
    FirewallServiceAction.disable => '停用',
    FirewallServiceAction.reload => '重载',
  };

  String get _message => switch (widget.action) {
    FirewallServiceAction.enable =>
      '开启 @backend 前请确认已放行 SSH 端口，避免断开后无法重新连接。'.trParams({
        'backend': widget.backend.displayName,
      }),
    FirewallServiceAction.disable =>
      '关闭 @backend 后将停止端口拦截规则，服务器监听端口可能直接暴露。'.trParams({
        'backend': widget.backend.displayName,
      }),
    FirewallServiceAction.reload => '将重新加载 @backend 配置并使已保存规则生效。'.trParams({
      'backend': widget.backend.displayName,
    }),
  };

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm();
      if (mounted) {
        setState(() => _busy = false);
        AppNavigation.closeDialog(result: true);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is SshEngineException
              ? error.message
              : '防火墙服务操作失败，请刷新状态后检查',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final destructive = widget.action == FirewallServiceAction.disable;
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Text(_title.tr),
        content: Text(_message),
        feedback: _busy
            ? Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: shadcn.CircularProgressIndicator(),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('正在执行防火墙操作…'.tr)),
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
          if (destructive)
            shadcn.DestructiveButton(
              key: ValueKey('firewall-confirm-service-${widget.action.name}'),
              onPressed: _busy ? null : _submit,
              child: Text(_confirmLabel.tr),
            )
          else
            shadcn.PrimaryButton(
              key: ValueKey('firewall-confirm-service-${widget.action.name}'),
              onPressed: _busy ? null : _submit,
              child: Text(_confirmLabel.tr),
            ),
        ],
      ),
    );
  }
}
