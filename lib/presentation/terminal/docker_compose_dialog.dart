import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';

class DockerComposeDialog extends StatefulWidget {
  const DockerComposeDialog({
    required this.project,
    required this.action,
    required this.onConfirm,
    super.key,
  });

  final DockerResource project;
  final DockerComposeAction action;
  final Future<void> Function() onConfirm;

  @override
  State<DockerComposeDialog> createState() => _DockerComposeDialogState();
}

class _DockerComposeDialogState extends State<DockerComposeDialog> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _delete => widget.action == DockerComposeAction.delete;
  String get _label => switch (widget.action) {
    DockerComposeAction.start => '启动编排',
    DockerComposeAction.stop => '停止编排',
    DockerComposeAction.rebuild => '重建编排',
    DockerComposeAction.delete => '删除编排',
  };

  Future<void> _submit() async {
    if (_busy || (_delete && _name.text != widget.project.name)) return;
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
              : 'Docker 编排操作失败，请刷新列表检查',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Text(_label.tr),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.project.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Text(
              (switch (widget.action) {
                DockerComposeAction.start => '将启动此编排中已创建的服务。',
                DockerComposeAction.stop => '停止编排会中断其中所有服务。',
                DockerComposeAction.rebuild => '将停止并移除编排容器，删除可移除的编排镜像，再按原配置重新构建并启动。有 build 配置的服务将无缓存构建，其余服务重新拉取镜像。',
                DockerComposeAction.delete => '将停止并删除此编排的容器和网络，保留镜像、数据卷与配置文件。',
              }).tr,
            ),
            if (widget.action == DockerComposeAction.rebuild) ...[
              const SizedBox(height: 12),
              Text(
                '重建期间服务不可用，容器可写层中的改动会丢失。数据卷与配置文件保留，匿名卷不会自动重新挂载；仍被其他容器引用的镜像会保留。'
                    .tr,
                style: const TextStyle(color: StatusColors.failed),
              ),
            ],
            if (_delete) ...[
              const SizedBox(height: 16),
              Text(
                '请输入编排名称「@name」以确认删除，必须完全一致。'.trParams({
                  'name': widget.project.name,
                }),
              ),
              const SizedBox(height: 8),
              AppTextFormField(
                key: const ValueKey('docker-compose-delete-name'),
                controller: _name,
                enabled: !_busy,
                autofocus: true,
                enableSuggestions: false,
                autocorrect: false,
                smartPunctuation: false,
                decoration: AppInputDecoration(hintText: '输入编排名称'.tr),
                onFieldSubmitted: (_) => unawaited(_submit()),
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
                  Expanded(child: Text('正在执行编排操作…'.tr)),
                ],
              )
            : _error == null
            ? null
            : Text(
                AppTranslations.error(_error!),
                style: const TextStyle(color: StatusColors.failed),
              ),
        actions: [
          shadcn.OutlineButton(
            onPressed: _busy
                ? null
                : () => AppNavigation.closeDialog(result: false),
            child: Text('取消'.tr),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _name,
            builder: (_, value, _) => shadcn.DestructiveButton(
              key: ValueKey('docker-compose-confirm-${widget.action.name}'),
              onPressed:
                  !_busy && (!_delete || value.text == widget.project.name)
                  ? _submit
                  : null,
              child: Text(_label.tr),
            ),
          ),
        ],
      ),
    );
  }
}
