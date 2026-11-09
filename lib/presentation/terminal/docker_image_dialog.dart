import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';

class DockerImageDialog extends StatefulWidget {
  const DockerImageDialog({
    required this.action,
    required this.onConfirm,
    this.image,
    super.key,
  });

  final DockerImageAction action;
  final DockerResource? image;
  final Future<void> Function(DockerImageAction action) onConfirm;

  @override
  State<DockerImageDialog> createState() => _DockerImageDialogState();
}

class _DockerImageDialogState extends State<DockerImageDialog> {
  bool _busy = false;
  late bool _allUnused = widget.action == DockerImageAction.pruneUnused;
  String? _error;

  bool get _prune => widget.action != DockerImageAction.delete;
  DockerImageAction get _selectedAction => !_prune
      ? DockerImageAction.delete
      : _allUnused
      ? DockerImageAction.pruneUnused
      : DockerImageAction.pruneUntagged;
  String get _title => _prune ? '清理镜像' : '删除镜像';

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm(_selectedAction);
      if (mounted) {
        setState(() => _busy = false);
        AppNavigation.closeDialog(result: true);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is SshEngineException
              ? error.message
              : 'Docker 镜像操作失败，请刷新列表检查',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Text(_title.tr),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_prune) ...[
              Text(
                (_allUnused
                        ? '将清理所有未被容器使用的镜像，包括有标签的镜像。'
                        : '默认清理没有标签且未被容器使用的镜像。')
                    .tr,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              shadcn.Checkbox(
                key: const ValueKey('docker-prune-all-unused'),
                state: _allUnused
                    ? shadcn.CheckboxState.checked
                    : shadcn.CheckboxState.unchecked,
                onChanged: _busy
                    ? null
                    : (state) => setState(
                        () =>
                            _allUnused = state == shadcn.CheckboxState.checked,
                      ),
                trailing: Text('清理所有未使用的镜像'.tr),
              ),
              const SizedBox(height: 12),
              Text(
                '清理范围为当前 Docker 服务，不受搜索条件影响。'.tr,
                style: TextStyle(fontSize: 12, color: colors.mutedForeground),
              ),
            ] else ...[
              Text(
                widget.image!.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                widget.image!.id,
                style: TextStyle(fontSize: 11, color: colors.mutedForeground),
              ),
              const SizedBox(height: 16),
              Text('删除镜像后，再次使用时需要重新拉取或构建。'.tr),
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
                  Expanded(child: Text('正在处理 Docker 镜像…'.tr)),
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
            key: ValueKey('docker-confirm-image-${widget.action.name}'),
            onPressed: _busy ? null : _submit,
            child: Text((_prune ? '清理' : '删除镜像').tr),
          ),
        ],
      ),
    );
  }
}
