import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/docker_manager_controller.dart';
import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_menu.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'docker_compose_dialog.dart';
import 'docker_container_dialog.dart';
import 'docker_details_dialog.dart';
import 'docker_image_dialog.dart';
import 'docker_resource_labels.dart';

class DockerManagerPanel extends StatefulWidget {
  const DockerManagerPanel({
    required this.source,
    required this.active,
    this.onOpenTerminal,
    super.key,
  });

  final DockerManagerSource? source;
  final bool active;
  final Future<void> Function(DockerResource)? onOpenTerminal;

  @override
  State<DockerManagerPanel> createState() => _DockerManagerPanelState();
}

class _DockerManagerPanelState extends State<DockerManagerPanel> {
  DockerManagerController? _controller;
  final _search = {
    for (final kind in DockerResourceKind.values) kind: TextEditingController(),
  };
  final _scroll = {
    for (final kind in DockerResourceKind.values) kind: ScrollController(),
  };
  bool _showingDetails = false;
  bool _showingAction = false;
  final _opening = <String>{};

  @override
  void initState() {
    super.initState();
    for (final entry in _search.entries) {
      entry.value.addListener(() {
        _controller?.states[entry.key]?.query.value = entry.value.text;
      });
    }
    _createController();
  }

  void _createController() {
    final source = widget.source;
    _controller = source == null
        ? null
        : DockerManagerController(source: source);
    for (final entry in _search.entries) {
      _controller?.states[entry.key]?.query.value = entry.value.text;
    }
    _controller?.setEnabled(widget.active);
  }

  @override
  void didUpdateWidget(DockerManagerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _controller?.onClose();
      _createController();
    } else {
      _controller?.setEnabled(widget.active);
    }
  }

  @override
  void dispose() {
    _controller?.onClose();
    for (final search in _search.values) {
      search.dispose();
    }
    for (final scroll in _scroll.values) {
      scroll.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('docker-manager-panel'),
    color: AppTheme.terminalBackground,
    child: Column(
      children: [
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: [
                const AppIcon(
                  AppIcons.container,
                  size: 15,
                  color: AppTheme.serverStatusCpuColor,
                ),
                const SizedBox(width: 8),
                Expanded(child: _heading()),
                if (_controller case final controller?)
                  Obx(
                    () => AppIconButton(
                      key: const ValueKey('docker-manager-refresh'),
                      semanticLabel: '刷新 Docker 列表'.tr,
                      tooltip: '刷新 Docker 列表'.tr,
                      icon: const AppIcon(AppIcons.refreshCw, size: 15),
                      onPressed:
                          controller.current.loading.value ||
                              controller.busy ||
                              !widget.active
                          ? null
                          : () => unawaited(controller.refreshResources()),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(child: _body()),
      ],
    ),
  );

  Widget _heading() {
    final title = Text(
      'Docker 管理'.tr,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );
    final controller = _controller;
    if (controller == null) return title;
    return LayoutBuilder(
      builder: (_, constraints) => Obx(() {
        final updated = controller.current.updatedAt.value;
        final time = updated == null
            ? null
            : '${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}:${updated.second.toString().padLeft(2, '0')}';
        final label = '更新于 @time'.trParams({'time': time ?? ''});
        return Row(
          children: [
            Flexible(child: title),
            if (time != null) ...[
              const SizedBox(width: 8),
              Semantics(
                label: label,
                excludeSemantics: true,
                child: Text(
                  constraints.maxWidth >= 200 ? label : time,
                  key: const ValueKey('docker-manager-updated'),
                  style: _secondaryStyle.copyWith(fontSize: 10),
                ),
              ),
            ],
          ],
        );
      }),
    );
  }

  Widget _body() {
    final controller = _controller;
    if (controller == null) {
      return _message('连接未就绪，暂无 Docker 信息'.tr);
    }
    return Obx(() {
      final kind = controller.selected.value;
      final state = controller.current;
      final resources = state.visibleResources;
      final error = state.error.value;
      final hasData = state.updatedAt.value != null;
      final loading = state.loading.value;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: _tabs(controller),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Semantics(
              label: '搜索 Docker 资源'.tr,
              child: AppTextFormField(
                key: ValueKey('docker-search-${kind.name}'),
                controller: _search[kind]!,
                compact: true,
                decoration: AppInputDecoration(
                  hintText: '搜索名称、ID 或属性'.tr,
                  suffixIcon: const AppIcon(AppIcons.search, size: 14),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${kind.label} · ${'@shown / @total 项资源'.trParams({'shown': '${resources.length}', 'total': '${state.resources.length}'})}',
                    key: const ValueKey('docker-manager-count'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _secondaryStyle,
                  ),
                ),
                if (kind == DockerResourceKind.image) ...[
                  const SizedBox(width: 6),
                  shadcn.TextButton(
                    key: const ValueKey('docker-image-cleanup'),
                    density: shadcn.ButtonDensity.compact,
                    leading: const AppIcon(AppIcons.brush, size: 13),
                    onPressed:
                        widget.active &&
                            !controller.busy &&
                            controller.canMutateImages
                        ? () => unawaited(
                            _requestImageAction(
                              controller,
                              DockerImageAction.pruneUntagged,
                            ),
                          )
                        : null,
                    child: Text(
                      '一键清理'.tr,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${hasData ? '${'更新失败，显示上次数据'.tr}\n' : ''}${AppTranslations.error(error)}',
                  key: const ValueKey('docker-manager-error'),
                  style: _secondaryStyle.copyWith(color: StatusColors.failed),
                ),
              ),
            ),
          Expanded(
            child: resources.isEmpty
                ? _message(
                    (loading && !hasData
                            ? '正在获取 Docker 列表…'
                            : error != null && !hasData
                            ? '可点击刷新重试'
                            : state.query.value.trim().isNotEmpty
                            ? '没有匹配的 Docker 资源'
                            : '暂无 Docker 资源')
                        .tr,
                  )
                : ListView.builder(
                    key: ValueKey('docker-list-${kind.name}'),
                    controller: _scroll[kind],
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                    itemCount: resources.length,
                    itemBuilder: (_, index) =>
                        _resourceCard(controller, resources[index]),
                  ),
          ),
        ],
      );
    });
  }

  Widget _tabs(DockerManagerController controller) => LayoutBuilder(
    builder: (_, constraints) {
      final showLabels =
          constraints.maxWidth >=
          (Get.locale?.languageCode == 'en' ? 480 : 300);
      return shadcn.TabList(
        key: const ValueKey('docker-manager-tabs'),
        index: controller.selected.value.index,
        onChanged: (index) =>
            controller.select(DockerResourceKind.values[index]),
        theme: const shadcn.TabListTheme(
          borderColor: AppTheme.terminalBorder,
          indicatorColor: AppTheme.serverStatusCpuColor,
        ),
        children: [
          for (final kind in DockerResourceKind.values)
            shadcn.TabChildWidget(
              indexed: true,
              child: Expanded(
                child: shadcn.TabItem(
                  key: ValueKey('docker-tab-${kind.name}'),
                  child: shadcn.Tooltip(
                    tooltip: (_) =>
                        shadcn.TooltipContainer(child: Text(kind.label)),
                    child: Semantics(
                      label: kind.label,
                      selected: controller.selected.value == kind,
                      excludeSemantics: true,
                      child: showLabels
                          ? FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                kind.label,
                                style: const TextStyle(fontSize: 11),
                              ),
                            )
                          : AppIcon(kind.icon, size: 15),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _resourceCard(
    DockerManagerController controller,
    DockerResource resource,
  ) => Obx(() => _resourceCardBody(controller, resource));

  Widget _resourceCardBody(
    DockerManagerController controller,
    DockerResource resource,
  ) {
    final pending = controller.pendingAction.value;
    final available = widget.active && !controller.busy;
    final running = resource.fields[DockerField.state] == 'running';
    final stoppable = const {
      'running',
      'restarting',
      'paused',
    }.contains(resource.fields[DockerField.state]);
    final powerAction = stoppable
        ? DockerContainerAction.stop
        : DockerContainerAction.start;
    final fields = switch (resource.kind) {
      DockerResourceKind.compose => [
        DockerField.status,
        DockerField.serviceCount,
        DockerField.containerCount,
      ],
      DockerResourceKind.container => [DockerField.image, DockerField.status],
      DockerResourceKind.image => [
        DockerField.tags,
        DockerField.size,
        DockerField.createdAt,
      ],
      DockerResourceKind.network ||
      DockerResourceKind.volume => [DockerField.driver, DockerField.scope],
    };
    return Padding(
      key: ValueKey('docker-card-${resource.identity}'),
      padding: const EdgeInsets.only(bottom: 6),
      child: shadcn.Card(
        theme: shadcn.CardTheme(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          filled: true,
          fillColor: AppTheme.terminalBackground,
          borderColor: AppTheme.terminalBorder,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (resource.kind == DockerResourceKind.container ||
                    resource.kind == DockerResourceKind.compose) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: resource.fields[DockerField.state] == 'running'
                          ? AppTheme.serverStatusCpuColor
                          : AppTheme.terminalMutedForeground,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: shadcn.Tooltip(
                    tooltip: (_) =>
                        shadcn.TooltipContainer(child: Text(resource.name)),
                    child: Text(
                      resource.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (resource.kind == DockerResourceKind.compose) ...[
                  _cardButton(
                    stoppable ? 'stop' : 'start',
                    resource,
                    stoppable ? '停止编排' : '启动编排',
                    stoppable ? AppIcons.square : AppIcons.play,
                    available && controller.canMutateCompose
                        ? () => unawaited(
                            stoppable
                                ? _requestComposeAction(
                                    controller,
                                    resource,
                                    DockerComposeAction.stop,
                                  )
                                : _performComposeAction(
                                    controller,
                                    resource,
                                    DockerComposeAction.start,
                                  ),
                          )
                        : null,
                    color: stoppable ? StatusColors.failed : StatusColors.ready,
                  ),
                  const SizedBox(width: 2),
                ],
                if (resource.kind == DockerResourceKind.container) ...[
                  _cardButton(
                    powerAction.name,
                    resource,
                    stoppable ? '停止容器' : '启动容器',
                    stoppable ? AppIcons.square : AppIcons.play,
                    available &&
                            controller.canMutate &&
                            !const {
                              'dead',
                              'removing',
                            }.contains(resource.fields[DockerField.state])
                        ? () => unawaited(
                            stoppable
                                ? _requestAction(
                                    controller,
                                    resource,
                                    powerAction,
                                  )
                                : _performAction(
                                    controller,
                                    resource,
                                    powerAction,
                                  ),
                          )
                        : null,
                    color: stoppable ? StatusColors.failed : StatusColors.ready,
                  ),
                  const SizedBox(width: 2),
                ],
                _cardButton(
                  'details',
                  resource,
                  '查看 Docker 详情',
                  AppIcons.info,
                  available
                      ? () => unawaited(_requestDetails(controller, resource))
                      : null,
                ),
                if (resource.kind == DockerResourceKind.image &&
                    resource.imageInUse == false) ...[
                  const SizedBox(width: 2),
                  _cardButton(
                    'delete-image',
                    resource,
                    '删除镜像',
                    AppIcons.trash2,
                    available && controller.canMutateImages
                        ? () => unawaited(
                            _requestImageAction(
                              controller,
                              DockerImageAction.delete,
                              image: resource,
                            ),
                          )
                        : null,
                  ),
                ],
                if (resource.kind == DockerResourceKind.container) ...[
                  const SizedBox(width: 2),
                  SizedBox.square(
                    dimension: 22,
                    child: AppMenuButton<String>(
                      key: ValueKey('docker-more-${resource.identity}'),
                      semanticLabel: '更多容器操作'.tr,
                      tooltip: '更多容器操作'.tr,
                      density: shadcn.ButtonDensity.compact,
                      icon: const AppIcon(AppIcons.ellipsis, size: 14),
                      enabled:
                          available && !_opening.contains(resource.identity),
                      items: [
                        ('container-terminal', '终端'.tr),
                        ('container-upgrade', '升级'.tr),
                        ('delete', '删除'.tr),
                      ],
                      disabledValues: {
                        if (!running || widget.onOpenTerminal == null)
                          'container-terminal',
                        if (!controller.canMutate) ...[
                          'container-upgrade',
                          'delete',
                        ],
                      },
                      onSelected: (action) {
                        if (action == 'container-terminal') {
                          unawaited(_requestTerminal(resource));
                        } else {
                          unawaited(
                            _requestAction(
                              controller,
                              resource,
                              action == 'delete'
                                  ? DockerContainerAction.delete
                                  : DockerContainerAction.upgrade,
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ],
                if (resource.kind == DockerResourceKind.compose) ...[
                  const SizedBox(width: 2),
                  SizedBox.square(
                    dimension: 22,
                    child: AppMenuButton<DockerComposeAction>(
                      key: ValueKey('docker-more-${resource.identity}'),
                      semanticLabel: '更多编排操作'.tr,
                      tooltip: '更多编排操作'.tr,
                      density: shadcn.ButtonDensity.compact,
                      icon: const AppIcon(AppIcons.ellipsis, size: 14),
                      enabled: available && controller.canMutateCompose,
                      items: [
                        (DockerComposeAction.rebuild, '重建'.tr),
                        (DockerComposeAction.delete, '删除'.tr),
                      ],
                      onSelected: (action) => unawaited(
                        _requestComposeAction(controller, resource, action),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (resource.kind == DockerResourceKind.image)
              Row(
                children: [
                  Expanded(
                    child: Text(resource.shortId, style: _secondaryStyle),
                  ),
                  Text(
                    DockerField.usage.display(
                      resource.fields[DockerField.usage] ?? 'unknown',
                    ),
                    key: ValueKey('docker-image-usage-${resource.identity}'),
                    style: _secondaryStyle.copyWith(
                      color: resource.imageInUse == true
                          ? AppTheme.serverStatusCpuColor
                          : AppTheme.terminalMutedForeground,
                    ),
                  ),
                ],
              )
            else if (resource.kind != DockerResourceKind.volume &&
                resource.kind != DockerResourceKind.compose)
              Text(resource.shortId, style: _secondaryStyle),
            if (pending?.resourceId == resource.identity)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  (pending?.composeAction != null
                          ? '正在执行编排操作…'
                          : pending?.imageAction != null
                          ? '正在处理 Docker 镜像…'
                          : '正在执行容器操作…')
                      .tr,
                  style: _secondaryStyle,
                ),
              ),
            for (final field in fields)
              if (resource.fields[field] case final value?
                  when value.isNotEmpty || field == DockerField.tags)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${field.label} · ${field.display(value)}',
                    maxLines: field == DockerField.tags ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: _secondaryStyle,
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _cardButton(
    String key,
    DockerResource resource,
    String label,
    AppIcons icon,
    VoidCallback? onPressed, {
    Color? color,
  }) => SizedBox.square(
    dimension: 22,
    child: AppIconButton(
      key: ValueKey('docker-$key-${resource.identity}'),
      semanticLabel: label.tr,
      tooltip: label.tr,
      density: shadcn.ButtonDensity.compact,
      icon: AppIcon(
        icon,
        size: 14,
        color: onPressed == null && color != null
            ? AppTheme.terminalMutedForeground
            : color,
      ),
      onPressed: onPressed,
    ),
  );

  Future<void> _performAction(
    DockerManagerController controller,
    DockerResource resource,
    DockerContainerAction action, {
    String? image,
    bool forcePull = false,
  }) async {
    try {
      final result = await controller.runContainerAction(
        resource,
        action,
        targetImage: image,
        forcePull: forcePull,
      );
      if (result.warning case final warning?) {
        AppNotice.error(warning);
      } else {
        AppNotice.success(switch (action) {
          DockerContainerAction.start => '容器已启动'.tr,
          DockerContainerAction.stop => '容器已停止'.tr,
          DockerContainerAction.upgrade => '容器已升级'.tr,
          DockerContainerAction.delete => '容器已删除'.tr,
        });
      }
    } on Object catch (error) {
      AppNotice.error(
        error is SshEngineException ? error.message : 'Docker 容器操作失败，请刷新列表检查',
      );
      if (action != DockerContainerAction.start) rethrow;
    }
  }

  Future<void> _requestAction(
    DockerManagerController controller,
    DockerResource resource,
    DockerContainerAction action,
  ) async {
    if (_showingAction || controller.busy || !widget.active) return;
    _showingAction = true;
    try {
      await AppNavigation.dialog<bool>(
        DockerContainerDialog(
          key: ValueKey('docker-${action.name}-dialog'),
          container: resource,
          action: action,
          onConfirm: (image, force) => _performAction(
            controller,
            resource,
            action,
            image: image,
            forcePull: force,
          ),
        ),
        barrierDismissible: false,
      );
    } finally {
      _showingAction = false;
    }
  }

  Future<void> _performComposeAction(
    DockerManagerController controller,
    DockerResource resource,
    DockerComposeAction action,
  ) async {
    try {
      final result = await controller.runComposeAction(resource, action);
      if (result.warning case final warning?) {
        AppNotice.error(warning);
      } else {
        AppNotice.success(switch (action) {
          DockerComposeAction.start => '编排已启动'.tr,
          DockerComposeAction.stop => '编排已停止'.tr,
          DockerComposeAction.rebuild => '编排已重建'.tr,
          DockerComposeAction.delete => '编排已删除'.tr,
        });
      }
    } on Object catch (error) {
      AppNotice.error(
        error is SshEngineException ? error.message : 'Docker 编排操作失败，请刷新列表检查',
      );
      if (action != DockerComposeAction.start) rethrow;
    }
  }

  Future<void> _requestComposeAction(
    DockerManagerController controller,
    DockerResource resource,
    DockerComposeAction action,
  ) async {
    if (_showingAction || controller.busy || !widget.active) return;
    _showingAction = true;
    try {
      await AppNavigation.dialog<bool>(
        DockerComposeDialog(
          project: resource,
          action: action,
          onConfirm: () => _performComposeAction(controller, resource, action),
        ),
        barrierDismissible: false,
      );
    } finally {
      _showingAction = false;
    }
  }

  Future<void> _requestImageAction(
    DockerManagerController controller,
    DockerImageAction action, {
    DockerResource? image,
  }) async {
    if (_showingAction || controller.busy || !widget.active) return;
    _showingAction = true;
    try {
      await AppNavigation.dialog<bool>(
        DockerImageDialog(
          key: ValueKey('docker-image-${action.name}-dialog'),
          action: action,
          image: image,
          onConfirm: (selectedAction) async {
            try {
              await controller.runImageAction(selectedAction, image: image);
              AppNotice.success(switch (selectedAction) {
                DockerImageAction.delete => '镜像已删除'.tr,
                DockerImageAction.pruneUntagged => '无标签镜像清理完成'.tr,
                DockerImageAction.pruneUnused => '未使用镜像清理完成'.tr,
              });
            } on Object catch (error) {
              AppNotice.error(
                error is SshEngineException
                    ? error.message
                    : 'Docker 镜像操作失败，请刷新列表检查',
              );
              rethrow;
            }
          },
        ),
        barrierDismissible: false,
      );
    } finally {
      _showingAction = false;
    }
  }

  Widget _message(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(message, style: _secondaryStyle, textAlign: TextAlign.center),
    ),
  );

  Future<void> _requestDetails(
    DockerManagerController controller,
    DockerResource resource,
  ) async {
    if (_showingDetails || !widget.active) return;
    _showingDetails = true;
    try {
      await AppNavigation.dialog<void>(
        DockerDetailsDialog(
          key: const ValueKey('docker-details-dialog'),
          resource: resource,
          readDetails: controller.readDetails,
        ),
      );
    } finally {
      _showingDetails = false;
    }
  }

  Future<void> _requestTerminal(DockerResource resource) async {
    final open = widget.onOpenTerminal;
    if (open == null || !widget.active || !_opening.add(resource.identity)) {
      return;
    }
    setState(() {});
    try {
      await open(resource);
    } on Object {
      // 容器终端的失败原因及重试入口由会话页签展示，菜单不重复弹出提示。
    } finally {
      if (mounted) setState(() => _opening.remove(resource.identity));
    }
  }

  static const _secondaryStyle = TextStyle(
    fontSize: 11,
    color: AppTheme.terminalMutedForeground,
  );
}
