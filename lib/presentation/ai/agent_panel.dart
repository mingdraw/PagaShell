import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_controller.dart';
import '../../application/ai/ai_settings_controller.dart';
import '../../domain/ai/agent_skill.dart';
import '../../domain/ai/ai_model.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../components/app_menu.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../settings/settings_dialog.dart';
import '../theme/app_theme.dart';
import 'agent_history_dialog.dart';
import 'agent_input_controller.dart';
import 'agent_message_body.dart';
import 'agent_session_input.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key});
  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _input = AgentInputController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final AgentController _agent = Get.find<AgentController>();
  late final Worker _entries;

  @override
  void initState() {
    super.initState();
    _entries = ever(_agent.entries, (_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          unawaited(
            _scroll.animateTo(
              _scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
            ),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _entries.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    if (_agent.busy.value ||
        _agent.currentModel == null ||
        _input.text.trim().isEmpty ||
        (_input.value.composing.isValid &&
            !_input.value.composing.isCollapsed)) {
      return;
    }
    final text = _input.text;
    final targets = _input.sessions;
    final labels = _input.referenceLabels;
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
                const Icon(shadcn.LucideIcons.bot, size: 17),
                const SizedBox(width: 8),
                const Text(
                  'Agent',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Obx(() {
                    final model = _agent.currentModel?.model ?? '未选择模型'.tr;
                    return shadcn.Tooltip(
                      tooltip: (_) =>
                          shadcn.TooltipContainer(child: Text(model)),
                      child: Text(
                        model,
                        key: const ValueKey('agent-model-name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.mutedForeground,
                        ),
                      ),
                    );
                  }),
                ),
                AppIconButton(
                  key: const ValueKey('agent-history'),
                  semanticLabel: '历史对话'.tr,
                  tooltip: '历史对话'.tr,
                  icon: const Icon(
                    shadcn.LucideIcons.history,
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
                  icon: const Icon(
                    shadcn.LucideIcons.squarePen,
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
                  icon: const Icon(
                    shadcn.LucideIcons.settings2,
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
              return ListView.builder(
                key: const ValueKey('agent-messages'),
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: entries.length,
                itemBuilder: (context, index) => _entry(entries[index]),
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
                            ? const Icon(
                                shadcn.LucideIcons.shieldCheck,
                                size: 12,
                              )
                            : const SizedBox(
                                width: 12,
                                height: 12,
                                child: shadcn.CircularProgressIndicator(),
                              ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _agent.activity.value.tr,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Obx(
            () => _agent.error.value == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(
                      _agent.error.value!.tr,
                      key: const ValueKey('agent-error'),
                      style: TextStyle(fontSize: 12, color: colors.destructive),
                    ),
                  ),
          ),
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
                  child: Obx(
                    () => AgentSessionInput(
                      agent: _agent,
                      controller: _input,
                      focusNode: _focus,
                      onSend: _send,
                      footer: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Wrap(
                                  spacing: 12,
                                  runSpacing: 4,
                                  children: [
                                    _reasoningSelector(),
                                    _accessSelector(),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _agent.busy.value
                                ? shadcn.OutlineButton(
                                    key: const ValueKey('agent-stop'),
                                    onPressed: _agent.stop,
                                    size: shadcn.ButtonSize.small,
                                    child: Text('停止'.tr),
                                  )
                                : shadcn.PrimaryButton(
                                    key: const ValueKey('agent-send'),
                                    onPressed:
                                        settings.state.value.apiConfig == null
                                        ? null
                                        : _send,
                                    size: shadcn.ButtonSize.small,
                                    child: Text('发送'.tr),
                                  ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '聊天及所选会话输出发送至 API · 历史加密保存在本机'.tr,
                  style: TextStyle(fontSize: 10, color: colors.mutedForeground),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reasoningSelector() => Builder(
    builder: (context) => Obx(() {
      final options = _agent.reasoningOptions;
      final selected = _agent.reasoningEffort.value;
      final label = '${'思考强度'.tr} · ${selected.label.tr}';
      return AppIconButton.text(
        key: const ValueKey('agent-reasoning-select'),
        semanticLabel: label,
        density: shadcn.ButtonDensity.compact,
        onPressed:
            !_agent.modesLoaded || _agent.busy.value || options.length < 2
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
            const Icon(shadcn.LucideIcons.brain, size: 14),
            const SizedBox(width: 4),
            Text(
              selected.label.tr,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      );
    }),
  );

  Widget _accessSelector() => Builder(
    builder: (context) => Obx(() {
      final selected = _agent.accessMode.value;
      final label = '${'审核模式'.tr} · ${selected.label.tr}';
      return AppIconButton.text(
        key: const ValueKey('agent-access-select'),
        semanticLabel: label,
        density: shadcn.ButtonDensity.compact,
        onPressed: !_agent.modesLoaded || _agent.busy.value
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
                      _agent.selectAccessMode,
                      selectedValue: selected,
                    ),
                  ),
                );
              },
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected == AgentAccessMode.fullAccess
                  ? shadcn.LucideIcons.shieldOff
                  : shadcn.LucideIcons.shieldCheck,
              size: 14,
            ),
            const SizedBox(width: 4),
            Text(
              selected.label.tr,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      );
    }),
  );

  Widget _welcome() => SingleChildScrollView(
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text(
          '你的运维助手'.tr,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Text(
          '解答工具使用、分析 SSH/RDP 问题，并生成可确认的命令建议。'.tr,
          style: TextStyle(
            fontSize: 12,
            height: 1.7,
            color: shadcn.Theme.of(context).colorScheme.mutedForeground,
          ),
        ),
        const SizedBox(height: 20),
        for (final skill in AgentSkill.builtIn) ...[
          shadcn.OutlineBadge(child: Text(skill.title.tr)),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 12),
        for (final prompt in [
          '如何使用 PagaShell 的文件传输和端口转发？',
          '帮我排查 SSH 连接失败',
          '如何排查 Windows RDP 登录问题？',
        ]) ...[
          shadcn.GhostButton(
            onPressed: () {
              _input.text = prompt.tr;
              _focus.requestFocus();
            },
            child: Text(prompt.tr, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(height: 6),
        ],
        const SizedBox(height: 12),
        Obx(
          () => Get.find<AiSettingsController>().state.value.apiConfig == null
              ? shadcn.OutlineButton(
                  onPressed: () => unawaited(showSettingsDialog(ai: true)),
                  child: Text('配置 AI 模型'.tr),
                )
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );

  Widget _entry(AgentEntry entry) {
    if (entry.command != null) {
      return _CommandCard(proposal: entry.command!, agent: _agent);
    }
    if (entry.archivedCommand != null) {
      final command = entry.archivedCommand!;
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.border(context)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '目标：@host'.trParams({'host': command.target}),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(command.purpose, style: const TextStyle(fontSize: 12)),
            AgentCodeBlock(code: command.command, language: 'shell'),
            Text(
              '${'历史命令（只读）'.tr} · ${switch (command.state) {
                AgentCommandState.sent => '已发送到终端'.tr,
                AgentCommandState.rejected => '已拒绝'.tr,
                _ => '未发送'.tr,
              }}',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      );
    }
    if (entry.kind == AgentEntryKind.tool) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Icon(shadcn.LucideIcons.wrench, size: 12),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                entry.text.tr,
                style: TextStyle(
                  fontSize: 11,
                  color: shadcn.Theme.of(context).colorScheme.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final user = entry.kind == AgentEntryKind.user;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(user ? 10 : 0),
      decoration: user
          ? BoxDecoration(
              color: AppTheme.surface(context),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            user ? '你'.tr : 'Agent',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          user
              ? shadcn.SelectableText(
                  entry.text,
                  style: const TextStyle(fontSize: 13, height: 1.6),
                )
              : AgentMessageBody(entry.text),
        ],
      ),
    );
  }
}

class _CommandCard extends StatelessWidget {
  const _CommandCard({required this.proposal, required this.agent});
  final AgentCommandProposal proposal;
  final AgentController agent;

  Future<void> _approve() async {
    final confirmed = await AppNavigation.dialog<bool>(
      AppDialog(
        title: Text('确认发送命令'.tr),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '目标：@host'.trParams({
                'host':
                    '${proposal.target.host.name} · ${proposal.target.host.address}',
              }),
            ),
            const SizedBox(height: 12),
            Text(proposal.purpose),
            AgentCodeBlock(code: proposal.command, language: 'shell'),
            const SizedBox(height: 12),
            Text('确认后将把命令及回车发送到此 SSH 终端，请检查内容与目标。'.tr),
          ],
        ),
        actions: [
          shadcn.OutlineButton(
            onPressed: () => AppNavigation.closeDialog(result: false),
            child: Text('取消'.tr),
          ),
          shadcn.PrimaryButton(
            key: const ValueKey('agent-confirm-command'),
            onPressed: () => AppNavigation.closeDialog(result: true),
            child: Text('确认发送'.tr),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (agent.approveCommand(proposal)) {
      AppNotice.success('命令已发送，正在读取会话输出');
    } else {
      AppNotice.error('原 SSH 会话不可用，命令未发送');
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      border: Border.all(color: AppTheme.border(context)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '目标：@host'.trParams({'host': proposal.target.title}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(proposal.purpose, style: const TextStyle(fontSize: 12)),
        AgentCodeBlock(code: proposal.command, language: 'shell'),
        Obx(
          () => proposal.state.value == AgentCommandState.pending
              ? Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    shadcn.OutlineButton(
                      size: shadcn.ButtonSize.small,
                      onPressed: () => agent.rejectCommand(proposal),
                      child: Text('拒绝'.tr),
                    ),
                    shadcn.PrimaryButton(
                      size: shadcn.ButtonSize.small,
                      onPressed: agent.canSendCommand(proposal)
                          ? _approve
                          : null,
                      child: Text('发送到终端'.tr),
                    ),
                  ],
                )
              : Text(switch (proposal.state.value) {
                  AgentCommandState.sent => '已发送到终端'.tr,
                  AgentCommandState.rejected => '已拒绝'.tr,
                  _ => '原 SSH 会话不可用，命令未发送'.tr,
                }, style: const TextStyle(fontSize: 11)),
        ),
      ],
    ),
  );
}
