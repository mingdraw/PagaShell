import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/entities/small_text_file.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';

class SmallTextFileDialog extends StatefulWidget {
  const SmallTextFileDialog({
    required this.name,
    required this.path,
    required this.read,
    required this.save,
    super.key,
  });

  final String name;
  final String path;
  final Future<SmallTextFile> Function() read;
  final Future<void> Function(SmallTextFile original, String text) save;

  @override
  State<SmallTextFileDialog> createState() => _SmallTextFileDialogState();
}

class _SmallTextFileDialogState extends State<SmallTextFileDialog> {
  final _text = TextEditingController();
  SmallTextFile? _original;
  String _initialText = '';
  bool _hasBom = false;
  bool _crlf = false;
  bool _saving = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String _message(Object error, String fallback) => switch (error) {
    SmallTextFileException(:final message) => message.tr,
    SshEngineException(:final message) => AppTranslations.error(message),
    _ => fallback.tr,
  };

  Future<void> _load() async {
    try {
      final snapshot = await widget.read();
      if (!mounted) return;
      _hasBom = snapshot.text.startsWith('\uFEFF');
      var display = _hasBom ? snapshot.text.substring(1) : snapshot.text;
      _crlf =
          display.contains('\r\n') &&
          !display.replaceAll('\r\n', '').contains('\n');
      if (_crlf) display = display.replaceAll('\r\n', '\n');
      setState(() {
        _original = snapshot;
        _initialText = display;
        _text.text = display;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _message(error, '无法读取文本，请重试');
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final original = _original;
    if (_saving || original == null || _text.text == _initialText) return;
    final body = _crlf ? _text.text.replaceAll('\n', '\r\n') : _text.text;
    final text = _hasBom ? '\uFEFF$body' : body;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      validateSmallText(text);
      await widget.save(original, text);
      if (mounted) AppNavigation.closeDialog(result: true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error, '无法保存文本，请重试'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editable = _original?.modified != null;
    final colors = shadcn.Theme.of(context).colorScheme;
    return PopScope<bool>(
      canPop: !_saving,
      child: AppDialog(
        maxWidth: 720,
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 660,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.mutedForeground),
              ),
              if (_loading)
                const Center(child: shadcn.CircularProgressIndicator())
              else if (_original != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: math.min(
                    380,
                    MediaQuery.sizeOf(context).height * 0.46,
                  ),
                  child: shadcn.TextField(
                    key: const ValueKey('sftp-text-editor'),
                    controller: _text,
                    readOnly: _saving || !editable,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    smartDashesType: SmartDashesType.disabled,
                    smartQuotesType: SmartQuotesType.disabled,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ],
          ),
        ),
        feedback: _error != null
            ? Text(_error!, style: TextStyle(color: colors.destructive))
            : _original != null && !editable
            ? Text('无法确认文件修改时间，不能保存'.tr)
            : null,
        actions: [
          shadcn.OutlineButton(
            onPressed: _saving ? null : () => AppNavigation.closeDialog<bool>(),
            child: Text('关闭'.tr),
          ),
          if (_original != null && editable)
            shadcn.PrimaryButton(
              key: const ValueKey('sftp-text-save'),
              onPressed: _saving || _text.text == _initialText ? null : _save,
              child: Text((_saving ? '保存中…' : '保存').tr),
            ),
        ],
      ),
    );
  }
}
