import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/repositories/known_host_repository.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:pagashell/presentation/rdp/rdp_certificate_prompt.dart';
import 'package:pagashell/presentation/rdp/rdp_password_dialog.dart';

import 'support/fake_rdp_engine.dart';
import 'support/shadcn_test_app.dart';

class _NoSsh implements SshEngine {
  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) => throw StateError('unexpected SSH');
}

class _KnownHosts implements KnownHostRepository {
  SshHostKey? saved;
  @override
  Future<SshHostKey?> find(
    String hostname,
    int port, {
    ServerIdentityProtocol protocol = ServerIdentityProtocol.ssh,
  }) async => saved?.protocol == protocol ? saved : null;
  @override
  Future<bool> trustIfAbsent(SshHostKey key) async {
    saved ??= key;
    return saved!.matches(key);
  }

  @override
  Future<bool> removeIfMatches(SshHostKey key) async {
    if (saved?.hostname != key.hostname ||
        saved?.port != key.port ||
        saved?.matches(key) != true) {
      return false;
    }
    saved = null;
    return true;
  }
}

const _host = Host(
  id: 'rdp',
  name: 'Windows',
  hostname: 'windows.test',
  port: 3389,
  serviceType: ServiceType.rdp,
);
const _credentials = SshCredentials.password('secret');
const _certificate = SshHostKey(
  hostname: 'windows.test',
  port: 3389,
  keyType: 'X.509 SHA-256',
  fingerprint: 'SHA256:new',
  protocol: ServerIdentityProtocol.rdp,
  certificateError: 'unknownIssuer',
);

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  Future<(SessionController, FakeRdpEngine)> pump(
    WidgetTester tester, {
    Locale? locale,
    _KnownHosts? known,
    FakeRdpEngine? rdpEngine,
    Size size = const Size(800, 600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = rdpEngine ?? FakeRdpEngine(identity: _certificate);
    final controller = SessionController(
      engine: _NoSsh(),
      rdpEngine: engine,
      knownHosts: known ?? _KnownHosts(),
    );
    addTearDown(controller.closeAll);
    await tester.pumpWidget(
      ShadcnTestApp(
        locale: locale,
        home: Obx(
          () => RdpCertificatePrompts(
            sessions: controller.sessions.toList(),
            controller: controller,
            child: const Text('workspace'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, engine);
  }

  for (final english in [false, true]) {
    testWidgets('${english ? 'en' : 'zh'} 证书失败弹框可查看新旧指纹，确认后才认证', (
      tester,
    ) async {
      final known = _KnownHosts()
        ..saved = const SshHostKey(
          hostname: 'windows.test',
          port: 3389,
          keyType: 'X.509 SHA-256',
          fingerprint: 'SHA256:old',
          protocol: ServerIdentityProtocol.rdp,
        );
      final (controller, engine) = await pump(
        tester,
        locale: english ? const Locale('en', 'US') : null,
        known: known,
      );
      final opening = controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsOneWidget);
      expect(engine.authentications, 0);
      expect(find.textContaining('windows.test:3389'), findsOneWidget);
      expect(
        find.text(
          english
              ? 'This certificate could not be verified up to a trusted root certificate.'
              : '无法将此证书验证到受信任的根证书。',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(english ? 'Show certificate' : '显示证书'));
      await tester.pumpAndSettle();
      expect(find.text('SHA256:old'), findsOneWidget);
      expect(find.text('SHA256:new'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(english ? 'Continue connecting' : '继续连接'));
      await tester.pumpAndSettle();
      await opening;
      expect(engine.authentications, 1);
      expect(controller.sessions.single.phase, SessionPhase.ready);
      expect(known.saved!.fingerprint, 'SHA256:old');
      expect(find.byType(AppDialog), findsNothing);
    });
  }

  testWidgets('取消或点击遮罩不发送凭据，重试仍弹证书警告', (tester) async {
    final (controller, engine) = await pump(tester);
    Future<void> opening = controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await opening;
    expect(engine.authentications, 0);
    opening = controller.retry(controller.sessions.single.id);
    await tester.pumpAndSettle();
    expect(find.byType(RdpCertificateDialog), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    await opening;
    expect(engine.authentications, 0);
    expect(controller.sessions.single.phase, SessionPhase.failed);
  });

  testWidgets('多个证书提示串行，关闭等待连接仅移除自身弹框', (tester) async {
    final (controller, engine) = await pump(tester);
    final first = controller.open(_host, _credentials);
    final second = controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    expect(find.byType(RdpCertificateDialog), findsOneWidget);
    await tester.tap(find.text('继续连接'));
    await tester.pumpAndSettle();
    await first;
    expect(engine.authentications, 1);
    expect(find.byType(RdpCertificateDialog), findsOneWidget);
    unawaited(
      AppNavigation.dialog<void>(
        const AppDialog(
          title: Text('another dialog'),
          content: Text('keep open'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await controller.closeAll();
    await tester.pumpAndSettle();
    await second;
    expect(engine.authentications, 1);
    expect(find.byType(RdpCertificateDialog), findsNothing);
    expect(find.text('another dialog'), findsOneWidget);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  for (final english in [false, true]) {
    testWidgets('${english ? 'en' : 'zh'} 密码失败弹框在小窗口校验空密码、切换显示、回车重连', (
      tester,
    ) async {
      final engine = FakeRdpEngine(
        authenticationError: (credentials, _) =>
            credentials.password == ' correct '
            ? null
            : const RdpAuthenticationException('登录失败'),
      );
      final (controller, _) = await pump(
        tester,
        rdpEngine: engine,
        locale: english ? const Locale('en', 'US') : null,
        size: const Size(480, 400),
      );
      final opening = controller.open(
        _host,
        const SshCredentials.password(
          'wrong',
          username: 'selected@example.test',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RdpPasswordDialog), findsOneWidget);
      expect(find.textContaining('windows.test:3389'), findsOneWidget);
      expect(find.textContaining('selected@example.test'), findsOneWidget);
      expect(
        find.text(
          english ? 'RDP sign-in credentials did not work' : 'RDP 登录凭据无效',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).obscureText,
        isTrue,
      );
      await tester.tap(find.text(english ? 'Continue connecting' : '继续连接'));
      await tester.pumpAndSettle();
      expect(find.text(english ? 'Enter a password' : '请输入密码'), findsOneWidget);
      expect(engine.authentications, 1);
      await tester.ensureVisible(find.byType(AppTextFormField));
      await tester.pumpAndSettle();
      await tester.tap(findAppIconButton(english ? 'Show password' : '显示密码'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).obscureText,
        isFalse,
      );
      await tester.enterText(find.byType(EditableText), ' correct ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await opening;
      expect(controller.sessions.single.phase, SessionPhase.ready);
      expect(engine.attempts.last.password, ' correct ');
      expect(find.byType(AppDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('取消密码弹框保留失败，重试直接再弹；关闭会话仅移除自身弹框', (tester) async {
    final engine = FakeRdpEngine(
      authenticationError: (_, _) => const RdpAuthenticationException('登录失败'),
    );
    final (controller, _) = await pump(tester, rdpEngine: engine);
    final opening = controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await opening;
    expect(controller.sessions.single.phase, SessionPhase.failed);
    final retrying = controller.retry(controller.sessions.single.id);
    await tester.pumpAndSettle();
    expect(engine.authentications, 1);
    expect(find.byType(RdpPasswordDialog), findsOneWidget);
    unawaited(
      AppNavigation.dialog<void>(
        const AppDialog(
          title: Text('another dialog'),
          content: Text('keep open'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await controller.closeAll();
    await tester.pumpAndSettle();
    await retrying;
    expect(find.byType(RdpPasswordDialog), findsNothing);
    expect(find.text('another dialog'), findsOneWidget);
    AppNavigation.closeDialog<void>();
    await tester.pumpAndSettle();
  });

  testWidgets('密码与证书提示排队，不叠加；证书未确认前不重新提交密码', (tester) async {
    final engine = FakeRdpEngine(
      identity: _certificate,
      authenticationError: (credentials, _) => credentials.password == 'correct'
          ? null
          : const RdpAuthenticationException('登录失败'),
    );
    final (controller, _) = await pump(tester, rdpEngine: engine);
    final first = controller.open(_host, _credentials);
    final second = controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    expect(find.byType(RdpCertificateDialog), findsOneWidget);
    expect(engine.authentications, 0);
    await tester.tap(find.text('继续连接'));
    await tester.pumpAndSettle();
    expect(find.byType(RdpPasswordDialog), findsOneWidget);
    expect(find.byType(RdpCertificateDialog), findsNothing);
    expect(engine.authentications, 1);
    await tester.enterText(find.byType(EditableText), 'correct');
    await tester.tap(find.text('继续连接'));
    await tester.pumpAndSettle();
    expect(find.byType(RdpCertificateDialog), findsOneWidget);
    expect(engine.authentications, 1);
    await tester.tap(find.text('继续连接'));
    await tester.pumpAndSettle();
    await first;
    expect(engine.authentications, 2);
    expect(find.byType(RdpCertificateDialog), findsOneWidget);
    await controller.closeAll();
    await tester.pumpAndSettle();
    await second;
    expect(find.byType(AppDialog), findsNothing);
  });

  testWidgets('控制器销毁会移除等待中的密码弹框', (tester) async {
    final engine = FakeRdpEngine(
      authenticationError: (_, _) => const RdpAuthenticationException('登录失败'),
    );
    final (controller, _) = await pump(tester, rdpEngine: engine);
    final opening = controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    expect(find.byType(RdpPasswordDialog), findsOneWidget);
    controller.onClose();
    await tester.pumpAndSettle();
    await opening;
    expect(find.byType(RdpPasswordDialog), findsNothing);
    expect(engine.authentications, 1);
  });
}
