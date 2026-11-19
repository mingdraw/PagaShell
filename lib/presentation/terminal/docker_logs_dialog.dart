import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
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
  static const _limit = 96 * 1024;
  static final _controls = RegExp(
    r'\x1b\[[0-?]*[ -/]*[@-~]|[\x00-\x08\x0b-\x1f\x7f-\x9f]',
  );

  final _scroll = ScrollController();
  DockerLogSession? _logs;
  StreamSubscription<String>? _subscription;
  Timer? _update;
  String _pending = '';
  String _text = '';
  String? _error;
  bool _ended = false;
  bool _discarded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final logs = await widget.source.openDockerLogs(widget.container);
      if (!mounted) {
        await _close(logs);
        return;
      }
      setState(() => _logs = logs);
      _subscription = logs.output.listen(
        (chunk) {
          _pending = _tail(_pending + chunk.replaceAll(_controls, ''));
          _update ??= Timer(const Duration(milliseconds: 80), _flush);
        },
        onError: (Object error) => _finish(error),
        onDone: () => _finish(),
        cancelOnError: true,
      );
    } on Object catch (error) {
      _finish(error);
    }
  }

  String _tail(String value) {
    if (value.length <= _limit) return value;
    _discarded = true;
    var start = value.length - _limit;
    final unit = value.codeUnitAt(start);
    if (unit >= 0xdc00 && unit <= 0xdfff) start++;
    return value.substring(start);
  }

  void _flush() {
    _update?.cancel();
    _update = null;
    if (!mounted || _pending.isEmpty) return;
    final follow = !_scroll.hasClients || _scroll.position.extentAfter < 60;
    setState(() {
      _text = _tail(_text + _pending);
      _pending = '';
    });
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _finish([Object? error]) {
    if (!mounted || _ended) return;
    _flush();
    final logs = _logs;
    setState(() {
      _ended = true;
      _error = error == null
          ? null
          : error is SshEngineException
          ? error.message
          : '无法读取容器日志，请检查容器和权限';
    });
    if (logs != null) unawaited(_close(logs));
  }

  Future<void> _close(DockerLogSession logs) async {
    try {
      await logs.close();
    } on Object {
      // A disconnected host may already have closed the log channel.
    }
  }

  @override
  void dispose() {
    _update?.cancel();
    final logs = _logs;
    if (logs != null && !_ended) unawaited(_close(logs));
    unawaited(_subscription?.cancel());
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text('容器日志 · @name'.trParams({'name': widget.container.name})),
    maxWidth: 860,
    content: SizedBox(
      width: 800,
      height: math.min(450, MediaQuery.sizeOf(context).height * .54),
      child: ColoredBox(
        color: AppTheme.terminalBackground,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          child: shadcn.SelectableText(
            _text.isNotEmpty
                ? _text
                : (_logs == null && !_ended ? '正在打开容器日志…' : '暂无日志输出').tr,
            key: const ValueKey('docker-live-log-output'),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: AppTheme.terminalForeground,
            ),
          ),
        ),
      ),
    ),
    feedback: _error != null
        ? Text(AppTranslations.error(_error!))
        : _ended
        ? Text('日志流已结束'.tr)
        : _discarded
        ? Text('仅显示最近的日志内容'.tr)
        : null,
    actions: [
      shadcn.OutlineButton(
        onPressed: AppNavigation.closeDialog<void>,
        child: Text('关闭'.tr),
      ),
    ],
  );
}
