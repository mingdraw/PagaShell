import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/identities/identity_controller.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vault/secret_store.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../components/app_select_field.dart';
import '../components/app_text_form_field.dart';
import '../components/copy_name.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../ssh/private_key_fields.dart';
import '../theme/app_theme.dart';

/// 新建 / 编辑凭证对话框。
///
/// [identity] 非空表示编辑：预填元数据，敏感字段留空则保持不变。
/// [copyFrom] 非空表示复制：预填全部内容，保存时创建独立的新凭证。
Future<void> showIdentityEditDialog(
  BuildContext context, {
  Identity? identity,
  Identity? copyFrom,
  String? initialFolderId,
}) {
  return AppNavigation.dialog<void>(
    _IdentityEditDialog(
      identity: identity,
      copyFrom: copyFrom,
      initialFolderId: initialFolderId,
    ),
  );
}

/// 确认删除凭证及其密文。
Future<void> confirmDeleteIdentity(
  BuildContext context,
  Identity identity,
) async {
  final ok = await AppNavigation.dialog<bool>(
    AppDialog(
      title: Text('删除凭证「@name」？'.trParams({'name': identity.name})),
      content: Text('将删除此凭证及其保存的密码或私钥。'.tr),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog(result: false),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(
          onPressed: () => AppNavigation.closeDialog(result: true),
          child: Text('删除'.tr),
        ),
      ],
    ),
  );
  if (ok ?? false) {
    try {
      await Get.find<IdentityController>().remove(identity.id);
    } on StateError catch (e) {
      if (context.mounted) {
        AppNotice.error(e.message.toString().tr);
      }
    } on SecretStoreException catch (e) {
      if (context.mounted) {
        AppNotice.error(e.message.tr);
      }
    }
  }
}

class _IdentityEditDialog extends StatefulWidget {
  const _IdentityEditDialog({
    this.identity,
    this.copyFrom,
    this.initialFolderId,
  }) : assert(identity == null || copyFrom == null);

  final Identity? identity;
  final Identity? copyFrom;
  final String? initialFolderId;

  @override
  State<_IdentityEditDialog> createState() => _IdentityEditDialogState();
}

class _IdentityEditDialogState extends State<_IdentityEditDialog> {
  final _formKey = GlobalKey<FormState>();
  Identity? get _source => widget.identity ?? widget.copyFrom;
  String? get _folderId => _source?.folderId ?? widget.initialFolderId;
  late final _name = TextEditingController(
    text: widget.copyFrom == null
        ? _source?.name ?? ''
        : copyName(
            widget.copyFrom!.name,
            isTaken: (name) => Get.find<IdentityController>().isNameTaken(
              name,
              folderId: _folderId,
            ),
          ),
  );
  late final _username = TextEditingController(
    text: _source?.username ?? 'root',
  );
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  late AuthType _authType = _source?.authType ?? AuthType.password;
  late ServiceType _serviceType = _source?.serviceType ?? ServiceType.ssh;
  bool _obscure = true;
  bool _saving = false;
  bool _loadingCopy = false;
  bool _copyReady = true;
  String? _error;

  bool get _isEdit => widget.identity != null;
  bool get _supported =>
      _authType == AuthType.password || _authType == AuthType.privateKey;

  @override
  void initState() {
    super.initState();
    if (widget.copyFrom != null) _loadCopyCredentials();
  }

  Future<void> _loadCopyCredentials() async {
    setState(() {
      _loadingCopy = true;
      _copyReady = false;
      _error = null;
    });
    try {
      final credentials = await Get.find<IdentityController>().credentialsOf(
        widget.copyFrom!,
      );
      if (!mounted) return;
      setState(() {
        _password.text = credentials?.password ?? '';
        _privateKey.text = credentials?.privateKey ?? '';
        _passphrase.text = credentials?.passphrase ?? '';
        _copyReady = true;
        if (credentials == null) _error = '凭证密文不存在，请重新输入';
      });
    } on SecretStoreException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on SshEngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) {
        setState(() => _error = '无法读取系统钥匙串，请解锁后重试');
      }
    } finally {
      if (mounted) setState(() => _loadingCopy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving ||
        !_copyReady ||
        !_supported ||
        !_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final controller = Get.find<IdentityController>();
    final username = _serviceType == ServiceType.vnc
        ? ''
        : _username.text.trim();
    final name = _name.text.trim();
    final displayName = name.isEmpty ? username : name;

    try {
      if (_isEdit) {
        await controller.updateIdentity(
          id: widget.identity!.id,
          name: displayName,
          username: username,
          password: _password.text.isEmpty ? null : _password.text,
          authType: _authType,
          privateKey: _privateKey.text.trim().isEmpty ? null : _privateKey.text,
          passphrase: _passphrase.text,
        );
      } else if (_authType == AuthType.password) {
        await controller.saveWithPassword(
          name: displayName,
          username: username,
          password: _password.text,
          folderId: _folderId,
          serviceType: _serviceType,
        );
      } else {
        await controller.saveWithPrivateKey(
          name: displayName,
          username: username,
          privateKey: _privateKey.text,
          passphrase: _passphrase.text,
          folderId: _folderId,
        );
      }
      if (mounted) AppNavigation.closeDialog<void>();
    } on SecretStoreException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on SshEngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? '必填'.tr : null;

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_saving,
      child: AppDialog(
        scrollable: true,
        title: Text(_isEdit ? '编辑凭证'.tr : '新建凭证'.tr),
        content: SizedBox(
          width: 420,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextFormField(
                  controller: _name,
                  enabled: !_saving,
                  autofocus: true,
                  validator: (value) {
                    final name = (value ?? '').trim();
                    if (_serviceType == ServiceType.vnc && name.isEmpty) {
                      return '必填'.tr;
                    }
                    return Get.find<IdentityController>().isNameTaken(
                          name.isEmpty ? _username.text.trim() : name,
                          folderId: _folderId,
                          excludeId: widget.identity?.id,
                        )
                        ? '同级下已存在同名凭证'.tr
                        : null;
                  },
                  decoration: AppInputDecoration(
                    labelText: '名称'.tr,
                    hintText: _serviceType == ServiceType.vnc
                        ? null
                        : '留空则使用用户名'.tr,
                  ),
                ),
                const SizedBox(height: 12),
                AppSelectField<ServiceType>(
                  key: const ValueKey('identity-service-type'),
                  initialValue: _serviceType,
                  label: '凭证类型'.tr,
                  items: [
                    for (final type in ServiceType.values)
                      AppSelectOption(value: type, child: Text(type.label)),
                  ],
                  onChanged: _saving || _loadingCopy || _isEdit
                      ? null
                      : (type) {
                          if (type == null) return;
                          setState(() {
                            _serviceType = type;
                            if (type != ServiceType.ssh) {
                              _authType = AuthType.password;
                            }
                          });
                        },
                ),
                const SizedBox(height: 12),
                if (_serviceType != ServiceType.vnc) ...[
                  AppTextFormField(
                    controller: _username,
                    enabled: !_saving,
                    decoration: AppInputDecoration(labelText: '用户名'.tr),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                ],
                AppSelectField<AuthType>(
                  key: ValueKey('identity-auth-$_serviceType'),
                  initialValue: _authType,
                  label: '认证方式'.tr,
                  items: [
                    AppSelectOption(
                      value: AuthType.password,
                      child: Text('密码'.tr),
                    ),
                    if (_serviceType == ServiceType.ssh)
                      AppSelectOption(
                        value: AuthType.privateKey,
                        child: Text('私钥'.tr),
                      ),
                    if (!_supported)
                      AppSelectOption(
                        value: _authType,
                        child: Text('暂不支持此认证方式'.tr),
                      ),
                  ],
                  onChanged: _saving || _loadingCopy || _isEdit
                      ? null
                      : (type) {
                          if (type != null) setState(() => _authType = type);
                        },
                ),
                const SizedBox(height: 12),
                if (_authType == AuthType.privateKey)
                  PrivateKeyFields(
                    privateKey: _privateKey,
                    passphrase: _passphrase,
                    preserveExisting: _isEdit,
                    enabled: !_saving && !_loadingCopy,
                    exportName: _name.text,
                    loadPrivateKey: !_isEdit
                        ? null
                        : () async =>
                              (await Get.find<IdentityController>()
                                      .credentialsOf(widget.identity!))
                                  ?.privateKey,
                  )
                else if (_authType == AuthType.password)
                  AppTextFormField(
                    controller: _password,
                    enabled: !_saving && !_loadingCopy,
                    obscureText: _obscure,
                    validator: _isEdit ? null : _required,
                    decoration: AppInputDecoration(
                      labelText: '密码'.tr,
                      hintText: _isEdit ? '留空则保持不变'.tr : null,
                      suffixIcon: AppIconButton(
                        density: shadcn.ButtonDensity.compact,
                        icon: Icon(
                          _obscure
                              ? shadcn.LucideIcons.eyeOff
                              : shadcn.LucideIcons.eye,
                          size: AppTheme.inputIconSize,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  !_supported
                      ? '请新建密码或私钥凭证后重新绑定服务'.tr
                      : _authType == AuthType.privateKey
                      ? '私钥和口令一起加密保存在本机，可供多个服务复用'.tr
                      : '密码加密保存在本机，可供多个服务复用'.tr,
                  style: TextStyle(
                    fontSize: 12,
                    color: shadcn.Theme.of(context).colorScheme.mutedForeground,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!.tr,
                    style: TextStyle(
                      color: shadcn.Theme.of(context).colorScheme.destructive,
                    ),
                  ),
                ],
                if (!_copyReady && !_loadingCopy)
                  shadcn.OutlineButton(
                    onPressed: _loadCopyCredentials,
                    child: Text('重试'.tr),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          shadcn.OutlineButton(
            onPressed: _saving ? null : () => AppNavigation.closeDialog<void>(),
            child: Text('取消'.tr),
          ),
          shadcn.PrimaryButton(
            onPressed: _saving || !_copyReady || !_supported ? null : _save,
            child: Text(
              _loadingCopy ? '读取中…'.tr : (_saving ? '保存中…'.tr : '保存'.tr),
            ),
          ),
        ],
      ),
    );
  }
}
