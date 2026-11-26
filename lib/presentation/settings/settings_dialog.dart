import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_api_codec.dart';
import '../../application/ai/agent_controller.dart';
import '../../application/ai/ai_settings_controller.dart';
import '../../application/mcp/mcp_server_controller.dart';
import '../../application/settings/settings_controller.dart';
import '../../application/tray/system_tray_controller.dart';
import '../../domain/ai/ai_model.dart';
import '../../domain/entities/app_proxy_settings.dart';
import '../../domain/entities/app_theme_mode.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_radio_card_field.dart';
import '../components/app_select_field.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'about_settings_section.dart';
import 'mcp_settings_section.dart';
import 'quick_commands_settings_section.dart';
import 'terminal_settings_section.dart';

enum SettingsTab {
  general('通用'),
  terminal('终端'),
  quickCommands('常用指令'),
  proxy('代理'),
  ai('AI 设置'),
  about('关于');

  const SettingsTab(this.label);

  final String label;
}

Future<void> showSettingsDialog({
  bool ai = false,
  bool proxy = false,
  bool quickCommands = false,
}) => AppNavigation.dialog<void>(
  SettingsDialog(
    initialTab: ai
        ? SettingsTab.ai
        : proxy
        ? SettingsTab.proxy
        : quickCommands
        ? SettingsTab.quickCommands
        : SettingsTab.general,
  ),
);

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({this.initialTab = SettingsTab.general, super.key});

  final SettingsTab initialTab;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsTab _tab = widget.initialTab;
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _modelFocus = FocusNode();
  late final _appSettings = Get.find<SettingsController>();
  late final _settings = Get.find<AiSettingsController>();
  AiModelConfig? _config;
  bool _aiHydrated = false;
  bool _proxyHydrated = false;

  final _proxyForm = GlobalKey<FormState>();
  final _proxyAddress = TextEditingController();
  final _proxyUsername = TextEditingController();
  final _proxyPassword = TextEditingController();
  AppProxyMode _proxyMode = AppProxyMode.auto;
  AppProxyProtocol _proxyProtocol = AppProxyProtocol.http;
  bool _hasSavedProxyPassword = false;
  bool _clearSavedProxyPassword = false;
  bool _obscureProxyPassword = true;
  bool _updatingProxy = false;
  String? _proxyError;
  String? _proxySuccess;

  AiApiFormat _format = AiApiFormat.openai;
  String _lastModelText = '';
  bool _updating = false;
  bool _saving = false;
  bool _testing = false;
  bool _refreshing = false;
  bool _obscureKey = true;
  bool _showAllModels = false;
  int _refreshGeneration = 0;
  List<String> _models = const [];
  String? _modelsError;
  String? _error;
  String? _success;

  bool get _busy =>
      _saving || _testing || _appSettings.savingProxySettings.value;

  @override
  void initState() {
    super.initState();
    _url.addListener(_invalidateModels);
    _key.addListener(_invalidateModels);
    _model.addListener(_modelChanged);
    _modelFocus.addListener(_focusChanged);
    _proxyAddress.addListener(_proxyFieldChanged);
    _proxyUsername.addListener(_proxyFieldChanged);
    _proxyPassword.addListener(_proxyPasswordChanged);
    if (_appSettings.isLoaded.value) {
      _hydrateProxy();
    } else {
      unawaited(
        _appSettings.ready.then((_) {
          if (mounted) setState(_hydrateProxy);
        }),
      );
    }
    if (_settings.isLoaded.value) {
      _hydrateAi();
    } else {
      unawaited(
        _settings.ready.then((_) {
          if (mounted) setState(_hydrateAi);
        }),
      );
    }
  }

  void _hydrateAi() {
    _config = _settings.state.value.apiConfig;
    _syncAiFields(_config);
    _models = List.of(_config?.cachedModels ?? const []);
    _aiHydrated = true;
  }

  void _hydrateProxy() {
    _syncProxyFields(_appSettings.proxySettings.value);
    _proxyHydrated = true;
  }

  void _syncAiFields(AiModelConfig? config) {
    _updating = true;
    _format = config?.format ?? AiApiFormat.openai;
    _url.text = config?.baseUrl ?? '';
    _model.text = config?.model ?? '';
    _lastModelText = _model.text;
    _updating = false;
  }

  void _syncProxyFields(AppProxySettings settings) {
    _updatingProxy = true;
    _proxyMode = settings.mode;
    _proxyProtocol = settings.protocol;
    _proxyAddress.text = settings.address;
    _proxyUsername.text = settings.username;
    _proxyPassword.clear();
    _hasSavedProxyPassword = settings.hasSavedPassword;
    _clearSavedProxyPassword = false;
    _updatingProxy = false;
  }

  void _proxyFieldChanged() {
    if (_updatingProxy) return;
    if (_proxyError != null || _proxySuccess != null) {
      setState(() {
        _proxyError = null;
        _proxySuccess = null;
      });
    }
  }

  void _proxyPasswordChanged() {
    if (_updatingProxy) return;
    setState(() {
      if (_proxyPassword.text.isNotEmpty) {
        _clearSavedProxyPassword = false;
      }
      _proxyError = null;
      _proxySuccess = null;
    });
  }

  void _invalidateModels() {
    if (_updating) return;
    ++_refreshGeneration;
    setState(() {
      _models = const [];
      _modelsError = null;
      _refreshing = false;
      _showAllModels = false;
      _success = null;
      _error = null;
    });
  }

  void _modelChanged() {
    if (_updating || _lastModelText == _model.text) return;
    _lastModelText = _model.text;
    setState(() {
      _showAllModels = false;
      _success = null;
      _error = null;
    });
  }

  void _focusChanged() => setState(() {});

  @override
  void dispose() {
    _url.removeListener(_invalidateModels);
    _key.removeListener(_invalidateModels);
    _model.removeListener(_modelChanged);
    _modelFocus.removeListener(_focusChanged);
    _proxyAddress.removeListener(_proxyFieldChanged);
    _proxyUsername.removeListener(_proxyFieldChanged);
    _proxyPassword.removeListener(_proxyPasswordChanged);
    _modelFocus.dispose();
    for (final controller in [
      _url,
      _model,
      _key,
      _proxyAddress,
      _proxyUsername,
      _proxyPassword,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _selectProxyMode(AppProxyMode mode) {
    if (_busy) return;
    setState(() {
      _proxyMode = mode;
      _proxyError = null;
      _proxySuccess = null;
    });
  }

  Future<void> _saveProxy() async {
    if (_busy) return;
    if (_proxyMode == AppProxyMode.manual &&
        !(_proxyForm.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _proxyError = null;
      _proxySuccess = null;
    });
    try {
      await _appSettings.saveProxySettings(
        mode: _proxyMode,
        protocol: _proxyProtocol,
        address: _proxyAddress.text,
        username: _proxyUsername.text,
        password: _proxyPassword.text,
        clearPassword: _clearSavedProxyPassword,
      );
      if (!mounted) return;
      _syncProxyFields(_appSettings.proxySettings.value);
      setState(() => _proxySuccess = '代理设置已保存');
    } on ProxySettingsException catch (e) {
      if (mounted) setState(() => _proxyError = e.message);
    }
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    _modelFocus.unfocus();
    ++_refreshGeneration;
    setState(() {
      _saving = true;
      _refreshing = false;
      _error = null;
      _success = null;
    });
    try {
      await _settings.saveApi(
        format: _format,
        baseUrl: _url.text,
        defaultModel: _model.text,
        apiKey: _key.text,
        cachedModels: _models,
      );
      if (!mounted) return;
      _config = _settings.state.value.apiConfig;
      _updating = true;
      _key.clear();
      _updating = false;
      setState(() => _success = 'AI 设置已保存');
    } on AiSettingsException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '必填'.tr : null;

  Future<void> _test() async {
    if (_busy) return;
    _modelFocus.unfocus();
    ++_refreshGeneration;
    setState(() {
      _testing = true;
      _refreshing = false;
      _success = null;
      _error = null;
    });
    try {
      await Get.find<AgentController>().testConnection(
        AiModelConfig(
          id: _config?.id ?? '',
          name: _format.label,
          format: _format,
          baseUrl: _url.text.trim(),
          model: _model.text.trim(),
          secretRef: _config?.secretRef ?? '',
        ),
        apiKey: _key.text,
      );
      if (mounted) setState(() => _success = 'AI 模型连接成功');
    } on AgentApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) setState(() => _error = 'AI 请求失败，请检查模型配置或凭据存储');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _refreshModels() async {
    if (_busy || _refreshing) return;
    final generation = ++_refreshGeneration;
    setState(() {
      _refreshing = true;
      _modelsError = null;
      _models = const [];
    });
    try {
      final models = await Get.find<AgentController>().fetchModels(
        format: _format,
        baseUrl: _url.text,
        apiKey: _key.text,
        modelConfigId: _config?.id,
      );
      final ids = models.map((model) => model.id).toList();
      if (!mounted || generation != _refreshGeneration) return;
      final saved = _config;
      if (saved != null &&
          _key.text.trim().isEmpty &&
          saved.format == _format &&
          AiModelConfig.modelsEndpoint(saved.baseUrl) ==
              AiModelConfig.modelsEndpoint(_url.text.trim())) {
        try {
          await _settings.updateCachedModels(saved.id, ids);
          if (mounted && generation == _refreshGeneration) {
            _config = _settings.state.value.apiConfig;
          }
        } on Object {
          // 缓存保存失败不阻断当前表单下拉选择。
        }
      }
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _models = ids;
        _showAllModels = true;
        if (_models.isEmpty) _modelsError = '服务商未返回可用模型，可手动填写模型 ID';
      });
      if (_models.isNotEmpty) _modelFocus.requestFocus();
    } on AgentApiException catch (e) {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _modelsError = e.message);
      }
    } finally {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _refreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final aiReady = _aiHydrated && !_settings.loadFailed.value;
    final proxyReady = _proxyHydrated && !_appSettings.proxyLoadFailed.value;
    final savingProxy = _appSettings.savingProxySettings.value;
    final savingQuickCommands = _appSettings.savingQuickCommands.value;
    final busy = _saving || _testing || savingProxy || savingQuickCommands;
    final feedback = switch (_tab) {
      SettingsTab.proxy => _feedbackBanner(context, _proxyError, _proxySuccess),
      SettingsTab.ai => _feedbackBanner(context, _error, _success),
      _ => null,
    };
    return PopScope(
      canPop: !_saving && !savingProxy && !savingQuickCommands,
      child: AppDialog(
        maxWidth: AppTheme.settingsDialogMaxWidth,
        title: Text('设置'.tr),
        scrollable: true,
        feedback: feedback,
        scrollKey: ValueKey(_tab),
        header: shadcn.Tabs(
          key: const ValueKey('settings-tabs'),
          index: _tab.index,
          expand: true,
          padding: AppTheme.settingsTabPadding,
          onChanged: (value) {
            if (!busy) setState(() => _tab = SettingsTab.values[value]);
          },
          children: [
            for (final tab in SettingsTab.values)
              shadcn.TabItem(
                child: Text(
                  tab.label.tr,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_tab == SettingsTab.general)
              _GeneralSettings(
                onLocaleChanged: () {
                  if (mounted) setState(() {});
                },
              )
            else if (_tab == SettingsTab.terminal)
              const TerminalSettingsSection()
            else if (_tab == SettingsTab.quickCommands)
              const QuickCommandsSettingsSection()
            else if (_tab == SettingsTab.proxy)
              _proxySection(context, busy: busy)
            else if (_tab == SettingsTab.about)
              const AboutSettingsSection()
            else if (!_aiHydrated)
              const Center(child: shadcn.CircularProgressIndicator())
            else if (_settings.loadFailed.value)
              Column(
                children: [
                  Text('AI 设置读取失败，请重试'.tr),
                  if (_settings.loadError.value case final failure?) ...[
                    const SizedBox(height: 6),
                    Text(
                      failure.key.trParams(failure.params),
                      style: TextStyle(
                        fontSize: 12,
                        color: shadcn.Theme.of(context)
                            .colorScheme
                            .mutedForeground,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  shadcn.OutlineButton(
                    onPressed: () async {
                      try {
                        await _settings.reload();
                        if (mounted) setState(_hydrateAi);
                      } on Object {
                        AppNotice.error('AI 设置读取失败，请重试');
                      }
                    },
                    child: Text('重试'.tr),
                  ),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _aiForm(context, busy: busy),
                  if (Get.isRegistered<McpServerController>()) ...[
                    const SizedBox(height: 24),
                    Container(height: 1, color: AppTheme.border(context)),
                    const SizedBox(height: 20),
                    const McpSettingsSection(),
                  ],
                ],
              ),
          ],
        ),
        actions: [
          shadcn.OutlineButton(
            onPressed: _saving || savingProxy || savingQuickCommands
                ? null
                : AppNavigation.closeDialog<void>,
            child: Text('关闭'.tr),
          ),
          if (_tab == SettingsTab.proxy && proxyReady)
            shadcn.PrimaryButton(
              key: const ValueKey('proxy-save'),
              onPressed: busy ? null : _saveProxy,
              child: Text((savingProxy ? '保存中' : '保存').tr),
            ),
          if (_tab == SettingsTab.ai && aiReady)
            shadcn.OutlineButton(
              key: const ValueKey('ai-model-test'),
              onPressed: busy ? null : _test,
              child: Text((_testing ? '正在测试' : '测试连接').tr),
            ),
          if (_tab == SettingsTab.ai && aiReady)
            shadcn.PrimaryButton(
              key: const ValueKey('ai-model-save'),
              onPressed: busy ? null : _save,
              child: Text((_saving ? '保存中' : '保存').tr),
            ),
        ],
      ),
    );
  });

  Widget? _feedbackBanner(
    BuildContext context,
    String? error,
    String? success,
  ) {
    if (error != null) {
      return Text(
        error.tr,
        style: TextStyle(
          color: shadcn.Theme.of(context).colorScheme.destructive,
        ),
      );
    }
    if (success == null) return null;
    return Row(
      children: [
        const AppIcon(
          AppIcons.circleCheck,
          size: AppTheme.inputIconSize,
          color: StatusColors.ready,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(success.tr)),
      ],
    );
  }

  Widget _proxySection(BuildContext context, {required bool busy}) {
    if (!_proxyHydrated) {
      return const Center(child: shadcn.CircularProgressIndicator());
    }
    if (_appSettings.proxyLoadFailed.value) {
      return Column(
        children: [
          Text('代理设置读取失败，请重试'.tr),
          if (_appSettings.proxyLoadError.value case final failure?) ...[
            const SizedBox(height: 6),
            Text(
              failure.key.trParams(failure.params),
              style: TextStyle(
                fontSize: 12,
                color: shadcn.Theme.of(context).colorScheme.mutedForeground,
              ),
            ),
          ],
          const SizedBox(height: 12),
          shadcn.OutlineButton(
            onPressed: () async {
              try {
                await _appSettings.reloadProxySettings();
                if (mounted) setState(_hydrateProxy);
              } on Object {
                AppNotice.error('代理设置读取失败，请重试');
              }
            },
            child: Text('重试'.tr),
          ),
        ],
      );
    }
    final muted = shadcn.Theme.of(context).colorScheme.mutedForeground;
    final modeHint = switch (_proxyMode) {
      AppProxyMode.auto => '自动使用系统代理，未配置系统代理时直接连接。',
      AppProxyMode.off => '不使用代理，直接发起网络请求。',
      AppProxyMode.manual => '通过指定的代理服务器发起应用内网络请求。',
    };
    return Form(
      key: _proxyForm,
      child: Column(
        key: const ValueKey('proxy-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppRadioCardField<AppProxyMode>(
            key: ValueKey('proxy-mode-${_proxyMode.name}'),
            label: '代理模式'.tr,
            initialValue: _proxyMode,
            items: [
              AppRadioCardOption(
                value: AppProxyMode.auto,
                child: Text('自动'.tr),
              ),
              AppRadioCardOption(
                value: AppProxyMode.off,
                child: Text('关闭代理'.tr),
              ),
              AppRadioCardOption(
                value: AppProxyMode.manual,
                child: Text('手动设置'.tr),
              ),
            ],
            onChanged: busy ? null : _selectProxyMode,
          ),
          const SizedBox(height: 12),
          Text(
            modeHint.tr,
            style: TextStyle(fontSize: 12, height: 1.6, color: muted),
          ),
          if (_proxyMode == AppProxyMode.manual) ...[
            const SizedBox(height: 20),
            AppSelectField<AppProxyProtocol>(
              key: ValueKey('proxy-protocol-${_proxyProtocol.name}'),
              label: '代理协议'.tr,
              initialValue: _proxyProtocol,
              items: [
                for (final protocol in AppProxyProtocol.values)
                  AppSelectOption(value: protocol, child: Text(protocol.label)),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _proxyProtocol = value;
                        _proxyError = null;
                        _proxySuccess = null;
                      });
                    },
            ),
            const SizedBox(height: 16),
            AppTextFormField(
              key: const ValueKey('proxy-address'),
              controller: _proxyAddress,
              enabled: !busy,
              smartPunctuation: false,
              autocorrect: false,
              decoration: AppInputDecoration(
                labelText: '代理地址'.tr,
                hintText: '127.0.0.1:7890',
                helperText: '填写主机与端口，例如 127.0.0.1:7890'.tr,
              ),
              validator: (value) =>
                  AppProxySettings.validateAddress(value ?? '')?.tr,
            ),
            const SizedBox(height: 16),
            AppTextFormField(
              key: const ValueKey('proxy-username'),
              controller: _proxyUsername,
              enabled: !busy,
              smartPunctuation: false,
              autocorrect: false,
              decoration: AppInputDecoration(
                labelText: '用户名'.tr,
                hintText: '可选'.tr,
              ),
              validator: (value) =>
                  AppProxySettings.validateCredential(value ?? '')?.tr,
            ),
            const SizedBox(height: 16),
            AppTextFormField(
              key: const ValueKey('proxy-password'),
              controller: _proxyPassword,
              enabled: !busy,
              obscureText: _obscureProxyPassword,
              enableSuggestions: false,
              autocorrect: false,
              smartPunctuation: false,
              decoration: AppInputDecoration(
                labelText: '密码'.tr,
                hintText: '可选'.tr,
                labelTrailing:
                    _hasSavedProxyPassword &&
                        !_clearSavedProxyPassword &&
                        _proxyPassword.text.isEmpty
                    ? AppIconButton(
                        key: const ValueKey('proxy-password-clear'),
                        density: shadcn.ButtonDensity.compact,
                        icon: const AppIcon(
                          AppIcons.x,
                          size: AppTheme.inputIconSize,
                        ),
                        semanticLabel: '清除已保存密码'.tr,
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                _clearSavedProxyPassword = true;
                                _proxyError = null;
                                _proxySuccess = null;
                              }),
                      )
                    : null,
                helperText:
                    (_clearSavedProxyPassword
                            ? '将在保存后清除已保存密码'
                            : _hasSavedProxyPassword
                            ? '留空则保持不变'
                            : '仅加密保存在本机，留空表示无需认证')
                        .tr,
                suffixIcon: AppIconButton(
                  key: const ValueKey('proxy-password-visibility'),
                  density: shadcn.ButtonDensity.compact,
                  icon: AppIcon(
                    _obscureProxyPassword ? AppIcons.eyeOff : AppIcons.eye,
                    size: AppTheme.inputIconSize,
                  ),
                  semanticLabel: (_obscureProxyPassword ? '显示密码' : '隐藏密码').tr,
                  onPressed: busy
                      ? null
                      : () => setState(
                          () => _obscureProxyPassword = !_obscureProxyPassword,
                        ),
                ),
              ),
              validator: (value) =>
                  AppProxySettings.validateCredential(value ?? '')?.tr,
            ),
          ],
        ],
      ),
    );
  }

  Widget _aiForm(BuildContext context, {required bool busy}) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '使用你自己的第三方 API。聊天内容和主动共享的会话信息会发送到所选服务，API Key 加密保存在本机。'.tr,
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: shadcn.Theme.of(context).colorScheme.mutedForeground,
          ),
        ),
        const SizedBox(height: 16),
        AppSelectField<AiApiFormat>(
          key: const ValueKey('ai-model-format'),
          label: 'API 协议'.tr,
          initialValue: _format,
          items: [
            for (final format in AiApiFormat.values)
              AppSelectOption(value: format, child: Text(format.label)),
          ],
          onChanged: busy
              ? null
              : (value) {
                  if (value == null) return;
                  _invalidateModels();
                  setState(() => _format = value);
                },
        ),
        const SizedBox(height: 16),
        AppTextFormField(
          key: const ValueKey('ai-model-url'),
          controller: _url,
          enabled: !busy,
          smartPunctuation: false,
          autocorrect: false,
          decoration: AppInputDecoration(
            labelText: 'API 地址'.tr,
            hintText: _format == AiApiFormat.anthropic
                ? 'https://api.anthropic.com/v1'
                : 'https://api.openai.com/v1',
            helperText: '支持根地址、/v1 或完整接口地址；本机代理可使用 HTTP。'.tr,
          ),
          validator: (value) => AiModelConfig.validateEndpoint(value ?? '')?.tr,
        ),
        const SizedBox(height: 16),
        AppTextFormField(
          key: const ValueKey('ai-model-key'),
          controller: _key,
          enabled: !busy,
          obscureText: _obscureKey,
          enableSuggestions: false,
          autocorrect: false,
          smartPunctuation: false,
          decoration: AppInputDecoration(
            labelText: 'API Key',
            helperText: (_config == null ? '仅加密保存在本机' : '留空保留原 API Key').tr,
            suffixIcon: AppIconButton(
              key: const ValueKey('ai-model-key-visibility'),
              density: shadcn.ButtonDensity.compact,
              icon: AppIcon(
                _obscureKey ? AppIcons.eyeOff : AppIcons.eye,
                size: AppTheme.inputIconSize,
              ),
              semanticLabel: (_obscureKey ? '显示 API Key' : '隐藏 API Key').tr,
              onPressed: busy
                  ? null
                  : () => setState(() => _obscureKey = !_obscureKey),
            ),
          ),
          validator: _config == null ? _required : null,
        ),
        const SizedBox(height: 16),
        shadcn.AutoComplete(
          theme: const shadcn.AutoCompleteTheme(
            mode: shadcn.AutoCompleteMode.replaceAll,
            popoverConstraints: BoxConstraints(maxHeight: 200),
          ),
          suggestions: !busy && _modelFocus.hasFocus
              ? _models
                    .where(
                      (model) =>
                          _showAllModels ||
                          (model != _model.text &&
                              model.toLowerCase().contains(
                                _model.text.toLowerCase(),
                              )),
                    )
                    .toList()
              : const [],
          child: AppTextFormField(
            key: const ValueKey('ai-model-id'),
            controller: _model,
            focusNode: _modelFocus,
            enabled: !busy,
            smartPunctuation: false,
            autocorrect: false,
            decoration: AppInputDecoration(
              labelText: '默认模型 ID'.tr,
              labelTrailing: AppIconButton(
                key: const ValueKey('ai-model-refresh'),
                density: shadcn.ButtonDensity.compact,
                icon: _refreshing
                    ? const SizedBox.square(
                        dimension: AppTheme.inputIconSize,
                        child: shadcn.CircularProgressIndicator(),
                      )
                    : const AppIcon(
                        AppIcons.refreshCw,
                        size: AppTheme.inputIconSize,
                      ),
                semanticLabel: (_refreshing ? '正在获取模型' : '刷新模型列表').tr,
                onPressed: busy || _refreshing ? null : _refreshModels,
              ),
              helperText: '从下拉列表选择，或手动填写模型 ID'.tr,
              suffixIcon: AppIconButton(
                key: const ValueKey('ai-model-options'),
                density: shadcn.ButtonDensity.compact,
                icon: const AppIcon(
                  AppIcons.chevronDown,
                  size: AppTheme.inputIconSize,
                ),
                semanticLabel: '选择模型'.tr,
                onPressed: busy || _models.isEmpty
                    ? null
                    : () {
                        _modelFocus.requestFocus();
                        setState(() => _showAllModels = true);
                      },
              ),
            ),
            validator: _required,
          ),
        ),
        if (_modelsError != null) ...[
          const SizedBox(height: 8),
          Text(
            _modelsError!.tr,
            style: TextStyle(
              fontSize: 12,
              color: shadcn.Theme.of(context).colorScheme.destructive,
            ),
          ),
        ],
      ],
    ),
  );
}

class _GeneralSettings extends StatelessWidget {
  const _GeneralSettings({required this.onLocaleChanged});

  final VoidCallback onLocaleChanged;

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();
    final muted = shadcn.Theme.of(context).colorScheme.mutedForeground;
    final trayLabel = '关闭时最小化到托盘'.tr;
    final rdpLabel = 'RDP 性能模式'.tr;
    return Obx(
      () => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSelectField<AppThemeMode>(
            key: ValueKey(settings.themeMode.value),
            label: '主题模式'.tr,
            initialValue: settings.themeMode.value,
            items: [
              for (final option in [
                (AppThemeMode.system, '自动'),
                (AppThemeMode.light, '浅色'),
                (AppThemeMode.dark, '深色'),
              ])
                AppSelectOption(value: option.$1, child: Text(option.$2.tr)),
            ],
            onChanged: (value) async {
              if (value == null) return;
              try {
                await settings.setThemeMode(value);
              } on Object {
                AppNotice.error('主题模式保存失败，请重试');
              }
            },
          ),
          const SizedBox(height: 20),
          AppSelectField<Locale>(
            label: '语言'.tr,
            initialValue:
                AppTranslations.supportedLocales
                    .where(
                      (locale) =>
                          locale.languageCode == settings.languageCode.value,
                    )
                    .firstOrNull ??
                Get.locale ??
                AppTranslations.defaultLocale,
            items: const [
              AppSelectOption(
                value: AppTranslations.defaultLocale,
                child: Text('简体中文'),
              ),
              AppSelectOption(
                value: AppTranslations.englishLocale,
                child: Text('English'),
              ),
            ],
            onChanged: settings.savingLanguage.value
                ? null
                : (value) async {
                    if (value == null) return;
                    try {
                      await settings.setLanguageCode(value.languageCode);
                      if (settings.languageCode.value != value.languageCode) {
                        return;
                      }
                      await Get.updateLocale(value);
                      if (Get.isRegistered<SystemTrayController>()) {
                        Get.find<SystemTrayController>().refreshMenu();
                      }
                      onLocaleChanged();
                    } on Object {
                      AppNotice.error('语言设置保存失败，请重试');
                    }
                  },
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rdpLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '重新连接后请求远端关闭壁纸、主题特效和光标阴影。'.tr,
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Semantics(
                label: rdpLabel,
                child: shadcn.Switch(
                  key: const ValueKey('rdp-performance-mode'),
                  value: settings.rdpPerformanceMode.value,
                  onChanged: settings.savingRdpPerformanceMode.value
                      ? null
                      : (value) async {
                          try {
                            await settings.setRdpPerformanceMode(value);
                          } on Object {
                            AppNotice.error('RDP 性能模式保存失败，请重试');
                          }
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trayLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '开启后点击关闭按钮不会退出应用，而是隐藏窗口并在系统托盘保持后台运行（端口转发、动态代理与本地 MCP 服务不受影响）。'
                          .tr,
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Semantics(
                label: trayLabel,
                child: shadcn.Switch(
                  key: const ValueKey('minimize-to-tray-on-close'),
                  value: settings.minimizeToTrayOnClose.value,
                  onChanged: settings.savingMinimizeToTrayOnClose.value
                      ? null
                      : (value) async {
                          try {
                            await settings.setMinimizeToTrayOnClose(value);
                          } on Object {
                            AppNotice.error('保存失败，请重试');
                          }
                        },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
