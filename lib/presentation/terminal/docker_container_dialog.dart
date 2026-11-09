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

class DockerContainerDialog extends StatefulWidget {
  const DockerContainerDialog({
    required this.container,
    required this.action,
    required this.onConfirm,
    super.key,
  });

  final DockerResource container;
  final DockerContainerAction action;
  final Future<void> Function(String? image, bool forcePull) onConfirm;

  @override
  State<DockerContainerDialog> createState() => _DockerContainerDialogState();
}

class _DockerContainerDialogState extends State<DockerContainerDialog> {
  final _form = GlobalKey<FormState>();
  late final _image = TextEditingController(
    text: widget.container.fields[DockerField.image] ?? '',
  );
  final _name = TextEditingController();
  bool _forcePull = false;
  bool _busy = false;
  String? _error;
  static final _imagePattern = RegExp(
    r'^[a-zA-Z0-9\[][a-zA-Z0-9._:/@\-\[\]]{0,1023}$',
  );

  bool get _upgrade => widget.action == DockerContainerAction.upgrade;
  bool get _delete => widget.action == DockerContainerAction.delete;
  String get _label => switch (widget.action) {
    DockerContainerAction.start => '启动容器',
    DockerContainerAction.stop => '停止容器',
    DockerContainerAction.upgrade => '升级容器',
    DockerContainerAction.delete => '删除容器',
  };

  Future<void> _submit() async {
    if (_busy ||
        (_delete && _name.text != widget.container.name) ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm(_upgrade ? _image.text.trim() : null, _forcePull);
      if (mounted) {
        setState(() => _busy = false);
        AppNavigation.closeDialog(result: true);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is SshEngineException
              ? error.message
              : 'Docker 容器操作失败，请刷新列表检查',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _image.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Text(_label.tr),
        scrollable: true,
        content: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.container.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              if (_upgrade) ...[
                Text(
                  '当前镜像'.tr,
                  style: TextStyle(color: colors.mutedForeground),
                ),
                const SizedBox(height: 8),
                shadcn.OutlineBadge(
                  child: Text(
                    widget.container.fields[DockerField.image] ?? '—',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 20),
                AppTextFormField(
                  key: const ValueKey('docker-upgrade-image'),
                  controller: _image,
                  enabled: !_busy,
                  autofocus: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  smartPunctuation: false,
                  validator: (value) {
                    final image = value?.trim() ?? '';
                    if (image.isEmpty) return '请输入目标镜像'.tr;
                    if (!_imagePattern.hasMatch(image)) return '目标镜像格式无效'.tr;
                    return null;
                  },
                  decoration: AppInputDecoration(
                    labelText: '目标镜像'.tr,
                    hintText: '仓库名称/镜像名称:镜像版本'.tr,
                  ),
                ),
                const SizedBox(height: 16),
                shadcn.Checkbox(
                  key: const ValueKey('docker-force-pull'),
                  state: _forcePull
                      ? shadcn.CheckboxState.checked
                      : shadcn.CheckboxState.unchecked,
                  onChanged: _busy
                      ? null
                      : (value) => setState(
                          () => _forcePull =
                              value == shadcn.CheckboxState.checked,
                        ),
                  trailing: Text('强制重新拉取镜像'.tr),
                ),
                const SizedBox(height: 8),
                Text(
                  '忽略服务器已存在的目标镜像，重新从仓库拉取。'.tr,
                  style: TextStyle(fontSize: 12, color: colors.mutedForeground),
                ),
                const SizedBox(height: 20),
                Text(
                  '将按原配置重建并启动容器。挂载卷保留，容器可写层中的改动不会保留。'.tr,
                  style: const TextStyle(fontSize: 12),
                ),
              ] else ...[
                Text(
                  (_delete ? '将强制停止并删除此容器，保留挂载卷和镜像。' : '停止容器会中断其中运行的服务。').tr,
                ),
                if (_delete) ...[
                  const SizedBox(height: 16),
                  Text(
                    '请输入容器名称「@name」以确认删除，必须完全一致。'.trParams({
                      'name': widget.container.name,
                    }),
                  ),
                  const SizedBox(height: 8),
                  AppTextFormField(
                    key: const ValueKey('docker-delete-name'),
                    controller: _name,
                    enabled: !_busy,
                    autofocus: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    smartPunctuation: false,
                    decoration: AppInputDecoration(hintText: '输入容器名称'.tr),
                    onFieldSubmitted: (_) => unawaited(_submit()),
                  ),
                ],
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
                  Expanded(
                    child: Text((_upgrade ? '正在准备镜像并升级容器…' : '正在执行容器操作…').tr),
                  ),
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
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _name,
            builder: (_, value, _) {
              final enabled =
                  !_busy && (!_delete || value.text == widget.container.name);
              final child = Text(_label.tr);
              return _delete || widget.action == DockerContainerAction.stop
                  ? shadcn.DestructiveButton(
                      key: ValueKey('docker-confirm-${widget.action.name}'),
                      onPressed: enabled ? _submit : null,
                      child: child,
                    )
                  : shadcn.PrimaryButton(
                      key: ValueKey('docker-confirm-${widget.action.name}'),
                      onPressed: enabled ? _submit : null,
                      child: child,
                    );
            },
          ),
        ],
      ),
    );
  }
}
