import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_api_codec.dart';
import '../../application/ai/agent_controller.dart';
import '../../application/ai/ai_settings_controller.dart';
import '../../application/session/session_controller.dart';
import '../../domain/ai/agent_skill.dart';
import '../../domain/ai/ai_model.dart';
import '../components/app_copy_button.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_list_row.dart';
import '../components/app_menu.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../settings/settings_dialog.dart';
import '../theme/app_theme.dart';
import 'agent_action_cards.dart';
import 'agent_history_dialog.dart';
import 'agent_input_controller.dart';
import 'agent_message_body.dart';
import 'agent_session_input.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key});
  @override
  State<AgentPanel> createState() => AgentPanelState();
}

class AgentPanelState extends State<AgentPanel> {
  static const _maxMessageLength = 20000;
  static const _bottomTolerance = 1.0;
  final _input = AgentInputController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final AgentController _agent = Get.find<AgentController>();
  late final Worker _entries;
  final _stickToBottom = ValueNotifier<bool>(true);
  final _modelPopover = shadcn.OverlayController();
  bool _bottomScheduled = false;
  bool _confirmingFullAccess = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _entries = ever(_agent.entries, (_) {
      if (_agent.entries.isEmpty) {
        if (!_stickToBottom.value && mounted) {
          _stickToBottom.value = true;
        }
        return;
      }
      _scheduleScrollToBottom();
    });
    _scheduleScrollToBottom();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    // A wheel or trackpad can move only a few pixels per event. Even this
    // small move away from the bottom must cancel a pending follow.
    final atBottom = position.extentAfter <= _bottomTolerance;
    if (atBottom != _stickToBottom.value) {
      _stickToBottom.value = atBottom;
    }
  }

  void _scrollToBottom() {
    if (!_stickToBottom.value) _stickToBottom.value = true;
    _scheduleScrollToBottom();
  }

  void _scheduleScrollToBottom() {
    if (!_stickToBottom.value || _bottomScheduled) return;
    _bottomScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _bottomScheduled = false;
      if (!mounted || !_stickToBottom.value || !_scroll.hasClients) return;
      final position = _scroll.position;
      if (position.pixels != position.maxScrollExtent) {
        position.jumpTo(position.maxScrollExtent);
      }
    });
    binding.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _entries.dispose();
    _scroll.removeListener(_onScroll);
    _stickToBottom.dispose();
    _modelPopover.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _insertToTerminal(String code) {
    final sessions = Get.isRegistered<SessionController>()
        ? Get.find<SessionController>()
        : null;
    final id = sessions?.activeSessionId.value;
    showAgentTerminalInsertResult(
      id == null
          ? TerminalInsertResult.unavailable
          : sessions!.insertTextToSession(id, code),
      unavailable: '请先切换到要填入的 SSH 终端',
    );
  }

  /// 将终端选区追加为可编辑的草稿，保留已有输入。
  void quoteTerminalSelection(String text) {
    final selection = text.trimRight();
    if (selection.isEmpty) return;
    final quote = selection.split('\n').map((line) => '> $line').join('\n');
    final draft = _input.text;
    final separator = draft.isEmpty ? '' : '\n\n';
    final updated = '$draft$separator$quote\n\n';
    if (updated.length > _maxMessageLength) {
      AppNotice.error('消息过长，请缩短后发送');
      return;
    }
    _input.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: updated.length),
    );
    _focus.requestFocus();
  }

  void _send() {
    if (_agent.currentModel == null ||
        _input.text.trim().isEmpty ||
        (_input.value.composing.isValid &&
            !_input.value.composing.isCollapsed)) {
      return;
    }
    final text = _input.text;
    if (text.trim().length > _maxMessageLength) {
      _agent.error.value = '消息过长，请缩短后发送';
      return;
    }
    final targets = _input.sessions;
    final labels = _input.referenceLabels;
    _scrollToBottom();
    _input.clear();
    _focus.requestFocus();
    unawaited(
      _agent.send(text, referencedSessions: targets, referenceLabels: labels),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<AiSettingsController>();
    final colors = shadcn.Theme.of(context).colorScheme;
    return ColoredBox(
      key: const ValueKey('agent-panel'),
      color: AppTheme.sidebar(context),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            child: Row(
              children: [
                const AppIcon(AppIcons.bot, size: 17),
                const SizedBox(width: 8),
                Text(
                  'AI助手'.tr,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                AppIconButton(
                  key: const ValueKey('agent-history'),
                  semanticLabel: '历史对话'.tr,
                  tooltip: '历史对话'.tr,
                  icon: const AppIcon(
                    AppIcons.history,
                    size: AppTheme.toolbarIconSize,
                  ),
                  onPressed: () async {
                    if (await showAgentHistory(_agent) == true && mounted) {
                      _input.clear();
                      _focus.requestFocus();
                    }
                  },
                ),
                AppIconButton(
                  key: const ValueKey('agent-new-chat'),
                  semanticLabel: '新对话'.tr,
                  tooltip: '新对话'.tr,
                  icon: const AppIcon(
                    AppIcons.squarePen,
                    size: AppTheme.toolbarIconSize,
                  ),
                  onPressed: () {
                    _agent.clear();
                    _input.clear();
                  },
                ),
                AppIconButton(
                  semanticLabel: 'AI 设置'.tr,
                  tooltip: 'AI 设置'.tr,
                  icon: const AppIcon(
                    AppIcons.settings2,
                    size: AppTheme.toolbarIconSize,
                  ),
                  onPressed: () => unawaited(showSettingsDialog(ai: true)),
                ),
              ],
            ),
          ),
          Obx(
            () => _agent.historyError.value == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: shadcn.GhostButton(
                      onPressed: () => showAgentHistory(_agent),
                      child: Text(
                        _agent.historyError.value!.tr,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.destructive,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          Obx(
            () => !_agent.historyTrimmed.value
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Text(
                      '较早的对话已移出模型上下文，聊天内容仍可查看'.tr,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.mutedForeground,
                      ),
                    ),
                  ),
          ),
          Expanded(
            child: Obx(() {
              final entries = _agent.entries.toList();
              if (entries.isEmpty) return _welcome();
              final rows = <List<AgentEntry>>[];
              for (final entry in entries) {
                if (entry.kind.isActivity &&
                    rows.isNotEmpty &&
                    rows.last.first.kind.isActivity) {
                  rows.last.add(entry);
                } else {
                  rows.add([entry]);
                }
              }
              final rowIndices = {
                for (var i = 0; i < rows.length; i++)
                  ObjectKey(rows[i].first): i,
              };
              return Stack(
                fit: StackFit.expand,
                children: [
                  NotificationListener<ScrollMetricsNotification>(
                    onNotification: (notification) {
                      if (notification.depth == 0 &&
                          notification.metrics.extentAfter > 0) {
                        _scheduleScrollToBottom();
                      }
                      return false;
                    },
                    child: ListView.builder(
                      key: const ValueKey('agent-messages'),
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      findChildIndexCallback: (key) => rowIndices[key],
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        return row.first.kind.isActivity
                            ? _AgentActivityTimeline(
                                key: ObjectKey(row.first),
                                entries: row,
                              )
                            : KeyedSubtree(
                                key: ObjectKey(row.first),
                                child: _entry(row.single),
                              );
                      },
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _stickToBottom,
                      builder: (context, sticky, child) =>
                          sticky ? const SizedBox.shrink() : child!,
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppTheme.surface(context),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x33000000),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: shadcn.OutlineButton(
                            key: const ValueKey('agent-scroll-bottom'),
                            size: shadcn.ButtonSize.small,
                            onPressed: _scrollToBottom,
                            leading: const AppIcon(
                              AppIcons.arrowDown,
                              size: 13,
                            ),
                            child: Text('回到底部'.tr),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
          Obx(
            () => _agent.busy.value
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                    child: Row(
                      children: [
                        _agent.waitingForApproval.value
                            ? const AppIcon(AppIcons.shieldCheck, size: 12)
                            : const SizedBox(
                                width: 12,
                                height: 12,
                                child: shadcn.CircularProgressIndicator(),
                              ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _agent.queuedCount == 0
                                ? _agent.activity.value.tr
                                : '${_agent.activity.value.tr} · ${'@count 条消息排队中'.trParams({'count': '${_agent.queuedCount}'})}',
                            key: const ValueKey('agent-activity'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        shadcn.OutlineButton(
                          key: const ValueKey('agent-stop'),
                          onPressed: _agent.stop,
                          size: shadcn.ButtonSize.small,
                          child: Text('停止'.tr),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Obx(
            () => !_agent.canContinueTurn.value
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '已达到单轮工具步数上限（24 步），已保留完成的步骤。'.tr,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        const SizedBox(width: 8),
                        shadcn.OutlineButton(
                          key: const ValueKey('agent-continue'),
                          size: shadcn.ButtonSize.small,
                          onPressed: () => unawaited(_agent.continueLastTurn()),
                          child: Text('继续执行'.tr),
                        ),
                      ],
                    ),
                  ),
          ),
          _AgentRequestNotice(agent: _agent),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.border(context))),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Obx(
                  () => _agent.modesError.value == null
                      ? const SizedBox.shrink()
                      : Row(
                          children: [
                            Expanded(
                              child: Text(
                                _agent.modesError.value!.tr,
                                key: const ValueKey('agent-modes-error'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.destructive,
                                ),
                              ),
                            ),
                            shadcn.GhostButton(
                              onPressed: _agent.retryModes,
                              size: shadcn.ButtonSize.small,
                              child: Text('重试'.tr),
                            ),
                          ],
                        ),
                ),
                CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): _send,
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        _send,
                  },
                  child: Obx(() {
                    final hasApi = settings.state.value.apiConfig != null;
                    final queuing = _agent.busy.value;
                    return AgentSessionInput(
                      agent: _agent,
                      controller: _input,
                      focusNode: _focus,
                      onSend: _send,
                      modeControls: _ComposerControlsRow(
                        spacing: 6,
                        minModelWidth: 36,
                        children: [
                          _modelSelector(),
                          _reasoningSelector(),
                          _accessSelector(),
                        ],
                      ),
                      sendButton: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _input,
                        builder: (context, value, _) {
                          final canSend =
                              hasApi && value.text.trim().isNotEmpty;
                          return shadcn.PrimaryButton(
                            key: const ValueKey('agent-send'),
                            onPressed: canSend ? _send : null,
                            size: shadcn.ButtonSize.small,
                            child: Text((queuing ? '加入队列' : '发送').tr),
                          );
                        },
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _selectActiveModel(String modelId) async {
    _modelPopover.close();
    try {
      await _agent.selectActiveModel(modelId);
    } on Object {
      if (mounted) AppNotice.error('模型切换保存失败，请重试');
    }
  }

  Future<void> _openModelPicker(BuildContext anchorContext) async {
    final current = _agent.currentModel;
    if (current == null) {
      unawaited(showSettingsDialog(ai: true));
      return;
    }
    if (_modelPopover.hasOpenOverlay) {
      _modelPopover.close();
      return;
    }
    var models = _agent.availableModels;
    if (current.cachedModels.isEmpty) {
      try {
        models = await _agent.ensureCachedModels();
      } on AgentApiException catch (error) {
        if (mounted) AppNotice.error(error.message);
        models = _agent.availableModels;
      } on Object {
        if (mounted) AppNotice.error('模型列表获取失败，请检查 API 地址或手动填写模型 ID');
        models = _agent.availableModels;
      }
      if (!mounted || !anchorContext.mounted) return;
    }
    final latest = _agent.currentModel;
    if (latest == null) return;
    final options = models.isEmpty ? [latest.model] : models;
    unawaited(
      _modelPopover.show<void>(
        anchorContext,
        const shadcn.PopoverConfiguration(
          widthConstraint: shadcn.PopoverConstraint.flexible,
          anchorAlignment: Alignment.topLeft,
          alignment: Alignment.bottomLeft,
          offset: Offset(0, -6),
        ),
        adaptive: false,
        builder: (_) => _AgentModelPicker(
          models: options,
          selected: latest.model,
          onSelected: (id) => unawaited(_selectActiveModel(id)),
          onOpenSettings: () {
            _modelPopover.close();
            unawaited(showSettingsDialog(ai: true));
          },
        ),
      ),
    );
  }

  Widget _modelSelector() => Builder(
    builder: (anchorContext) => Obx(() {
      final current = _agent.currentModel;
      final loading = _agent.loadingModels.value;
      final colors = shadcn.Theme.of(anchorContext).colorScheme;
      final modelName = current?.model ?? '未选择模型'.tr;
      final label = current == null
          ? '配置 AI 模型'.tr
          : '${'切换模型'.tr} · ${current.model}';
      return AppIconButton.text(
        key: const ValueKey('agent-model-select'),
        semanticLabel: label,
        tooltip: current?.model ?? '配置 AI 模型'.tr,
        density: shadcn.ButtonDensity.compact,
        onPressed: loading
            ? null
            : () => unawaited(_openModelPicker(anchorContext)),
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) ...[
              const SizedBox.square(
                dimension: 11,
                child: shadcn.CircularProgressIndicator(),
              ),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                modelName,
                key: const ValueKey('agent-model-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  fontSize: 11,
                  color: current == null ? colors.mutedForeground : null,
                ),
              ),
            ),
            if (current != null && !loading) ...[
              const SizedBox(width: 1),
              AppIcon(
                AppIcons.chevronDown,
                size: 11,
                color: colors.mutedForeground,
              ),
            ],
          ],
        ),
      );
    }),
  );

  Widget _reasoningSelector() => Builder(
    builder: (context) => Obx(() {
      final options = _agent.reasoningOptions;
      final selected = _agent.reasoningEffort.value;
      final label = '${'思考强度'.tr} · ${selected.label.tr}';
      return AppIconButton.text(
        key: const ValueKey('agent-reasoning-select'),
        semanticLabel: label,
        density: shadcn.ButtonDensity.compact,
        onPressed: !_agent.modesLoaded || options.length < 2
            ? null
            : () {
                shadcn.showDropdown<void>(
                  context: context,
                  builder: (_) => shadcn.DropdownMenu(
                    children: appMenuItems<AiReasoningEffort>(
                      [for (final effort in options) (effort, effort.label.tr)],
                      _agent.selectReasoningEffort,
                      selectedValue: selected,
                    ),
                  ),
                );
              },
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppIcon(AppIcons.brain, size: 13),
            const SizedBox(width: 2),
            Flexible(
              child: Text(
                selected.label.tr,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      );
    }),
  );

  Future<void> _selectAccessMode(AgentAccessMode mode) async {
    if (mode == _agent.accessMode.value || _confirmingFullAccess) return;
    if (mode == AgentAccessMode.fullAccess) {
      _confirmingFullAccess = true;
      try {
        final confirmed = await AppNavigation.dialog<bool>(
          AppDialog(
            title: Text('启用完全访问？'.tr),
            content: Text('已识别的只读检查可直接发送到引用的 SSH 终端。文件变更和其他命令仍需批准。'.tr),
            actions: [
              shadcn.OutlineButton(
                onPressed: () => AppNavigation.closeDialog(result: false),
                child: Text('取消'.tr),
              ),
              shadcn.DestructiveButton(
                key: const ValueKey('agent-confirm-full-access'),
                onPressed: () => AppNavigation.closeDialog(result: true),
                child: Text('启用完全访问'.tr),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
      } finally {
        _confirmingFullAccess = false;
      }
    }
    _agent.selectAccessMode(mode);
  }

  Widget _accessSelector() => Builder(
    builder: (context) => Obx(() {
      final selected = _agent.accessMode.value;
      final isFull = selected == AgentAccessMode.fullAccess;
      final isReadOnly = selected == AgentAccessMode.approveWrites;
      final label = '${'审核模式'.tr} · ${selected.label.tr}';
      const accent = AppTheme.serverStatusWarningColor;
      return AppIconButton.text(
        key: const ValueKey('agent-access-select'),
        semanticLabel: label,
        tooltip: isFull
            ? '完全访问模式：允许自动在终端运行已识别的只读检查'.tr
            : isReadOnly
            ? '只读自动：巡检可自动运行，变更需要批准'.tr
            : label,
        density: shadcn.ButtonDensity.compact,
        onPressed: !_agent.modesLoaded
            ? null
            : () {
                shadcn.showDropdown<void>(
                  context: context,
                  builder: (_) => shadcn.DropdownMenu(
                    children: appMenuItems<AgentAccessMode>(
                      [
                        for (final mode in AgentAccessMode.values)
                          (mode, mode.label.tr),
                      ],
                      (mode) => unawaited(_selectAccessMode(mode)),
                      selectedValue: selected,
                    ),
                  ),
                );
              },
        icon: Container(
          padding: isFull
              ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
              : EdgeInsets.zero,
          decoration: isFull
              ? BoxDecoration(
                  border: Border.all(color: accent.withValues(alpha: 0.65)),
                  borderRadius: BorderRadius.circular(5),
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                isFull ? AppIcons.shieldOff : AppIcons.shieldCheck,
                size: 13,
                color: isFull ? accent : null,
              ),
              const SizedBox(width: 2),
              Flexible(
                child: Text(
                  selected.label.tr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 11,
                    color: isFull
                        ? accent
                        : isReadOnly
                        ? StatusColors.ready
                        : null,
                    fontWeight: isFull || isReadOnly ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }),
  );

  Widget _welcome() {
    final colors = shadcn.Theme.of(context).colorScheme;
    const prompts = [
      (
        icon: AppIcons.folderOpen,
        prompt: '全面巡检服务器状态与资源瓶颈',
        subtitle: '系统基线、进程、磁盘和监听端口',
      ),
      (
        icon: AppIcons.terminal,
        prompt: '排查 SSH 服务或端口异常',
        subtitle: 'Linux/macOS 排障、资源、网络、服务与安全命令建议',
      ),
      (
        icon: AppIcons.folderOpen,
        prompt: '分析并优化当前 MySQL 配置',
        subtitle: '内存预算、运行指标和配置变更',
      ),
      (
        icon: AppIcons.settings2,
        prompt: '调优系统文件句柄与内核参数',
        subtitle: '内核、PAM、systemd 与运行态复验',
      ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.surface(context),
                  border: Border.all(color: AppTheme.border(context)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const AppIcon(AppIcons.bot, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '你的运维助手'.tr,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '巡检服务器、后台运行命令，并审阅、应用和回滚配置。'.tr,
            style: TextStyle(
              fontSize: 12,
              height: 1.7,
              color: colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '内置能力'.tr,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final skill in AgentSkill.builtIn)
                shadcn.Tooltip(
                  tooltip: (_) => shadcn.TooltipContainer(
                    child: Text(skill.description.tr),
                  ),
                  child: shadcn.OutlineBadge(child: Text(skill.title.tr)),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            '常见提问'.tr,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < prompts.length; i++) ...[
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppTheme.surface(context),
                border: Border.all(color: AppTheme.border(context)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: AppSurfaceAction(
                key: ValueKey('agent-welcome-prompt-$i'),
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  final text = prompts[i].prompt.tr;
                  _input.value = TextEditingValue(
                    text: text,
                    selection: TextSelection.collapsed(offset: text.length),
                  );
                  _focus.requestFocus();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      AppIcon(prompts[i].icon, size: 15, color: colors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              prompts[i].prompt.tr,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              prompts[i].subtitle.tr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: colors.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      AppIcon(
                        AppIcons.arrowRight,
                        size: 13,
                        color: colors.mutedForeground,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 6),
          Obx(
            () => Get.find<AiSettingsController>().state.value.apiConfig == null
                ? shadcn.OutlineButton(
                    key: const ValueKey('agent-configure-model'),
                    onPressed: () => unawaited(showSettingsDialog(ai: true)),
                    child: Text('配置 AI 模型'.tr),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _entry(AgentEntry entry) {
    if (entry.command != null) {
      final proposal = entry.command!;
      return AgentCommandCard(
        key: ObjectKey(proposal),
        proposal: proposal,
        agent: _agent,
      );
    }
    if (entry.archivedCommand != null) {
      return ArchivedCommandCard(command: entry.archivedCommand!);
    }
    if (entry.fileChange case final change?) {
      return AgentFileChangeCard(
        key: ObjectKey(change),
        proposal: change,
        agent: _agent,
      );
    }
    if (entry.archivedFileChange case final change?) {
      return ArchivedFileChangeCard(change: change);
    }
    if (entry.kind != AgentEntryKind.user) {
      return _AgentReply(entry: entry, onInsertToTerminal: _insertToTerminal);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.surface(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '你'.tr,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Obx(() {
                  final state = entry.requestState.value;
                  final label = switch (state) {
                    AgentRequestState.queued => '排队中',
                    AgentRequestState.running => '处理中…',
                    AgentRequestState.failed => '请求失败',
                    AgentRequestState.cancelled => '已取消',
                    _ => '',
                  };
                  final canRetry =
                      (state == AgentRequestState.failed ||
                          state == AgentRequestState.cancelled) &&
                      _agent.currentModel != null;
                  return Row(
                    children: [
                      Expanded(
                        child: Text(
                          label.tr,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: state == AgentRequestState.failed
                                ? shadcn.Theme.of(context)
                                      .colorScheme
                                      .destructive
                                : shadcn.Theme.of(context)
                                      .colorScheme
                                      .mutedForeground,
                          ),
                        ),
                      ),
                      if (canRetry)
                        shadcn.GhostButton(
                          key: const ValueKey('agent-entry-retry'),
                          size: shadcn.ButtonSize.small,
                          density: shadcn.ButtonDensity.compact,
                          onPressed: () => unawaited(_agent.retry(entry)),
                          child: Text(
                            '重试'.tr,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                    ],
                  );
                }),
              ),
            ],
          ),
          const SizedBox(height: 4),
          shadcn.SelectableText(
            entry.text,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          Obx(
            () => entry.requestError.value == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      entry.requestError.value!.tr,
                      style: TextStyle(
                        fontSize: 11,
                        color: shadcn.Theme.of(context).colorScheme.destructive,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _AgentRequestNotice extends StatelessWidget {
  const _AgentRequestNotice({required this.agent});

  final AgentController agent;

  @override
  Widget build(BuildContext context) => Obx(() {
    // Keep a failure in sight while the next queued message starts. Each
    // original user message also keeps its own status in the transcript.
    AgentEntry? failed;
    for (var i = agent.entries.length - 1; i >= 0; i--) {
      final entry = agent.entries[i];
      if (entry.kind != AgentEntryKind.user) continue;
      final state = entry.requestState.value;
      if (state == AgentRequestState.failed) failed = entry;
      if (state == AgentRequestState.completed ||
          state == AgentRequestState.failed ||
          state == AgentRequestState.cancelled) {
        break;
      }
    }
    final failure = failed;
    final requestError = failure?.requestError.value;
    final error = agent.error.value ?? requestError;
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              error.tr,
              key: const ValueKey('agent-error'),
              style: TextStyle(
                fontSize: 12,
                color: shadcn.Theme.of(context).colorScheme.destructive,
              ),
            ),
          ),
          if (failure != null &&
              requestError == error &&
              agent.currentModel != null)
            shadcn.GhostButton(
              key: const ValueKey('agent-error-retry'),
              size: shadcn.ButtonSize.small,
              density: shadcn.ButtonDensity.compact,
              onPressed: agent.busy.value
                  ? null
                  : () => unawaited(agent.retry(failure)),
              child: Text('重试'.tr),
            ),
        ],
      ),
    );
  });
}

class _AgentReply extends StatelessWidget {
  const _AgentReply({required this.entry, required this.onInsertToTerminal});

  final AgentEntry entry;
  final ValueChanged<String> onInsertToTerminal;

  @override
  Widget build(BuildContext context) => Obx(() {
    final text = entry.text;
    final state = entry.requestState.value;
    final colors = shadcn.Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Agent',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
              if (state == AgentRequestState.failed ||
                  state == AgentRequestState.cancelled) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '已中断'.tr,
                    key: const ValueKey('agent-reply-interrupted'),
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.mutedForeground,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (text.trim().isNotEmpty) ...[
                const Spacer(),
                AppCopyButton(
                  text: text,
                  size: 12,
                  semanticLabel: '复制回复'.tr,
                  resetOnTextChange: false,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          AgentStreamingText(
            key: const ValueKey('agent-reply-body'),
            text: text,
            streaming: state == AgentRequestState.running,
            style: const TextStyle(fontSize: 13, height: 1.65),
            buildFinal: (text) =>
                AgentMessageBody(text, onInsertToTerminal: onInsertToTerminal),
          ),
        ],
      ),
    );
  });
}

class _AgentActivityTimeline extends StatefulWidget {
  const _AgentActivityTimeline({required this.entries, super.key});

  final List<AgentEntry> entries;

  @override
  State<_AgentActivityTimeline> createState() => _AgentActivityTimelineState();
}

class _AgentActivityTimelineState extends State<_AgentActivityTimeline> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          shadcn.GhostButton(
            key: const ValueKey('agent-activity-timeline-toggle'),
            onPressed: () => setState(() => _expanded = !_expanded),
            leading: AppIcon(
              _expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
              size: 14,
            ),
            child: Text(
              '思考与工具调用'.tr,
              style: TextStyle(fontSize: 12, color: colors.mutedForeground),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final entry in widget.entries)
                    _AgentActivityItem(key: ObjectKey(entry), entry: entry),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AgentActivityItem extends StatelessWidget {
  const _AgentActivityItem({required this.entry, super.key});

  final AgentEntry entry;

  @override
  Widget build(BuildContext context) => Obx(() {
    final color = shadcn.Theme.of(context).colorScheme.mutedForeground;
    final text = entry.text;
    final summary = entry.toolSummary;
    final reasoningStyle = TextStyle(fontSize: 12, color: color);
    final detailStyle = TextStyle(fontSize: 11, color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: entry.kind == AgentEntryKind.reasoning
          ? AgentStreamingText(
              text: text,
              streaming: entry.requestState.value == AgentRequestState.running,
              style: reasoningStyle,
              buildFinal: (text) =>
                  shadcn.SelectableText(text, style: reasoningStyle),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text.tr,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (summary != null) ...[
                  if (summary.target case final target?)
                    Text(
                      '目标：@host'.trParams({'host': target}),
                      style: detailStyle,
                    ),
                  Text(
                    summary.cancelled
                        ? '工具调用已取消'.tr
                        : summary.elapsedMs == null
                        ? '等待工具结果'.tr
                        : '耗时 @ms ms · 输出 @count 字符'.trParams({
                            'ms': '${summary.elapsedMs}',
                            'count': '${summary.outputLength ?? 0}',
                          }),
                    style: detailStyle,
                  ),
                ],
              ],
            ),
    );
  });
}

class _AgentModelPicker extends StatefulWidget {
  const _AgentModelPicker({
    required this.models,
    required this.selected,
    required this.onSelected,
    required this.onOpenSettings,
  });

  final List<String> models;
  final String selected;
  final ValueChanged<String> onSelected;
  final VoidCallback onOpenSettings;

  @override
  State<_AgentModelPicker> createState() => _AgentModelPickerState();
}

class _AgentModelPickerState extends State<_AgentModelPicker> {
  late final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      final next = _search.text.trim().toLowerCase();
      if (next != _query) setState(() => _query = next);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final filtered = _query.isEmpty
        ? widget.models
        : widget.models
              .where((id) => id.toLowerCase().contains(_query))
              .toList();
    return shadcn.WidgetStatesProvider.boundary(
      child: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 32).clamp(180.0, 260.0),
        child: shadcn.SurfaceCard(
          key: const ValueKey('agent-model-popover'),
          theme: const shadcn.CardTheme(padding: EdgeInsets.all(6)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.models.length > 6) ...[
                shadcn.TextField(
                  key: const ValueKey('agent-model-search'),
                  controller: _search,
                  placeholder: Text(
                    '搜索模型…'.tr,
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: filtered.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          '没有匹配的模型'.tr,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.mutedForeground,
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final id in filtered)
                              shadcn.SelectedButton(
                                key: ValueKey('agent-model-option-$id'),
                                value: id == widget.selected,
                                alignment: Alignment.centerLeft,
                                onChanged: (_) => widget.onSelected(id),
                                child: Row(
                                  children: [
                                    SizedBox.square(
                                      dimension: 14,
                                      child: id == widget.selected
                                          ? const AppIcon(
                                              AppIcons.check,
                                              size: 13,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        id,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Container(height: 1, color: AppTheme.border(context)),
              ),
              shadcn.GhostButton(
                key: const ValueKey('agent-model-open-settings'),
                density: shadcn.ButtonDensity.compact,
                alignment: Alignment.centerLeft,
                onPressed: widget.onOpenSettings,
                child: Row(
                  children: [
                    AppIcon(
                      AppIcons.refreshCw,
                      size: 13,
                      color: colors.mutedForeground,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '在 AI 设置中刷新模型列表'.tr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.mutedForeground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposerControlsRowParentData
    extends ContainerBoxParentData<RenderBox> {}

/// 单行紧密排列输入框底部控制项：空间不足时不换行，优先压缩首位模型名称并以省略号显示。
class _ComposerControlsRow extends MultiChildRenderObjectWidget {
  const _ComposerControlsRow({
    required this.spacing,
    required this.minModelWidth,
    required super.children,
  });

  final double spacing;
  final double minModelWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderComposerControlsRow(
        spacing: spacing,
        minModelWidth: minModelWidth,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderComposerControlsRow renderObject,
  ) {
    renderObject
      ..spacing = spacing
      ..minModelWidth = minModelWidth;
  }
}

class _RenderComposerControlsRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ComposerControlsRowParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _ComposerControlsRowParentData
        > {
  _RenderComposerControlsRow({
    required this._spacing,
    required this._minModelWidth,
  });

  double _spacing;
  double get spacing => _spacing;
  set spacing(double value) {
    if (_spacing == value) return;
    _spacing = value;
    markNeedsLayout();
  }

  double _minModelWidth;
  double get minModelWidth => _minModelWidth;
  set minModelWidth(double value) {
    if (_minModelWidth == value) return;
    _minModelWidth = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ComposerControlsRowParentData) {
      child.parentData = _ComposerControlsRowParentData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) {
    var total = 0.0;
    var count = 0;
    var child = firstChild;
    while (child != null) {
      total += child.getMaxIntrinsicWidth(height);
      count++;
      child = childAfter(child);
    }
    if (count > 1) total += spacing * (count - 1);
    return total;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    var height = 0.0;
    var child = firstChild;
    while (child != null) {
      height = math.max(height, child.getMinIntrinsicHeight(width));
      child = childAfter(child);
    }
    return height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    var height = 0.0;
    var child = firstChild;
    while (child != null) {
      height = math.max(height, child.getMaxIntrinsicHeight(width));
      child = childAfter(child);
    }
    return height;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void performLayout() {
    final items = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      items.add(child);
      child = childAfter(child);
    }
    if (items.isEmpty) {
      size = constraints.smallest;
      return;
    }

    final maxWidth = constraints.maxWidth;
    final maxHeight = constraints.maxHeight;
    final totalSpacing = spacing * (items.length - 1);
    final available = maxWidth.isFinite
        ? math.max(0.0, maxWidth - totalSpacing)
        : double.infinity;

    if (items.length == 1 || !available.isFinite) {
      final loose = BoxConstraints(maxWidth: available, maxHeight: maxHeight);
      for (final item in items) {
        item.layout(loose, parentUsesSize: true);
      }
    } else {
      final model = items.first;
      final others = items.sublist(1);
      final loose = BoxConstraints(maxWidth: available, maxHeight: maxHeight);
      var othersWidth = 0.0;
      for (final item in others) {
        item.layout(loose, parentUsesSize: true);
        othersWidth += item.size.width;
      }
      final preferredMinModel = math.min(minModelWidth, available);
      if (othersWidth + preferredMinModel <= available) {
        final modelBudget = math.max(0.0, available - othersWidth);
        model.layout(
          BoxConstraints(maxWidth: modelBudget, maxHeight: maxHeight),
          parentUsesSize: true,
        );
      } else {
        final modelBudget = math.min(preferredMinModel, available * 0.34);
        model.layout(
          BoxConstraints(maxWidth: modelBudget, maxHeight: maxHeight),
          parentUsesSize: true,
        );
        final othersBudget = math.max(0.0, available - model.size.width);
        if (othersWidth > 0 && othersWidth > othersBudget) {
          var remainingBudget = othersBudget;
          var remainingNatural = othersWidth;
          for (var i = 0; i < others.length; i++) {
            final item = others[i];
            final natural = item.size.width;
            final share = i == others.length - 1
                ? remainingBudget
                : (remainingBudget * (natural / remainingNatural)).clamp(
                    0.0,
                    remainingBudget,
                  );
            item.layout(
              BoxConstraints(maxWidth: share, maxHeight: maxHeight),
              parentUsesSize: true,
            );
            remainingBudget = math.max(0.0, remainingBudget - item.size.width);
            remainingNatural = math.max(0.0, remainingNatural - natural);
          }
        }
      }
    }

    var rowHeight = 0.0;
    var totalWidth = 0.0;
    for (var i = 0; i < items.length; i++) {
      final itemSize = items[i].size;
      rowHeight = math.max(rowHeight, itemSize.height);
      totalWidth += itemSize.width;
      if (i > 0) totalWidth += spacing;
    }

    var x = 0.0;
    for (final item in items) {
      final data = item.parentData! as _ComposerControlsRowParentData;
      data.offset = Offset(x, (rowHeight - item.size.height) / 2);
      x += item.size.width + spacing;
    }

    size = constraints.constrain(Size(totalWidth, rowHeight));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
