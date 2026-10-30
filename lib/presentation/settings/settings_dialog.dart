import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_api_codec.dart';
import '../../application/ai/agent_controller.dart';
import '../../application/ai/ai_settings_controller.dart';
import '../../application/settings/settings_controller.dart';
import '../../domain/ai/ai_model.dart';
import '../../domain/entities/app_theme_mode.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../components/app_select_field.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';

Future<void> showSettingsDialog({bool ai = false}) =>
    AppNavigation.dialog<void>(SettingsDialog(initialTab: ai ? 1 : 0));

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({this.initialTab = 0, super.key});
  final int initialTab;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late int _tab = widget.initialTab;
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _modelFocus = FocusNode();
  late final _settings = Get.find<AiSettingsController>();
  AiModelConfig? _config;
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
  bool get _busy => _saving || _testing;

  @override
  void initState() {
    super.initState();
    _url.addListener(_invalidateModels);
    _key.addListener(_invalidateModels);
    _model.addListener(_modelChanged);
    _modelFocus.addListener(_focusChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _settings.ready;
    if (!mounted) return;
    _config = _settings.state.value.apiConfig;
    _updating = true;
    _format = _config?.format ?? AiApiFormat.openai;
    _url.text = _config?.baseUrl ?? '';
    _model.text = _config?.model ?? '';
    _lastModelText = _model.text;
    _updating = false;
    setState(() {});
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
    _modelFocus.dispose();
    for (final controller in [_url, _model, _key]) {
      controller.dispose();
    }
    super.dispose();
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
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _models = models.map((model) => model.id).toList();
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
    final ready = _settings.isLoaded.value && !_settings.loadFailed.value;
    return PopScope(
      canPop: !_saving,
      child: AppDialog(
        maxWidth: AppTheme.settingsDialogMaxWidth,
        title: Text('设置'.tr),
        scrollable: true,
        feedback: _tab != 1 ? null : _feedback(context),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            shadcn.Tabs(
              index: _tab,
              onChanged: (value) {
                if (!_busy) setState(() => _tab = value);
              },
              children: [
                shadcn.TabItem(child: Text('通用'.tr)),
                shadcn.TabItem(child: Text('AI 设置'.tr)),
              ],
            ),
            const SizedBox(height: 24),
            if (_tab == 0)
              _GeneralSettings(
                onLocaleChanged: () {
                  if (mounted) setState(() {});
                },
              )
            else if (!_settings.isLoaded.value)
              const Center(child: shadcn.CircularProgressIndicator())
            else if (_settings.loadFailed.value)
              Column(
                children: [
                  Text('AI 设置读取失败，请重试'.tr),
                  const SizedBox(height: 12),
                  shadcn.OutlineButton(
                    onPressed: () async {
                      try {
                        await _settings.reload();
                        await _initialize();
                      } on Object {
                        AppNotice.error('AI 设置读取失败，请重试');
                      }
                    },
                    child: Text('重试'.tr),
                  ),
                ],
              )
            else
              _aiForm(context),
          ],
        ),
        actions: [
          if (_tab == 1 && ready)
            shadcn.OutlineButton(
              key: const ValueKey('ai-model-test'),
              onPressed: _busy ? null : _test,
              child: Text((_testing ? '正在测试' : '测试连接').tr),
            ),
          if (_tab == 1 && ready)
            shadcn.PrimaryButton(
              key: const ValueKey('ai-model-save'),
              onPressed: _busy ? null : _save,
              child: Text((_saving ? '保存中' : '保存').tr),
            ),
          shadcn.OutlineButton(
            onPressed: _saving ? null : AppNavigation.closeDialog<void>,
            child: Text('关闭'.tr),
          ),
        ],
      ),
    );
  });

  Widget? _feedback(BuildContext context) {
    if (_error != null) {
      return Text(
        _error!.tr,
        style: TextStyle(
          color: shadcn.Theme.of(context).colorScheme.destructive,
        ),
      );
    }
    if (_success == null) return null;
    return Row(
      children: [
        const Icon(
          shadcn.LucideIcons.circleCheck,
          size: AppTheme.inputIconSize,
          color: StatusColors.ready,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(_success!.tr)),
      ],
    );
  }

  Widget _aiForm(BuildContext context) => Form(
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
          onChanged: _busy
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
          enabled: !_busy,
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
          enabled: !_busy,
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
              icon: Icon(
                _obscureKey
                    ? shadcn.LucideIcons.eyeOff
                    : shadcn.LucideIcons.eye,
                size: AppTheme.inputIconSize,
              ),
              semanticLabel: (_obscureKey ? '显示 API Key' : '隐藏 API Key').tr,
              onPressed: _busy
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
          suggestions: !_busy && _modelFocus.hasFocus
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
            enabled: !_busy,
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
                    : const Icon(
                        shadcn.LucideIcons.refreshCw,
                        size: AppTheme.inputIconSize,
                      ),
                semanticLabel: (_refreshing ? '正在获取模型' : '刷新模型列表').tr,
                onPressed: _busy || _refreshing ? null : _refreshModels,
              ),
              helperText: '从下拉列表选择，或手动填写模型 ID'.tr,
              suffixIcon: AppIconButton(
                key: const ValueKey('ai-model-options'),
                density: shadcn.ButtonDensity.compact,
                icon: const Icon(
                  shadcn.LucideIcons.chevronDown,
                  size: AppTheme.inputIconSize,
                ),
                semanticLabel: '选择模型'.tr,
                onPressed: _busy || _models.isEmpty
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
            key: ValueKey(Get.locale),
            label: '语言'.tr,
            initialValue: Get.locale ?? AppTranslations.defaultLocale,
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
            onChanged: (value) async {
              if (value == null) return;
              await Get.updateLocale(value);
              onLocaleChanged();
            },
          ),
        ],
      ),
    );
  }
}
