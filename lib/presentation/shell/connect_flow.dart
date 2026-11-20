import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/gateways/gateway_controller.dart';
import '../../application/hosts/host_controller.dart';
import '../../application/identities/identity_controller.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../application/session/session_layout.dart';
import '../../application/settings/settings_controller.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/identity.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vault/secret_store.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_select_field.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
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
  bool temporary = false,
  SessionKind kind = SessionKind.terminal,
  String? forwardSessionId,
  ({String sessionId, SessionSplitEdge edge})? splitTarget,
}) => _runConnectionFlow(
  context,
  () => _connectToHost(
    context,
    host,
    forceNew: forceNew,
    temporary: temporary,
    kind: kind,
    forwardSessionId: forwardSessionId,
    splitTarget: splitTarget,
  ),
);

HostController? savedHostControllerForSession(Session session) {
  if (session.kind == SessionKind.containerTerminal ||
      Get.find<SessionController>().isTemporarySession(session.id)) {
    return null;
  }
  if (session.kind.usesGatewayEndpoint) {
    return Get.isRegistered<GatewayController>()
        ? Get.find<GatewayController>()
        : null;
  }
  return Get.isRegistered<HostController>() ? Get.find<HostController>() : null;
}

Future<void> duplicateSessionConnection(
  BuildContext context,
  Session session,
) => _runConnectionFlow(context, () async {
  final controller = Get.find<SessionController>();
  if (await controller.duplicateSession(session.id) != null ||
      !context.mounted) {
    return;
  }
  final hosts = savedHostControllerForSession(session);
  final host = await hosts?.findSaved(session.host.id);
  if (!context.mounted) return;
  await connectToHost(
    context,
    host ?? session.host,
    forceNew: true,
    temporary: host == null,
  );
});

Future<void> retryFailedSession(BuildContext context, Session session) =>
    _runConnectionFlow(context, () async {
      final controller = Get.find<SessionController>();
      bool isCurrent() => controller.sessions.any((s) => identical(s, session));
      if (!isCurrent() || !controller.canRetry(session.id)) return;
      final hosts = savedHostControllerForSession(session);
      final host = await hosts?.findSaved(session.host.id);
      if (!context.mounted || !isCurrent()) return;
      if (host == null) {
        await controller.retry(session.id);
        return;
      }
      if (session.kind == SessionKind.fileTransfer && host.isDesktop) {
        throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
      }
      final login = await _prepareHostConnection(context, host, hosts);
      if (login == null || !context.mounted || !isCurrent()) return;
      await controller.retryWithLogin(
        session.id,
        login.host,
        login.credentials,
        gateway: login.gateway,
      );
    });

Future<void> _runConnectionFlow(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
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
  required bool temporary,
  required SessionKind kind,
  String? forwardSessionId,
  ({String sessionId, SessionSplitEdge edge})? splitTarget,
}) async {
  if (host.isDesktop) {
    if (kind == SessionKind.fileTransfer || kind == SessionKind.portForward) {
      throw const SshEngineException('远程桌面服务不支持 SSH 文件传输或端口转发');
    }
    kind = SessionKind.remoteDesktop;
  }
  final sessionController = Get.find<SessionController>();
  if (splitTarget != null &&
      (kind != SessionKind.terminal ||
          !sessionController.canSplitToHost(splitTarget.sessionId, host))) {
    return;
  }
  if (splitTarget != null &&
      sessionController.sessions.any(
        (session) =>
            session.id == splitTarget.sessionId && session.host.id == host.id,
      )) {
    await sessionController.splitTerminal(
      splitTarget.sessionId,
      splitTarget.edge.axis,
      before: splitTarget.edge.before,
    );
    return;
  }

  if (kind.usesGatewayEndpoint) {
    final session = sessionController.sessions.firstWhereOrNull(
      (s) => s.id == forwardSessionId && s.host.id == host.id && s.kind == kind,
    );
    if (session == null || session.phase.isAlive) return;
    final controller = Get.find<GatewayController>();
    final endpoint = await controller.findSaved(host.id);
    if (endpoint == null) throw const SshEngineException('所选网关已不存在');
    if (!context.mounted) return;
    final gateway = await _prepareGateway(context, endpoint, controller);
    if (gateway != null && context.mounted) {
      if (kind == SessionKind.dynamicProxy) {
        await sessionController.startProxy(
          forwardSessionId!,
          gateway.host,
          gateway: gateway,
        );
      } else {
        await sessionController.startForward(forwardSessionId!, gateway);
      }
    }
    return;
  } else if (splitTarget == null &&
      !forceNew &&
      sessionController.focusExisting(host.id, kind: kind)) {
    return;
  }
  final login = await _prepareHostConnection(
    context,
    host,
    temporary ? null : Get.find<HostController>(),
  );
  if (login == null || !context.mounted) return;
  // 准备凭据及网关期间可能已有同类标签打开，创建前再检查一次。
  if (splitTarget != null) {
    if (!sessionController.canSplitToHost(splitTarget.sessionId, login.host)) {
      return;
    }
  } else if (!forceNew &&
      sessionController.focusExisting(host.id, kind: kind)) {
    return;
  }
  if (!temporary && Get.isRegistered<SettingsController>()) {
    unawaited(
      Get.find<SettingsController>()
          .recordRecentHost(host.id)
          .catchError((Object _) {}),
    );
  }
  if (splitTarget != null) {
    await sessionController.splitToHost(
      splitTarget.sessionId,
      login.host,
      login.credentials,
      edge: splitTarget.edge,
      gateway: login.gateway,
      temporary: temporary,
    );
    return;
  }
  await sessionController.open(
    login.host,
    login.credentials,
    kind: kind,
    gateway: login.gateway,
    temporary: temporary,
  );
}

Future<({Host host, SshCredentials credentials, SshGateway? gateway})?>
_prepareHostConnection(
  BuildContext context,
  Host host,
  HostController? hostController,
) async {
  final login = await _prepareLogin(context, host, hostController);
  if (login == null || !context.mounted) return null;
  SshGateway? gateway;
  if (login.$1.gatewayId case final gatewayId?) {
    if (!Get.isRegistered<GatewayController>()) {
      throw const SshEngineException('所选网关不可用，请检查服务的网关配置');
    }
    final controller = Get.find<GatewayController>();
    final endpoint = await controller.findSaved(gatewayId);
    if (!context.mounted) return null;
    if (endpoint == null) throw const SshEngineException('所选网关已不存在');
    gateway = await _prepareGateway(context, endpoint, controller);
    if (gateway == null) return null;
  }
  return (host: login.$1, credentials: login.$2, gateway: gateway);
}

Future<SshGateway?> _prepareGateway(
  BuildContext context,
  Host endpoint,
  GatewayController controller,
) async {
  if (endpoint.gatewayType == GatewayType.page) {
    final token = await controller.passwordOf(endpoint.id);
    if (token == null || token.isEmpty) {
      throw const SshEngineException('Page 访问令牌未保存，请编辑网关');
    }
    return SshGateway.page(host: endpoint, token: token);
  }
  final login = await _prepareLogin(context, endpoint, controller);
  if (login == null || !context.mounted) return null;
  return SshGateway(host: login.$1, credentials: login.$2);
}

Future<(Host, SshCredentials)?> _prepareLogin(
  BuildContext context,
  Host host,
  HostController? hostController,
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
  final hostPassword = await hostController?.passwordOf(host.id);
  if (hostPassword != null) {
    return (host, SshCredentials.password(hostPassword));
  }

  if (!context.mounted) return null;
  return AppNavigation.dialog<(Host, SshCredentials)>(
    _ConnectDialog(
      host: host,
      canRemember: hostController != null,
      resolve: (choice) => _resolveConnectChoice(
        host,
        hostController,
        identityController,
        choice,
      ),
    ),
  );
}

Future<(Host, SshCredentials)> _resolveConnectChoice(
  Host host,
  HostController? hostController,
  IdentityController identityController,
  _ConnectChoice choice,
) async {
  if (choice.identity != null) {
    final identity = choice.identity!;
    final credentials = await identityController.credentialsOf(identity);
    if (credentials == null) {
      throw const SecretStoreException('所选凭证的密文不存在，请重新编辑凭证');
    }
    // 记住绑定，下次直连。
    final connectHost = host.copyWith(identityId: identity.id);
    await hostController?.save(connectHost);
    return (connectHost, credentials);
  }

  var connectHost = host;
  final credentials = choice.credentials!;
  if (choice.saveAsIdentity && hostController != null) {
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
            rdpDomain: host.isRdp ? host.rdpDomain : null,
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
  const _ConnectDialog({
    required this.host,
    required this.canRemember,
    required this.resolve,
  });

  final Host host;
  final bool canRemember;
  final Future<(Host, SshCredentials)> Function(_ConnectChoice) resolve;

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
  bool _submitting = false;
  String? _error;
  String? _duplicateName;
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

  String? _validateIdentityName(String? value) {
    final name = value?.trim() ?? '';
    if (name.isEmpty) return '必填'.tr;
    if (_duplicateName == name ||
        Get.find<IdentityController>().isNameTaken(name)) {
      return '同级下已存在同名凭证'.tr;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final identity = _selectedIdentity;
    if (identity == null && !_formKey.currentState!.validate()) return;
    final choice = identity == null
        ? _ConnectChoice.manual(
            credentials: _authType == AuthType.privateKey
                ? SshCredentials.privateKey(
                    _privateKey.text.trim(),
                    passphrase: _passphrase.text,
                  )
                : SshCredentials.password(_password.text),
            saveAsIdentity: _save,
            identityName: _identityName.text.trim(),
          )
        : _ConnectChoice.identity(identity);
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await widget.resolve(choice);
      if (mounted) AppNavigation.closeDialog(result: result);
    } on ArgumentError catch (error) {
      if (mounted && choice.saveAsIdentity && error.message == '同级下已存在同名凭证') {
        _duplicateName = choice.identityName;
        _formKey.currentState?.validate();
      } else if (mounted) {
        setState(() => _error = '无法准备连接，请重试');
      }
    } on SecretStoreException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on SshEngineException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) setState(() => _error = '无法准备连接，请重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final identities = Get.find<IdentityController>().sorted
        .where(
          (identity) =>
              identity.supports(widget.host.serviceType) &&
              (widget.canRemember || identity.username == widget.host.username),
        )
        .toList();

    return PopScope(
      canPop: !_submitting,
      child: AppDialog(
        scrollable: true,
        title: Text('连接到 @name'.trParams({'name': widget.host.name})),
        feedback: _error == null
            ? null
            : Text(
                AppTranslations.error(_error!),
                style: TextStyle(color: colors.destructive),
              ),
        content: AbsorbPointer(
          absorbing: _submitting,
          child: SizedBox(
            width: 420,
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.host.address,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.mutedForeground,
                    ),
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
                                          (identity.authType ==
                                                      AuthType.privateKey
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
                    if (!widget.host.isDesktop) ...[
                      AppSelectField<AuthType>(
                        initialValue: _authType,
                        label: '认证方式'.tr,
                        items: [
                          AppSelectOption(
                            value: AuthType.password,
                            child: Text('密码'.tr),
                          ),
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
                    ],
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
                            !widget.host.isVnc &&
                                (value == null || value.isEmpty)
                            ? '请输入密码'.tr
                            : null,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: AppInputDecoration(
                          labelText: '密码'.tr,
                          suffixIcon: AppIconButton(
                            density: shadcn.ButtonDensity.compact,
                            icon: AppIcon(
                              _obscure ? AppIcons.eyeOff : AppIcons.eye,
                              size: AppTheme.inputIconSize,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                    if (widget.canRemember) ...[
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
                    ],
                    if (_save) ...[
                      AppTextFormField(
                        controller: _identityName,
                        key: const ValueKey('connect-identity-name'),
                        decoration: AppInputDecoration(labelText: '凭证名称'.tr),
                        validator: _validateIdentityName,
                        onFieldSubmitted: (_) => _submit(),
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
                      !widget.canRemember
                          ? '将使用所选凭证连接'.tr
                          : widget.host.isVnc
                          ? '将使用所选凭证连接，并记住此绑定'.tr
                          : '将以 @username 连接，并记住此绑定'.trParams({
                              'username': _selectedIdentity!.username,
                            }),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.mutedForeground,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          shadcn.OutlineButton(
            onPressed: _submitting
                ? null
                : () => AppNavigation.closeDialog<void>(),
            child: Text('取消'.tr),
          ),
          shadcn.PrimaryButton(
            onPressed: _submitting ? null : _submit,
            child: Text((_submitting ? '正在处理…' : '连接').tr),
          ),
        ],
      ),
    );
  }
}
