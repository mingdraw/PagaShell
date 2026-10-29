import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/repositories/known_host_repository.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import 'support/fake_sftp_session.dart';
import 'support/in_memory_binding.dart';

const _host = Host(id: 'server', name: 'SSH server', hostname: 'example.test');
const _oldKey = SshHostKey(
  hostname: 'example.test',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:previous',
);
const _newKey = SshHostKey(
  hostname: 'example.test',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:replacement',
);

class _KnownHosts implements KnownHostRepository {
  SshHostKey? stored = _oldKey;

  @override
  Future<SshHostKey?> find(
    String hostname,
    int port, {
    ServerIdentityProtocol protocol = ServerIdentityProtocol.ssh,
  }) async =>
      stored?.hostname == hostname &&
          stored?.port == port &&
          stored?.protocol == protocol
      ? stored
      : null;

  @override
  Future<bool> trustIfAbsent(SshHostKey key) async {
    stored ??= key;
    return stored!.matches(key);
  }

  @override
  Future<bool> removeIfMatches(SshHostKey key) async {
    final current = await find(key.hostname, key.port, protocol: key.protocol);
    if (current == null || !current.matches(key)) return false;
    stored = null;
    return true;
  }
}

class _Engine implements SshEngine {
  _Engine({this.error});
  final String? error;
  int authentications = 0;
  final logins = <SshCredentials>[];

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    logins.add(credentials);
    if (error != null) throw SshEngineException(error!);
    if (!await verifyHostKey!(_newKey)) {
      throw const SshEngineException('主机密钥未获信任，已取消连接');
    }
    authentications++;
    return FakeSftpSession();
  }
}

const _captureDir = String.fromEnvironment('PAGASHELL_CAPTURE_DIR');

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_captureDir.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(_captureDir).create(recursive: true);
      await File('$_captureDir/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (_captureDir.isEmpty) return;
    for (final entry in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
    final cjk = File('/System/Library/Fonts/STHeiti Light.ttc');
    if (cjk.existsSync()) {
      await (FontLoader(
        'PingFang SC',
      )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('$locale 指纹错误页可清除并重试，重新确认之前不认证', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _Engine();
      final known = _KnownHosts();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: PagaShellApp(
            binding: InMemoryBinding(sshEngine: engine, knownHosts: known),
            platform: TargetPlatform.macOS,
          ),
        ),
      );
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      final controller = Get.find<SessionController>();
      final opening = controller.open(
        _host,
        const SshCredentials.password('test-only', username: 'rocky'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('拒绝连接'.tr));
      await tester.pumpAndSettle();
      final id = await opening;
      final clear = find.byKey(const ValueKey('clear-host-key-and-retry'));
      expect(clear, findsOneWidget);
      expect(
        find.text('无法连接到 @address'.trParams({'address': 'rocky@example.test'})),
        findsOneWidget,
      );
      expect(find.textContaining('root@example.test'), findsNothing);
      expect(engine.authentications, 0);
      expect(known.stored, same(_oldKey));
      for (final size in [
        const Size(1280, 800),
        const Size(800, 600),
        const Size(640, 480),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(clear.hitTestable(), findsOneWidget);
        expect(find.text('重试'.tr).hitTestable(), findsOneWidget);
        await _capture(
          tester,
          key,
          'host-key-retry-${locale.languageCode}-${size.width.toInt()}',
        );
      }
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(clear, findsNothing);
      expect(find.text('首次连接：确认主机指纹'.tr), findsOneWidget);
      expect(find.text(_newKey.fingerprint), findsOneWidget);
      expect(known.stored, isNull);
      expect(engine.authentications, 0);
      await tester.ensureVisible(find.text('信任并连接'.tr));
      await tester.tap(find.text('信任并连接'.tr));
      await tester.pumpAndSettle();
      expect(controller.sessions.single.phase, SessionPhase.ready);
      expect(controller.sessions.single.address, 'rocky@example.test');
      expect(controller.sessions.single.host.username, 'root');
      expect(
        engine.logins.map((login) => login.username),
        everyElement('rocky'),
      );
      expect(engine.authentications, 1);
      expect(known.stored, same(_newKey));
      await tester.runAsync(() => controller.close(id));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('普通连接失败显示凭证用户名，重试保留同一用户名', (tester) async {
    final known = _KnownHosts();
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(
          sshEngine: _Engine(error: '认证失败'),
          knownHosts: known,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = Get.find<SessionController>();
    final id = await controller.open(
      _host,
      const SshCredentials.password('test-only', username: 'rocky'),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('clear-host-key-and-retry')),
      findsNothing,
    );
    expect(find.text('重试'.tr).hitTestable(), findsOneWidget);
    final address = find.text(
      '无法连接到 @address'.trParams({'address': 'rocky@example.test'}),
    );
    expect(address, findsOneWidget);
    expect(find.textContaining('root@example.test'), findsNothing);
    await tester.tap(find.text('重试'.tr));
    await tester.pumpAndSettle();
    expect(address, findsOneWidget);
    expect(known.stored, same(_oldKey));
    await controller.clearHostKeyAndRetry(id);
    expect(known.stored, same(_oldKey));
    await controller.close(id);
    await tester.pumpAndSettle();
  });
}
