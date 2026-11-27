import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/gateways/gateway_controller.dart';
import '../../application/hosts/host_controller.dart';
import '../../application/session/session.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/proxy_config.dart';
import '../../domain/ssh/ssh_endpoint.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vault/secret_store.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_radio_card_field.dart';
import '../components/app_select_field.dart';
import '../components/app_text_form_field.dart';
import '../components/copy_name.dart';
import '../gateways/gateway_select_field.dart';
import '../identities/identity_select_field.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../shell/connect_flow.dart';
import '../theme/app_theme.dart';

/// 打开新建/编辑服务对话框。[host] 为 null 时表示新建，[initialFolderId]
/// 用于在某个文件夹下新建服务时指定归属（对话框内不提供文件夹选择，
/// 归属由入口上下文决定：根组/文件夹右键「在此新建服务」）。
/// [copyFrom] 预填来源内容，使用新的标识与独立的密码记录。
Future<void> showHostEditDialog(
  BuildContext context, {
  Host? host,
  Host? copyFrom,
  String? initialFolderId,
  bool gateway = false,
  Future<void> Function(Host)? onConnect,
}) async {
  final hostToConnect = await AppNavigation.dialog<Host>(
    HostEditDialog(
      host: host,
      copyFrom: copyFrom,
      initialFolderId: initialFolderId,
      gateway: gateway,
      allowConnectOnEdit: onConnect != null,
    ),
  );
  if (hostToConnect != null && context.mounted) {
    await (onConnect?.call(hostToConnect) ??
        connectToHost(context, hostToConnect));
  }
}

Future<void> showSessionHostEditDialog(
  BuildContext context,
  Session session, {
  bool retryOnSave = false,
}) async {
  final controller = savedHostControllerForSession(session);
  if (controller == null) return;
  final gateway = session.kind.usesGatewayEndpoint;
  try {
    final host = await controller.findSaved(session.host.id);
    if (!context.mounted) return;
    if (host == null) {
      AppNotice.error(gateway ? '所选网关已不存在' : '所选服务已不存在');
      return;
    }
    await showHostEditDialog(
      context,
      host: host,
      gateway: gateway,
      onConnect: retryOnSave
          ? (_) => retryFailedSession(context, session)
          : null,
    );
  } on Object {
    if (context.mounted) AppNotice.error('无法读取连接配置，请重试');
  }
}

/// 确认删除服务或网关及其已保存的凭据/配置。
Future<void> confirmDeleteHost(
  BuildContext context,
  Host host, {
  bool gateway = false,
}) async {
  final ok = await AppNavigation.dialog<bool>(
    AppDialog(
      title: Text(
        (gateway ? '删除网关「@name」？' : '删除服务「@name」？').trParams({
          'name': host.name,
        }),
      ),
      content: Text(
        gateway
            ? '将删除此网关及其端口转发、动态代理配置与保存的凭据，此操作无法撤销。'.tr
            : '将删除此服务（@address）及其保存的密码，此操作无法撤销。'.trParams({
                'address': host.address,
              }),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog(result: false),
          child: Text('取消'.tr),
        ),
        shadcn.DestructiveButton(
          key: const ValueKey('host-confirm-delete'),
          onPressed: () => AppNavigation.closeDialog(result: true),
          child: Text('删除'.tr),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    final controller = gateway
        ? Get.find<GatewayController>()
        : Get.find<HostController>();
    await controller.remove(host.id);
  } on SecretStoreException catch (e) {
    if (context.mounted) AppNotice.error(e.message);
  } on SshEngineException catch (e) {
    if (context.mounted) AppNotice.error(e.message.tr);
  } on StateError catch (e) {
    if (context.mounted) AppNotice.error(e.message.toString().tr);
  }
}

/// 登录方式：直接维护本服务的用户名密码，或复用已有凭证。
enum _AuthMode { password, identity }

class HostEditDialog extends StatefulWidget {
  const HostEditDialog({
    super.key,
    this.host,
    this.copyFrom,
    this.initialFolderId,
    this.gateway = false,
    this.allowConnectOnEdit = false,
  }) : assert(host == null || copyFrom == null);

  final Host? host;
  final Host? copyFrom;
  final String? initialFolderId;
  final bool gateway;
  final bool allowConnectOnEdit;

  @override
  State<HostEditDialog> createState() => _HostEditDialogState();
}

class _HostEditDialogState extends State<HostEditDialog> {
  static final _clientIdPattern = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');
  static final _fingerprintPattern = RegExp(r'^[a-fA-F0-9]{64}$');

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _hostname;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _note;
  late final TextEditingController _tags;
  int? _colorValue;
  late final TextEditingController _rdpDomain;
  late final TextEditingController _pageClientId;
  late final TextEditingController _pageFingerprint;
  late GatewayType _gatewayType;
  bool get _isPage => widget.gateway && _gatewayType == GatewayType.page;
  bool get _canKeepSecret =>
      _hasSavedPassword && widget.host?.gatewayType == _gatewayType;
  late ServiceType _serviceType;
  bool get _isRdp => !widget.gateway && _serviceType == ServiceType.rdp;
  bool get _isVnc => !widget.gateway && _serviceType == ServiceType.vnc;
  bool get _canKeepServiceSecret =>
      _hasSavedPassword && widget.host?.serviceType == _serviceType;
  late _AuthMode _mode;
  String? _identityId;
  late final String? _folderId;
  String? _gatewayId;
  bool _advancedExpanded = false;
  HostController get _controller => widget.gateway
      ? Get.find<GatewayController>()
      : Get.find<HostController>();
  bool _obscure = true;
  bool _saving = false;
  bool _loadingCopy = false;
  bool _copyReady = true;
  String? _error;
  bool _passwordOperationFailed = false;
  late final String _hostId =
      widget.host?.id ??
      '${widget.gateway ? 'gateway' : 'host'}-${DateTime.now().microsecondsSinceEpoch}';

  /// 编辑时该服务是否已有保存的自有密码（异步探测，仅影响提示文案）。
  bool _hasSavedPassword = false;

  bool get _isEdit => widget.host != null;

  @override
  void initState() {
    super.initState();
    final h = widget.host ?? widget.copyFrom;
    _gatewayType = h?.gatewayType ?? GatewayType.ssh;
    _pageClientId = TextEditingController(text: h?.pageClientId ?? '');
    _pageFingerprint = TextEditingController(
      text: h?.pageServerFingerprint ?? '',
    );
    _serviceType = widget.gateway
        ? ServiceType.ssh
        : h?.serviceType ?? ServiceType.ssh;
    _rdpDomain = TextEditingController(text: h?.rdpDomain ?? '');
    _name = TextEditingController(
      text: widget.copyFrom == null
          ? h?.name ?? ''
          : copyName(
              h!.name,
              isTaken: (name) =>
                  _controller.isNameTaken(name, folderId: h.folderId),
            ),
    );
    _hostname = TextEditingController(text: h?.hostname ?? '');
    _port = TextEditingController(text: '${h?.port ?? 22}');
    _username = TextEditingController(
      text: h?.username ?? _serviceType.defaultUsername,
    );
    _password = TextEditingController();
    _note = TextEditingController(text: h?.note ?? '');
    _tags = TextEditingController(text: h?.tags.join(', ') ?? '');
    _colorValue = h?.colorValue;
    _identityId = h?.identityId;
    _folderId = h?.folderId ?? widget.initialFolderId;
    _gatewayId = h?.gatewayId;
    _advancedExpanded =
        _gatewayId != null || _tags.text.isNotEmpty || (_colorValue ?? 0) != 0;
    _mode = h?.identityId != null ? _AuthMode.identity : _AuthMode.password;
    if (widget.copyFrom != null && h?.identityId == null) {
      _loadCopyPassword();
    } else if (_isEdit) {
      _controller
          .passwordOf(h!.id)
          .then((p) {
            if (mounted && p != null) setState(() => _hasSavedPassword = true);
          })
          .catchError((Object _) {
            if (mounted) setState(() => _error = '无法读取系统钥匙串，请解锁后重试');
          });
    }
  }

  Future<void> _loadCopyPassword() async {
    setState(() {
      _loadingCopy = true;
      _copyReady = false;
      _error = null;
    });
    try {
      final password = await _controller.passwordOf(widget.copyFrom!.id);
      if (!mounted) return;
      setState(() {
        _password.text = password ?? '';
        _copyReady = true;
      });
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
    _hostname.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _note.dispose();
    _tags.dispose();
    _rdpDomain.dispose();
    _pageClientId.dispose();
    _pageFingerprint.dispose();
    super.dispose();
  }

  Future<void> _save({bool connect = false}) async {
    if (_saving || !_copyReady) return;
    setState(() {
      _saving = true;
      _error = null;
      _passwordOperationFailed = false;
    });
    final controller = _controller;
    final id = _hostId;
    try {
      final latest = _isEdit ? await controller.findSaved(id) : widget.copyFrom;
      if (!mounted) return;
      if (_isEdit && latest == null) {
        throw StateError(widget.gateway ? '所选网关已不存在' : '所选服务已不存在');
      }
      _applyTypedAddress();
      if (_gatewayId case final gatewayId? when !widget.gateway) {
        final gateway = Get.isRegistered<GatewayController>()
            ? await Get.find<GatewayController>().findSaved(gatewayId)
            : null;
        if (!mounted) return;
        if (gateway == null) {
          setState(() => _advancedExpanded = true);
          throw StateError('所选网关已不存在');
        }
      }
      if (!_formKey.currentState!.validate()) return;
      final name = _name.text.trim();
      final username = _username.text.trim();
      final password = _password.text;
      final mode = _mode;
      final host = Host(
        id: id,
        name: name.isEmpty ? _hostname.text.trim() : name,
        hostname: _hostname.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _isVnc
            ? username
            : username.isEmpty
            ? _serviceType.defaultUsername
            : username,
        note: _note.text.trim(),
        tags: widget.gateway
            ? latest?.tags ?? const []
            : _tags.text
                  .split(RegExp(r'[,，\n]'))
                  .map((tag) => tag.trim())
                  .where((tag) => tag.isNotEmpty)
                  .toSet()
                  .toList(growable: false),
        folderId: _folderId,
        identityId: !_isPage && _mode == _AuthMode.identity
            ? _identityId
            : null,
        gatewayId: widget.gateway ? null : _gatewayId,
        gatewayType: _gatewayType,
        serviceType: _serviceType,
        rdpDomain: _isRdp ? _rdpDomain.text.trim() : '',
        pageClientId: _isPage ? _pageClientId.text.trim() : '',
        pageServerFingerprint: _isPage ? _pageFingerprint.text.trim() : '',
        colorValue: _colorValue,
        sortOrder: widget.host?.sortOrder ?? 0,
        forwardPorts: latest?.forwardPorts ?? const [],
        proxyConfig: latest?.proxyConfig ?? const ProxyConfig(),
      );
      await controller.save(host);
      if (_isPage || mode == _AuthMode.password) {
        // 留空：编辑时保持已存密码不变；新建时不保存（连接时询问）。
        if (password.isNotEmpty) {
          await controller.savePassword(id, password);
        } else if (widget.host != null &&
            (widget.gateway
                ? widget.host!.gatewayType != _gatewayType
                : widget.host!.serviceType != _serviceType)) {
          await controller.clearPassword(id);
        }
      } else {
        // 切换为凭证登录后清掉服务自有密码，不留无主密文。
        await controller.clearPassword(id);
      }
      if (mounted) {
        AppNavigation.closeDialog<Host>(result: connect ? host : null);
      }
    } on SecretStoreException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _passwordOperationFailed = true;
        });
      }
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message.toString());
    } on Object {
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? '必填'.tr : null;

  /// 同级（同文件夹）下服务名唯一；名称留空时以服务地址为实际名称参与校验。
  String? _validName(String? v) {
    final name = (v ?? '').trim();
    final effective = name.isEmpty ? _hostname.text.trim() : name;
    if (effective.isEmpty) return null; // 地址为空由「服务地址」字段报必填。
    final taken = _controller.isNameTaken(
      effective,
      folderId: _folderId,
      excludeId: _hostId,
    );
    return taken ? (widget.gateway ? '同级下已存在同名网关' : '同级下已存在同名服务').tr : null;
  }

  String? _validPort(String? v) {
    final port = int.tryParse(v?.trim() ?? '');
    if (port == null || port < 1 || port > 65535) return '1-65535';
    return null;
  }

  SshEndpoint? _splitAddress(String text) {
    if (_isPage || _serviceType != ServiceType.ssh) return null;
    final endpoint = parseSshEndpoint(text);
    if (endpoint == null) return null;
    if (endpoint.port case final port?) _port.text = '$port';
    if (endpoint.username case final username?) _username.text = username;
    return endpoint;
  }

  void _applyTypedAddress() {
    if (_splitAddress(_hostname.text) case final endpoint?) {
      _hostname.text = endpoint.hostname;
    }
  }

  String? _validAddress(String? value) {
    final requiredError = _required(value);
    if (requiredError != null) return requiredError;
    final address = value!.trim();
    if (!_isPage &&
        _serviceType == ServiceType.ssh &&
        (RegExp(r'[\s@\[\]]').hasMatch(address) ||
            ':'.allMatches(address).length == 1) &&
        parseSshEndpoint(address) == null) {
      return '请输入主机地址或有效的 SSH 连接地址'.tr;
    }
    return null;
  }

  TextEditingValue _formatAddressPaste(
    TextEditingValue previous,
    TextEditingValue next,
  ) {
    if (!next.composing.isCollapsed) return next;
    final replaced = previous.selection.isValid
        ? previous.selection.end - previous.selection.start
        : 0;
    if (next.text.length - previous.text.length + replaced <= 1) return next;
    final endpoint = _splitAddress(next.text);
    if (endpoint == null) return next;
    return TextEditingValue(
      text: endpoint.hostname,
      selection: TextSelection.collapsed(offset: endpoint.hostname.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    return PopScope<Host>(
      canPop: !_saving,
      child: AppDialog(
        scrollable: true,
        title: Text(
          (widget.gateway
                  ? (_isEdit ? '编辑网关' : '新建网关')
                  : (_isEdit ? '编辑服务' : '新建服务'))
              .tr,
        ),
        content: SizedBox(
          width: 420,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: AppInputDecoration(
                    labelText: '名称'.tr,
                    hintText: (widget.gateway ? '留空则使用网关地址' : '留空则使用服务地址').tr,
                  ),
                  validator: _validName,
                ),
                const SizedBox(height: 12),
                if (widget.gateway)
                  AppRadioCardField<GatewayType>(
                    key: const ValueKey('gateway-type'),
                    initialValue: _gatewayType,
                    label: '网关类型'.tr,
                    items: const [
                      AppRadioCardOption(
                        value: GatewayType.ssh,
                        icon: AppIcons.terminal,
                        child: Text('SSH'),
                      ),
                      AppRadioCardOption(
                        value: GatewayType.page,
                        icon: AppIcons.network,
                        child: Text('Page'),
                      ),
                    ],
                    onChanged: _saving
                        ? null
                        : (type) {
                            if (type == _gatewayType) return;
                            setState(() {
                              if (_port.text == (_isPage ? '7443' : '22')) {
                                _port.text = type == GatewayType.page
                                    ? '7443'
                                    : '22';
                              }
                              _gatewayType = type;
                              _password.clear();
                              _mode = _AuthMode.password;
                            });
                          },
                  )
                else
                  AppRadioCardField<ServiceType>(
                    key: const ValueKey('service-type'),
                    initialValue: _serviceType,
                    label: '服务类型'.tr,
                    items: const [
                      AppRadioCardOption(
                        value: ServiceType.ssh,
                        icon: AppIcons.terminal,
                        child: Text('SSH'),
                      ),
                      AppRadioCardOption(
                        value: ServiceType.rdp,
                        icon: AppIcons.rdp,
                        child: Text('RDP'),
                      ),
                      AppRadioCardOption(
                        value: ServiceType.vnc,
                        icon: AppIcons.screenShare,
                        child: Text('VNC'),
                      ),
                    ],
                    onChanged: _saving
                        ? null
                        : (type) {
                            if (type == _serviceType) return;
                            setState(() {
                              final oldDefault = '${_serviceType.defaultPort}';
                              if (_port.text == oldDefault) {
                                _port.text = '${type.defaultPort}';
                              }
                              if (_username.text.trim().isEmpty ||
                                  _username.text ==
                                      _serviceType.defaultUsername) {
                                _username.text = type.defaultUsername;
                              }
                              _serviceType = type;
                              _identityId = null;
                              _password.clear();
                            });
                          },
                  ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: AppTextFormField(
                        key: const ValueKey('host-address'),
                        controller: _hostname,
                        smartPunctuation: false,
                        inputFormatters: [
                          TextInputFormatter.withFunction(_formatAddressPaste),
                        ],
                        onFieldSubmitted: (_) => _applyTypedAddress(),
                        decoration: AppInputDecoration(
                          labelText:
                              (_isPage
                                      ? '中转 Server 地址'
                                      : (widget.gateway ? '网关地址' : '服务地址'))
                                  .tr,
                        ),
                        validator: _validAddress,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AppTextFormField(
                        controller: _port,
                        decoration: AppInputDecoration(labelText: '端口'.tr),
                        validator: _validPort,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_isPage) ...[
                  AppTextFormField(
                    key: const ValueKey('page-client-id'),
                    controller: _pageClientId,
                    smartPunctuation: false,
                    decoration: AppInputDecoration(labelText: 'Client ID'.tr),
                    validator: (v) => _clientIdPattern.hasMatch(v?.trim() ?? '')
                        ? null
                        : 'Client ID 使用 1-64 位字母、数字、下划线或短横线'.tr,
                  ),
                  const SizedBox(height: 12),
                  AppTextFormField(
                    key: const ValueKey('page-fingerprint'),
                    controller: _pageFingerprint,
                    smartPunctuation: false,
                    decoration: AppInputDecoration(
                      labelText: 'Server 证书 SHA-256 指纹（可选）'.tr,
                      helperText: '留空使用无证书 TCP；填写指纹使用 TLS'.tr,
                    ),
                    validator: (v) {
                      final value = v?.trim() ?? '';
                      if (value.isEmpty) return null;
                      return _fingerprintPattern.hasMatch(
                            value
                                .replaceFirst('SHA256:', '')
                                .replaceAll(':', ''),
                          )
                          ? null
                          : '请输入 Server 提供的 SHA-256 证书指纹'.tr;
                    },
                  ),
                  const SizedBox(height: 12),
                ] else
                  AppSelectField<_AuthMode>(
                    key: ValueKey('host-auth-$_serviceType-$_mode'),
                    initialValue: _mode,
                    label: '认证方式'.tr,
                    items: [
                      AppSelectOption(
                        value: _AuthMode.password,
                        child: Text('账号密码'.tr),
                      ),
                      AppSelectOption(
                        value: _AuthMode.identity,
                        child: Text('已有凭证'.tr),
                      ),
                    ],
                    onChanged: _saving || _loadingCopy
                        ? null
                        : (mode) {
                            if (mode != null) setState(() => _mode = mode);
                          },
                  ),
                const SizedBox(height: 12),
                if (_isRdp) ...[
                  AppTextFormField(
                    key: const ValueKey('rdp-domain'),
                    controller: _rdpDomain,
                    smartPunctuation: false,
                    decoration: AppInputDecoration(
                      labelText: 'Windows 域（可选）'.tr,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_isPage || _mode == _AuthMode.password) ...[
                  if (!_isPage) ...[
                    AppTextFormField(
                      key: const ValueKey('host-username'),
                      controller: _username,
                      decoration: AppInputDecoration(
                        labelText: (_isVnc ? '用户名（可选）' : '用户名').tr,
                        hintText: _isVnc
                            ? 'macOS 屏幕共享填写系统用户名；标准 VNC 留空'.tr
                            : null,
                      ),
                      validator: _isVnc ? null : _required,
                    ),
                    const SizedBox(height: 12),
                  ],
                  AppTextFormField(
                    key: const ValueKey('host-password'),
                    controller: _password,
                    enabled: !_loadingCopy,
                    obscureText: _obscure,
                    decoration: AppInputDecoration(
                      labelText: (_isPage ? '访问令牌' : '密码').tr,
                      hintText:
                          (widget.gateway
                              ? _canKeepSecret
                              : _canKeepServiceSecret)
                          ? '已保存；留空保持不变'.tr
                          : (_isPage
                                ? '与 Server 的 access_token 对应'.tr
                                : '留空则连接时询问'.tr),
                      suffixIcon: AppIconButton(
                        density: shadcn.ButtonDensity.compact,
                        icon: AppIcon(
                          _obscure ? AppIcons.eyeOff : AppIcons.eye,
                          size: AppTheme.inputIconSize,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: !_isPage
                        ? null
                        : (v) {
                            if ((v ?? '').isEmpty && _canKeepSecret) {
                              return null;
                            }
                            return (v ?? '').isEmpty ? '必填'.tr : null;
                          },
                  ),
                ] else
                  IdentitySelectField(
                    value: _identityId,
                    serviceType: widget.gateway
                        ? ServiceType.ssh
                        : _serviceType,
                    onChanged: (v) => setState(() => _identityId = v),
                  ),
                const SizedBox(height: 12),
                AppTextFormField(
                  key: const ValueKey('host-note'),
                  controller: _note,
                  decoration: AppInputDecoration(labelText: '备注'.tr),
                ),
                if (!widget.gateway) ...[
                  const SizedBox(height: 12),
                  shadcn.GhostButton(
                    key: const ValueKey('host-advanced-toggle'),
                    onPressed: () =>
                        setState(() => _advancedExpanded = !_advancedExpanded),
                    leading: AppIcon(
                      _advancedExpanded
                          ? AppIcons.chevronDown
                          : AppIcons.chevronRight,
                      size: 16,
                    ),
                    child: Text('高级选项'.tr),
                  ),
                  if (_advancedExpanded) ...[
                    AppTextFormField(
                      key: const ValueKey('host-tags'),
                      controller: _tags,
                      decoration: AppInputDecoration(
                        labelText: '标签'.tr,
                        hintText: '用逗号分隔，例如 prod, db'.tr,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _colorField(),
                    const SizedBox(height: 12),
                    _gatewayField(),
                  ],
                ],
                const SizedBox(height: 8),
                if (_error != null)
                  Text(
                    _passwordOperationFailed
                        ? (widget.gateway
                                  ? '@error。网关信息已保存，密码操作未完成'
                                  : '@error。服务信息已保存，密码操作未完成')
                              .trParams({'error': _error!.tr})
                        : _error!.tr,
                    style: TextStyle(color: colors.destructive),
                  ),
                if (!_copyReady && !_loadingCopy)
                  shadcn.OutlineButton(
                    onPressed: _loadCopyPassword,
                    child: Text('重试'.tr),
                  ),
                if (widget.gateway)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _isPage
                          ? 'Page 通过 PagaGateway Server 中转至内网 Client；令牌加密保存在本机'
                                .tr
                          : _mode == _AuthMode.password
                          ? '密码加密保存在本机，仅用于本网关'.tr
                          : '使用所选凭证的用户名与密码或私钥登录，凭证可在多个服务复用'.tr,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.mutedForeground,
                      ),
                    ),
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
          if (!widget.gateway && (!_isEdit || widget.allowConnectOnEdit))
            shadcn.OutlineButton(
              key: const ValueKey('host-save-connect'),
              onPressed: _saving || !_copyReady
                  ? null
                  : () => _save(connect: true),
              child: Text('保存并连接'.tr),
            ),
          shadcn.PrimaryButton(
            onPressed: _saving || !_copyReady ? null : _save,
            child: Text(
              _loadingCopy ? '读取中…'.tr : (_saving ? '保存中…'.tr : '保存'.tr),
            ),
          ),
        ],
      ),
    );
  }

  Widget _colorField() {
    final colors = shadcn.Theme.of(context).colorScheme;
    Widget option(int value, String label) => Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: value == 0 ? colors.mutedForeground : Color(value),
            shape: BoxShape.circle,
          ),
          child: const SizedBox.square(dimension: 10),
        ),
        const SizedBox(width: 8),
        Text(label.tr),
      ],
    );

    final palette = AppTheme.hostColorPresets;
    final current = _colorValue;
    return AppSelectField<int>(
      key: const ValueKey('host-color'),
      label: '色标'.tr,
      initialValue: current ?? 0,
      items: [
        AppSelectOption(value: 0, child: option(0, '无色标')),
        for (final entry in palette.entries)
          AppSelectOption(
            value: entry.key,
            child: option(entry.key, entry.value),
          ),
        if (current != null && current != 0 && !palette.containsKey(current))
          AppSelectOption(value: current, child: option(current, '自定义色标')),
      ],
      onChanged: _saving
          ? null
          : (value) => setState(() => _colorValue = value == 0 ? null : value),
    );
  }

  Widget _gatewayField() {
    if (!Get.isRegistered<GatewayTreeController>()) {
      return Text('还没有网关，可在侧边栏「网关」组新建'.tr);
    }
    return GatewaySelectField(
      value: _gatewayId,
      onChanged: _saving ? null : (id) => setState(() => _gatewayId = id),
    );
  }
}
