import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/proxy/v2ray_extension_config.dart';
import '../../domain/entities/proxy_config.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/export_file.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'proxy_export_code.dart';

class V2RayExtensionDialog extends StatefulWidget {
  const V2RayExtensionDialog({required this.config, super.key});

  final V2RayExtensionConfig config;

  @override
  State<V2RayExtensionDialog> createState() => _V2RayExtensionDialogState();
}

class _V2RayExtensionDialogState extends State<V2RayExtensionDialog> {
  static const _maxFileBytes = 8 * 1024 * 1024;
  late final _standalone = widget.config.source;
  String? _merged;
  bool _copied = false;
  bool _busy = false;

  String get _source => _merged ?? _standalone;

  Future<void> _merge() async {
    final config = widget.config;
    setState(() => _busy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (file == null || !mounted) return;
      if (await file.length() > _maxFileBytes) {
        throw const V2RayConfigException('V2Ray 配置文件不能超过 8 MiB');
      }
      final merged = config.mergeInto(await file.readAsString());
      if (mounted) {
        setState(() {
          _merged = merged;
          _copied = false;
        });
      }
    } on V2RayConfigException catch (error) {
      if (mounted) {
        AppNotice.error(
          error.message.trParams({
            if (error.port case final port?) 'port': '$port',
          }),
        );
      }
    } on Object {
      if (mounted) AppNotice.error('读取 V2Ray 配置失败，请检查文件后重试'.tr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      if (await saveExportFile(utf8.encode(_source), 'PagaShell-v2ray.json') &&
          mounted) {
        AppNotice.success('已保存 V2Ray 配置'.tr);
      }
    } on Object {
      if (mounted) AppNotice.error('保存 V2Ray 配置失败，请重试'.tr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final source = _source;
    try {
      await Clipboard.setData(ClipboardData(text: source));
      if (mounted && _source == source) setState(() => _copied = true);
    } on Object {
      if (mounted) AppNotice.error('复制失败，请重试'.tr);
    }
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text('V2Ray 扩展配置'.tr),
    maxWidth: AppTheme.proxyExportDialogMaxWidth,
    scrollable: true,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text(
          '将 JSON 导入 v2rayN 的「自定义配置」，选择 Xray 内核；也可供 V2Ray 直接加载。使用时，请先启动 PagaShell 动态代理。'
              .tr,
        ),
        Text(
          (widget.config.mode == ProxyMode.global
                  ? '全局模式：现有规则未匹配的 TCP 流量通过 PagaShell 网关。'
                  : widget.config.hasRules
                  ? '规则模式：命中的 TCP 流量通过 PagaShell 网关，其余沿用现有分流；独立配置默认直连。'
                  : '尚未配置代理规则，JSON 仅添加 PagaShell 出站，不改变分流。')
              .tr,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            shadcn.OutlineButton(
              key: const ValueKey('v2ray-extension-merge'),
              onPressed: _busy ? null : _merge,
              child: Text('合并现有 JSON'.tr),
            ),
            if (_merged != null)
              shadcn.OutlineButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _merged = null;
                        _copied = false;
                      }),
                child: Text('恢复独立配置'.tr),
              ),
            if (_merged == null)
              Text(
                '本机入口：SOCKS5 @socks / HTTP(S) @http'.trParams({
                  'socks': '${widget.config.socksInboundPort}',
                  'http': '${widget.config.httpInboundPort}',
                }),
              )
            else
              Text('已合并，原文件未修改'.tr),
          ],
        ),
        ProxyExportCode(
          _source,
          codeKey: const ValueKey('v2ray-extension-code'),
        ),
      ],
    ),
    actions: [
      shadcn.OutlineButton(
        onPressed: () => AppNavigation.closeDialog<void>(),
        child: Text('关闭'.tr),
      ),
      shadcn.OutlineButton(
        key: const ValueKey('v2ray-extension-save'),
        onPressed: _busy ? null : _save,
        child: Text('另存为 JSON'.tr),
      ),
      shadcn.PrimaryButton(
        key: const ValueKey('v2ray-extension-copy'),
        onPressed: _busy ? null : _copy,
        leading: AppIcon(_copied ? AppIcons.check : AppIcons.copy, size: 16),
        child: Text((_copied ? '已复制' : '复制 JSON').tr),
      ),
    ],
  );
}
