import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../../domain/ssh/host_key.dart';
import '../components/app_dialog.dart';
import '../navigation/app_navigation.dart';
import 'rdp_password_dialog.dart';

/// Serialize RDP certificate and password prompts across all session tabs.
/// Closing/cancelling a session removes only its own modal route.
class RdpCertificatePrompts extends StatefulWidget {
  const RdpCertificatePrompts({
    required this.sessions,
    required this.controller,
    required this.child,
    super.key,
  });

  final List<Session> sessions;
  final SessionController controller;
  final Widget child;

  @override
  State<RdpCertificatePrompts> createState() => _RdpCertificatePromptsState();
}

class _RdpCertificatePromptsState extends State<RdpCertificatePrompts> {
  Session? _showing;
  ModalRoute<dynamic>? _route;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(RdpCertificatePrompts oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  bool _stillPending(Session session) => widget.sessions.any(
    (s) =>
        s.id == session.id &&
        s.phase == session.phase &&
        (session.phase == SessionPhase.credentialsPending
            ? identical(s.passwordRequest, session.passwordRequest)
            : identical(s.hostKeyReview, session.hostKeyReview)),
  );

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_sync());
    });
  }

  Future<void> _sync() async {
    final showing = _showing;
    if (showing != null) {
      if (!_stillPending(showing)) _dismiss();
      return;
    }
    final pending = widget.sessions.where(
      (s) =>
          (s.phase == SessionPhase.hostKeyPending &&
              s.hostKeyReview?.presented.isRdp == true) ||
          (s.phase == SessionPhase.credentialsPending &&
              s.passwordRequest != null),
    );
    if (pending.isEmpty) return;
    final session = pending.first;
    _showing = session;
    final request = session.passwordRequest;
    final decision = await AppNavigation.dialog<Object>(
      Builder(
        builder: (context) {
          final route = ModalRoute.of(context);
          // A previous dialog may rebuild during its exit transition. It must
          // not replace the route belonging to the next prompt in the queue.
          if (identical(_showing, session)) _route = route;
          // The session can close after the route is pushed but before its
          // first build. Recheck once the route can actually be removed.
          if (!mounted || !_stillPending(session)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (route != null && route.isActive) {
                route.navigator?.removeRoute(route);
              }
            });
          }
          if (request != null) {
            return RdpPasswordDialog(
              request: request,
              onDecision: (value) => Navigator.of(context).pop(value),
            );
          }
          return RdpCertificateDialog(
            review: session.hostKeyReview!,
            onDecision: (value) => Navigator.of(context).pop(value),
          );
        },
      ),
    );
    _route = null;
    if (mounted && _stillPending(session)) {
      if (request != null) {
        widget.controller.confirmRdpPassword(
          session.id,
          request: request,
          password: decision is String ? decision : null,
        );
      } else {
        widget.controller.confirmHostKey(session.id, trust: decision == true);
      }
    }
    _showing = null;
    if (mounted) _schedule();
  }

  void _dismiss() {
    final route = _route;
    _route = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  @override
  void dispose() {
    // Navigator may be building while the workspace is being disposed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _dismiss());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class RdpCertificateDialog extends StatefulWidget {
  const RdpCertificateDialog({
    required this.review,
    required this.onDecision,
    super.key,
  });

  final HostKeyReview review;
  final ValueChanged<bool> onDecision;

  @override
  State<RdpCertificateDialog> createState() => _RdpCertificateDialogState();
}

class _RdpCertificateDialogState extends State<RdpCertificateDialog> {
  bool _details = false;

  String _reason(String code) => switch (code) {
    'unknownIssuer' => '无法将此证书验证到受信任的根证书。'.tr,
    'expired' => '服务器证书已过期。'.tr,
    'notValidYet' => '服务器证书尚未生效。'.tr,
    'nameMismatch' => '服务器证书中的名称与连接地址不匹配。'.tr,
    'trustStoreUnavailable' => '无法读取本机受信任的根证书。'.tr,
    _ => '服务器证书未通过验证。'.tr,
  };

  @override
  Widget build(BuildContext context) {
    final review = widget.review;
    final key = review.presented;
    final warning = review.hasChanged || key.certificateError != null;
    return AppDialog(
      maxWidth: 620,
      scrollable: true,
      title: Text((warning ? '无法验证 RDP 服务器身份' : '确认 RDP 服务器身份').tr),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            shadcn.LucideIcons.shieldAlert,
            size: 40,
            color: shadcn.Theme.of(context).colorScheme.destructive,
          ),
          const SizedBox(height: 16),
          Text(
            '正在连接 RDP 主机“@host”。你的连接可能不安全，是否继续？'.trParams({
              'host': '${key.hostname}:${key.port}',
            }),
          ),
          const SizedBox(height: 12),
          if (key.certificateError != null)
            Text(_reason(key.certificateError!)),
          if (review.hasChanged) Text('服务器证书与已保存记录不一致，可能存在中间人攻击或服务器重装。'.tr),
          if (!warning) Text('尚未保存此服务器的证书，请通过可信渠道核对指纹。'.tr),
          const SizedBox(height: 12),
          Text(
            (warning
                    ? '确认前不会发送 Windows 登录凭据。继续仅允许本次证书例外，不会覆盖已保存的证书。'
                    : '请通过可信渠道与服务器管理员核对下方 SHA-256 指纹。确认后保存可信记录，后续连接自动校验。')
                .tr,
          ),
          if (_details) ...[
            const SizedBox(height: 16),
            shadcn.SelectableText(
              '${key.hostname}:${key.port} · ${key.keyType}',
            ),
            if (review.hasChanged) ...[
              const SizedBox(height: 12),
              Text('已保存指纹'.tr),
              shadcn.SelectableText(review.trusted!.fingerprint),
            ],
            const SizedBox(height: 12),
            Text('服务器指纹'.tr),
            shadcn.SelectableText(key.fingerprint),
          ],
        ],
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => setState(() => _details = !_details),
          child: Text((_details ? '隐藏证书' : '显示证书').tr),
        ),
        shadcn.OutlineButton(
          onPressed: () => widget.onDecision(false),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(
          onPressed: () => widget.onDecision(true),
          child: Text('继续连接'.tr),
        ),
      ],
    );
  }
}
