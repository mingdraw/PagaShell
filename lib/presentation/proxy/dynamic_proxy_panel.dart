import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/gateways/gateway_controller.dart';
import '../../application/proxy/clash_extension_script.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../domain/entities/host.dart';
import '../../domain/entities/proxy_config.dart';
import '../components/app_icon_button.dart';
import '../components/app_select_field.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../shell/connect_flow.dart';
import '../ssh/host_key_confirmation.dart';
import '../theme/app_theme.dart';
import 'clash_extension_dialog.dart';

class DynamicProxyPanel extends StatefulWidget {
  const DynamicProxyPanel({required this.session, super.key});
  final Session session;

  @override
  State<DynamicProxyPanel> createState() => _DynamicProxyPanelState();
}

class _RuleEditor {
  _RuleEditor(ProxyRule rule)
    : type = rule.type,
      value = TextEditingController(text: rule.value);
  final key = UniqueKey();
  ProxyRuleType type;
  final TextEditingController value;
}

class _DynamicProxyPanelState extends State<DynamicProxyPanel> {
  final _form = GlobalKey<FormState>();
  late final GatewayController _gateways;
  final _http = TextEditingController();
  final _socks = TextEditingController();
  late ProxyMode _mode;
  late bool _httpEnabled, _socksEnabled, _autoSystemProxy;
  List<_RuleEditor> _rules = [];
  final _retired = <_RuleEditor>[];
  late String _saved;
  Timer? _timer;
  Future<Host?>? _pendingSave;
  int _revision = 0;
  bool _dirty = false;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _gateways = Get.find<GatewayController>();
    _load(widget.session.host.proxyConfig);
  }

  void _load(ProxyConfig config) {
    _saved = jsonEncode(config.toJson());
    _mode = config.mode;
    _httpEnabled = config.httpEnabled || config.httpsEnabled;
    _socksEnabled = config.socks5Enabled;
    _autoSystemProxy = config.autoSystemProxy;
    // 兼容旧配置：只启用 HTTPS 时沿用其端口，否则优先沿用 HTTP 端口。
    _http.text =
        '${!config.httpEnabled && config.httpsEnabled ? config.httpsPort : config.httpPort}';
    _socks.text = '${config.socks5Port}';
    _retired.addAll(_rules);
    _rules = config.rules.map(_RuleEditor.new).toList();
  }

  @override
  void didUpdateWidget(covariant DynamicProxyPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dirty &&
        _pendingSave == null &&
        !_starting &&
        _saved != jsonEncode(widget.session.host.proxyConfig.toJson())) {
      _load(widget.session.host.proxyConfig);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_dirty && !widget.session.phase.isAlive) {
      try {
        unawaited(_persist(_read()));
      } on StateError {
        // An incomplete draft must not replace the last valid configuration.
      }
    }
    for (final c in [
      _http,
      _socks,
      ...[..._rules, ..._retired].map((r) => r.value),
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    _timer?.cancel();
    setState(() {
      _dirty = true;
      _revision++;
      _error = null;
    });
    _timer = Timer(const Duration(milliseconds: 350), () => unawaited(_save()));
  }

  ProxyConfig _read() {
    int port(TextEditingController controller) {
      final number = int.tryParse(controller.text.trim());
      if (number == null) throw StateError('请填写有效的端口（1-65535）');
      return number;
    }

    final httpPort = port(_http);
    final config = ProxyConfig(
      mode: _mode,
      httpEnabled: _httpEnabled,
      httpPort: httpPort,
      httpsEnabled: _httpEnabled,
      httpsPort: httpPort,
      socks5Enabled: _socksEnabled,
      socks5Port: port(_socks),
      autoSystemProxy: _autoSystemProxy,
      rules: List.unmodifiable([
        for (final row in _rules)
          if (row.value.text.trim().isNotEmpty)
            ProxyRule(type: row.type, value: row.value.text.trim()),
      ]),
    );
    config.validate();
    return config;
  }

  Future<Host?> _save({bool forStart = false}) async {
    _timer?.cancel();
    if (!mounted || !(_form.currentState?.validate() ?? false)) return null;
    try {
      final config = _read();
      config.validate(forStart: forStart);
      if (!forStart &&
          _pendingSave == null &&
          _saved == jsonEncode(config.toJson())) {
        setState(() => _dirty = false);
        return null;
      }
      return await _persist(config);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message.toString());
      return null;
    }
  }

  Future<Host?> _persist(ProxyConfig config) {
    final previous = _pendingSave;
    final revision = _revision;
    final hostId = widget.session.host.id;
    final future = () async {
      await previous;
      try {
        final host = await _gateways.saveProxyConfig(hostId, config);
        _saved = jsonEncode(config.toJson());
        if (mounted && _revision == revision) {
          setState(() {
            _dirty = false;
            _error = null;
          });
        }
        return host;
      } on Object catch (e) {
        if (mounted && _revision == revision) {
          setState(
            () => _error = e is StateError ? e.message.toString() : '保存失败，请重试',
          );
        }
        return null;
      }
    }();
    _pendingSave = future;
    unawaited(
      future.then((_) {
        if (identical(_pendingSave, future)) _pendingSave = null;
      }),
    );
    return future;
  }

  Future<void> _start() async {
    if (_starting || widget.session.phase.isAlive) return;
    setState(() => _starting = true);
    try {
      final host = await _save(forStart: true);
      if (host == null || !mounted) return;
      await connectToHost(
        context,
        host,
        kind: SessionKind.dynamicProxy,
        forwardSessionId: widget.session.id,
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _showClashScript() {
    if (_autoSystemProxy || !(_form.currentState?.validate() ?? false)) return;
    try {
      final script = ClashExtensionScript.fromConfig(
        widget.session.host,
        _read(),
      );
      unawaited(
        AppNavigation.dialog<void>(ClashExtensionDialog(script: script)),
      );
    } on StateError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  Widget _protocol(
    String name,
    bool selected,
    TextEditingController port,
    ValueChanged<bool> onChanged,
    bool editable,
  ) => shadcn.Card(
    child: Row(
      children: [
        Expanded(
          child: shadcn.Checkbox(
            state: selected
                ? shadcn.CheckboxState.checked
                : shadcn.CheckboxState.unchecked,
            onChanged: editable
                ? (s) {
                    setState(
                      () => onChanged(s == shadcn.CheckboxState.checked),
                    );
                    _changed();
                  }
                : null,
            trailing: Text(name),
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 200,
          child: AppTextFormField(
            key: ValueKey('proxy-$name-port'),
            controller: port,
            enabled: editable && selected,
            decoration: AppInputDecoration(
              labelText: '监听端口'.tr,
              inlineLabel: true,
            ),
            validator: (s) {
              final n = int.tryParse(s?.trim() ?? '');
              return n == null || n < 1 || n > 65535 ? '1-65535' : null;
            },
          ),
        ),
      ],
    ),
  );

  Widget _protocols(bool editable) => LayoutBuilder(
    builder: (context, constraints) {
      final http = _protocol(
        'HTTP(S)',
        _httpEnabled,
        _http,
        (selected) => _httpEnabled = selected,
        editable,
      );
      final socks = _protocol(
        'SOCKS5',
        _socksEnabled,
        _socks,
        (selected) => _socksEnabled = selected,
        editable,
      );
      if (constraints.maxWidth < 800) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [http, const SizedBox(height: 8), socks],
        );
      }
      return Row(
        children: [
          Expanded(child: http),
          const SizedBox(width: 12),
          Expanded(child: socks),
        ],
      );
    },
  );

  Widget _modeCard(ProxyMode mode, bool editable) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final (label, description) = switch (mode) {
      ProxyMode.rule => ('规则', '命中任一规则走网关，其余请求由本机直连'),
      ProxyMode.global => ('全局', '所有请求通过当前网关连接目标'),
    };
    return Semantics(
      checked: _mode == mode,
      inMutuallyExclusiveGroup: true,
      enabled: editable,
      child: shadcn.RadioCard<ProxyMode>(
        key: ValueKey('proxy-mode-${mode.name}'),
        value: mode,
        enabled: editable,
        theme: const shadcn.RadioCardTheme(padding: EdgeInsets.all(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label.tr, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              description.tr,
              style: TextStyle(fontSize: 12, color: colors.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modes(bool editable) => shadcn.RadioGroup<ProxyMode>(
    value: _mode,
    enabled: editable,
    onChanged: editable
        ? (mode) {
            setState(() => _mode = mode);
            _changed();
          }
        : null,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final rule = _modeCard(ProxyMode.rule, editable);
        final global = _modeCard(ProxyMode.global, editable);
        const cardWidth = AppTheme.proxyModeCardWidth;
        final Widget cards;
        if (constraints.maxWidth < cardWidth * 2 + 12) {
          cards = SizedBox(
            width: cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [rule, const SizedBox(height: 12), global],
            ),
          );
        } else {
          cards = SizedBox(
            width: cardWidth * 2 + 12,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: rule),
                  const SizedBox(width: 12),
                  Expanded(child: global),
                ],
              ),
            ),
          );
        }
        return Align(alignment: Alignment.centerLeft, child: cards);
      },
    ),
  );

  String _typeLabel(ProxyRuleType type) => switch (type) {
    ProxyRuleType.ip => 'IP / CIDR',
    ProxyRuleType.domainExact => '域名全匹配',
    ProxyRuleType.domainPrefix => '域名前缀',
    ProxyRuleType.domainSuffix => '域名后缀',
  };

  Widget _rule(_RuleEditor row, bool editable) => Padding(
    key: row.key,
    padding: const EdgeInsets.only(bottom: 12),
    child: shadcn.Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final type = AppSelectField<ProxyRuleType>(
            initialValue: row.type,
            label: '匹配方式'.tr,
            inlineLabel: true,
            items: [
              for (final t in ProxyRuleType.values)
                AppSelectOption(value: t, child: Text(_typeLabel(t).tr)),
            ],
            onChanged: editable
                ? (t) {
                    if (t == null) return;
                    setState(() => row.type = t);
                    _changed();
                  }
                : null,
          );
          final value = AppTextFormField(
            key: const ValueKey('proxy-rule-value'),
            controller: row.value,
            enabled: editable,
            decoration: AppInputDecoration(
              labelText: '匹配内容'.tr,
              inlineLabel: true,
              hintText: row.type == ProxyRuleType.ip
                  ? '10.0.0.0/16 / 2001:db8::/32'
                  : 'example.com',
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) return null;
              try {
                ProxyRule(type: row.type, value: value).validate();
              } on StateError catch (e) {
                return e.message.toString().tr;
              }
              return null;
            },
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: constraints.maxWidth < 600
                    ? Column(
                        children: [type, const SizedBox(height: 12), value],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 300, child: type),
                          const SizedBox(width: 12),
                          Expanded(child: value),
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              AppIconButton(
                semanticLabel: '移除规则'.tr,
                icon: const Icon(shadcn.LucideIcons.trash2, size: 16),
                onPressed: editable
                    ? () {
                        setState(() {
                          _rules.remove(row);
                          _retired.add(row);
                        });
                        _changed();
                      }
                    : null,
              ),
            ],
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final editable = !session.phase.isAlive && !_starting;
    final busy = session.phase.isBusy || _starting;
    final controller = Get.find<SessionController>();
    final colors = shadcn.Theme.of(context).colorScheme;
    final status = controller.proxyNeedsCleanup(session.id)
        ? '系统代理待恢复'
        : switch (session.phase) {
            SessionPhase.ready => '正在监听',
            SessionPhase.closed => '未启用',
            SessionPhase.failed => '代理失败',
            SessionPhase.stopping => '正在停止',
            SessionPhase.hostKeyPending => '等待确认主机指纹',
            _ => '正在连接',
          };
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(shadcn.LucideIcons.network, size: 22),
              Text(
                '动态代理'.tr,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              shadcn.OutlineBadge(child: Text(status.tr)),
            ],
          ),
          const SizedBox(height: 12),
          Text('关联网关：@name'.trParams({'name': session.host.name})),
          const SizedBox(height: 8),
          Text(
            '监听地址：127.0.0.1；支持手动配置或自动设置系统网络代理'.tr,
            style: TextStyle(fontSize: 12, color: colors.mutedForeground),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Form(
                key: _form,
                onChanged: _changed,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (session.phase == SessionPhase.hostKeyPending &&
                        session.hostKeyReview != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: HostKeyConfirmation(
                          review: session.hostKeyReview!,
                          onDecision: (trust) => controller.confirmHostKey(
                            session.id,
                            trust: trust,
                          ),
                        ),
                      ),
                    Text(
                      '代理模式'.tr,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _modes(editable),
                    const SizedBox(height: 16),
                    Text(
                      '协议端口'.tr,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _protocols(editable),
                    if (_mode == ProxyMode.rule) ...[
                      const SizedBox(height: 24),
                      Text(
                        '代理规则'.tr,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      for (final row in _rules) _rule(row, editable),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: shadcn.OutlineButton(
                          onPressed: editable
                              ? () {
                                  setState(
                                    () => _rules.add(
                                      _RuleEditor(
                                        const ProxyRule(
                                          type: ProxyRuleType.domainSuffix,
                                          value: '',
                                        ),
                                      ),
                                    ),
                                  );
                                  _changed();
                                }
                              : null,
                          leading: const Icon(
                            shadcn.LucideIcons.plus,
                            size: 16,
                          ),
                          child: Text('添加规则'.tr),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Builder(
            builder: (context) {
              final autoSystemProxy = shadcn.Checkbox(
                key: const ValueKey('proxy-auto-system'),
                state: _autoSystemProxy
                    ? shadcn.CheckboxState.checked
                    : shadcn.CheckboxState.unchecked,
                onChanged: editable
                    ? (state) {
                        setState(
                          () => _autoSystemProxy =
                              state == shadcn.CheckboxState.checked,
                        );
                        _changed();
                      }
                    : null,
                trailing: Text('自动设置系统网络代理'.tr),
              );
              final action = session.phase.isAlive
                  ? shadcn.OutlineButton(
                      onPressed: session.phase == SessionPhase.stopping
                          ? null
                          : () => controller.stopProxy(session.id),
                      leading: const Icon(shadcn.LucideIcons.square, size: 16),
                      child: Text('停止代理'.tr),
                    )
                  : shadcn.PrimaryButton(
                      onPressed: busy ? null : _start,
                      leading: const Icon(shadcn.LucideIcons.play, size: 16),
                      child: Text((busy ? '正在连接' : '启动代理').tr),
                    );
              final error =
                  _error?.tr ??
                  (session.error == null
                      ? null
                      : AppTranslations.error(session.error!));
              final actions = Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  action,
                  if (!_autoSystemProxy)
                    shadcn.OutlineButton(
                      key: const ValueKey('proxy-clash-script'),
                      onPressed: _showClashScript,
                      leading: const Icon(shadcn.LucideIcons.code, size: 16),
                      child: Text('Clash 扩展脚本'.tr),
                    ),
                  if (error != null)
                    Text(error, style: TextStyle(color: colors.destructive)),
                ],
              );
              return Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [autoSystemProxy, actions],
              );
            },
          ),
        ],
      ),
    );
  }
}
