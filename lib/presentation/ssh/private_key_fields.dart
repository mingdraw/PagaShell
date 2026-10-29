import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import '../components/export_file.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';

/// 新私钥仅保留在表单控制器中；导入时不复制文件、不显示内容。
class PrivateKeyFields extends StatefulWidget {
  const PrivateKeyFields({
    required this.privateKey,
    required this.passphrase,
    this.preserveExisting = false,
    this.enabled = true,
    this.pickFile,
    this.loadPrivateKey,
    this.exportName = 'id_pagashell',
    this.saveFile = saveExportFile,
    super.key,
  });

  final TextEditingController privateKey;
  final TextEditingController passphrase;
  final bool preserveExisting;
  final bool enabled;
  final Future<XFile?> Function()? pickFile;
  final Future<String?> Function()? loadPrivateKey;
  final String exportName;
  final Future<bool> Function(Uint8List, String) saveFile;

  @override
  State<PrivateKeyFields> createState() => _PrivateKeyFieldsState();
}

class _PrivateKeyFieldsState extends State<PrivateKeyFields> {
  static const _maxBytes = 1024 * 1024;
  bool _importing = false;
  bool _exporting = false;
  bool _obscurePassphrase = true;
  String? _filename;
  String? _error;

  Future<void> _import() async {
    if (_importing) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final file = await (widget.pickFile?.call() ?? openFile());
      if (file == null) return;
      if (await file.length() > _maxBytes) {
        if (mounted) setState(() => _error = '私钥文件不能超过 1 MiB');
        return;
      }
      final contents = await file.readAsString();
      if (!mounted) return;
      if (utf8.encode(contents).length > _maxBytes) {
        setState(() => _error = '私钥文件不能超过 1 MiB');
        return;
      }
      widget.privateKey.text = contents;
      setState(() => _filename = file.name);
    } on Object {
      if (mounted) setState(() => _error = '无法读取私钥，请选择 OpenSSH、PEM 或 PPK 文本文件');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _export() async {
    if (_exporting || _importing) return;
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final key = widget.privateKey.text.trim().isNotEmpty
          ? widget.privateKey.text
          : await widget.loadPrivateKey?.call();
      if (!mounted) return;
      if (key == null || key.trim().isEmpty) {
        setState(() => _error = '没有可导出的私钥，请先导入或保存私钥');
        return;
      }
      final bytes = Uint8List.fromList(utf8.encode(key));
      if (bytes.length > _maxBytes) {
        setState(() => _error = '私钥内容不能超过 1 MiB');
        return;
      }
      final name = widget.exportName.replaceAll(
        RegExp(r'[^\p{L}\p{N}_.-]', unicode: true),
        '_',
      );
      final extension = key.startsWith('PuTTY-User-Key-File-') ? 'ppk' : 'key';
      final saved = await widget.saveFile(
        bytes,
        '${name.isEmpty ? 'id_pagashell' : name}.$extension',
      );
      if (saved && mounted) AppNotice.success('私钥文件已导出'.tr);
    } on Object {
      if (mounted) setState(() => _error = '私钥导出失败，请检查钥匙串和文件写入权限');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_importing && !_exporting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListenableBuilder(
          listenable: widget.privateKey,
          builder: (context, _) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              shadcn.OutlineButton(
                onPressed: enabled ? _import : null,
                leading: const Icon(shadcn.LucideIcons.fileKey, size: 16),
                child: Text(_importing ? '读取中…'.tr : '导入私钥文件'.tr),
              ),
              shadcn.OutlineButton(
                key: const ValueKey('export-private-key'),
                onPressed:
                    enabled &&
                        (widget.loadPrivateKey != null ||
                            widget.privateKey.text.trim().isNotEmpty)
                    ? _export
                    : null,
                leading: const Icon(shadcn.LucideIcons.download, size: 16),
                child: Text(_exporting ? '导出中…'.tr : '导出私钥文件'.tr),
              ),
            ],
          ),
        ),
        if (_filename != null)
          Text(
            '已导入：@filename'.trParams({'filename': _filename!}),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 8),
        AppTextFormField(
          controller: widget.privateKey,
          enabled: enabled,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: AppInputDecoration(
            labelText: '私钥内容'.tr,
            hintText: widget.preserveExisting
                ? '已保存；留空保持原私钥与口令'.tr
                : '导入文件或粘贴私钥'.tr,
            helperText: 'OpenSSH / PEM / PPK，最多 1 MiB'.tr,
          ),
          validator: (value) {
            if ((value == null || value.trim().isEmpty) &&
                !widget.preserveExisting) {
              return '请导入或粘贴私钥'.tr;
            }
            if (utf8.encode(value ?? '').length > _maxBytes) {
              return '私钥内容不能超过 1 MiB'.tr;
            }
            return null;
          },
        ),
        const SizedBox(height: 12),
        AppTextFormField(
          controller: widget.passphrase,
          enabled: enabled,
          obscureText: _obscurePassphrase,
          enableSuggestions: false,
          autocorrect: false,
          decoration: AppInputDecoration(
            labelText: '私钥口令（可选）'.tr,
            hintText: '导入加密私钥时填写，未加密则留空'.tr,
            suffixIcon: AppIconButton(
              density: shadcn.ButtonDensity.compact,
              onPressed: enabled
                  ? () =>
                        setState(() => _obscurePassphrase = !_obscurePassphrase)
                  : null,
              icon: Icon(
                _obscurePassphrase
                    ? shadcn.LucideIcons.eyeOff
                    : shadcn.LucideIcons.eye,
                size: AppTheme.inputIconSize,
              ),
            ),
          ),
          validator: (value) =>
              widget.preserveExisting &&
                  widget.privateKey.text.trim().isEmpty &&
                  (value?.isNotEmpty ?? false)
              ? '更换口令时请重新导入私钥'.tr
              : null,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!.tr,
            style: TextStyle(
              color: shadcn.Theme.of(context).colorScheme.destructive,
            ),
          ),
        ],
      ],
    );
  }
}
