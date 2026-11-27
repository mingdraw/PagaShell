import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:url_launcher/url_launcher.dart';

import '../../application/settings/settings_controller.dart';
import '../../domain/entities/sidebar_state.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_menu.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'terminal_pane_zoom_intent.dart';

enum _MultilinePasteMode { raw, trimTrailingNewline }

typedef _MultilinePasteDecision = ({_MultilinePasteMode mode, bool skipFuture});

class AppTerminalView extends StatefulWidget {
  const AppTerminalView(
    this.terminal, {
    required this.focusNode,
    required this.active,
    this.canInput = true,
    this.hasPaneControls = false,
    this.onSplitHorizontal,
    this.onSplitVertical,
    this.onOpenFileTransfer,
    this.onReconnect,
    this.onQuoteSelection,
    this.onUserInput,
    this.inputSyncPanes,
    super.key,
  });

  final Terminal terminal;
  final FocusNode focusNode;
  final bool active;
  final bool canInput;
  final bool hasPaneControls;
  final VoidCallback? onSplitHorizontal;
  final VoidCallback? onSplitVertical;
  final VoidCallback? onOpenFileTransfer;
  final VoidCallback? onReconnect;
  final ValueChanged<String>? onQuoteSelection;
  final ValueChanged<void Function(Terminal)>? onUserInput;
  final List<String> Function()? inputSyncPanes;

  @override
  State<AppTerminalView> createState() => AppTerminalViewState();
}

class AppTerminalViewState extends State<AppTerminalView> {
  final _paneKey = GlobalKey<TerminalPaneState>();

  void scrollToBottom() => _paneKey.currentState?.scrollToBottom();
  bool _skipMultilinePastePrompt = false;
  bool _pasteConfirming = false;
  final _query = TextEditingController();
  final _findFocus = FocusNode();
  final _textSearch = TerminalTextSearch();
  TextEditingValue _previousQuery = TextEditingValue.empty;
  final _handledKeys = <PhysicalKeyboardKey>{};
  Timer? _fontSizeHintTimer;
  double? _fontSizeHint;
  Timer? _findTimer;
  bool _finding = false;
  bool _caseSensitive = false;
  bool _regex = false;
  String? _findError;
  List<TerminalTextMatch> _matches = const [];
  int _matchIndex = -1;
  int _searchRevision = 0;
  bool _findBusy = false;
  bool _findAgain = false;
  bool _revealNext = false;
  bool _wasAtBottom = true;
  bool _newOutput = false;
  late int _outputRevision;
  late bool _usingAltBuffer;
  double? _cachedFontSize;
  TerminalStyle? _cachedTextStyle;

  static const _terminalFontFamilyFallback = [
    'MesloLGS NF',
    'Menlo',
    'PingFang SC',
    'Microsoft YaHei',
    'Noto Sans Mono CJK SC',
    'Apple Color Emoji',
    'Segoe UI Emoji',
    'Noto Color Emoji',
    'monospace',
  ];

  static final _terminalTheme = TerminalTheme(
    cursor: TerminalThemes.defaultTheme.cursor,
    selection: TerminalThemes.defaultTheme.selection,
    foreground: TerminalThemes.defaultTheme.foreground,
    background: AppTheme.terminalBackground,
    black: TerminalThemes.defaultTheme.black,
    red: TerminalThemes.defaultTheme.red,
    green: TerminalThemes.defaultTheme.green,
    yellow: TerminalThemes.defaultTheme.yellow,
    blue: TerminalThemes.defaultTheme.blue,
    magenta: TerminalThemes.defaultTheme.magenta,
    cyan: TerminalThemes.defaultTheme.cyan,
    white: TerminalThemes.defaultTheme.white,
    brightBlack: TerminalThemes.defaultTheme.brightBlack,
    brightRed: TerminalThemes.defaultTheme.brightRed,
    brightGreen: TerminalThemes.defaultTheme.brightGreen,
    brightYellow: TerminalThemes.defaultTheme.brightYellow,
    brightBlue: TerminalThemes.defaultTheme.brightBlue,
    brightMagenta: TerminalThemes.defaultTheme.brightMagenta,
    brightCyan: TerminalThemes.defaultTheme.brightCyan,
    brightWhite: TerminalThemes.defaultTheme.brightWhite,
    searchHitBackground: TerminalThemes.defaultTheme.searchHitBackground,
    searchHitBackgroundCurrent:
        TerminalThemes.defaultTheme.searchHitBackgroundCurrent,
    searchHitForeground: TerminalThemes.defaultTheme.searchHitForeground,
  );

  TerminalStyle _styleFor(double fontSizePt, TargetPlatform platform) {
    final logicalFontSize = terminalFontSizeToLogicalPixels(
      fontSizePt,
      platform,
    );
    if (_cachedFontSize == logicalFontSize && _cachedTextStyle != null) {
      return _cachedTextStyle!;
    }
    _cachedFontSize = logicalFontSize;
    return _cachedTextStyle = TerminalStyle(
      fontSize: logicalFontSize,
      fontFamily: 'FiraCode Nerd Font Mono',
      fontFamilyFallback: _terminalFontFamilyFallback,
    );
  }

  @override
  void initState() {
    super.initState();
    _outputRevision = widget.terminal.outputRevision;
    _usingAltBuffer = widget.terminal.isUsingAltBuffer;
    widget.terminal.addListener(_onTerminalFrame);
    _query.addListener(_onQueryChanged);
  }

  @override
  void didUpdateWidget(covariant AppTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.terminal, widget.terminal)) {
      _skipMultilinePastePrompt = false;
      oldWidget.terminal.removeListener(_onTerminalFrame);
      widget.terminal.addListener(_onTerminalFrame);
      _outputRevision = widget.terminal.outputRevision;
      _usingAltBuffer = widget.terminal.isUsingAltBuffer;
      _textSearch.cancel();
      _clearFindResults();
      _wasAtBottom = true;
      _newOutput = false;
      _scheduleSearch();
    } else if (widget.active && !oldWidget.active) {
      _scheduleSearch();
    }
  }

  @override
  void dispose() {
    _searchRevision++;
    _findTimer?.cancel();
    _fontSizeHintTimer?.cancel();
    _textSearch.dispose();
    _query.dispose();
    _findFocus.dispose();
    widget.terminal.removeListener(_onTerminalFrame);
    super.dispose();
  }

  void _onTerminalFrame() {
    if (_usingAltBuffer != widget.terminal.isUsingAltBuffer) {
      _usingAltBuffer = widget.terminal.isUsingAltBuffer;
      setState(_clearFindResults);
      _textSearch.cancel();
      _scheduleSearch();
    }
    final revision = widget.terminal.outputRevision;
    if (revision == _outputRevision) return;
    _outputRevision = revision;
    if (!_wasAtBottom && !_newOutput) setState(() => _newOutput = true);
    _scheduleSearch();
  }

  void _onScrollChanged(bool atBottom) {
    if (atBottom == _wasAtBottom && (!atBottom || !_newOutput)) return;
    setState(() {
      _wasAtBottom = atBottom;
      if (atBottom) _newOutput = false;
    });
  }

  void _showFind() {
    if (!_finding) {
      setState(() => _finding = true);
      _scheduleSearch(reveal: true);
    }
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
    _findFocus.requestFocus();
  }

  void _hideFind() {
    _textSearch.cancel();
    setState(() {
      _finding = false;
      _clearFindResults();
    });
    widget.focusNode.requestFocus();
  }

  void _clearFindResults() {
    _findTimer?.cancel();
    _findTimer = null;
    _searchRevision++;
    _findAgain = false;
    _revealNext = false;
    _matches = const [];
    _matchIndex = -1;
    _findError = null;
    _paintMatches();
  }

  void _onQueryChanged() {
    final value = _query.value;
    final previous = _previousQuery;
    _previousQuery = value;
    if (!_finding ||
        (value.text == previous.text &&
            value.composing == previous.composing)) {
      return;
    }
    setState(_clearFindResults);
    _scheduleSearch(reveal: true);
  }

  void _scheduleSearch({bool reveal = false}) {
    if (!_finding ||
        !widget.active ||
        _query.text.isEmpty ||
        !_query.value.composing.isCollapsed ||
        (_findError != null && !reveal)) {
      return;
    }
    if (reveal) {
      _searchRevision++;
      _revealNext = true;
      _findTimer?.cancel();
      _findTimer = null;
    }
    _findTimer ??= Timer(Duration(milliseconds: _revealNext ? 120 : 450), () {
      _findTimer = null;
      if (_findBusy) {
        _findAgain = true;
        return;
      }
      final revealMatches = _revealNext;
      _revealNext = false;
      _findBusy = true;
      unawaited(
        _find(reveal: revealMatches).whenComplete(() {
          _findBusy = false;
          if (mounted && _finding && _findAgain) {
            _findAgain = false;
            _scheduleSearch();
          }
        }),
      );
    });
  }

  Future<void> _find({required bool reveal}) async {
    if (!mounted || !_finding || !widget.active) return;
    final revision = _searchRevision;
    final buffer = widget.terminal.buffer;
    List<TerminalTextMatch> results = const [];
    String? error;
    try {
      results = await _textSearch.find(
        buffer,
        _query.text,
        regex: _regex,
        caseSensitive: _caseSensitive,
      );
    } on FormatException {
      error = '正则表达式无效';
    } on TimeoutException {
      error = '搜索超时，请简化正则表达式';
    } on Object {
      error = '终端查找失败，请重试';
    }
    if (!mounted ||
        !_finding ||
        !widget.active ||
        revision != _searchRevision ||
        !identical(buffer, widget.terminal.buffer)) {
      return;
    }
    final previous = _matchIndex < 0 ? null : _matches[_matchIndex];
    final index = reveal || previous == null
        ? -1
        : results.indexWhere(
            (match) =>
                identical(previous.first, match.first) &&
                previous.start == match.start,
          );
    setState(() {
      _matches = results;
      _matchIndex = index >= 0 ? index : results.length - 1;
      _findError = error;
    });
    _paintMatches(reveal: reveal);
  }

  void _paintMatches({bool reveal = false}) {
    final pane = _paneKey.currentState;
    pane?.paintSearchMatches(
      _matches,
      _matchIndex,
      matchColor: AppTheme.terminalSearchMatch,
      selectedColor: AppTheme.terminalSearchSelected,
    );
    if (reveal) _revealMatch();
  }

  void _revealMatch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_finding || _matchIndex < 0) return;
      _paneKey.currentState?.revealMatch(_matches[_matchIndex]);
    });
  }

  void _stepMatch(int direction) {
    if (_matches.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + direction) % _matches.length);
    _paneKey.currentState?.selectSearchMatch(_matchIndex);
    _revealMatch();
  }

  KeyEventResult _paneShortcut(KeyEvent event) {
    if (event is KeyDownEvent) {
      _handledKeys.remove(event.physicalKey);
    } else if (_handledKeys.contains(event.physicalKey)) {
      if (event is KeyUpEvent) _handledKeys.remove(event.physicalKey);
      return KeyEventResult.handled;
    }
    if (!widget.active) return KeyEventResult.ignored;
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final key = event.logicalKey;
    bool accepts({bool shift = false, bool alt = false}) => SingleActivator(
      key,
      meta: isMac,
      control: !isMac,
      shift: shift,
      alt: alt,
    ).accepts(event, HardwareKeyboard.instance);
    if (_isEnter(key) && accepts(shift: true)) {
      // 单窗格和按键连发都必须拦截，不能把回车交给远端。
      if (event is KeyDownEvent) {
        Actions.maybeInvoke(context, const TerminalPaneZoomIntent());
      }
    } else if ((key == LogicalKeyboardKey.bracketLeft ||
            key == LogicalKeyboardKey.bracketRight) &&
        accepts(alt: true)) {
      if (event is KeyDownEvent) {
        Actions.maybeInvoke(
          context,
          TerminalPaneCycleIntent(
            key == LogicalKeyboardKey.bracketLeft ? -1 : 1,
          ),
        );
      }
    } else if (key == LogicalKeyboardKey.keyF && accepts(shift: !isMac)) {
      if (event is KeyDownEvent) _showFind();
    } else {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _handledKeys.add(event.physicalKey);
    return KeyEventResult.handled;
  }

  bool _isEnter(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;

  KeyEventResult _terminalKey(FocusNode node, KeyEvent event) {
    final command = _paneShortcut(event);
    if (command != KeyEventResult.ignored) return command;
    if (!widget.active ||
        !node.hasFocus ||
        !Get.isRegistered<SettingsController>()) {
      return KeyEventResult.ignored;
    }
    final isMac = shadcn.Theme.of(context).platform == TargetPlatform.macOS;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isMetaPressed != isMac ||
        keyboard.isControlPressed == isMac) {
      return KeyEventResult.ignored;
    }
    final shift = keyboard.isShiftPressed;
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.equal ||
      LogicalKeyboardKey.add ||
      LogicalKeyboardKey.numpadAdd => 1.0,
      LogicalKeyboardKey.minus ||
      LogicalKeyboardKey.numpadSubtract when shift != isMac => -1.0,
      LogicalKeyboardKey.underscore when shift && !isMac => -1.0,
      LogicalKeyboardKey.digit0 ||
      LogicalKeyboardKey.numpad0 when !shift => 0.0,
      _ => null,
    };
    if (delta == null || event is KeyUpEvent) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _handledKeys.add(event.physicalKey);
      _adjustFontSize(delta);
    }
    return KeyEventResult.handled;
  }

  void _adjustFontSize(double delta) {
    final settings = Get.find<SettingsController>();
    final next = delta == 0
        ? SidebarState.defaultTerminalFontSize
        : (settings.terminalFontSize.value + delta).clamp(
            SidebarState.minTerminalFontSize,
            SidebarState.maxTerminalFontSize,
          );
    unawaited(settings.setTerminalFontSize(next).catchError((Object _) {}));
    _fontSizeHintTimer?.cancel();
    setState(() => _fontSizeHint = next);
    _fontSizeHintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _fontSizeHint = null);
    });
  }

  KeyEventResult _findKey(FocusNode node, KeyEvent event) {
    final command = _paneShortcut(event);
    if (command != KeyEventResult.ignored) return command;
    final key = event.logicalKey;
    if (!_isEnter(key) && key != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_isEnter(key) && !_findFocus.hasFocus) return KeyEventResult.ignored;
    if (!_query.value.composing.isCollapsed) {
      return KeyEventResult.skipRemainingHandlers;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      if (key == LogicalKeyboardKey.escape) {
        _hideFind();
      } else {
        _stepMatch(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      }
    }
    return KeyEventResult.handled;
  }

  Future<void> _openLink(Uri url) async {
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } on Exception {
      // Platform launcher may be unavailable.
    }
    if (mounted) AppNotice.error('无法打开链接');
  }

  Future<bool> _handlePaste(Terminal terminal, String text) async {
    bool canPaste() =>
        mounted &&
        widget.active &&
        widget.canInput &&
        identical(widget.terminal, terminal);
    if (!canPaste() || text.isEmpty) return false;
    final hasNewline = text.contains('\n') || text.contains('\r');
    List<String> syncPanes() => widget.inputSyncPanes?.call() ?? const [];
    final recipients = syncPanes();
    if (!hasNewline || (_skipMultilinePastePrompt && recipients.isEmpty)) {
      _paste(terminal, text);
      return true;
    }
    if (_pasteConfirming) return false;
    _pasteConfirming = true;
    try {
      final decision = await AppNavigation.dialog<_MultilinePasteDecision>(
        _MultilinePasteDialog(text: text, syncPanes: recipients),
      );
      if (!canPaste()) return false;
      if (decision == null) {
        widget.focusNode.requestFocus();
        return false;
      }
      if (!listEquals(recipients, syncPanes())) {
        AppNotice.error('同步输入目标已变化，请重新粘贴');
        widget.focusNode.requestFocus();
        return false;
      }
      if (decision.skipFuture) {
        _skipMultilinePastePrompt = true;
      }
      final payload = decision.mode == _MultilinePasteMode.trimTrailingNewline
          ? text.replaceFirst(RegExp(r'[\r\n]+$'), '')
          : text;
      if (payload.isNotEmpty) {
        _paste(terminal, payload);
      }
      widget.focusNode.requestFocus();
      return payload.isNotEmpty;
    } finally {
      _pasteConfirming = false;
    }
  }

  void _paste(Terminal terminal, String text) {
    _sendInput(terminal, (target) => target.paste(text));
  }

  void _sendInput(Terminal terminal, void Function(Terminal) send) {
    send(terminal);
    if (widget.active) widget.onUserInput?.call(send);
    _paneKey.currentState?.scrollToBottom();
  }

  Future<void> _pasteFromClipboard(Terminal terminal) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.isEmpty) return;
    if (await _handlePaste(terminal, text) && mounted) {
      _paneKey.currentState?.clearSelection();
    }
  }

  void _showContextMenu(TapUpDetails details, CellOffset _) {
    final terminal = widget.terminal;
    final pane = _paneKey.currentState;
    final hasSelection = pane?.hasSelection ?? false;
    final selection = widget.onQuoteSelection == null
        ? null
        : pane?.selectedText;
    final workspaceActions = <(String, String)>[
      if (widget.onSplitHorizontal != null) ('split-horizontal', '左右分屏'.tr),
      if (widget.onSplitVertical != null) ('split-vertical', '上下分屏'.tr),
      if (widget.onOpenFileTransfer != null) ('open-transfer', '文件传输'.tr),
      if (widget.onReconnect != null) ('reconnect', '重新连接'.tr),
    ];
    final disabled = <String>{
      if (!hasSelection) 'copy',
      if (selection == null || selection.trim().isEmpty) 'quote-to-agent',
      if (!widget.canInput) 'paste',
      if (!widget.canInput) 'clear',
    };
    const icons = <String, AppIcons>{
      'copy': AppIcons.copy,
      'paste': AppIcons.fileImport,
      'quote-to-agent': AppIcons.bot,
      'select-all': AppIcons.layers,
      'find': AppIcons.search,
      'clear': AppIcons.brush,
      'split-horizontal': AppIcons.columns2,
      'split-vertical': AppIcons.rows2,
      'open-transfer': AppIcons.folderOpen,
      'reconnect': AppIcons.rotateCw,
    };
    void onSelected(String action) {
      if (!mounted || !identical(widget.terminal, terminal)) return;
      switch (action) {
        case 'copy':
          final text = _paneKey.currentState?.selectedText;
          if (text != null && text.isNotEmpty) {
            unawaited(Clipboard.setData(ClipboardData(text: text)));
          }
          widget.focusNode.requestFocus();
        case 'paste':
          unawaited(_pasteFromClipboard(terminal));
        case 'quote-to-agent':
          if (selection != null) widget.onQuoteSelection?.call(selection);
        case 'select-all':
          _paneKey.currentState?.selectAll();
          widget.focusNode.requestFocus();
        case 'find':
          _showFind();
        case 'clear':
          if (widget.canInput) {
            _sendInput(terminal, (target) => target.textInput('\x0c'));
          }
          widget.focusNode.requestFocus();
        case 'split-horizontal':
          widget.onSplitHorizontal?.call();
        case 'split-vertical':
          widget.onSplitVertical?.call();
        case 'open-transfer':
          widget.onOpenFileTransfer?.call();
        case 'reconnect':
          widget.onReconnect?.call();
      }
    }

    shadcn.showDropdown<void>(
      context: context,
      position: details.globalPosition,
      alignment: Alignment.topLeft,
      anchorAlignment: Alignment.topRight,
      offset: const Offset(4, 0),
      follow: false,
      builder: (_) => shadcn.DropdownMenu(
        children: [
          ...appMenuItems<String>(
            [
              ('copy', '复制'.tr),
              ('paste', '粘贴'.tr),
              ('select-all', '全选'.tr),
              ('find', '查找终端输出'.tr),
              ('clear', '清屏'.tr),
              if (widget.onQuoteSelection != null)
                ('quote-to-agent', '引用选区到 Agent'.tr),
            ],
            onSelected,
            disabledValues: disabled,
            icons: icons,
          ),
          if (workspaceActions.isNotEmpty) ...[
            const shadcn.MenuDivider(),
            ...appMenuItems<String>(workspaceActions, onSelected, icons: icons),
          ],
        ],
      ),
    );
  }

  Widget _pane(double fontSizePt) {
    final terminal = widget.terminal;
    final platform = shadcn.Theme.of(context).platform;
    final pane = TerminalPane(
      terminal,
      key: _paneKey,
      focusNode: widget.focusNode,
      active: widget.active,
      backgroundColor: AppTheme.terminalBackground,
      theme: _terminalTheme,
      selectionEdgeExtent: AppTheme.terminalSelectionEdgeExtent,
      selectionScrollInterval: AppTheme.terminalSelectionScrollInterval,
      onPaste: (text) => _handlePaste(terminal, text),
      onSecondaryTapUp: _showContextMenu,
      onOpenLink: (url) => unawaited(_openLink(url)),
      onKeyEvent: _terminalKey,
      onUserInput: widget.active && widget.canInput ? widget.onUserInput : null,
      onScrollPositionChanged: _onScrollChanged,
      showScrollbar: true,
      textStyle: _styleFor(fontSizePt, platform),
    );
    final body = Stack(
      fit: StackFit.expand,
      children: [
        pane,
        if (!_wasAtBottom && widget.active)
          Positioned(
            bottom: widget.canInput ? 10 : 60,
            right: 14,
            child: shadcn.Theme(
              data: AppTheme.terminalTheme(context),
              child: shadcn.OutlineButton(
                key: const ValueKey('terminal-scroll-bottom'),
                onPressed: () {
                  _paneKey.currentState?.scrollToBottom();
                  widget.focusNode.requestFocus();
                },
                size: shadcn.ButtonSize.small,
                leading: const AppIcon(AppIcons.arrowDown, size: 13),
                child: Text((_newOutput ? '回到底部 · 有新输出' : '回到底部').tr),
              ),
            ),
          ),
        if (_fontSizeHint case final size?)
          Positioned(
            bottom: 10,
            left: 10,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppTheme.terminalControlBackground,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    '终端字号：@size'.trParams({
                      'size': '${size.toStringAsFixed(0)} pt',
                    }),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.terminalForeground,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_finding)
            Padding(
              padding: EdgeInsets.fromLTRB(
                8,
                4,
                widget.hasPaneControls
                    ? 8 +
                          AppTheme.terminalPaneControlsInset +
                          AppTheme.terminalPaneControlsWidth
                    : 8,
                4,
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: shadcn.Theme(
                  data: AppTheme.terminalTheme(context),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.max(0, constraints.maxHeight - 8) * .65,
                      maxWidth: 440,
                    ),
                    child: SingleChildScrollView(child: _findBar()),
                  ),
                ),
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _findBar() {
    Widget option(
      String label,
      String text,
      bool selected,
      VoidCallback toggle,
    ) => AppIconButton.text(
      semanticLabel: label.tr,
      tooltip: label.tr,
      onPressed: toggle,
      icon: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          color: selected
              ? AppTheme.terminalSearchOption
              : AppTheme.terminalMutedForeground,
        ),
      ),
    );
    Widget button(String label, AppIcons icon, VoidCallback? action) =>
        AppIconButton(
          semanticLabel: label.tr,
          tooltip: label.tr,
          onPressed: action,
          icon: AppIcon(icon, size: 14),
        );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.terminalControlBackground,
          border: Border.all(color: AppTheme.terminalSelectedBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Focus(
            canRequestFocus: false,
            onKeyEvent: _findKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                shadcn.TextField(
                  key: const ValueKey('terminal-find-input'),
                  controller: _query,
                  focusNode: _findFocus,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  placeholder: Text('查找终端输出'.tr),
                  onEditingComplete: () {},
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    option('区分大小写', 'Aa', _caseSensitive, () {
                      setState(() => _caseSensitive = !_caseSensitive);
                      _scheduleSearch(reveal: true);
                    }),
                    option('正则表达式', '.*', _regex, () {
                      setState(() => _regex = !_regex);
                      _scheduleSearch(reveal: true);
                    }),
                    if (_query.text.isNotEmpty)
                      Text(
                        _findError?.tr ??
                            '${_matchIndex + 1}/${_matches.length}${_matches.length == terminalSearchLimit ? '+' : ''}',
                        key: const ValueKey('terminal-find-count'),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.terminalForeground,
                        ),
                      ),
                    button(
                      '上一个匹配',
                      AppIcons.chevronUp,
                      _matches.isEmpty ? null : () => _stepMatch(-1),
                    ),
                    button(
                      '下一个匹配',
                      AppIcons.chevronDown,
                      _matches.isEmpty ? null : () => _stepMatch(1),
                    ),
                    button('关闭查找', AppIcons.x, _hideFind),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<SettingsController>()) {
      return _pane(SidebarState.defaultTerminalFontSize);
    }
    final settings = Get.find<SettingsController>();
    return Obx(() => _pane(settings.terminalFontSize.value));
  }
}

class _MultilinePasteDialog extends StatefulWidget {
  const _MultilinePasteDialog({required this.text, required this.syncPanes});

  final String text;
  final List<String> syncPanes;

  @override
  State<_MultilinePasteDialog> createState() => _MultilinePasteDialogState();
}

class _MultilinePasteDialogState extends State<_MultilinePasteDialog> {
  static const _maxPreviewChars = 4000;
  bool _skipFuture = false;

  int get _lineCount {
    final normalized = widget.text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final parts = normalized.split('\n');
    if (parts.length > 1 && parts.last.isEmpty) return parts.length - 1;
    return parts.length;
  }

  bool get _hasTrailingNewline =>
      widget.text.endsWith('\n') || widget.text.endsWith('\r');

  String get _preview => widget.text.length > _maxPreviewChars
      ? '${widget.text.substring(0, _maxPreviewChars)}\n…'
      : widget.text;

  void _confirm(_MultilinePasteMode mode) {
    AppNavigation.closeDialog<_MultilinePasteDecision>(
      result: (mode: mode, skipFuture: _skipFuture),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final lines = _lineCount;
    final message = lines > 1
        ? '剪贴板包含 @lines 行文本，粘贴到终端可能立即执行多条命令。'.trParams({'lines': '$lines'})
        : '剪贴板内容末尾包含换行符，粘贴到终端可能立即执行命令。'.tr;
    return AppDialog(
      maxWidth: 520,
      scrollable: true,
      title: Text('确认粘贴多行内容'.tr),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            message,
            style: TextStyle(fontSize: 13, color: colors.mutedForeground),
          ),
          if (widget.syncPanes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '将粘贴到 @count 个窗格：@targets'.trParams({
                'count': '${widget.syncPanes.length}',
                'targets': widget.syncPanes.join(' · '),
              }),
            ),
          ],
          const SizedBox(height: 12),
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: AppTheme.surface(context),
              border: Border.all(color: AppTheme.border(context)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: shadcn.SelectableText(
                _preview,
                key: const ValueKey('terminal-paste-preview'),
                style: const TextStyle(
                  fontFamily: 'FiraCode Nerd Font Mono',
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ),
          if (widget.syncPanes.isEmpty) ...[
            const SizedBox(height: 12),
            shadcn.Checkbox(
              key: const ValueKey('terminal-paste-skip-session'),
              theme: const shadcn.CheckboxTheme(size: 14, gap: 8),
              state: _skipFuture
                  ? shadcn.CheckboxState.checked
                  : shadcn.CheckboxState.unchecked,
              onChanged: (state) => setState(
                () => _skipFuture = state == shadcn.CheckboxState.checked,
              ),
              trailing: Text(
                '本次会话不再提示'.tr,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
      actions: [
        shadcn.OutlineButton(
          key: const ValueKey('terminal-paste-cancel'),
          onPressed: () => AppNavigation.closeDialog<_MultilinePasteDecision>(),
          child: Text('取消'.tr),
        ),
        if (_hasTrailingNewline)
          shadcn.OutlineButton(
            key: const ValueKey('terminal-paste-trim-newline'),
            onPressed: () => _confirm(_MultilinePasteMode.trimTrailingNewline),
            child: Text('去除末尾换行粘贴'.tr),
          ),
        shadcn.PrimaryButton(
          key: const ValueKey('terminal-paste-confirm'),
          onPressed: () => _confirm(_MultilinePasteMode.raw),
          child: Text('直接粘贴'.tr),
        ),
      ],
    );
  }
}
