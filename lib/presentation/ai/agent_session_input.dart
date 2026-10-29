import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_controller.dart';
import '../../application/session/session.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import 'agent_input_controller.dart';

class _MentionOption {
  const _MentionOption({
    required this.id,
    required this.label,
    required this.detail,
    required this.icon,
    required this.selected,
    required this.onSelected,
  });
  final String id;
  final String label;
  final String detail;
  final IconData icon;
  final bool selected;
  final VoidCallback onSelected;
}

class _MentionGroup {
  const _MentionGroup(this.id, this.label, this.options);
  final String id;
  final String label;
  final List<_MentionOption> options;
}

class _MentionOptionRow extends StatefulWidget {
  const _MentionOptionRow({
    required this.option,
    required this.highlighted,
    required this.onHover,
    super.key,
  });

  final _MentionOption option;
  final bool highlighted;
  final VoidCallback onHover;

  @override
  State<_MentionOptionRow> createState() => _MentionOptionRowState();
}

class _MentionOptionRowState extends State<_MentionOptionRow> {
  @override
  void didUpdateWidget(covariant _MentionOptionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.highlighted && widget.highlighted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.highlighted) {
          unawaited(Scrollable.ensureVisible(context));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final option = widget.option;
    return shadcn.Tooltip(
      tooltip: (_) => shadcn.TooltipContainer(
        child: Text('${option.label}\n${option.detail}'),
      ),
      child: ExcludeFocus(
        child: MouseRegion(
          onEnter: (_) => widget.onHover(),
          child: shadcn.SelectedButton(
            key: ValueKey('agent-mention-${option.id}'),
            value: widget.highlighted,
            alignment: Alignment.centerLeft,
            onChanged: (_) => option.onSelected(),
            child: Row(
              children: [
                Icon(
                  option.selected ? shadcn.LucideIcons.check : option.icon,
                  size: 15,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// @ 和 + 共用按来源分组的弹层；连接句柄只由用户选择，保留输入焦点。
class AgentSessionInput extends StatefulWidget {
  const AgentSessionInput({
    required this.agent,
    required this.controller,
    required this.focusNode,
    required this.footer,
    required this.onSend,
    super.key,
  });

  final AgentController agent;
  final AgentInputController controller;
  final FocusNode focusNode;
  final Widget footer;
  final VoidCallback onSend;

  @override
  State<AgentSessionInput> createState() => _AgentSessionInputState();
}

class _AgentSessionInputState extends State<AgentSessionInput> {
  final _popover = shadcn.OverlayController();
  final _groups = ValueNotifier<List<_MentionGroup>>([]);
  final _highlight = ValueNotifier<int>(-1);
  TextEditingValue? _lastValue;
  TextEditingValue? _dismissed;
  TextEditingValue? _buttonRequest;
  List<Object?> _lastOptions = [];
  int _revision = 0;
  late Worker _referencesWorker;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
    _listenReferences();
  }

  void _listenReferences() {
    widget.controller.addListener(_referencesChanged);
    _referencesWorker = ever(widget.agent.selectedSessions, (_) {
      final count = widget.controller.mentions.length;
      widget.controller.retainSessions(widget.agent.canReferenceSession);
      if (widget.controller.mentions.length != count) {
        // 连接失效只解除引用，不把留下的 @ 文字当作新搜索自动打开弹层。
        _buttonRequest = null;
        _dismissed = widget.controller.value;
        _popover.close();
      }
    });
    _referencesChanged();
  }

  void _referencesChanged() =>
      widget.agent.setReferencedSessions(widget.controller.sessions);

  @override
  void didUpdateWidget(covariant AgentSessionInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.agent != widget.agent) {
      oldWidget.controller.removeListener(_referencesChanged);
      _referencesWorker.dispose();
      _listenReferences();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    widget.controller.removeListener(_referencesChanged);
    _referencesWorker.dispose();
    _popover.dispose();
    _groups.dispose();
    _highlight.dispose();
    super.dispose();
  }

  bool _composing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  ({int start, int end, String query})? _query(TextEditingValue value) {
    if (widget.agent.busy.value ||
        !value.selection.isValid ||
        !value.selection.isCollapsed ||
        value.selection.baseOffset > value.text.length ||
        widget.controller.containsMentionAt(value.selection.baseOffset)) {
      return null;
    }
    final caret = value.selection.baseOffset;
    final match = RegExp(r'@([^\r\n@]*)$')
        .firstMatch(value.text.substring(0, caret));
    if (match == null ||
        // 已选引用后的空格和普通文本不继续当作搜索词。
        widget.controller.containsMentionAt(match.start + 1) ||
        (match.start > 0 &&
            !RegExp(r'\s').hasMatch(value.text[match.start - 1]))) {
      return null;
    }
    return (
      start: match.start,
      end: caret,
      query: match.group(1)!.trim().toLowerCase(),
    );
  }

  void _focusChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPopover();
    });
  }

  bool _requestedByButton(TextEditingValue value) =>
      _buttonRequest == value && !widget.agent.busy.value && !_composing(value);

  void _openMentions() {
    if (widget.agent.busy.value || _composing(widget.controller.value)) return;
    if (!widget.controller.selection.isValid) {
      widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length,
      );
    }
    widget.focusNode.requestFocus();
    if (_popover.hasOpenOverlay) return;
    setState(() {
      // 每次点击保留独立快照，旧弹层的关闭回调不清除新的打开请求。
      _buttonRequest = widget.controller.value.copyWith();
      _dismissed = null;
    });
  }

  void _syncPopover() {
    final value = widget.controller.value;
    if (_dismissed != null && value != _dismissed) _dismissed = null;
    if (_buttonRequest != value || !widget.focusNode.hasFocus) {
      _buttonRequest = null;
    }
    if (!widget.focusNode.hasFocus ||
        (_query(value) == null && !_requestedByButton(value)) ||
        value == _dismissed) {
      _popover.close();
      return;
    }
    if (_popover.hasOpenOverlay) return;
    final buttonRequest = _buttonRequest;
    unawaited(
      _popover
          .show<void>(
            context,
            const shadcn.PopoverConfiguration(
              widthConstraint: shadcn.PopoverConstraint.flexible,
              anchorAlignment: Alignment.topLeft,
              alignment: Alignment.bottomLeft,
              offset: Offset(0, -6),
              dismissBackdropFocus: false,
            ),
            adaptive: false,
            builder: _popoverContent,
          )
          .then((_) {
            if (mounted &&
                buttonRequest != null &&
                identical(buttonRequest, _buttonRequest)) {
              setState(() => _buttonRequest = null);
            }
          }),
    );
  }

  List<_MentionOption> get _options =>
      _groups.value.expand((group) => group.options).toList();

  void _chooseSession(Session session, String label) {
    final value = widget.controller.value;
    final query = _query(value);
    if (_composing(value) ||
        (query == null && !_requestedByButton(value)) ||
        !widget.agent.canReferenceSession(session)) {
      return;
    }
    _buttonRequest = null;
    _popover.close();
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    widget.controller.insertSession(
      session,
      label,
      query == null
          ? TextRange(start: selection.start, end: selection.end)
          : TextRange(start: query.start, end: query.end),
    );
    widget.focusNode.requestFocus();
  }

  void _accept() {
    final options = _options;
    if (options.isEmpty) return;
    options[_highlight.value.clamp(0, options.length - 1)].onSelected();
  }

  void _enter() {
    if (_composing(widget.controller.value)) return;
    if (_popover.hasOpenOverlay && _options.isNotEmpty) {
      _accept();
    } else {
      _popover.close();
      widget.onSend();
    }
  }

  void _newline() {
    final value = widget.controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, '\n'),
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
  }

  void _navigate(int direction) {
    final options = _options;
    if (options.isEmpty) return;
    final previous = _highlight.value;
    final index = previous < 0
        ? direction > 0
              ? 0
              : options.length - 1
        : (previous + direction) % options.length;
    _highlight.value = index;
  }

  Widget _popoverContent(BuildContext context) => TextFieldTapRegion(
    child: SizedBox(
      width: (MediaQuery.sizeOf(context).width - 32).clamp(0, 300),
      child: shadcn.SurfaceCard(
        key: const ValueKey('agent-mention-popover'),
        theme: const shadcn.CardTheme(padding: EdgeInsets.all(6)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ListenableBuilder(
            listenable: Listenable.merge([_groups, _highlight]),
            builder: (context, _) {
              var index = 0;
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final group in _groups.value) ...[
                      Padding(
                        key: ValueKey('agent-mention-group-${group.id}'),
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                        child: Text(
                          group.label,
                          style: TextStyle(
                            fontSize: 11,
                            color: shadcn.Theme.of(context)
                                .colorScheme
                                .mutedForeground,
                          ),
                        ),
                      ),
                      if (group.options.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            '没有匹配的会话'.tr,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      for (final option in group.options)
                        _option(option, index++),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _option(_MentionOption option, int index) => _MentionOptionRow(
    key: ValueKey(option.id),
    option: option,
    highlighted: index == _highlight.value,
    onHover: () => _highlight.value = index,
  );

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: widget.controller,
    builder: (context, value, _) => Obx(() {
      final agent = widget.agent;
      final query = _query(value);
      final terms = (query?.query ?? '')
          .split(RegExp(r'\s+'))
          .where((term) => term.isNotEmpty)
          .toList();
      final byButton = _requestedByButton(value);
      final allSessions = agent.selectableSessions;
      final sessions = query == null && !byButton
          ? <Session>[]
          : allSessions.where((session) {
              final searchable = '${session.title} ${session.host.address}'
                  .toLowerCase();
              return terms.every(searchable.contains);
            }).toList();
      final selected = agent.selectedSessions.toList();
      String label(Session session) =>
          '${session.title} · ${session.kind == SessionKind.remoteDesktop ? '远程桌面'.tr : '终端'.tr}';
      String displayLabel(Session session) =>
          allSessions.where((item) => label(item) == label(session)).length > 1
          ? '${label(session)} · ${allSessions.takeWhile((item) => item.id != session.id).where((item) => label(item) == label(session)).length + 1}'
          : label(session);
      bool isSelected(Session session) =>
          selected.any((item) => item.id == session.id);
      final identities = <Object?>[
        query,
        byButton,
        for (final session in sessions)
          (
            session.id,
            session.engineSession,
            session.terminal,
            session.desktopSession,
            displayLabel(session),
            session.host.address,
            isSelected(session),
          ),
        '会话'.tr,
      ];
      if (_lastValue != value || !listEquals(_lastOptions, identities)) {
        _lastValue = value;
        _lastOptions = identities;
        final revision = ++_revision;
        final groups = [
          _MentionGroup('sessions', '会话'.tr, [
            for (var i = 0; i < sessions.length; i++)
              _MentionOption(
                id: sessions[i].id,
                label: displayLabel(sessions[i]),
                detail: sessions[i].host.address,
                icon: sessions[i].kind == SessionKind.remoteDesktop
                    ? shadcn.LucideIcons.monitor
                    : shadcn.LucideIcons.terminal,
                selected: isSelected(sessions[i]),
                onSelected: () => _chooseSession(
                  sessions[i],
                  allSessions
                              .where((item) => item.title == sessions[i].title)
                              .length >
                          1
                      ? displayLabel(sessions[i])
                      : sessions[i].title,
                ),
              ),
          ]),
        ];
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || revision != _revision) return;
          _highlight.value = -1;
          _groups.value = groups;
          _syncPopover();
        });
      }
      return ListenableBuilder(
        listenable: _popover,
        builder: (context, _) => CallbackShortcuts(
          bindings: {
            if (!_composing(value)) ...{
              const SingleActivator(LogicalKeyboardKey.enter): _enter,
              const SingleActivator(LogicalKeyboardKey.numpadEnter): _enter,
              const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                  _newline,
              const SingleActivator(
                LogicalKeyboardKey.numpadEnter,
                shift: true,
              ): _newline,
              if (_popover.hasOpenOverlay) ...{
                const SingleActivator(LogicalKeyboardKey.tab): _accept,
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _navigate(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _navigate(-1),
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  _buttonRequest = null;
                  _dismissed = widget.controller.value;
                  _popover.close();
                },
              },
            },
          },
          child: AppTextFormField(
            key: const ValueKey('agent-input'),
            controller: widget.controller,
            focusNode: widget.focusNode,
            maxLines: 4,
            minLines: 2,
            smartPunctuation: false,
            decoration: AppInputDecoration(
              hintText: '输入消息，@ 选择会话…'.tr,
              footer: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  AppIconButton.text(
                    key: const ValueKey('agent-add-context'),
                    density: shadcn.ButtonDensity.compact,
                    semanticLabel: '添加上下文'.tr,
                    icon: const Icon(shadcn.LucideIcons.plus, size: 16),
                    onPressed: agent.busy.value || _composing(value)
                        ? null
                        : _openMentions,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: widget.footer),
                ],
              ),
            ),
          ),
        ),
      );
    }),
  );
}
