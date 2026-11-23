import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show ScrollDirection, ViewportOffset;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_selectable_region.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';

class DockerLogsDialog extends StatefulWidget {
  const DockerLogsDialog({
    required this.container,
    required this.source,
    super.key,
  });

  final DockerResource container;
  final DockerLogsSource source;

  @override
  State<DockerLogsDialog> createState() => _DockerLogsDialogState();
}

class _DockerLogsDialogState extends State<DockerLogsDialog> {
  final _scroll = ScrollController();
  final _filter = TextEditingController();
  _LogBuffer _buffer = _LogBuffer();
  _LogAnsiFilter _ansi = _LogAnsiFilter();
  DockerLogSession? _logs;
  StreamSubscription<String>? _subscription;
  Timer? _update;
  int _generation = 0;
  bool _opening = false;
  bool _following = true;
  bool _ended = false;
  String? _error;
  final _snapshot = ListQueue<_LogLine>();
  final _matches = ListQueue<_LogLine>();
  int? _publishedPartialId;
  String _query = '';

  ListQueue<_LogLine> get _visible => _query.isEmpty ? _snapshot : _matches;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    if (_opening) return;
    final generation = ++_generation;
    setState(() {
      _opening = true;
      _ended = false;
      _error = null;
    });
    try {
      await _stopStream();
      if (!mounted || generation != _generation) return;
      final logs = await widget.source.openDockerLogs(widget.container);
      if (!mounted || generation != _generation) {
        await _ignoreCloseError(logs.close);
        return;
      }
      setState(() {
        _logs = logs;
        _opening = false;
        _following = true;
        _buffer = _LogBuffer();
        _ansi = _LogAnsiFilter();
        _snapshot.clear();
        _matches.clear();
        _publishedPartialId = null;
      });
      _subscription = logs.output.listen(
        (chunk) {
          if (generation != _generation || !mounted) return;
          final text = _ansi.sanitize(chunk);
          if (text.isEmpty) return;
          _buffer.add(text);
          if (_following) {
            _update ??= Timer(const Duration(milliseconds: 100), _flush);
          }
        },
        onError: (Object error) => _finish(generation, error),
        onDone: () => _finish(generation),
        cancelOnError: true,
      );
    } on Object catch (error) {
      _finish(generation, error);
    }
  }

  void _applyFilter() {
    final query = _filter.text.trim().toLowerCase();
    if (_query == query) return;
    _query = query;
    _matches.clear();
    if (query.isNotEmpty) {
      _matches.addAll(
        _snapshot.where((line) => line.text.toLowerCase().contains(query)),
      );
    }
  }

  void _publish() {
    final firstId = _buffer.firstId;
    // The last, unfinished line can be extended or replaced by a complete row.
    for (final rows in [_snapshot, _matches]) {
      if (rows.isNotEmpty && rows.last.id == _publishedPartialId) {
        rows.removeLast();
      }
      while (rows.isNotEmpty && rows.first.id < firstId) {
        rows.removeFirst();
      }
    }
    final startId = _snapshot.isEmpty ? firstId : _snapshot.last.id + 1;
    for (final line in _buffer.completeLinesFrom(startId)) {
      _appendPublished(line);
    }
    final partial = _buffer.partial;
    _publishedPartialId = partial?.id;
    if (partial != null) _appendPublished(partial);
  }

  void _appendPublished(_LogLine line) {
    _snapshot.addLast(line);
    if (_query.isNotEmpty && line.text.toLowerCase().contains(_query)) {
      _matches.addLast(line);
    }
  }

  void _flush() {
    _update?.cancel();
    _update = null;
    if (!mounted || !_following) return;
    setState(_publish);
    _scrollAfterLayout();
  }

  void _scrollAfterLayout({bool toEnd = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (toEnd && !_following) || !_scroll.hasClients) return;
      final position = _scroll.position;
      if (position.hasContentDimensions) {
        _scroll.jumpTo(
          toEnd ? position.maxScrollExtent : position.minScrollExtent,
        );
      }
    });
  }

  void _pauseFollow() {
    if (_following) setState(() => _following = false);
  }

  void _followTail() {
    setState(() {
      _following = true;
      _publish();
    });
    _scrollAfterLayout();
  }

  Future<void> _copyLogs() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: _visible.map((line) => line.text).join('\n')),
      );
      if (mounted) AppNotice.success('已复制');
    } on Object {
      if (mounted) AppNotice.error('无法复制日志');
    }
  }

  void _finish(int generation, [Object? error]) {
    if (!mounted || generation != _generation || _ended) return;
    _flush();
    setState(() {
      _opening = false;
      _ended = true;
      _error = error == null
          ? null
          : error is SshEngineException
          ? error.message
          : '无法读取容器日志，请检查容器和权限';
    });
    unawaited(_stopStream());
  }

  Future<void> _stopStream() async {
    final logs = _logs;
    final cancellation = _subscription?.cancel();
    _logs = null;
    _subscription = null;
    // Cancel both together: a native read can wait for the log channel to close.
    await Future.wait<void>([
      if (logs != null) _ignoreCloseError(logs.close),
      if (cancellation != null) _ignoreCloseError(() => cancellation),
    ]);
  }

  Future<void> _ignoreCloseError(Future<void> Function() close) async {
    try {
      await close();
    } on Object {
      // The remote host may already have disconnected.
    }
  }

  @override
  void dispose() {
    _generation++;
    _update?.cancel();
    unawaited(_stopStream());
    _scroll.dispose();
    _filter.dispose();
    super.dispose();
  }

  Widget _output() => ColoredBox(
    key: const ValueKey('docker-live-log-output'),
    color: AppTheme.terminalBackground,
    child: _visible.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                (_opening
                        ? '正在打开容器日志…'
                        : _filter.text.trim().isNotEmpty
                        ? '没有匹配的日志'
                        : '暂无日志输出')
                    .tr,
                style: const TextStyle(color: AppTheme.terminalMutedForeground),
              ),
            ),
          )
        : NotificationListener<UserScrollNotification>(
            onNotification: (event) {
              if (event.depth == 0 &&
                  event.direction == ScrollDirection.forward) {
                _pauseFollow();
              }
              return false;
            },
            child: Listener(
              onPointerDown: (_) => _pauseFollow(),
              child: AppSelectableRegion(
                child: _LogList(
                  controller: _scroll,
                  itemCount: _visible.length,
                  itemBuilder: (context, index) {
                    final line = _visible.elementAt(index);
                    return Text(
                      line.text.isEmpty ? ' ' : line.text,
                      key: ValueKey(line.id),
                      style: const TextStyle(
                        fontFamily: 'FiraCode Nerd Font Mono',
                        fontFamilyFallback: [
                          'Menlo',
                          'PingFang SC',
                          'Microsoft YaHei',
                          'monospace',
                        ],
                        fontSize: 12,
                        color: AppTheme.terminalForeground,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
  );

  @override
  Widget build(BuildContext context) {
    final followLabel = (_following ? '暂停跟随' : '继续跟随').tr;
    final error = _error;
    return AppDialog(
      title: Text('容器日志 · @name'.trParams({'name': widget.container.name})),
      maxWidth: 860,
      content: SizedBox(
        width: 800,
        height: math.min(450, MediaQuery.sizeOf(context).height * .54),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: shadcn.TextField(
                    key: const ValueKey('docker-log-filter'),
                    controller: _filter,
                    placeholder: Text('筛选日志'.tr),
                    onChanged: (_) {
                      setState(_applyFilter);
                      _scrollAfterLayout(toEnd: _following);
                    },
                  ),
                ),
                const SizedBox(width: 4),
                AppIconButton(
                  key: const ValueKey('docker-log-follow'),
                  semanticLabel: followLabel,
                  tooltip: followLabel,
                  onPressed: _following ? _pauseFollow : _followTail,
                  icon: AppIcon(
                    _following ? AppIcons.pause : AppIcons.play,
                    size: 15,
                  ),
                ),
                AppIconButton(
                  semanticLabel: '复制日志'.tr,
                  tooltip: '复制日志'.tr,
                  onPressed: _visible.isEmpty
                      ? null
                      : () => unawaited(_copyLogs()),
                  icon: const AppIcon(AppIcons.copy, size: 15),
                ),
                AppIconButton(
                  semanticLabel: '回到底部'.tr,
                  tooltip: '回到底部'.tr,
                  onPressed: _followTail,
                  icon: const AppIcon(AppIcons.arrowDown, size: 15),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: _output()),
          ],
        ),
      ),
      feedback: error != null
          ? Text(
              AppTranslations.error(error),
              style: const TextStyle(color: StatusColors.failed),
            )
          : _ended
          ? Text('日志流已结束'.tr)
          : _buffer.discarded
          ? Text('仅显示最近的日志内容'.tr)
          : null,
      actions: [
        if (_ended)
          shadcn.OutlineButton(
            key: const ValueKey('docker-log-retry'),
            onPressed: () => unawaited(_open()),
            child: Text('重新连接'.tr),
          ),
        shadcn.OutlineButton(
          onPressed: AppNavigation.closeDialog<void>,
          child: Text('关闭'.tr),
        ),
      ],
    );
  }
}

class _LogList extends ListView {
  _LogList({
    required super.controller,
    required int itemCount,
    required Widget Function(BuildContext, int) itemBuilder,
  }) : super.builder(
         padding: const EdgeInsets.all(12),
         itemCount: itemCount,
         itemBuilder: itemBuilder,
       );

  @override
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection direction,
    List<Widget> slivers,
  ) =>
      // The scrollable owns selection autoscroll. Join the actual lines inside it.
      AppBlockSelection(
        child: super.buildViewport(context, offset, direction, slivers),
      );
}

typedef _LogLine = ({int id, String text});

/// Keep a bounded tail and evict complete rows. While paused, the view keeps its
/// last snapshot so output does not move selected text or the scroll position.
class _LogBuffer {
  static const _maxUnits = 96 * 1024;
  static const _maxRows = 4096;
  static const _maxLine = 16 * 1024;
  final _lines = ListQueue<_LogLine>();
  String _partial = '';
  bool _partialTruncated = false;
  int _units = 0;
  int _nextId = 0;
  bool discarded = false;

  void add(String chunk) {
    var from = 0;
    for (
      var end = chunk.indexOf('\n');
      end != -1;
      end = chunk.indexOf('\n', from)
    ) {
      _append(chunk.substring(from, end));
      final text = _partialTruncated ? '…$_partial' : _partial;
      _lines.addLast((id: _nextId++, text: text));
      _units += text.length + 1;
      _partial = '';
      _partialTruncated = false;
      _trim();
      from = end + 1;
    }
    _append(chunk.substring(from));
    _trim();
  }

  void _append(String text) {
    if (text.isEmpty) return;
    final value = _partial + text;
    if (value.length <= _maxLine) {
      _partial = value;
      return;
    }
    _partialTruncated = true;
    discarded = true;
    var start = value.length - _maxLine;
    final unit = value.codeUnitAt(start);
    if (unit >= 0xdc00 && unit <= 0xdfff) start++;
    _partial = value.substring(start);
  }

  void _trim() {
    while (_units + _partial.length > _maxUnits || _lines.length >= _maxRows) {
      _units -= _lines.removeFirst().text.length + 1;
      discarded = true;
    }
  }

  int get firstId => _nextId - _lines.length;

  Iterable<_LogLine> completeLinesFrom(int id) sync* {
    for (var i = id - firstId; i < _lines.length; i++) {
      yield _lines.elementAt(i);
    }
  }

  _LogLine? get partial => _partial.isEmpty
      ? null
      : (id: _nextId, text: _partialTruncated ? '…$_partial' : _partial);
}

enum _EscapeState { text, escape, csi, controlString, stringEscape }

/// A control sequence can span multiple chunks, including OSC hyperlinks.
class _LogAnsiFilter {
  _EscapeState _state = _EscapeState.text;

  String sanitize(String chunk) {
    final result = StringBuffer();
    for (var i = 0; i < chunk.length; i++) {
      final unit = chunk.codeUnitAt(i);
      switch (_state) {
        case _EscapeState.text:
          if ((unit >= 32 && unit < 0x7f) ||
              unit > 0x9f ||
              unit == 9 ||
              unit == 10) {
            result.writeCharCode(unit);
          } else if (unit == 0x1b) {
            _state = _EscapeState.escape;
          } else if (unit == 0x9b) {
            _state = _EscapeState.csi;
          } else if (const {0x90, 0x98, 0x9d, 0x9e, 0x9f}.contains(unit)) {
            _state = _EscapeState.controlString;
          }
        case _EscapeState.escape:
          if (unit == 0x5b) {
            _state = _EscapeState.csi;
          } else if (const {0x50, 0x58, 0x5d, 0x5e, 0x5f}.contains(unit)) {
            _state = _EscapeState.controlString;
          } else if (unit >= 0x30) {
            _state = _EscapeState.text;
          }
        case _EscapeState.csi:
          if (unit == 0x1b) {
            _state = _EscapeState.escape;
          } else if (unit >= 0x40 && unit <= 0x7e) {
            _state = _EscapeState.text;
          }
        case _EscapeState.controlString:
          if (unit == 7 || unit == 0x9c) {
            _state = _EscapeState.text;
          } else if (unit == 0x1b) {
            _state = _EscapeState.stringEscape;
          }
        case _EscapeState.stringEscape:
          if (unit == 0x5c || unit == 7 || unit == 0x9c) {
            _state = _EscapeState.text;
          } else if (unit != 0x1b) {
            _state = _EscapeState.controlString;
          }
      }
    }
    return result.toString();
  }
}
