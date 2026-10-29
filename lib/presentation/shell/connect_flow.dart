import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/gateways/gateway_controller.dart';
import '../../application/hosts/host_controller.dart';
import '../../application/identities/identity_controller.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vault/secret_store.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../components/app_select_field.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../ssh/private_key_fields.dart';
import '../theme/app_theme.dart';

/// 统一的连接入口。
///
/// - 标签策略：默认每台服务一个标签。已有会话时聚焦已有标签；
///   [forceNew] 为 true（右键「新建会话」）时总是新开标签；
/// - 服务已绑定凭证：读取对应密码或私钥连接；
/// - 服务自有密码（编辑对话框「账号密码」方式保存）：同样直连；
/// - 都没有：选择已有凭证或即时提供密码/私钥，可保存为凭证复用。
Future<void> connectToHost(
  BuildContext context,
  Host host, {
  bool forceNew = false,
  SessionKind kind = SessionKind.terminal,
  String? forwardSessionId,
}) async {
  try {
    await _connectToHost(
      context,
      host,
      forceNew: forceNew,
      kind: kind,
      forwardSessionId: forwardSessionId,
    );
  } on SecretStoreException catch (e) {
    if (context.mounted) {
      AppNotice.error(e.message);
    }
  } on SshEngineException catch (e) {
    if (context.mounted) {
      AppNotice.error(e.message);
    }
  } on Object {
    if (context.mounted) {
      AppNotice.error('无法准备连接，请重试'.tr);
    }
  }
}

Future<void> _connectToHost(
  BuildContext context,
  Host host, {
  required bool forceNew,
  required SessionKind kind,
  String? forwardSessionId,
}) async {
  if (host.isDesktop) {
    if (kind == SessionKind.fileTransfer || kind == SessionKind.portForward) {
      throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
    }
    kind = SessionKind.remoteDesktop;
  }
  final sessionController = Get.find<SessionController>();

  if (kind == SessionKind.portForward) {
    final session = sessionController.sessions.firstWhereOrNull(
      (s) =>
          s.id == forwardSessionId &&
          s.host.id == host.id &&
          s.kind == SessionKind.portForward,
    );
    if (session == null || session.phase.isAlive) return;
  } else if (!forceNew &&
      sessionController.focusExisting(host.id, kind: kind)) {
    return;
  }
  final login = await _prepareLogin(context, host, Get.find<HostController>());
  if (login == null || !context.mounted) return;
  SshGateway? gateway;
  final gatewayId = login.$1.gatewayId;
  if (gatewayId != null) {
    if (!Get.isRegistered<GatewayController>()) {
      throw const SshEngineException('所选网关不可用，请检查服务的网关配置');
    }
    final controller = Get.find<GatewayController>();
    final endpoint = controller.hosts.firstWhereOrNull(
      (h) => h.id == gatewayId,
    );
    if (endpoint == null) throw const SshEngineException('所选网关已不存在');
    if (endpoint.gatewayType == GatewayType.page) {
      final token = await controller.passwordOf(endpoint.id);
      if (token == null || token.isEmpty) {
        throw const SshEngineException('Page 访问令牌未保存，请编辑网关');
      }
      gateway = SshGateway.page(host: endpoint, token: token);
    } else {
      final gatewayLogin = await _prepareLogin(context, endpoint, controller);
      if (gatewayLogin == null || !context.mounted) return;
      gateway = SshGateway(host: gatewayLogin.$1, credentials: gatewayLogin.$2);
    }
  }
  if (kind == SessionKind.portForward) {
    await sessionController.startForward(
      forwardSessionId!,
      login.$1,
      login.$2,
      gateway: gateway,
    );
  } else {
    // 准备凭据及网关期间可能已有同类标签打开，创建前再检查一次。
    if (!forceNew && sessionController.focusExisting(host.id, kind: kind)) {
      return;
    }
    await sessionController.open(
      login.$1,
      login.$2,
      kind: kind,
      gateway: gateway,
    );
  }
}

Future<(Host, SshCredentials)?> _prepareLogin(
  BuildContext context,
  Host host,
  HostController hostController,
) async {
  final identityController = Get.find<IdentityController>();

  // 已绑定凭证 → 直连。凭证被删或密文缺失则回退到弹窗。
  final bound = identityController.byId(host.identityId);
  if (bound != null) {
    if (!bound.supports(host.serviceType)) {
      throw const SshEngineException('凭证类型与服务不匹配，请修改所选凭证');
    }
    final credentials = await identityController.credentialsOf(bound);
    if (credentials != null) {
      return (host, credentials);
    }
  }

  // 服务自有密码（「账号密码」登录方式）→ 直连。
  final hostPassword = await hostController.passwordOf(host.id);
  if (hostPassword != null) {
    return (host, SshCredentials.password(hostPassword));
  }

  if (!context.mounted) return null;
  final choice = await AppNavigation.dialog<_ConnectChoice>(
    _ConnectDialog(host: host),
  );
  if (choice == null) return null;

  if (choice.identity != null) {
    final identity = choice.identity!;
    final credentials = await identityController.credentialsOf(identity);
    if (credentials == null) {
      throw const SecretStoreException('所选凭证的密文不存在，请重新编辑凭证');
    }
    // 记住绑定，下次直连。
    final connectHost = host.copyWith(identityId: identity.id);
    await hostController.save(connectHost);
    return (connectHost, credentials);
  }

  var connectHost = host;
  final credentials = choice.credentials!;
  if (choice.saveAsIdentity) {
    final identity = credentials.authType == AuthType.privateKey
        ? await identityController.saveWithPrivateKey(
            name: choice.identityName,
            username: host.username,
            privateKey: credentials.privateKey!,
            passphrase: credentials.passphrase,
          )
        : await identityController.saveWithPassword(
            name: choice.identityName,
            username: host.username,
            password: credentials.password!,
            serviceType: host.serviceType,
          );
    connectHost = host.copyWith(identityId: identity.id);
    await hostController.save(connectHost);
  }
  return (connectHost, credentials);
}

class _ConnectChoice {
  const _ConnectChoice.identity(Identity this.identity)
    : credentials = null,
      saveAsIdentity = false,
      identityName = '';

  const _ConnectChoice.manual({
    required this.credentials,
    required this.saveAsIdentity,
    required this.identityName,
  }) : identity = null;

  final Identity? identity;
  final SshCredentials? credentials;
  final bool saveAsIdentity;
  final String identityName;
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.host});

  final Host host;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  late final TextEditingController _identityName;

  /// null 表示即时提供凭据。
  Identity? _selectedIdentity;
  bool _obscure = true;
  bool _save = false;
  AuthType _authType = AuthType.password;

  @override
  void initState() {
    super.initState();
    _identityName = TextEditingController(
      text: widget.host.isVnc
          ? widget.host.name
          : '${widget.host.username}@${widget.host.name}',
    );
  }

  @override
  void dispose() {
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    _identityName.dispose();
    super.dispose();
  }

  void _submit() {
    final identity = _selectedIdentity;
    if (identity != null) {
      AppNavigation.closeDialog(result: _ConnectChoice.identity(identity));
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    AppNavigation.closeDialog(
      result: _ConnectChoice.manual(
        credentials: _authType == AuthType.privateKey
            ? SshCredentials.privateKey(
                _privateKey.text.trim(),
                passphrase: _passphrase.text,
              )
            : SshCredentials.password(_password.text),
        saveAsIdentity: _save && _identityName.text.trim().isNotEmpty,
        identityName: _identityName.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final identities = Get.find<IdentityController>().sorted
        .where((identity) => identity.supports(widget.host.serviceType))
        .toList();

    return AppDialog(
      scrollable: true,
      title: Text('连接到 @name'.trParams({'name': widget.host.name})),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.host.address,
                style: TextStyle(fontSize: 12, color: colors.mutedForeground),
              ),
              const SizedBox(height: 16),
              if (identities.isNotEmpty) ...[
                AppSelectField<String>(
                  initialValue: _selectedIdentity?.id ?? '',
                  label: '凭证'.tr,
                  items: [
                    AppSelectOption(
                      value: '',
                      child: Text(
                        (widget.host.isDesktop ? '即时提供密码' : '即时提供密码或私钥').tr,
                      ),
                    ),
                    for (final identity in identities)
                      AppSelectOption(
                        value: identity.id,
                        child: Text(
                          widget.host.isVnc
                              ? identity.name
                              : '@name（@username · @auth）'.trParams({
                                  'name': identity.name,
                                  'username': identity.username,
                                  'auth':
                                      (identity.authType == AuthType.privateKey
                                              ? '私钥'
                                              : '密码')
                                          .tr,
                                }),
                        ),
                      ),
                  ],
                  onChanged: (id) => setState(() {
                    _selectedIdentity = identities.firstWhereOrNull(
                      (identity) => identity.id == id,
                    );
                  }),
                ),
                const SizedBox(height: 12),
              ],
              if (_selectedIdentity == null) ...[
                AppSelectField<AuthType>(
                  initialValue: _authType,
                  label: '认证方式'.tr,
                  items: [
                    AppSelectOption(
                      value: AuthType.password,
                      child: Text('密码'.tr),
                    ),
                    if (!widget.host.isDesktop)
                      AppSelectOption(
                        value: AuthType.privateKey,
                        child: Text('私钥'.tr),
                      ),
                  ],
                  onChanged: (type) {
                    if (type != null) setState(() => _authType = type);
                  },
                ),
                const SizedBox(height: 12),
                if (_authType == AuthType.privateKey)
                  PrivateKeyFields(
                    privateKey: _privateKey,
                    passphrase: _passphrase,
                  )
                else
                  AppTextFormField(
                    controller: _password,
                    autofocus: true,
                    obscureText: _obscure,
                    validator: (value) =>
                        !widget.host.isVnc && (value == null || value.isEmpty)
                        ? '请输入密码'.tr
                        : null,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: AppInputDecoration(
                      labelText: '密码'.tr,
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
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: shadcn.Checkbox(
                    state: _save
                        ? shadcn.CheckboxState.checked
                        : shadcn.CheckboxState.unchecked,
                    onChanged: (state) => setState(
                      () => _save = state == shadcn.CheckboxState.checked,
                    ),
                    trailing: Text(
                      '保存为凭证，供其他服务复用'.tr,
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ),
                if (_save) ...[
                  AppTextFormField(
                    controller: _identityName,
                    decoration: AppInputDecoration(labelText: '凭证名称'.tr),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '密码或私钥及口令加密保存在本机，服务和凭证信息仅保存在本机'.tr,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.mutedForeground,
                    ),
                  ),
                ],
              ] else
                Text(
                  widget.host.isVnc
                      ? '将使用所选凭证连接，并记住此绑定'.tr
                      : '将以 @username 连接，并记住此绑定'.trParams({
                          'username': _selectedIdentity!.username,
                        }),
                  style: TextStyle(fontSize: 12, color: colors.mutedForeground),
                ),
            ],
          ),
        ),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog<void>(),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(onPressed: _submit, child: Text('连接'.tr)),
      ],
    );
  }
}
