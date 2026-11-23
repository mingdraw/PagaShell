import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_controller.dart';
import '../../application/session/session_controller.dart';
import '../../domain/ai/agent_conversation.dart';
import '../../domain/ai/command_classifier.dart';
import '../components/app_copy_button.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'agent_message_body.dart';

const _mono = TextStyle(
  fontFamily: 'FiraCode Nerd Font Mono',
  fontFamilyFallback: ['Menlo', 'PingFang SC', 'Microsoft YaHei', 'monospace'],
  fontSize: 12,
);

void showAgentTerminalInsertResult(
  TerminalInsertResult result, {
  required String unavailable,
}) {
  switch (result) {
    case TerminalInsertResult.inserted:
      AppNotice.success('已填入终端');
    case TerminalInsertResult.unavailable:
      AppNotice.error(unavailable);
    case TerminalInsertResult.requiresBracketedPaste:
      AppNotice.error('当前终端未启用括号粘贴，请复制后分行检查并粘贴');
    case TerminalInsertResult.invalidText:
      AppNotice.error('文本为空或包含终端控制字符，无法填入');
  }
}

bool _insert(String id, String code, {required bool available}) {
  final result = available && Get.isRegistered<SessionController>()
      ? Get.find<SessionController>().insertTextToSession(id, code)
      : TerminalInsertResult.unavailable;
  showAgentTerminalInsertResult(result, unavailable: '原 SSH 会话不可用，命令未发送');
  return result == TerminalInsertResult.inserted;
}

class AgentCommandCard extends StatefulWidget {
  const AgentCommandCard({
    required this.proposal,
    required this.agent,
    super.key,
  });

  final AgentCommandProposal proposal;
  final AgentController agent;

  @override
  State<AgentCommandCard> createState() => _AgentCommandCardState();
}

class _AgentCommandCardState extends State<AgentCommandCard> {
  final _editor = TextEditingController();
  bool _editing = false;
  bool _confirming = false;
  AgentCommandProposal get proposal => widget.proposal;
  AgentController get agent => widget.agent;
  bool get _exec => proposal.executionMode == AgentCommandExecutionMode.exec;
  String get _target =>
      '${proposal.target.host.name} · ${proposal.target.address}';

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  Future<void> _approve(String command, {required bool confirm}) async {
    if (_confirming || !AgentCommandProposal.isValidCommand(command)) return;
    if (confirm) {
      _confirming = true;
      try {
        final confirmed = await AppNavigation.dialog<bool>(
          AppDialog(
            title: Text('确认发送命令'.tr),
            scrollable: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('目标：@host'.trParams({'host': _target})),
                const SizedBox(height: 10),
                Text(proposal.purpose.tr),
                AgentCodeBlock(code: command, language: 'shell'),
                Text(
                  (_exec
                          ? '确认后将在此主机后台执行命令，请检查内容与目标。'
                          : '确认后将把命令及回车发送到此 SSH 终端，请检查内容与目标。')
                      .tr,
                ),
              ],
            ),
            actions: [
              shadcn.OutlineButton(
                onPressed: () => AppNavigation.closeDialog(result: false),
                child: Text('取消'.tr),
              ),
              shadcn.DestructiveButton(
                key: const ValueKey('agent-confirm-command'),
                onPressed: () => AppNavigation.closeDialog(result: true),
                child: Text((_exec ? '确认执行' : '确认发送').tr),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
      } finally {
        _confirming = false;
      }
    }
    if (!agent.approveCommand(proposal, editedCommand: command)) {
      AppNotice.error('原 SSH 会话不可用，命令未发送');
    } else if (!_exec) {
      AppNotice.success('命令已发送，正在读取会话输出');
    }
  }

  void _fill(String command, {bool sudo = false, bool decline = false}) {
    if (sudo) {
      command = command.replaceAllMapped(
        RegExp(r'(\bsudo)\s+-n\b'),
        (match) => match[1]!,
      );
    }
    if (_insert(
          proposal.target.id,
          command,
          available: agent.canFillCommand(proposal),
        ) &&
        decline) {
      agent.rejectCommand(proposal);
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final state = proposal.state.value;
    final pending = state == AgentCommandState.pending;
    final running = proposal.running.value;
    final editing = pending && _editing;
    final command = editing ? _editor.text : proposal.effectiveCommand;
    final multiline = command.contains('\n') || command.contains('\r');
    final risk = proposal.isStructuredRead
        ? AgentCommandRisk.readOnly
        : classifyShellCommand(command);
    final highRisk = risk == AgentCommandRisk.highRisk;
    final confirm = highRisk || multiline;
    final canSend =
        agent.canSendCommand(proposal) &&
        AgentCommandProposal.isValidCommand(command);
    final needsSudo = proposal.sudoPasswordRequired.value;
    final duration = proposal.durationMs.value;
    final colors = shadcn.Theme.of(context).colorScheme;
    return _ActionFrame(
      highlight: confirm ? colors.destructive : null,
      children: [
        _Target(
          title: _target,
          trailing: pending && !proposal.isStructuredRead
              ? AppIconButton(
                  key: const ValueKey('agent-command-edit'),
                  semanticLabel: (editing ? '取消编辑' : '编辑命令').tr,
                  tooltip: (editing ? '取消编辑' : '编辑命令').tr,
                  icon: AppIcon(
                    editing ? AppIcons.x : AppIcons.pencil,
                    size: 13,
                  ),
                  onPressed: () {
                    if (!_editing) _editor.text = proposal.command;
                    setState(() => _editing = !_editing);
                  },
                )
              : null,
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _Pill((_exec ? '后台执行' : '终端输入').tr),
            _Pill(
              key: const ValueKey('agent-command-risk-badge'),
              switch (risk) {
                AgentCommandRisk.readOnly => '只读检查'.tr,
                AgentCommandRisk.mutating => (multiline ? '多行命令' : '变更操作').tr,
                AgentCommandRisk.highRisk => '高风险命令'.tr,
              },
              icon: confirm ? AppIcons.triangleAlert : null,
              color: confirm ? colors.destructive : null,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(proposal.purpose.tr, style: const TextStyle(fontSize: 12)),
        if (proposal.impact case final impact? when impact.isNotEmpty)
          Text(
            impact,
            style: TextStyle(fontSize: 11, color: colors.mutedForeground),
          ),
        if (editing)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: shadcn.TextField(
              key: const ValueKey('agent-command-input'),
              controller: _editor,
              autofocus: true,
              minLines: 1,
              maxLines: 5,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              autocorrect: false,
              style: _mono,
              onChanged: (_) => setState(() {}),
            ),
          )
        else
          AgentCodeBlock(code: command, language: 'shell'),
        if (pending)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              shadcn.OutlineButton(
                size: shadcn.ButtonSize.small,
                onPressed: () => agent.rejectCommand(proposal),
                child: Text('拒绝'.tr),
              ),
              if (!proposal.isStructuredRead)
                shadcn.OutlineButton(
                  key: const ValueKey('agent-command-insert'),
                  size: shadcn.ButtonSize.small,
                  onPressed: canSend && agent.canFillCommand(proposal)
                      ? () => _fill(command, decline: _exec)
                      : null,
                  child: Text((_exec ? '改在终端运行' : '填入终端').tr),
                ),
              shadcn.PrimaryButton(
                key: const ValueKey('agent-command-send'),
                size: shadcn.ButtonSize.small,
                onPressed: canSend
                    ? () => unawaited(_approve(command, confirm: confirm))
                    : null,
                child: Text(
                  (_exec
                          ? (proposal.isStructuredRead ? '允许读取' : '执行')
                          : '发送到终端')
                      .tr,
                ),
              ),
            ],
          )
        else if (running) ...[
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Pill(
                '正在执行 · @seconds 秒'.trParams({
                  'seconds': _seconds(duration ?? 0),
                }),
              ),
              if (!proposal.isStructuredRead)
                shadcn.OutlineButton(
                  key: const ValueKey('agent-command-cancel'),
                  size: shadcn.ButtonSize.small,
                  onPressed: proposal.cancelling.value
                      ? null
                      : () => unawaited(proposal.cancelRunningExec()),
                  child: Text('中断命令'.tr),
                ),
            ],
          ),
          if (proposal.liveOutput.value.isNotEmpty)
            _OutputSection(
              '实时输出'.tr,
              proposal.liveOutput.value,
              initiallyExpanded: true,
            ),
        ] else if (_exec && state == AgentCommandState.sent) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: _Pill(
              key: const ValueKey('agent-command-result'),
              needsSudo
                  ? '需要 sudo 密码'.tr
                  : _execStatus(
                      proposal.exitCode.value,
                      duration,
                      timedOut: proposal.timedOut.value,
                      cancelled: proposal.cancelled.value,
                    ),
              color: proposal.exitCode.value == 0
                  ? StatusColors.ready
                  : colors.destructive,
            ),
          ),
          if (proposal.error.value case final error?) _small(error.tr),
          if (proposal.truncated.value) _small('输出已截断'.tr),
          if (proposal.stdout.value.isNotEmpty)
            _OutputSection('标准输出'.tr, proposal.stdout.value),
          if (proposal.stderr.value.isNotEmpty)
            _OutputSection('错误输出'.tr, proposal.stderr.value),
          if (needsSudo)
            Align(
              alignment: Alignment.centerLeft,
              child: shadcn.OutlineButton(
                key: const ValueKey('agent-command-terminal-fallback'),
                size: shadcn.ButtonSize.small,
                onPressed: agent.canFillCommand(proposal)
                    ? () => _fill(proposal.effectiveCommand, sudo: true)
                    : null,
                child: Text('改在终端运行'.tr),
              ),
            ),
        ] else
          _small(_commandState(state)),
      ],
    );
  });
}

class AgentFileChangeCard extends StatefulWidget {
  const AgentFileChangeCard({
    required this.proposal,
    required this.agent,
    super.key,
  });
  final AgentFileChangeProposal proposal;
  final AgentController agent;

  @override
  State<AgentFileChangeCard> createState() => _AgentFileChangeCardState();
}

class _AgentFileChangeCardState extends State<AgentFileChangeCard> {
  bool _confirming = false;
  AgentFileChangeProposal get proposal => widget.proposal;

  Future<void> _rollback() async {
    if (_confirming) return;
    _confirming = true;
    try {
      final confirmed = await AppNavigation.dialog<bool>(
        AppDialog(
          title: Text('回滚文件更改？'.tr),
          content: Text(
            (proposal.createsFile
                    ? '将删除本次新建且未被外部修改的文件。运行中的服务不会自动重载。'
                    : '将从本次备份恢复文件。如果文件已被外部修改，回滚将停止。运行中的服务不会自动重载。')
                .tr,
          ),
          actions: [
            shadcn.OutlineButton(
              onPressed: () => AppNavigation.closeDialog(result: false),
              child: Text('取消'.tr),
            ),
            shadcn.DestructiveButton(
              key: const ValueKey('agent-file-confirm-rollback'),
              onPressed: () => AppNavigation.closeDialog(result: true),
              child: Text('确认回滚'.tr),
            ),
          ],
        ),
      );
      if (mounted && confirmed == true) {
        await widget.agent.rollbackFileChange(proposal);
      }
    } finally {
      _confirming = false;
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final state = proposal.state.value;
    final working = proposal.working.value;
    final backup = proposal.backupPath.value;
    final validation = proposal.validationPassed.value;
    final colors = shadcn.Theme.of(context).colorScheme;
    return _ActionFrame(
      children: [
        _Target(title: '${proposal.target.title} · ${proposal.target.address}'),
        _FilePills(
          creates: proposal.createsFile,
          sudo: proposal.useSudo,
          state: state,
        ),
        const SizedBox(height: 6),
        _PathRow(proposal.path),
        Text(proposal.purpose, style: const TextStyle(fontSize: 12)),
        _small('+${proposal.diff.added} / -${proposal.diff.removed}'),
        UnifiedDiffView(diffText: proposal.diffPreview),
        if (proposal.validationCommand case final command?)
          _small('配置校验：@command'.trParams({'command': command})),
        if (state == AgentFileChangeState.pending && !proposal.createsFile)
          _small('应用时将自动备份原文件'.tr),
        if (backup != null) _PathRow(backup, label: '备份'.tr),
        if (validation != null)
          Align(
            alignment: Alignment.centerLeft,
            child: _Pill(
              (validation ? '校验通过' : '校验失败').tr,
              color: validation ? StatusColors.ready : colors.destructive,
            ),
          ),
        if (proposal.validationOutput.value case final output?
            when output.isNotEmpty)
          _OutputSection('校验输出'.tr, output),
        if (proposal.error.value case final error?)
          Text(
            error.tr,
            style: TextStyle(fontSize: 11, color: colors.destructive),
          ),
        if (working)
          _small('正在处理远程文件'.tr)
        else
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (state == AgentFileChangeState.pending) ...[
                shadcn.OutlineButton(
                  size: shadcn.ButtonSize.small,
                  onPressed: () => widget.agent.rejectFileChange(proposal),
                  child: Text('拒绝'.tr),
                ),
                shadcn.PrimaryButton(
                  key: const ValueKey('agent-file-apply'),
                  size: shadcn.ButtonSize.small,
                  onPressed: widget.agent.canApplyFileChange(proposal)
                      ? () => widget.agent.approveFileChange(proposal)
                      : null,
                  child: Text('应用修改'.tr),
                ),
              ],
              if (state == AgentFileChangeState.applied)
                shadcn.OutlineButton(
                  key: const ValueKey('agent-file-rollback'),
                  size: shadcn.ButtonSize.small,
                  onPressed: widget.agent.canRollbackFileChange(proposal)
                      ? () => unawaited(_rollback())
                      : null,
                  child: Text('回滚更改'.tr),
                ),
              if (proposal.sudoPasswordRequired.value)
                shadcn.OutlineButton(
                  size: shadcn.ButtonSize.small,
                  onPressed: () => _insert(
                    proposal.target.id,
                    proposal.terminalFallback,
                    available: widget.agent.canFillFileChange(proposal),
                  ),
                  child: Text('改在终端运行'.tr),
                ),
            ],
          ),
      ],
    );
  });
}

class ArchivedCommandCard extends StatelessWidget {
  const ArchivedCommandCard({required this.command, super.key});
  final AgentArchivedCommand command;

  @override
  Widget build(BuildContext context) => _ActionFrame(
    children: [
      _Target(title: command.target),
      _small('历史命令（只读）'.tr),
      Text(command.purpose.tr, style: const TextStyle(fontSize: 12)),
      AgentCodeBlock(code: command.command, language: 'shell'),
      _small(
        command.executionMode == AgentCommandExecutionMode.exec &&
                command.state == AgentCommandState.sent
            ? _execStatus(
                command.exitCode,
                command.durationMs,
                timedOut: command.timedOut,
                cancelled: command.cancelled,
              )
            : _commandState(command.state),
      ),
      if (command.outputPreview case final output? when output.isNotEmpty)
        _OutputSection('执行输出'.tr, output),
    ],
  );
}

class ArchivedFileChangeCard extends StatelessWidget {
  const ArchivedFileChangeCard({required this.change, super.key});
  final AgentArchivedFileChange change;

  @override
  Widget build(BuildContext context) => _ActionFrame(
    children: [
      _Target(title: change.target),
      _small('历史文件变更（只读）'.tr),
      _FilePills(
        creates: change.createdNew,
        sudo: change.usedSudo,
        state: change.state,
      ),
      _PathRow(change.path),
      _small(change.purpose),
      _small('+${change.addedLines} / -${change.removedLines}'),
      UnifiedDiffView(diffText: change.diffText),
      if (change.backupPath case final path?) _PathRow(path, label: '备份'.tr),
      if (change.validationPassed case final passed?)
        _small((passed ? '校验通过' : '校验失败').tr),
      if (change.validationOutput case final output? when output.isNotEmpty)
        _OutputSection('校验输出'.tr, output),
      if (change.error case final message?) _small(message.tr),
    ],
  );
}

class UnifiedDiffView extends StatefulWidget {
  const UnifiedDiffView({required this.diffText, super.key});
  final String diffText;

  @override
  State<UnifiedDiffView> createState() => _UnifiedDiffViewState();
}

class _UnifiedDiffViewState extends State<UnifiedDiffView> {
  bool _expanded = false;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.diffText.isEmpty) return const SizedBox.shrink();
    final rows = widget.diffText.trimRight().split('\n');
    final colors = shadcn.Theme.of(context).colorScheme;
    final chars = rows.fold<int>(0, (largest, row) => max(largest, row.length));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _small('配置差异'.tr)),
            AppCopyButton(text: widget.diffText),
            AppIconButton(
              semanticLabel: (_expanded ? '折叠差异' : '展开差异').tr,
              tooltip: (_expanded ? '折叠差异' : '展开差异').tr,
              icon: AppIcon(
                _expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: 12,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ],
        ),
        SizedBox(
          height: min(rows.length * 18 + 12, _expanded ? 400 : 240),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.border(context)),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) => RawScrollbar(
                controller: _horizontal,
                notificationPredicate: (event) =>
                    event.metrics.axis == Axis.horizontal,
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: max(
                      constraints.maxWidth,
                      min(chars, 4096) * 10.0 + 16,
                    ),
                    child: RawScrollbar(
                      controller: _vertical,
                      child: ListView.builder(
                        key: const ValueKey('agent-unified-diff'),
                        controller: _vertical,
                        padding: const EdgeInsets.only(bottom: 10),
                        itemCount: rows.length,
                        itemExtent: 18,
                        itemBuilder: (context, index) {
                          final line = rows[index];
                          final added = line.startsWith('+') && index > 1;
                          final removed = line.startsWith('-') && index > 1;
                          return ColoredBox(
                            key: ValueKey(
                              added
                                  ? 'agent-diff-added-$index'
                                  : removed
                                  ? 'agent-diff-removed-$index'
                                  : 'agent-diff-context-$index',
                            ),
                            color:
                                (added
                                        ? StatusColors.ready
                                        : removed
                                        ? colors.destructive
                                        : colors.mutedForeground)
                                    .withValues(
                                      alpha: added || removed ? 0.16 : 0.07,
                                    ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Text(
                                line,
                                style: _mono,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _OutputSection extends StatefulWidget {
  const _OutputSection(
    this.label,
    this.output, {
    this.initiallyExpanded = false,
  });
  final String label, output;
  final bool initiallyExpanded;

  @override
  State<_OutputSection> createState() => _OutputSectionState();
}

class _OutputSectionState extends State<_OutputSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: shadcn.GhostButton(
              size: shadcn.ButtonSize.small,
              leading: AppIcon(
                _expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: 12,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(widget.label),
            ),
          ),
          AppCopyButton(text: widget.output),
        ],
      ),
      if (_expanded)
        Container(
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(maxHeight: 170),
          color: AppTheme.surface(context),
          child: SingleChildScrollView(
            primary: false,
            child: shadcn.SelectableText(widget.output, style: _mono),
          ),
        ),
    ],
  );
}

class _ActionFrame extends StatelessWidget {
  const _ActionFrame({required this.children, this.highlight});
  final List<Widget> children;
  final Color? highlight;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      border: Border.all(
        color: highlight?.withValues(alpha: 0.5) ?? AppTheme.border(context),
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

class _Target extends StatelessWidget {
  const _Target({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: shadcn.Tooltip(
          tooltip: (_) => shadcn.TooltipContainer(child: Text(title)),
          child: Text(
            '目标：@host'.trParams({'host': title}),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      ?trailing,
    ],
  );
}

class _PathRow extends StatelessWidget {
  const _PathRow(this.path, {this.label});
  final String path;
  final String? label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: shadcn.SelectableText(
          label == null ? path : '$label: $path',
          style: _mono,
        ),
      ),
      AppCopyButton(text: path),
    ],
  );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.color, this.icon, super.key});
  final String text;
  final Color? color;
  final AppIcons? icon;

  @override
  Widget build(BuildContext context) {
    final tone = color ?? shadcn.Theme.of(context).colorScheme.mutedForeground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon case final glyph?) ...[
            AppIcon(glyph, size: 11, color: tone),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilePills extends StatelessWidget {
  const _FilePills({
    required this.creates,
    required this.sudo,
    required this.state,
  });
  final bool creates, sudo;
  final AgentFileChangeState state;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      _Pill((creates ? '新建文件' : '修改文件').tr),
      if (sudo) const _Pill('sudo'),
      if (state != AgentFileChangeState.pending)
        _Pill(switch (state) {
          AgentFileChangeState.applied => '已应用'.tr,
          AgentFileChangeState.rolledBack => '已回滚'.tr,
          AgentFileChangeState.rejected => '已拒绝'.tr,
          AgentFileChangeState.failed => '文件操作失败'.tr,
          _ => '未应用'.tr,
        }),
    ],
  );
}

Widget _small(String text) => Text(text, style: const TextStyle(fontSize: 11));

String _seconds(int ms) => (ms / 1000).toStringAsFixed(1);

String _execStatus(
  int? code,
  int? duration, {
  required bool timedOut,
  required bool cancelled,
}) {
  if (timedOut) return '已超时'.tr;
  if (cancelled) return '已中断'.tr;
  if (code == null) return '未获得退出码'.tr;
  return '退出码 @code'.trParams({'code': '$code'}) +
      (duration == null ? '' : ' · ${_seconds(duration)}s');
}

String _commandState(AgentCommandState state) => switch (state) {
  AgentCommandState.sent => '已发送到终端'.tr,
  AgentCommandState.rejected => '已拒绝'.tr,
  _ => '未发送'.tr,
};
