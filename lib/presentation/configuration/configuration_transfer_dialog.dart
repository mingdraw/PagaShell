import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/configuration/configuration_transfer.dart';
import '../../domain/entities/connection_configuration.dart';
import '../components/app_dialog.dart';
import '../components/app_text_form_field.dart';
import '../components/export_file.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';

bool _importInProgress = false;

Future<void> showConfigurationImportDialog({
  Future<XFile?> Function()? pickFile,
}) async {
  if (_importInProgress) return;
  _importInProgress = true;
  try {
    final file =
        await (pickFile?.call() ??
            openFile(
              acceptedTypeGroups: const [
                XTypeGroup(label: 'PagaShell', extensions: ['pagashell']),
              ],
            ));
    if (file == null) return;
    if (await file.length() > ConfigurationTransfer.maxFileBytes) {
      AppNotice.error('配置文件不能超过 32 MiB'.tr);
      return;
    }
    final bytes = await file.readAsBytes();
    final transfer = Get.find<ConfigurationTransfer>();
    if (transfer.isEncrypted(bytes)) {
      await AppNavigation.dialog<void>(
        ConfigurationTransferDialog(
          importFileName: file.name,
          importBytes: bytes,
        ),
      );
    } else {
      await transfer.importFile(bytes);
      AppNotice.success('配置已导入'.tr);
    }
  } on ConfigurationException catch (e) {
    AppNotice.error(e.message.tr);
  } on Object {
    AppNotice.error('配置操作失败，请检查钥匙串或文件权限后重试'.tr);
  } finally {
    _importInProgress = false;
  }
}

Future<void> showConfigurationExportDialog() =>
    AppNavigation.dialog<void>(const ConfigurationTransferDialog());

class ConfigurationTransferDialog extends StatefulWidget {
  const ConfigurationTransferDialog({
    this.importFileName,
    this.importBytes,
    this.saveFile = saveExportFile,
    super.key,
  }) : assert((importFileName == null) == (importBytes == null));
  final String? importFileName;
  final Uint8List? importBytes;
  final Future<bool> Function(Uint8List, String) saveFile;

  @override
  State<ConfigurationTransferDialog> createState() =>
      _ConfigurationTransferDialogState();
}

class _ConfigurationTransferDialogState
    extends State<ConfigurationTransferDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _encrypt = false;
  String? _error;
  bool get _importing => widget.importBytes != null;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final transfer = Get.find<ConfigurationTransfer>();
      if (_importing) {
        await transfer.importFile(widget.importBytes!, _password.text);
        if (!mounted) return;
        AppNavigation.closeDialog<void>();
        AppNotice.success('配置已导入'.tr);
      } else {
        final bytes = await transfer.exportFile(
          _encrypt ? _password.text : null,
        );
        if (!mounted) return;
        final date = DateTime.now().toIso8601String().substring(0, 10);
        if (await widget.saveFile(bytes, 'PagaShell-$date.pagashell') &&
            mounted) {
          AppNavigation.closeDialog<void>();
          AppNotice.success('配置已导出'.tr);
        }
      }
    } on ConfigurationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) setState(() => _error = '配置操作失败，请检查钥匙串或文件权限后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AppDialog(
      maxWidth: AppTheme.configurationDialogMaxWidth,
      scrollable: true,
      title: Text((_importing ? '导入配置' : '导出配置').tr),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              (_importing ? '此配置文件已加密，请输入导出时设置的密码。' : '导出服务、凭证、网关及文件夹，包含密码和私钥。')
                  .tr,
            ),
            const SizedBox(height: 16),
            if (_importing) ...[
              Text(
                widget.importFileName!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
            ],
            if (!_importing) ...[
              shadcn.Checkbox(
                key: const ValueKey('config-encryption'),
                state: _encrypt
                    ? shadcn.CheckboxState.checked
                    : shadcn.CheckboxState.unchecked,
                onChanged: _busy
                    ? null
                    : (state) => setState(() {
                        _encrypt = state == shadcn.CheckboxState.checked;
                        _error = null;
                        if (!_encrypt) {
                          _password.clear();
                          _confirm.clear();
                        }
                      }),
                trailing: Text('加密'.tr),
              ),
              const SizedBox(height: 12),
              Text(
                (_encrypt ? '导出文件将使用密码加密，导入时需要此密码。' : '未加密的文件包含明文密码和私钥。').tr,
              ),
            ],
            if (_importing || _encrypt) ...[
              if (!_importing) const SizedBox(height: 12),
              AppTextFormField(
                key: const ValueKey('config-password'),
                controller: _password,
                obscureText: true,
                autofocus: true,
                enabled: !_busy,
                enableSuggestions: false,
                autocorrect: false,
                decoration: AppInputDecoration(
                  labelText: (_importing ? '配置文件密码' : '导出密码').tr,
                ),
                validator: (value) => (value ?? '').isEmpty
                    ? '必填'.tr
                    : !_importing && value!.length < 8
                    ? '导出密码至少需要 8 个字符'.tr
                    : null,
              ),
            ],
            if (!_importing && _encrypt) ...[
              const SizedBox(height: 12),
              AppTextFormField(
                key: const ValueKey('config-confirm-password'),
                controller: _confirm,
                obscureText: true,
                enabled: !_busy,
                enableSuggestions: false,
                autocorrect: false,
                decoration: AppInputDecoration(labelText: '确认密码'.tr),
                validator: (value) =>
                    value != _password.text ? '两次输入的密码不一致'.tr : null,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!.tr,
                style: TextStyle(
                  color: shadcn.Theme.of(context).colorScheme.destructive,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: _busy ? null : AppNavigation.closeDialog<void>,
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(
          key: const ValueKey('configuration-submit'),
          onPressed: _busy ? null : _submit,
          child: Text(
            (_busy
                    ? '处理中…'
                    : !_importing
                    ? '导出配置'
                    : '导入配置')
                .tr,
          ),
        ),
      ],
    ),
  );
}
