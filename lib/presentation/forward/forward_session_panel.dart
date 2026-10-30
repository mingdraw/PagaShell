import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/gateways/gateway_controller.dart';
import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../shell/connect_flow.dart';
import '../ssh/host_key_confirmation.dart';

class ForwardSessionPanel extends StatefulWidget {
  const ForwardSessionPanel({required this.session, super.key});
  final Session session;

  @override
  State<ForwardSessionPanel> createState() => _ForwardSessionPanelState();
}

class _PortEditors {
  _PortEditors(ForwardPort? port)
    : local = TextEditingController(text: port?.localPort.toString() ?? ''),
      host = TextEditingController(text: port?.targetHost ?? '127.0.0.1'),
      target = TextEditingController(text: port?.targetPort.toString() ?? '');
  final key = UniqueKey();
  final TextEditingController local;
  final TextEditingController host;
  final TextEditingController target;

  bool get isBlank => local.text.trim().isEmpty && target.text.trim().isEmpty;

  void dispose() {
    local.dispose();
    host.dispose();
    target.dispose();
  }
}

class _ForwardSessionPanelState extends State<ForwardSessionPanel> {
  final _form = GlobalKey<FormState>();
  late final GatewayController _hosts;
  late List<_PortEditors> _ports;
  late List<ForwardPort> _savedPorts;
  final _retired = <_PortEditors>[];
  Timer? _saveTimer;
  Future<Host?>? _pendingSave;
  int _revision = 0;
  bool _dirty = false;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hosts = Get.find<GatewayController>();
    _savedPorts = widget.session.host.forwardPorts;
    _ports = _savedPorts.map(_PortEditors.new).toList();
  }

  @override
  void didUpdateWidget(covariant ForwardSessionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dirty &&
        _pendingSave == null &&
        !_starting &&
        !listEquals(_savedPorts, widget.session.host.forwardPorts)) {
      _savedPorts = widget.session.host.forwardPorts;
      _retired.addAll(_ports);
      _ports = _savedPorts.map(_PortEditors.new).toList();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // 关闭页签前保留最后一份有效输入，避免防抖时间内的修改丢失。
    if (_dirty && !widget.session.phase.isAlive) {
      try {
        final ports = _readPorts();
        if (!listEquals(_savedPorts, ports) || _pendingSave != null) {
          unawaited(_persist(ports));
        }
      } on StateError {
        // 未填完整或无效的草稿不覆盖已保存配置。
      }
    }
    for (final port in [..._ports, ..._retired]) {
      port.dispose();
    }
    super.dispose();
  }

  void _changed() {
    _saveTimer?.cancel();
    setState(() {
      _revision++;
      _dirty = true;
      _error = null;
    });
    _saveTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_save());
    });
  }

  String? _port(String? value) {
    final number = int.tryParse(value?.trim() ?? '');
    return number == null || number < 1 || number > 65535 ? '1-65535' : null;
  }

  List<ForwardPort> _readPorts() {
    final ports = <ForwardPort>[];
    for (final row in _ports) {
      if (row.isBlank) continue;
      final local = int.tryParse(row.local.text.trim());
      final target = int.tryParse(row.target.text.trim());
      if (local == null || target == null) {
        throw StateError('请填写有效的端口（1-65535）');
      }
      ports.add(
        ForwardPort(
          localPort: local,
          targetHost: row.host.text.trim(),
          targetPort: target,
        ),
      );
    }
    ForwardPort.validateAll(ports);
    return ports;
  }

  Future<Host?> _save({bool forStart = false}) async {
    _saveTimer?.cancel();
    if (!mounted || !(_form.currentState?.validate() ?? false)) return null;
    try {
      final ports = _readPorts();
      ForwardPort.validateAll(ports, allowEmpty: !forStart);
      if (!forStart && _pendingSave == null && listEquals(_savedPorts, ports)) {
        setState(() => _dirty = false);
        return null;
      }
      return await _persist(ports);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message.toString());
      return null;
    }
  }

  Future<Host?> _persist(List<ForwardPort> ports) {
    final previous = _pendingSave;
    final revision = _revision;
    final hostId = widget.session.host.id;
    final save = () async {
      // 串行写入，慢写入期间继续输入也不会被较旧的结果覆盖。
      await previous;
      try {
        final saved = await _hosts.saveForwardPorts(hostId, ports);
        _savedPorts = ports;
        if (mounted && revision == _revision) {
          setState(() {
            _dirty = false;
            _error = null;
          });
        }
        return saved;
      } on StateError catch (e) {
        if (mounted && revision == _revision) {
          setState(() => _error = e.message.toString());
        }
      } on Object {
        if (mounted && revision == _revision) {
          setState(() => _error = '保存失败，请重试');
        }
      }
      return null;
    }();
    _pendingSave = save;
    unawaited(
      save.then((_) {
        if (identical(_pendingSave, save)) _pendingSave = null;
      }),
    );
    return save;
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
        kind: SessionKind.portForward,
        forwardSessionId: widget.session.id,
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Widget _mapping(_PortEditors row, {required bool editable}) {
    return Padding(
      key: row.key,
      padding: const EdgeInsets.only(bottom: 12),
      child: shadcn.Card(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final local = AppTextFormField(
              controller: row.local,
              enabled: editable,
              decoration: AppInputDecoration(
                labelText: '本地端口'.tr,
                inlineLabel: true,
              ),
              validator: (value) {
                if (row.isBlank) return null;
                final error = _port(value);
                if (error != null) return error;
                final number = int.parse(value!.trim());
                return _ports
                            .where(
                              (p) =>
                                  int.tryParse(p.local.text.trim()) == number,
                            )
                            .length >
                        1
                    ? '本地端口不能重复'.tr
                    : null;
              },
            );
            final target = AppTextFormField(
              controller: row.target,
              enabled: editable,
              decoration: AppInputDecoration(
                labelText: '目标端口'.tr,
                inlineLabel: true,
              ),
              validator: (value) => row.isBlank ? null : _port(value),
            );
            final host = AppTextFormField(
              controller: row.host,
              enabled: editable,
              decoration: AppInputDecoration(
                labelText: '目标地址'.tr,
                inlineLabel: true,
              ),
              validator: (value) =>
                  row.isBlank || (value?.trim().isNotEmpty ?? false)
                  ? null
                  : '请填写有效的目标地址'.tr,
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: constraints.maxWidth < 720
                      ? Column(
                          children: [
                            local,
                            const SizedBox(height: 12),
                            host,
                            const SizedBox(height: 12),
                            target,
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: local),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(12, 9, 12, 0),
                              child: Icon(
                                shadcn.LucideIcons.arrowRight,
                                size: 16,
                              ),
                            ),
                            Expanded(flex: 2, child: host),
                            const SizedBox(width: 12),
                            Expanded(child: target),
                          ],
                        ),
                ),
                const SizedBox(width: 12),
                AppIconButton(
                  icon: const Icon(shadcn.LucideIcons.trash2, size: 16),
                  semanticLabel: '移除映射'.tr,
                  onPressed: editable
                      ? () {
                          setState(() {
                            _ports.remove(row);
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
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final running = session.phase == SessionPhase.ready;
    final stopping = session.phase == SessionPhase.stopping;
    final busy = session.phase.isBusy || _starting;
    final editable = !session.phase.isAlive && !_starting;
    final colors = shadcn.Theme.of(context).colorScheme;
    final status = switch (session.phase) {
      SessionPhase.ready => '正在监听',
      SessionPhase.failed => '转发失败',
      SessionPhase.closed => '未启用',
      SessionPhase.stopping => '正在停止',
      SessionPhase.hostKeyPending => '等待确认主机指纹',
      _ => '正在连接',
    };
    final controller = Get.find<SessionController>();
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
              const Icon(shadcn.LucideIcons.arrowLeftRight, size: 22),
              Text(
                '端口转发'.tr,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              shadcn.OutlineBadge(child: Text(status.tr)),
            ],
          ),
          const SizedBox(height: 12),
          Obx(() {
            final host =
                _hosts.hosts.firstWhereOrNull((h) => h.id == session.host.id) ??
                session.host;
            return Text(
              '关联网关：@name'.trParams({'name': host.name}),
              overflow: TextOverflow.ellipsis,
            );
          }),
          const SizedBox(height: 8),
          Text(
            (session.host.gatewayType == GatewayType.page
                    ? '目标地址由内网 Client 访问，127.0.0.1 指 Client 本机'
                    : '目标地址由 SSH 网关访问，127.0.0.1 指网关本机')
                .tr,
            style: TextStyle(color: colors.mutedForeground, fontSize: 12),
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
                        padding: const EdgeInsets.only(bottom: 12),
                        child: HostKeyConfirmation(
                          review: session.hostKeyReview!,
                          onDecision: (trust) => controller.confirmHostKey(
                            session.id,
                            trust: trust,
                          ),
                        ),
                      ),
                    if (_ports.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          '暂无端口映射，添加后可手动启动转发'.tr,
                          style: TextStyle(color: colors.mutedForeground),
                        ),
                      ),
                    for (final row in _ports) _mapping(row, editable: editable),
                  ],
                ),
              ),
            ),
          ),
          if (_error != null || session.error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error?.tr ?? AppTranslations.error(session.error!),
              style: TextStyle(color: colors.destructive),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              shadcn.OutlineButton(
                leading: const Icon(shadcn.LucideIcons.plus, size: 16),
                onPressed: editable
                    ? () {
                        setState(() => _ports.add(_PortEditors(null)));
                        _changed();
                      }
                    : null,
                child: Text('添加映射'.tr),
              ),
              if (running || stopping)
                shadcn.OutlineButton(
                  onPressed: busy
                      ? null
                      : () => controller.stopForward(session.id),
                  child: _ForwardButtonContent(
                    loading: stopping,
                    icon: shadcn.LucideIcons.square,
                    label: '停止转发'.tr,
                  ),
                )
              else
                shadcn.PrimaryButton(
                  onPressed: busy ? null : _start,
                  child: _ForwardButtonContent(
                    loading: busy,
                    icon: shadcn.LucideIcons.play,
                    label: '启动转发'.tr,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ForwardButtonContent extends StatelessWidget {
  const _ForwardButtonContent({
    required this.loading,
    required this.icon,
    required this.label,
  });
  final bool loading;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Opacity(
          opacity: loading ? 0 : 1,
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
          ),
        ),
        if (loading)
          shadcn.ComponentTheme<shadcn.CircularProgressIndicatorTheme>(
            data: shadcn.CircularProgressIndicatorTheme(
              size: 16,
              strokeWidth: 2,
              color: IconTheme.of(context).color,
            ),
            child: const shadcn.CircularProgressIndicator(),
          ),
      ],
    ),
  );
}
