import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/settings/settings_controller.dart';
import '../../application/updates/app_update_controller.dart';
import '../../domain/updates/app_release.dart';
import '../components/app_dialog.dart';
import '../navigation/app_navigation.dart';

class AppUpdateSection extends StatefulWidget {
  const AppUpdateSection({super.key});

  @override
  State<AppUpdateSection> createState() => _AppUpdateSectionState();
}

class _AppUpdateSectionState extends State<AppUpdateSection> {
  final _settings = Get.find<SettingsController>();
  final _updates = Get.find<AppUpdateController>();
  String? _saveError;

  Future<void> _setAutomaticUpdates(bool value) async {
    setState(() => _saveError = null);
    try {
      await _settings.setAutomaticUpdates(value);
    } on Object {
      if (mounted) setState(() => _saveError = '自动更新设置保存失败，请重试');
    }
  }

  Future<void> _check() async {
    final release = await _updates.check();
    if (mounted && release != null) {
      await showAppUpdateDialog(_updates, release);
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final muted = shadcn.Theme.of(context).colorScheme.mutedForeground;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('软件更新'.tr, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('自动更新'.tr),
                  const SizedBox(height: 4),
                  Text(
                    '启动时检查新版本，下载和安装前会询问你。'.tr,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            shadcn.Switch(
              key: const ValueKey('automatic-updates-switch'),
              value: _settings.automaticUpdates.value,
              onChanged: _settings.savingAutomaticUpdates.value
                  ? null
                  : _setAutomaticUpdates,
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                '当前版本：@version'.trParams({
                  'version': _updates.currentVersion.value.isEmpty
                      ? '—'
                      : 'v${_updates.currentVersion.value}',
                }),
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ),
            shadcn.OutlineButton(
              key: const ValueKey('check-for-updates'),
              onPressed: _updates.busy ? null : _check,
              child: Text(
                (_updates.phase.value == UpdatePhase.checking
                        ? '正在检查更新…'
                        : '检查更新')
                    .tr,
              ),
            ),
          ],
        ),
        if (_saveError != null || _updates.message.value.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            (_saveError ?? _updates.message.value).tr,
            key: const ValueKey('update-status'),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ],
    );
  });
}

Future<void> showAppUpdateDialog(
  AppUpdateController updates,
  AppRelease release, {
  bool automatic = false,
}) async {
  if (!updates.beginPrompt(release, automatic: automatic)) return;
  try {
    await AppNavigation.dialog<void>(
      _AppUpdateDialog(updates: updates, release: release),
      barrierDismissible: false,
    );
  } finally {
    updates.endPrompt();
  }
}

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({required this.updates, required this.release});
  final AppUpdateController updates;
  final AppRelease release;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  bool _cancelling = false;

  Future<void> _cancel() async {
    setState(() => _cancelling = true);
    await widget.updates.cancelDownload();
    if (mounted) AppNavigation.closeDialog<void>();
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final updates = widget.updates;
    final phase = updates.phase.value;
    final busy = updates.busy;
    final label = switch (phase) {
      UpdatePhase.downloading => '正在下载更新…',
      UpdatePhase.verifying => '正在校验安装包…',
      UpdatePhase.preparing => '正在准备安装…',
      UpdatePhase.installing => '正在关闭会话并安装更新…',
      _ => '',
    };
    return PopScope(
      canPop: !busy && !_cancelling,
      child: AppDialog(
        key: const ValueKey('app-update-dialog'),
        title: Text('发现新版本 @version'.trParams({'version': widget.release.tag})),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('安装后将关闭当前会话并重新启动，配置和凭据会保留。'.tr),
            if (widget.release.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                '更新内容'.tr,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                widget.release.notes,
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ],
          ],
        ),
        feedback: busy
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(label.tr),
                  const SizedBox(height: 12),
                  shadcn.LinearProgressIndicator(
                    value: phase == UpdatePhase.downloading
                        ? updates.progress.value
                        : null,
                  ),
                  if (phase == UpdatePhase.downloading) ...[
                    const SizedBox(height: 8),
                    Text('${(updates.progress.value * 100).floor()}%'),
                  ],
                ],
              )
            : updates.message.value.isEmpty
            ? null
            : Text(updates.message.value.tr),
        actions: [
          if (!busy)
            shadcn.OutlineButton(
              onPressed: AppNavigation.closeDialog<void>,
              child: Text('暂不更新'.tr),
            ),
          if (updates.canCancel)
            shadcn.OutlineButton(
              key: const ValueKey('cancel-update-download'),
              onPressed: _cancelling ? null : _cancel,
              child: Text((_cancelling ? '正在取消…' : '取消下载').tr),
            ),
          shadcn.PrimaryButton(
            key: const ValueKey('install-app-update'),
            onPressed: busy || _cancelling
                ? null
                : () => unawaited(updates.install(widget.release)),
            child: Text('下载并更新'.tr),
          ),
        ],
      ),
    );
  });
}
