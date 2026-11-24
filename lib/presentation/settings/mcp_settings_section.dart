import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/ai_settings_controller.dart';
import '../../application/mcp/mcp_server_controller.dart';
import '../../domain/mcp/mcp_models.dart';
import '../../domain/mcp/mcp_server_transport.dart';
import '../components/app_copy_button.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_select_field.dart';
import '../components/app_selectable_region.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';

class McpSettingsSection extends StatefulWidget {
  const McpSettingsSection({super.key});

  @override
  State<McpSettingsSection> createState() => _McpSettingsSectionState();
}

class _McpSettingsSectionState extends State<McpSettingsSection> {
  late final McpServerController _mcp = Get.find<McpServerController>();
  late final AiSettingsController _aiSettings =
      Get.find<AiSettingsController>();
  late final TextEditingController _portController;

  bool _revealToken = false;
  bool _auditExpanded = false;
  int _syncedPort = McpServerConfig.defaultPort;
  String? _portError;

  @override
  void initState() {
    super.initState();
    _syncedPort = _mcp.config.port;
    _portController = TextEditingController(text: '$_syncedPort');
    _portController.addListener(_onPortTextChanged);
  }

  @override
  void dispose() {
    _portController.removeListener(_onPortTextChanged);
    _portController.dispose();
    super.dispose();
  }

  void _onPortTextChanged() {
    if (!mounted) return;
    setState(() {
      _portError = McpServerConfig.validatePort(_portController.text);
    });
  }

  Future<void> _toggleEnabled(bool enabled) async {
    try {
      await _mcp.setEnabled(enabled);
      if (!mounted) return;
      AppNotice.success(enabled ? '本地 MCP 服务已启动' : '本地 MCP 服务已停止');
    } on McpServerException catch (error) {
      if (mounted) AppNotice.error(error.message);
    } on AiSettingsException catch (error) {
      if (mounted) AppNotice.error(error.message);
    } on Object {
      if (mounted) AppNotice.error('本地 MCP 服务状态切换失败，请重试');
    }
  }

  Future<void> _applyPort() async {
    final parsed = McpServerConfig.parsePort(_portController.text);
    if (parsed == null) {
      setState(() {
        _portError = McpServerConfig.validatePort(_portController.text);
      });
      return;
    }
    try {
      await _mcp.updatePort(parsed);
      if (!mounted) return;
      _syncedPort = parsed;
      setState(() => _portError = null);
      AppNotice.success('MCP 监听端口已更新');
    } on McpServerException catch (error) {
      if (mounted) AppNotice.error(error.message);
    } on AiSettingsException catch (error) {
      if (mounted) AppNotice.error(error.message);
    } on Object {
      if (mounted) AppNotice.error('MCP 监听端口更新失败，请重试');
    }
  }

  Future<void> _changeAccessMode(McpAccessMode? mode) async {
    if (mode == null) return;
    try {
      await _mcp.setAccessMode(mode);
    } on AiSettingsException catch (error) {
      if (mounted) AppNotice.error(error.message);
    } on Object {
      if (mounted) AppNotice.error('MCP 访问权限保存失败，请重试');
    }
  }

  Future<void> _ensureToken() async {
    try {
      await _mcp.ensureToken();
    } on Object {
      if (mounted) AppNotice.error('无法生成 MCP 令牌，请检查本机凭据存储');
    }
  }

  Future<void> _confirmRotateToken() async {
    final confirmed =
        await AppNavigation.dialog<bool>(
          AppDialog(
            title: Text('重置 MCP 令牌？'.tr),
            content: Text('重置后旧令牌将立即失效，已接入的 Codex 等外部工具需要同步更新配置。'.tr),
            actions: [
              shadcn.OutlineButton(
                onPressed: () => AppNavigation.closeDialog(result: false),
                child: Text('取消'.tr),
              ),
              shadcn.DestructiveButton(
                key: const ValueKey('mcp-token-rotate-confirm'),
                onPressed: () => AppNavigation.closeDialog(result: true),
                child: Text('重置令牌'.tr),
              ),
            ],
          ),
        ) ==
        true;
    if (!confirmed || !mounted) return;
    try {
      await _mcp.rotateToken();
      if (mounted) AppNotice.success('MCP 令牌已重置');
    } on Object {
      if (mounted) AppNotice.error('重置 MCP 令牌失败，请重试');
    }
  }

  Future<void> _copySnippet({required bool codex}) async {
    try {
      final realToken = await _mcp.ensureToken();
      final cfg = _mcp.config;
      final port = _mcp.boundPort.value ?? cfg.port;
      final text = codex
          ? cfg.codexTomlSnippet(realToken, effectivePort: port)
          : cfg.mcpJsonSnippet(realToken, effectivePort: port);
      final copied = await copyAppText(text);
      if (copied && mounted) {
        AppNotice.success(
          codex
              ? '已复制 Codex 配置，可粘贴到 ~/.codex/config.toml'
              : '已复制通用 MCP JSON 配置',
        );
      }
    } on Object {
      if (mounted) AppNotice.error('无法生成 MCP 配置片段，请检查本机凭据存储');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = shadcn.Theme.of(context);
    final colors = theme.colorScheme;
    final muted = colors.mutedForeground;
    final monoStyle = theme.typography.mono;
    final surface = AppTheme.surface(context);
    final borderColor = AppTheme.border(context);

    return Obx(() {
      final config = _aiSettings.state.value.mcp;
      if (config.port != _syncedPort &&
          _portController.text == '$_syncedPort') {
        _syncedPort = config.port;
        _portController.text = '$_syncedPort';
      }
      final running = _mcp.running.value;
      final busy = _mcp.busy.value;
      final clients = _mcp.activeClients.value;
      final statusError = _mcp.statusError.value;
      final tokenValue = _mcp.token.value;
      final endpointUrl = _mcp.endpointUrl;
      final parsedPort = McpServerConfig.parsePort(_portController.text);
      final canApplyPort =
          !busy && parsedPort != null && parsedPort != config.port;
      final logs = _mcp.auditLogs;

      final switchLabel = '启用本地 MCP 服务'.tr;
      final modeHint = switch (config.accessMode) {
        McpAccessMode.fullAccess =>
          '暴露巡检、按需连接、命令执行、配置编辑与回滚工具，操作审批交由外部工具处理；文件修改自动备份，始终拦截凭据文件与明文密码命令。',
        McpAccessMode.readOnly =>
          '仅暴露巡检、文件读取、按需连接与白名单只读命令，拒绝配置写入、回滚、交互终端发送与非只读命令。',
      };
      final previewToken = tokenValue == null
          ? '<token>'
          : _revealToken
          ? tokenValue
          : '••••••••••••••••';
      final codexPreview = config
          .codexTomlSnippet(
            previewToken,
            effectivePort: _mcp.boundPort.value ?? config.port,
          )
          .trimRight();

      return Column(
        key: const ValueKey('mcp-settings-section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '本地 MCP 服务'.tr,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _StatusBadge(running: running, clients: clients),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '允许本机 Codex、Claude Code 等外部工具通过 MCP 协议调用 PagaShell 的 SSH 会话与运维能力。仅监听 127.0.0.1，强制 Bearer 令牌鉴权。'
                          .tr,
                      style: TextStyle(fontSize: 12, height: 1.5, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Semantics(
                label: switchLabel,
                child: shadcn.Switch(
                  key: const ValueKey('mcp-enabled-switch'),
                  value: running || config.enabled,
                  onChanged: busy ? null : _toggleEnabled,
                ),
              ),
            ],
          ),
          if (statusError != null) ...[
            const SizedBox(height: 10),
            Text(
              statusError.tr,
              key: const ValueKey('mcp-status-error'),
              style: TextStyle(fontSize: 12, color: colors.destructive),
            ),
          ],
          const SizedBox(height: 14),
          _InfoBox(
            label: '服务地址'.tr,
            surface: surface,
            borderColor: borderColor,
            trailing: AppCopyButton(
              key: const ValueKey('mcp-endpoint-copy'),
              text: endpointUrl,
              semanticLabel: '复制 MCP 地址'.tr,
            ),
            child: AppSelectableRegion(
              child: Text(
                endpointUrl,
                key: const ValueKey('mcp-endpoint-url'),
                style: monoStyle.copyWith(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: AppTextFormField(
                  key: const ValueKey('mcp-port-input'),
                  controller: _portController,
                  enabled: !busy,
                  smartPunctuation: false,
                  autocorrect: false,
                  decoration: AppInputDecoration(
                    labelText: '监听端口'.tr,
                    hintText: '${McpServerConfig.defaultPort}',
                    helperText: _portError?.tr ?? '范围 1024–65535，默认 47321'.tr,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: shadcn.OutlineButton(
                  key: const ValueKey('mcp-port-apply'),
                  onPressed: canApplyPort ? _applyPort : null,
                  child: Text('应用'.tr),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AppSelectField<McpAccessMode>(
            key: ValueKey('mcp-access-mode-${config.accessMode.name}'),
            label: '访问权限'.tr,
            initialValue: config.accessMode,
            items: [
              AppSelectOption(
                value: McpAccessMode.fullAccess,
                child: Text('完全放行（由外部工具审批）'.tr),
              ),
              AppSelectOption(
                value: McpAccessMode.readOnly,
                child: Text('只读模式'.tr),
              ),
            ],
            onChanged: busy ? null : _changeAccessMode,
          ),
          const SizedBox(height: 6),
          Text(
            modeHint.tr,
            style: TextStyle(fontSize: 12, height: 1.5, color: muted),
          ),
          const SizedBox(height: 14),
          _InfoBox(
            label: 'Bearer 鉴权令牌'.tr,
            surface: surface,
            borderColor: borderColor,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tokenValue != null) ...[
                  AppIconButton(
                    key: const ValueKey('mcp-token-visibility'),
                    density: shadcn.ButtonDensity.compact,
                    semanticLabel: (_revealToken ? '隐藏令牌' : '显示令牌').tr,
                    tooltip: (_revealToken ? '隐藏令牌' : '显示令牌').tr,
                    icon: AppIcon(
                      _revealToken ? AppIcons.eyeOff : AppIcons.eye,
                      size: AppTheme.inputIconSize,
                    ),
                    onPressed: () =>
                        setState(() => _revealToken = !_revealToken),
                  ),
                  AppCopyButton(
                    key: const ValueKey('mcp-token-copy'),
                    text: tokenValue,
                    semanticLabel: '复制令牌'.tr,
                  ),
                  AppIconButton(
                    key: const ValueKey('mcp-token-rotate'),
                    density: shadcn.ButtonDensity.compact,
                    semanticLabel: '重置令牌'.tr,
                    tooltip: '重置令牌'.tr,
                    icon: const AppIcon(
                      AppIcons.refreshCw,
                      size: AppTheme.inputIconSize,
                    ),
                    onPressed: busy ? null : _confirmRotateToken,
                  ),
                ] else
                  AppIconButton(
                    key: const ValueKey('mcp-token-generate'),
                    density: shadcn.ButtonDensity.compact,
                    semanticLabel: '生成令牌'.tr,
                    tooltip: '生成令牌'.tr,
                    icon: const AppIcon(
                      AppIcons.plus,
                      size: AppTheme.inputIconSize,
                    ),
                    onPressed: busy ? null : _ensureToken,
                  ),
              ],
            ),
            child: tokenValue == null
                ? Text(
                    '启用服务时将自动生成并加密保存在本机'.tr,
                    style: TextStyle(fontSize: 12, color: muted),
                  )
                : AppSelectableRegion(
                    child: Text(
                      _revealToken ? tokenValue : '••••••••••••••••••••••••',
                      key: const ValueKey('mcp-token-value'),
                      style: monoStyle.copyWith(fontSize: 12),
                    ),
                  ),
          ),
          const SizedBox(height: 14),
          Text(
            '外部工具接入配置'.tr,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              shadcn.GhostButton(
                key: const ValueKey('mcp-copy-codex'),
                size: shadcn.ButtonSize.small,
                onPressed: busy ? null : () => _copySnippet(codex: true),
                leading: const AppIcon(AppIcons.copy, size: 13),
                child: Text('复制 Codex 配置'.tr),
              ),
              shadcn.GhostButton(
                key: const ValueKey('mcp-copy-json'),
                size: shadcn.ButtonSize.small,
                onPressed: busy ? null : () => _copySnippet(codex: false),
                leading: const AppIcon(AppIcons.code, size: 13),
                child: Text('复制 MCP JSON'.tr),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: AppSelectableRegion(
              child: Text(
                codexPreview,
                key: const ValueKey('mcp-codex-preview'),
                style: monoStyle.copyWith(
                  fontSize: 11,
                  height: 1.45,
                  color: muted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              GestureDetector(
                key: const ValueKey('mcp-audit-toggle'),
                onTap: () => setState(() => _auditExpanded = !_auditExpanded),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(
                        _auditExpanded
                            ? AppIcons.chevronDown
                            : AppIcons.chevronRight,
                        size: 14,
                        color: muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '最近调用记录'.tr,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '(${logs.length})',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (logs.isNotEmpty)
                shadcn.GhostButton(
                  key: const ValueKey('mcp-audit-clear'),
                  density: shadcn.ButtonDensity.compact,
                  onPressed: _mcp.clearAuditLogs,
                  child: Text('清空'.tr),
                ),
            ],
          ),
          if (_auditExpanded) ...[
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('mcp-audit-list'),
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: borderColor),
              ),
              child: logs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '暂无外部工具调用记录'.tr,
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < logs.length; i++) ...[
                            if (i > 0)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: Container(height: 1, color: borderColor),
                              ),
                            _AuditEntryRow(entry: logs[i]),
                          ],
                        ],
                      ),
                    ),
            ),
          ],
        ],
      );
    });
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.running, required this.clients});

  final bool running;
  final int clients;

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final dotColor = running ? StatusColors.ready : colors.mutedForeground;
    final label = !running
        ? '已停止'.tr
        : clients > 0
        ? '运行中 · @count 个客户端'.trParams({'count': '$clients'})
        : '运行中'.tr;
    return Container(
      key: const ValueKey('mcp-status-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: dotColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: running ? StatusColors.ready : colors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({
    required this.label,
    required this.surface,
    required this.borderColor,
    required this.child,
    this.trailing,
  });

  final String label;
  final Color surface;
  final Color borderColor;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Expanded(child: child),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ],
    );
  }
}

class _AuditEntryRow extends StatelessWidget {
  const _AuditEntryRow({required this.entry});

  final McpAuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = shadcn.Theme.of(context);
    final muted = theme.colorScheme.mutedForeground;
    final monoStyle = theme.typography.mono;
    final dotColor = switch (entry.status) {
      McpAuditStatus.success => StatusColors.ready,
      McpAuditStatus.denied => AppTheme.serverStatusWarningColor,
      McpAuditStatus.error => StatusColors.failed,
    };
    final t = entry.timestamp;
    final time =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              entry.toolName,
              style: monoStyle.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (entry.target != null) ...[
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.target!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ),
            ] else
              const Spacer(),
            const SizedBox(width: 6),
            Text(
              '$time · ${entry.durationMs}ms',
              style: monoStyle.copyWith(fontSize: 10, color: muted),
            ),
          ],
        ),
        if (entry.summary.isNotEmpty) ...[
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              entry.summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ),
        ],
      ],
    );
  }
}
