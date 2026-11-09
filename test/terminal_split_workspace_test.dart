import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/session/session_layout.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/app_theme_mode.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/process_manager.dart';
import 'package:pagashell/domain/ssh/server_status.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_icon_button.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/terminal/docker_manager_panel.dart';
import 'package:pagashell/presentation/terminal/terminal_tab_workspace.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/docker_fixture.dart';
import 'support/fake_sftp_session.dart';
import 'support/fixture_terminal.dart';
import 'support/in_memory_binding.dart';
import 'support/process_fixture.dart';
import 'support/server_status_fixture.dart';
import 'support/shadcn_test_app.dart';

class _Session extends FakeSftpSession
    implements
        ServerStatusSource,
        ProcessManagerSource,
        DockerManagerSource,
        DockerContainerActions,
        DockerImageActions {
  Future<DockerActionResult> Function(DockerImageAction, DockerResource?)?
  imageActionHandler;
  List<DockerResource>? imageResources;

  @override
  Future<DockerActionResult> runDockerImageAction(
    DockerImageAction action, {
    DockerResource? image,
  }) async => imageActionHandler == null
      ? const DockerActionResult()
      : imageActionHandler!(action, image);

  Future<DockerActionResult> Function(
    DockerResource,
    DockerContainerAction,
    String?,
    bool,
  )?
  actionHandler;

  @override
  Future<DockerActionResult> runDockerContainerAction(
    DockerResource resource,
    DockerContainerAction action, {
    String? targetImage,
    bool forcePull = false,
  }) async => actionHandler == null
      ? const DockerActionResult()
      : actionHandler!(resource, action, targetImage, forcePull);
  final dockerReads = <DockerResourceKind>[];
  final dockerDetailReads = <DockerResource>[];
  Object? dockerFailure;
  Object? dockerDetailFailure;
  Completer<List<DockerResource>>? dockerGate;
  Completer<DockerDetails>? dockerDetailsGate;
  List<DockerResource>? containerResources;
  Future<DockerDetails> Function(DockerResource)? dockerDetailsReader;

  @override
  Future<List<DockerResource>> readDockerResources(
    DockerResourceKind kind,
  ) async {
    dockerReads.add(kind);
    if (dockerFailure case final failure?) throw failure;
    if (dockerGate case final gate?) return gate.future;
    if (kind == DockerResourceKind.image && imageResources != null) {
      return imageResources!;
    }
    if (kind == DockerResourceKind.container && containerResources != null) {
      return containerResources!;
    }
    return [
      dockerResource(kind: kind),
      if (kind == DockerResourceKind.container)
        dockerResource(
          id: 'b'.padRight(64, 'b'),
          name: 'stopped-worker',
          fields: {
            DockerField.image: 'worker:v1',
            DockerField.state: 'exited',
            DockerField.status: 'Exited (0) 1 hour ago',
          },
        ),
    ];
  }

  @override
  Future<DockerDetails> readDockerDetails(DockerResource resource) async {
    dockerDetailReads.add(resource);
    if (dockerDetailFailure case final failure?) throw failure;
    if (dockerDetailsGate case final gate?) return gate.future;
    if (dockerDetailsReader case final reader?) return reader(resource);
    return dockerDetails(resource);
  }

  final output = StreamController<String>();
  final written = <String>[];
  final sizes = <(int, int)>[];
  TerminalFrameFixture? fixture;
  int samples = 0;
  int processReads = 0;
  final terminated = <RemoteProcess>[];
  Object? terminationFailure;
  List<RemoteProcess>? processList;
  final detailsRead = <RemoteProcess>[];
  Completer<ProcessDetails>? detailsGate;
  Object? detailsFailure;

  @override
  Future<ProcessDetails> readProcessDetails(RemoteProcess process) async {
    detailsRead.add(process);
    if (detailsFailure case final failure?) throw failure;
    if (detailsGate case final gate?) return gate.future;
    return processDetails(process: process);
  }

  @override
  Future<ProcessSnapshot> readProcesses() async {
    processReads++;
    return processSnapshot(
      time: 1000 + processReads * 3,
      processes: processList,
    );
  }

  @override
  Future<void> terminateProcess(RemoteProcess process) async {
    terminated.add(process);
    if (terminationFailure case final failure?) throw failure;
  }

  @override
  Stream<TerminalFrame> startTerminalShell({
    required int cols,
    required int rows,
    int scrollback = 10000,
  }) {
    shellStarts++;
    fixture = TerminalFrameFixture(
      columns: cols,
      rows: rows,
      scrollback: scrollback,
    );
    return fixture!.decode(output.stream);
  }

  @override
  void resizeTerminal(int width, int height) {
    sizes.add((width, height));
    fixture?.resize(width, height);
    if (!output.isClosed) output.add('');
  }

  @override
  void write(String data) => written.add(data);

  @override
  Future<ServerStatusSample> readServerStatus() async {
    samples++;
    return statusSample(
      systemRelease: 'Ubuntu 24.04 LTS',
      uptime: 1000 + samples * 3,
      cpu: 1000 + samples * 100,
      idle: 800 + samples * 40,
    );
  }

  @override
  Future<void> close() async {
    unawaited(output.close());
    await super.close();
  }
}

class _Engine implements SshEngine {
  final sessions = <_Session>[];
  Completer<void>? nextConnection;
  Object? nextDockerShellFailure;
  final actions = <(DockerResource, DockerContainerAction, String?, bool)>[];
  final imageActions = <(DockerImageAction, DockerResource?)>[];
  Completer<DockerActionResult>? actionGate;
  Object? actionFailure;

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async {
    final gate = nextConnection;
    nextConnection = null;
    if (gate != null) await gate.future;
    final session = _Session();
    session.imageActionHandler = (action, image) async {
      imageActions.add((action, image));
      if (actionFailure case final failure?) throw failure;
      if (actionGate case final gate?) await gate.future;
      final existing =
          sessions
              .map((session) => session.imageResources)
              .whereType<List<DockerResource>>()
              .firstOrNull ??
          [dockerResource(kind: DockerResourceKind.image)];
      final updated = existing
          .where(
            (item) => switch (action) {
              DockerImageAction.delete => item.id != image!.id,
              DockerImageAction.pruneUntagged =>
                !item.isUntaggedImage || item.imageInUse != false,
              DockerImageAction.pruneUnused => item.imageInUse != false,
            },
          )
          .toList();
      for (final target in sessions) {
        target.imageResources = updated;
      }
      return const DockerActionResult();
    };
    session.actionHandler = (resource, action, image, force) async {
      actions.add((resource, action, image, force));
      if (actionFailure case final failure?) throw failure;
      if (actionGate case final gate?) await gate.future;
      final existing =
          sessions
              .map((session) => session.containerResources)
              .whereType<List<DockerResource>>()
              .firstOrNull ??
          [
            dockerResource(),
            dockerResource(
              id: 'b'.padRight(64, 'b'),
              name: 'stopped-worker',
              fields: {
                DockerField.image: 'worker:v1',
                DockerField.state: 'exited',
                DockerField.status: 'Exited (0)',
              },
            ),
          ];
      final updated = <DockerResource>[
        for (final item in existing)
          if (item.id != resource.id)
            item
          else if (action != DockerContainerAction.delete)
            dockerResource(
              id: action == DockerContainerAction.upgrade
                  ? 'c'.padRight(64, 'c')
                  : item.id,
              name: item.name,
              fields: {
                ...item.fields,
                DockerField.state: action == DockerContainerAction.stop
                    ? 'exited'
                    : 'running',
                DockerField.status: action == DockerContainerAction.stop
                    ? 'Exited (0)'
                    : 'Up',
                DockerField.image: ?image,
              },
            ),
      ];
      for (final target in sessions) {
        target.containerResources = updated;
      }
      return const DockerActionResult();
    };
    session.dockerShellFailure = nextDockerShellFailure;
    nextDockerShellFailure = null;
    sessions.add(session);
    return session;
  }
}

const _host = Host(id: 'one', name: 'Linux server', hostname: 'example.test');
const _credentials = SshCredentials.password('test-only', username: 'rocky');
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

Finder _button(String name) => find.byKey(ValueKey('terminal-$name'));
Finder _pane(String id) => find.byKey(ValueKey('terminal-pane-$id'));
Future<void> _dockerMenu(WidgetTester tester, DockerResource resource) async {
  await tester.tap(find.byKey(ValueKey('docker-more-${resource.identity}')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _dockerTerminal(
  WidgetTester tester,
  DockerResource resource,
) async {
  await _dockerMenu(tester, resource);
  await tester.tap(find.widgetWithText(shadcn.MenuButton, '终端'.tr));
  await tester.pumpAndSettle();
}

Finder _terminal(SessionController controller, String id) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is TerminalView &&
          identical(
            widget.terminal,
            controller.sessions
                .firstWhere((session) => session.id == id)
                .terminal,
          ),
    );

Future<(SessionController, _Engine, GlobalKey)> _mount(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final engine = _Engine();
  final captureKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: PagaShellApp(
        binding: InMemoryBinding(sshEngine: engine),
        platform: TargetPlatform.windows,
      ),
    ),
  );
  await tester.pumpAndSettle();
  Get.find<SettingsController>().sidebarVisible.value = false;
  await tester.pumpAndSettle();
  return (Get.find<SessionController>(), engine, captureKey);
}

void main() {
  setUpAll(() async {
    if (_captureDir.isEmpty) return;
    for (final entry in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
      'packages/shadcn_flutter/RadixIcons':
          'packages/shadcn_flutter/lib/icons/RadixIcons.otf',
      'FiraCode Nerd Font Mono':
          'assets/fonts/FiraCodeNerdFontMono-Regular.ttf',
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
    testWidgets('Docker 四类 TabList、搜索、按需详情和窄面板 ${locale.languageCode}', (
      tester,
    ) async {
      final (controller, engine, captureKey) = await _mount(tester);
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      expect(engine.sessions.single.dockerReads, isEmpty);
      expect(
        tester.widget<AppIconButton>(_button('toolbar-docker')).tooltip,
        'Docker 管理'.tr,
      );
      await tester.tap(_button('toolbar-docker'));
      await tester.pumpAndSettle();
      final source = engine.sessions.last;
      final panel = find.byKey(const ValueKey('docker-manager-panel'));
      expect(find.byType(shadcn.TabList), findsOneWidget);
      expect(source.dockerReads, [DockerResourceKind.container]);
      expect(source.shellStarts, 0);
      expect(find.text('stopped-worker'), findsOneWidget);
      expect(source.dockerDetailReads, isEmpty);
      expect(find.textContaining('0.0.0.0:8080'), findsNothing);
      final running = dockerResource();
      final stopped = dockerResource(id: 'b'.padRight(64, 'b'));
      expect(
        find.byKey(ValueKey('docker-terminal-${running.identity}')),
        findsNothing,
      );
      await _dockerMenu(tester, running);
      expect(
        tester
            .widget<shadcn.MenuButton>(
              find.widgetWithText(shadcn.MenuButton, '终端'.tr),
            )
            .onPressed,
        isNotNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _dockerMenu(tester, stopped);
      expect(
        tester
            .widget<shadcn.MenuButton>(
              find.widgetWithText(shadcn.MenuButton, '终端'.tr),
            )
            .onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('docker-search-container'));
      tester.widget<AppTextFormField>(search).controller.text = 'WEB';
      await tester.pumpAndSettle();
      expect(find.text('stopped-worker'), findsNothing);
      expect(find.text('web-api'), findsOneWidget);
      for (final kind in DockerResourceKind.values) {
        await tester.tap(find.byKey(ValueKey('docker-tab-${kind.name}')));
        await tester.pumpAndSettle();
        final resource = dockerResource(kind: kind);
        expect(
          find.byKey(ValueKey('docker-card-${resource.identity}')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(ValueKey('docker-details-${resource.identity}')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('docker-details-dialog')),
          findsOneWidget,
        );
        if (kind == DockerResourceKind.container) {
          expect(
            find.byKey(const ValueKey('docker-detail-ports')),
            findsOneWidget,
          );
          expect(find.text('0.0.0.0:8080->80/tcp'), findsOneWidget);
        }
        final detailReads = source.dockerDetailReads.length;
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(source.dockerDetailReads, hasLength(detailReads));
        await tester.tap(find.byKey(const ValueKey('docker-details-refresh')));
        await tester.pumpAndSettle();
        expect(source.dockerDetailReads, hasLength(detailReads + 1));
        await _capture(
          tester,
          captureKey,
          'docker-${kind.name}-details-${locale.languageCode}',
        );
        await tester.tap(find.byKey(const ValueKey('docker-details-close')));
        await tester.pumpAndSettle();
        await _capture(
          tester,
          captureKey,
          'docker-${kind.name}-${locale.languageCode}',
        );
      }
      await tester.tap(find.byKey(const ValueKey('docker-tab-container')));
      await tester.pumpAndSettle();
      expect(tester.widget<AppTextFormField>(search).controller.text, 'WEB');
      await tester.dragFrom(
        tester.getCenter(
          find.byKey(const ValueKey('terminal-side-panel-dragger')),
        ),
        const Offset(200, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).width, closeTo(220, 1));
      for (final kind in DockerResourceKind.values) {
        await tester.tap(find.byKey(ValueKey('docker-tab-${kind.name}')));
        await tester.pumpAndSettle();
      }
      await _capture(
        tester,
        captureKey,
        'docker-narrow-${locale.languageCode}',
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('容器终端按钮打开独立新标签，原 SSH 与 Docker 面板保持可用', (tester) async {
    final (controller, engine, captureKey) = await _mount(tester);
    final hostId = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    final resource = dockerResource();
    final background = engine.sessions.last;
    await _dockerTerminal(tester, resource);
    final container = controller.activeSession!;
    expect(container.id, isNot(hostId));
    expect(container.kind, SessionKind.containerTerminal);
    expect(container.title, 'web-api');
    expect(
      container.dockerTarget,
      DockerTerminalTarget(id: resource.id, name: resource.name),
    );
    expect(controller.tabs.map((tab) => tab.sessionIds), [
      [hostId],
      [container.id],
    ]);
    expect(engine.sessions.last.dockerShellStarts, [container.dockerTarget]);
    expect(engine.sessions.first.closes, 0);
    expect(background.closes, 0);
    expect(_terminal(controller, container.id), findsOneWidget);
    expect(_button('toolbar-status'), findsNothing);
    expect(_button('toolbar-docker'), findsNothing);
    expect(find.byKey(const ValueKey('server-status-panel')), findsNothing);
    expect(find.byKey(const ValueKey('docker-manager-panel')), findsNothing);
    expect(controller.serverStatusSource(container.id), isNull);
    expect(controller.dockerManagerSource(container.id), isNull);
    await _capture(tester, captureKey, 'docker-container-terminal-tab');
    final connections = engine.sessions.length;
    await tester.tap(_button('split-horizontal'));
    await tester.pumpAndSettle();
    expect(engine.sessions, hasLength(connections + 1));
    expect(controller.activeSession!.kind, SessionKind.containerTerminal);
    expect(controller.activeSession!.dockerTarget, container.dockerTarget);
    expect(engine.sessions.last.dockerShellStarts, [container.dockerTarget]);
    expect(_button('toolbar-status'), findsNothing);
    expect(_button('toolbar-docker'), findsNothing);
    await _capture(tester, captureKey, 'docker-container-terminal-split');
    await tester.runAsync(controller.closeActive);
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, hostId);
    expect(find.byKey(const ValueKey('docker-manager-panel')), findsOneWidget);
    expect(background.closes, 0);
    expect(find.text('web-api'), findsOneWidget);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('容器终端失败保留页签及具体原因，重试不弹 Toast ${locale.languageCode}', (
      tester,
    ) async {
      final (controller, engine, captureKey) = await _mount(tester);
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      final hostId = await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-docker'));
      await tester.pumpAndSettle();
      const error = '容器中未找到可用的 bash 或 sh';
      engine.nextDockerShellFailure = const SshEngineException(error);
      await _dockerTerminal(tester, dockerResource());
      final failed = controller.activeSession!;
      expect(failed.phase, SessionPhase.failed);
      expect(failed.error, error);
      final toast = find.ancestor(
        of: find.text(error.tr),
        matching: find.byType(shadcn.SurfaceCard),
      );
      expect(find.text(error.tr), findsOneWidget);
      expect(toast, findsNothing);
      expect(engine.sessions.last.closes, 1);
      // 流取消可能使用测试时钟之外已完成的 Future，让其完成清理回调。
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      controller.sessions.refresh();
      await tester.pumpAndSettle();
      expect(find.text(error.tr), findsOneWidget);
      expect(toast, findsNothing);
      await _capture(
        tester,
        captureKey,
        'docker-terminal-failure-${locale.languageCode}',
      );
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(controller.activeSession!.id, failed.id);
      expect(find.text(error.tr), findsOneWidget);
      expect(toast, findsNothing);
      engine.nextDockerShellFailure = const SshEngineException(error);
      await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '重试'.tr));
      await tester.pumpAndSettle();
      expect(controller.activeSession!.id, failed.id);
      expect(controller.activeSession!.phase, SessionPhase.failed);
      expect(controller.activeSession!.error, error);
      expect(find.text(error.tr), findsOneWidget);
      expect(toast, findsNothing);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(
        controller.sessions.firstWhere((session) => session.id == hostId).phase,
        SessionPhase.ready,
      );
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(shadcn.PrimaryButton, '重试'.tr));
      await tester.pumpAndSettle();
      expect(controller.activeSession!.phase, SessionPhase.ready);
      expect(controller.activeSession!.id, failed.id);
      expect(find.text(error.tr), findsNothing);
      expect(toast, findsNothing);
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('容器终端失败页签显示执行原因和退出码 ${locale.languageCode}', (tester) async {
      final (controller, engine, captureKey) = await _mount(tester);
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-docker'));
      await tester.pumpAndSettle();
      for (final (reason, chinese, english) in [
        (
          '容器中的 bash 或 sh 没有执行权限',
          '容器中的 bash 或 sh 没有执行权限',
          'The container does not have permission to execute bash or sh',
        ),
        (
          '容器内的 bash 或 sh 无法执行（退出码 126）',
          '容器内的 bash 或 sh 无法执行（退出码 126）',
          'The container cannot execute bash or sh (exit code 126)',
        ),
        (
          '容器内命令未找到，无法启动 bash 或 sh（退出码 127）',
          '容器内命令未找到，无法启动 bash 或 sh（退出码 127）',
          'A command was not found in the container, so bash or sh could not start (exit code 127)',
        ),
        (
          'Docker 执行容器终端失败（退出码 127）',
          '容器内命令未找到，无法启动 bash 或 sh（退出码 127）',
          'A command was not found in the container, so bash or sh could not start (exit code 127)',
        ),
        (
          'Docker 执行容器终端失败（退出码 126）',
          '容器内的 bash 或 sh 无法执行（退出码 126）',
          'The container cannot execute bash or sh (exit code 126)',
        ),
        (
          'Docker 执行容器终端失败（退出码 125）',
          'Docker 执行容器终端失败（退出码 125）',
          'Docker could not execute the container terminal (exit code 125)',
        ),
      ]) {
        engine.nextDockerShellFailure = SshEngineException(reason);
        await _dockerTerminal(tester, dockerResource());
        final failed = controller.activeSession!;
        expect(failed.phase, SessionPhase.failed);
        expect(failed.error, reason);
        final message = find.text(
          locale.languageCode == 'en' ? english : chinese,
        );
        expect(message, findsOneWidget);
        expect(
          find.ancestor(of: message, matching: find.byType(shadcn.SurfaceCard)),
          findsNothing,
        );
        expect(
          find.widgetWithText(shadcn.PrimaryButton, '重试'.tr),
          findsOneWidget,
        );
        if (reason.contains('127')) {
          await _capture(
            tester,
            captureKey,
            'docker-terminal-exit-127-${locale.languageCode}',
          );
          expect(find.text('Docker 执行容器终端失败（退出码 127）'.tr), findsNothing);
        }
        await tester.runAsync(() => controller.close(failed.id));
        await tester.pumpAndSettle();
      }
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('镜像展示无标签与使用状态，删除及清理均需确认且清理不受搜索影响 ${locale.languageCode}', (
      tester,
    ) async {
      final (controller, engine, captureKey) = await _mount(tester);
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-docker'));
      await tester.pumpAndSettle();
      final background = engine.sessions.last;
      final used = dockerImage(hex: 'a', tags: ['nginx:stable'], inUse: true);
      final unused = dockerImage(hex: 'b', tags: ['cache:old']);
      final dangling = dockerImage(hex: 'c');
      final referenced = dockerImage(hex: 'd', inUse: true);
      final removable = dockerImage(hex: 'e');
      background.imageResources = [
        used,
        unused,
        dangling,
        referenced,
        removable,
      ];
      await tester.tap(find.byKey(const ValueKey('docker-tab-image')));
      await tester.pumpAndSettle();
      Finder card(DockerResource image) =>
          find.byKey(ValueKey('docker-card-${image.identity}'));
      Finder remove(DockerResource image) =>
          find.byKey(ValueKey('docker-delete-image-${image.identity}'));
      expect(remove(used), findsNothing);
      expect(remove(referenced), findsNothing);
      expect(remove(unused), findsOneWidget);
      expect(
        find.descendant(
          of: card(dangling),
          matching: find.textContaining('无标签'.tr),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card(used), matching: find.text('使用中'.tr)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card(unused), matching: find.text('未使用'.tr)),
        findsOneWidget,
      );
      await _capture(
        tester,
        captureKey,
        'docker-images-${locale.languageCode}',
      );
      await tester.tap(remove(removable));
      await tester.pumpAndSettle();
      expect(engine.imageActions, isEmpty);
      expect(find.text('仅允许删除未被任何容器使用的镜像。'.tr), findsNothing);
      expect(find.text('删除镜像后，再次使用时需要重新拉取或构建。'.tr), findsOneWidget);
      await _capture(
        tester,
        captureKey,
        'docker-image-delete-${locale.languageCode}',
      );
      await tester.tap(
        find.byKey(const ValueKey('docker-confirm-image-delete')),
      );
      await tester.pumpAndSettle();
      expect(engine.imageActions.single, (DockerImageAction.delete, removable));
      expect(card(removable), findsNothing);
      final search = find.byKey(const ValueKey('docker-search-image'));
      tester.widget<AppTextFormField>(search).controller.text = 'nginx';
      await tester.pumpAndSettle();
      expect(card(dangling), findsNothing);
      await tester.tap(find.byKey(const ValueKey('docker-image-cleanup')));
      await tester.pumpAndSettle();
      expect(find.text('默认清理没有标签且未被容器使用的镜像。'.tr), findsOneWidget);
      final allUnused = find.byKey(const ValueKey('docker-prune-all-unused'));
      expect(
        tester.widget<shadcn.Checkbox>(allUnused).state,
        shadcn.CheckboxState.unchecked,
      );
      expect(find.text('清理镜像'.tr), findsOneWidget);
      expect(find.text('清理范围为当前 Docker 服务，不受搜索条件影响。'.tr), findsOneWidget);
      expect(engine.imageActions, hasLength(1));
      await _capture(
        tester,
        captureKey,
        'docker-image-cleanup-${locale.languageCode}',
      );
      final gate = engine.actionGate = Completer<DockerActionResult>();
      final confirm = find.byKey(
        const ValueKey('docker-confirm-image-pruneUntagged'),
      );
      await tester.tap(confirm);
      await tester.pump();
      expect(
        tester.widget<shadcn.DestructiveButton>(confirm).onPressed,
        isNull,
      );
      expect(tester.widget<shadcn.Checkbox>(allUnused).onChanged, isNull);
      final reads = background.dockerReads.length;
      await tester.pump(const Duration(seconds: 15));
      expect(background.dockerReads, hasLength(reads));
      gate.complete(const DockerActionResult());
      await tester.pumpAndSettle();
      expect(engine.imageActions.last, (DockerImageAction.pruneUntagged, null));
      tester.widget<AppTextFormField>(search).controller.clear();
      await tester.pumpAndSettle();
      expect(card(dangling), findsNothing);
      for (final retained in [used, unused, referenced]) {
        expect(card(retained), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('docker-image-cleanup')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<shadcn.Checkbox>(allUnused).state,
        shadcn.CheckboxState.unchecked,
      );
      await tester.tap(allUnused);
      await tester.pumpAndSettle();
      expect(
        tester.widget<shadcn.Checkbox>(allUnused).state,
        shadcn.CheckboxState.checked,
      );
      expect(find.text('将清理所有未被容器使用的镜像，包括有标签的镜像。'.tr), findsOneWidget);
      expect(find.text('清理镜像'.tr), findsOneWidget);
      expect(
        find.widgetWithText(shadcn.DestructiveButton, '清理'.tr),
        findsOneWidget,
      );
      expect(engine.imageActions, hasLength(2));
      await _capture(
        tester,
        captureKey,
        'docker-image-cleanup-all-${locale.languageCode}',
      );
      final allGate = engine.actionGate = Completer<DockerActionResult>();
      await tester.tap(confirm);
      await tester.pump();
      expect(engine.imageActions.last, (DockerImageAction.pruneUnused, null));
      expect(tester.widget<shadcn.Checkbox>(allUnused).onChanged, isNull);
      allGate.complete(const DockerActionResult());
      await tester.pumpAndSettle();
      expect(card(unused), findsNothing);
      expect(card(used), findsOneWidget);
      expect(card(referenced), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('docker-image-cleanup')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<shadcn.Checkbox>(allUnused).state,
        shadcn.CheckboxState.unchecked,
      );
      await tester.tap(find.widgetWithText(shadcn.OutlineButton, '取消'.tr));
      await tester.pumpAndSettle();
      expect(engine.imageActions, hasLength(3));
      expect(background.closes, 0);
      expect(engine.sessions.last.closes, 1);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('容器按状态显示单个启停按钮和信息，删除需精确输入名称且保留采集连接', (tester) async {
    final (controller, engine, captureKey) = await _mount(tester);
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    final resource = dockerResource();
    Finder action(String name) =>
        find.byKey(ValueKey('docker-$name-${resource.identity}'));
    expect(action('start'), findsNothing);
    expect(tester.widget<AppIconButton>(action('stop')).onPressed, isNotNull);
    final stopped = dockerResource(
      id: 'b'.padRight(64, 'b'),
      name: 'stopped-worker',
    );
    expect(
      find.byKey(ValueKey('docker-start-${stopped.identity}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('docker-stop-${stopped.identity}')),
      findsNothing,
    );
    await tester.tap(action('stop'));
    await tester.pumpAndSettle();
    expect(engine.actions, isEmpty);
    await tester.tap(find.byKey(const ValueKey('docker-confirm-stop')));
    await tester.pumpAndSettle();
    expect(engine.actions.single.$2, DockerContainerAction.stop);
    expect(tester.widget<AppIconButton>(action('start')).onPressed, isNotNull);
    expect(action('stop'), findsNothing);
    await tester.tap(action('start'));
    await tester.pumpAndSettle();
    expect(engine.actions.last.$2, DockerContainerAction.start);
    expect(action('start'), findsNothing);
    expect(tester.widget<AppIconButton>(action('stop')).onPressed, isNotNull);
    await tester.tap(action('details'));
    await tester.pumpAndSettle();
    expect(source.dockerDetailReads, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('docker-details-close')));
    await tester.pumpAndSettle();
    await _dockerMenu(tester, resource);
    await tester.tap(find.widgetWithText(shadcn.MenuButton, '删除'.tr));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('docker-confirm-delete'));
    final input = find.byKey(const ValueKey('docker-delete-name'));
    expect(tester.widget<shadcn.DestructiveButton>(confirm).onPressed, isNull);
    tester.widget<AppTextFormField>(input).controller.text = 'WEB-API';
    await tester.pump();
    expect(tester.widget<shadcn.DestructiveButton>(confirm).onPressed, isNull);
    expect(engine.actions, hasLength(2));
    tester.widget<AppTextFormField>(input).controller.text = resource.name;
    await tester.pumpAndSettle();
    await _capture(tester, captureKey, 'docker-delete-confirmation');
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(engine.actions.last.$2, DockerContainerAction.delete);
    expect(
      find.byKey(ValueKey('docker-card-${resource.identity}')),
      findsNothing,
    );
    expect(source.closes, 0);
    expect(
      engine.sessions.skip(2).every((session) => session.closes == 1),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('升级弹框默认当前镜像、可强制拉取，执行期间禁用重复提交 ${locale.languageCode}', (
      tester,
    ) async {
      final (controller, engine, captureKey) = await _mount(tester);
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-docker'));
      await tester.pumpAndSettle();
      final source = engine.sessions.last;
      final resource = dockerResource();
      await _dockerMenu(tester, resource);
      final upgrade = find.widgetWithText(shadcn.MenuButton, '升级'.tr);
      expect(
        tester.widget<shadcn.MenuButton>(upgrade).leading,
        isA<AppIcon>().having(
          (icon) => icon.icon,
          'icon',
          AppIcons.circleArrowUp,
        ),
      );
      await tester.tap(upgrade);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('docker-upgrade-image'));
      expect(
        tester.widget<AppTextFormField>(input).controller.text,
        resource.fields[DockerField.image],
      );
      final force = find.byKey(const ValueKey('docker-force-pull'));
      expect(
        tester.widget<shadcn.Checkbox>(force).state,
        shadcn.CheckboxState.unchecked,
      );
      tester.widget<AppTextFormField>(input).controller.text = '';
      final confirm = find.byKey(const ValueKey('docker-confirm-upgrade'));
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text('请输入目标镜像'.tr), findsOneWidget);
      expect(engine.actions, isEmpty);
      tester.widget<AppTextFormField>(input).controller.text =
          'ghcr.io/tale/headplane:latest';
      await tester.tap(force);
      await tester.pumpAndSettle();
      await _capture(
        tester,
        captureKey,
        'docker-upgrade-${locale.languageCode}',
      );
      final gate = engine.actionGate = Completer<DockerActionResult>();
      await tester.tap(confirm);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(engine.actions, hasLength(1));
      expect(engine.actions.single.$3, 'ghcr.io/tale/headplane:latest');
      expect(engine.actions.single.$4, isTrue);
      expect(tester.widget<shadcn.PrimaryButton>(confirm).onPressed, isNull);
      expect(tester.widget<AppTextFormField>(input).enabled, isFalse);
      expect(tester.widget<shadcn.Checkbox>(force).onChanged, isNull);
      final reads = source.dockerReads.length;
      await tester.pump(const Duration(seconds: 15));
      expect(source.dockerReads, hasLength(reads));
      gate.complete(const DockerActionResult());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('docker-upgrade-dialog')), findsNothing);
      expect(
        find.byKey(
          ValueKey(
            'docker-card-${dockerResource(id: 'c'.padRight(64, 'c')).identity}',
          ),
        ),
        findsOneWidget,
      );
      expect(source.closes, 0);
      expect(engine.sessions.last.closes, 1);
      expect(source.dockerReads.length, greaterThan(reads));
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('容器操作失败显示 Toast 并停止自动刷新，确认弹框可重试或取消', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    engine.actionFailure = const SshEngineException('没有权限操作 Docker 容器');
    await tester.tap(
      find.byKey(ValueKey('docker-stop-${dockerResource().identity}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('docker-confirm-stop')));
    await tester.pumpAndSettle();
    expect(find.text('没有权限操作 Docker 容器'.tr), findsNWidgets(2));
    expect(find.byKey(const ValueKey('docker-stop-dialog')), findsOneWidget);
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, '取消'.tr));
    await tester.pumpAndSettle();
    final reads = source.dockerReads.length;
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(source.dockerReads, hasLength(reads));
    await tester.tap(find.byKey(const ValueKey('docker-manager-refresh')));
    await tester.pumpAndSettle();
    expect(source.dockerReads.length, greaterThan(reads));
    expect(source.closes, 0);
    expect(engine.sessions.last.closes, 1);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('更多菜单终端回调异常不弹 Toast，不产生未处理异步错误并解除打开状态', (tester) async {
    final source = _Session();
    var attempts = 0;
    await tester.pumpWidget(
      shadcn.ShadcnApp(
        navigatorKey: Get.key,
        theme: AppTheme.shadcnLight.copyWith(
          platform: () => TargetPlatform.windows,
        ),
        scaling: shadcn.AdaptiveScaling.desktop,
        home: DockerManagerPanel(
          source: source,
          active: true,
          onOpenTerminal: (_) async {
            attempts++;
            throw StateError('/private/native/diagnostic');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _dockerTerminal(tester, dockerResource());
    expect(attempts, 1);
    expect(find.text('无法打开容器终端，请重试'.tr), findsNothing);
    expect(find.textContaining('/private/native'), findsNothing);
    expect(tester.takeException(), isNull);
    await _dockerTerminal(tester, dockerResource());
    expect(attempts, 2);
    expect(find.text('无法打开容器终端，请重试'.tr), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(source.close);
  });

  testWidgets('容器更新重建后详情使用同名新 ID，并同步列表供下次打开', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    final stale = dockerResource();
    final fresh = dockerResource(id: 'b'.padRight(64, 'b'));
    source.containerResources = [fresh];
    source.dockerDetailsReader = (resource) async {
      if (resource.id == stale.id) {
        throw const SshEngineException('Docker 资源可能已移除，请刷新后重试');
      }
      return dockerDetails(resource);
    };
    await tester.tap(find.byKey(ValueKey('docker-details-${stale.identity}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('docker-details-error')), findsNothing);
    expect(find.text(fresh.id), findsOneWidget);
    expect(source.dockerDetailReads.map((resource) => resource.id), [
      stale.id,
      fresh.id,
    ]);
    expect(source.dockerReads, hasLength(2));
    await tester.tap(find.byKey(const ValueKey('docker-details-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('docker-card-${stale.identity}')), findsNothing);
    expect(
      find.byKey(ValueKey('docker-card-${fresh.identity}')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey('docker-details-${fresh.identity}')));
    await tester.pumpAndSettle();
    expect(source.dockerDetailReads.last.id, fresh.id);
    expect(source.dockerReads, hasLength(2));
    await tester.tap(find.byKey(const ValueKey('docker-details-close')));
    await tester.pumpAndSettle();
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Docker 列表卡住十秒后显示超时，结束加载并可刷新重连', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    final gate = source.dockerGate = Completer<List<DockerResource>>();
    final refresh = find.byKey(const ValueKey('docker-manager-refresh'));
    await tester.tap(refresh);
    await tester.pump();
    expect(tester.widget<AppIconButton>(refresh).onPressed, isNull);
    await tester.pump(dockerQueryTimeout);
    await tester.pumpAndSettle();
    final error = find.byKey(const ValueKey('docker-manager-error'));
    expect(tester.widget<Text>(error).data, contains('Docker 查询超时，请重试'.tr));
    expect(tester.widget<AppIconButton>(refresh).onPressed, isNotNull);
    expect(find.text('web-api'), findsOneWidget);
    expect(source.closes, 1);
    expect(engine.sessions.first.closes, 0);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(error, findsNothing);
    gate.complete([dockerResource(name: 'stale-resource')]);
    await tester.pumpAndSettle();
    expect(find.text('stale-resource'), findsNothing);
    expect(engine.sessions, hasLength(3));
    expect(engine.sessions.last.closes, 0);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Docker 详情卡住后显示超时，重试按钮可重新获取详情', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    final gate = source.dockerDetailsGate = Completer<DockerDetails>();
    final resource = dockerResource();
    await tester.tap(
      find.byKey(ValueKey('docker-details-${resource.identity}')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在获取 Docker 详情…'.tr), findsOneWidget);
    await tester.pump(dockerQueryTimeout);
    await tester.pumpAndSettle();
    expect(find.text('Docker 查询超时，请重试'.tr), findsOneWidget);
    expect(source.closes, 1);
    await tester.tap(find.byKey(const ValueKey('docker-details-refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('docker-details-error')), findsNothing);
    expect(find.byKey(const ValueKey('docker-detail-id')), findsOneWidget);
    gate.completeError(const SshEngineException('Docker 管理连接已关闭'));
    await tester.pumpAndSettle();
    expect(engine.sessions.last.closes, 0);
    await tester.tap(find.byKey(const ValueKey('docker-details-close')));
    await tester.pumpAndSettle();
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Docker 折叠及切换其他面板暂停刷新，分屏保留面板和后台连接，失败保留列表并可重试', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    final first = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    final panel = find.byKey(const ValueKey('docker-manager-panel'));
    final element = tester.element(panel);
    final bounds = tester.getRect(panel);
    final reads = source.dockerReads.length;
    await tester.tap(_button('split-horizontal'));
    await tester.pumpAndSettle();
    final second = controller.activeSessionId.value!;
    await tester.tap(_terminal(controller, first));
    await tester.pumpAndSettle();
    expect(tester.element(panel), same(element));
    expect(tester.getRect(panel), bounds);
    expect(source.dockerReads, hasLength(reads));
    expect(engine.sessions, hasLength(3));
    await tester.tap(_button('toolbar-status'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(source.dockerReads, hasLength(reads));
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    expect(source.dockerReads, hasLength(reads + 1));
    for (final message in ['Docker 未运行', '没有权限获取 Docker 信息']) {
      source.dockerFailure = SshEngineException(message);
      await tester.tap(find.byKey(const ValueKey('docker-manager-refresh')));
      await tester.pumpAndSettle();
      final error = find.byKey(const ValueKey('docker-manager-error'));
      expect(tester.widget<Text>(error).data, contains(message.tr));
      expect(find.text('web-api'), findsOneWidget);
      expect(source.closes, 0);
      final readsAfterError = source.dockerReads.length;
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-docker'));
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-docker'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('docker-tab-image')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('docker-tab-container')));
      await tester.pumpAndSettle();
      expect(source.dockerReads, hasLength(readsAfterError));
    }
    source.dockerFailure = null;
    await tester.tap(find.byKey(const ValueKey('docker-manager-refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('docker-manager-error')), findsNothing);
    final paused = source.dockerReads.length;
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 12));
    expect(source.dockerReads, hasLength(paused));
    await tester.tap(_button('toolbar-docker'));
    await tester.pumpAndSettle();
    final other = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    final hiddenReads = source.dockerReads.length;
    await tester.pump(const Duration(seconds: 12));
    expect(source.dockerReads, hasLength(hiddenReads));
    await tester.runAsync(() => controller.close(other));
    controller.activate(second);
    await tester.pumpAndSettle();
    expect(tester.element(panel), same(element));
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
    expect(source.closes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具栏创建左右、上下嵌套会话，文字、中文输入法和 Enter 只发送到当前窗格', (tester) async {
    final (controller, engine, captureKey) = await _mount(tester);
    final first = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    final originalState = tester.state<TerminalViewState>(
      _terminal(controller, first),
    );
    final fullWidth = originalState.widget.terminal.viewWidth;
    expect(find.byKey(const ValueKey('terminal-toolbar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('server-status-floating-toggle')),
      findsNothing,
    );
    expect(
      tester.widget<AppIconButton>(_button('toolbar-status')).tooltip,
      '服务状态'.tr,
    );
    await tester.tap(_button('split-horizontal'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final second = controller.activeSessionId.value!;
    final firstBounds = tester.getRect(_pane(first));
    final secondBounds = tester.getRect(_pane(second));
    expect(firstBounds.right, lessThan(secondBounds.left));
    expect(firstBounds.top, secondBounds.top);
    expect(firstBounds.height, secondBounds.height);
    final leftRightGrip = find.descendant(
      of: find.byType(shadcn.HorizontalResizableDragger),
      matching: find.byType(Container),
    );
    final leftRightGripSize = tester.getSize(leftRightGrip);
    expect(leftRightGripSize.height, greaterThan(leftRightGripSize.width));
    expect(engine.sessions.map((session) => session.shellStarts), [1, 1]);
    final leftTerminal = controller.sessions.first.terminal!;
    final rightTerminal = controller.sessions.last.terminal!;
    expect(leftTerminal.viewWidth, lessThan(fullWidth));
    expect(leftTerminal.viewWidth, closeTo(rightTerminal.viewWidth, 1));

    await tester.tap(_button('split-vertical'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final third = controller.activeSessionId.value!;
    final upper = tester.getRect(_pane(second));
    final lower = tester.getRect(_pane(third));
    expect(upper.bottom, lessThan(lower.top));
    expect(upper.left, lower.left);
    expect(upper.width, lower.width);
    final topBottomGrip = find.descendant(
      of: find.byType(shadcn.VerticalResizableDragger),
      matching: find.byType(Container),
    );
    final topBottomGripSize = tester.getSize(topBottomGrip);
    expect(topBottomGripSize.width, greaterThan(topBottomGripSize.height));
    expect(tester.getRect(_pane(first)).height, greaterThan(upper.height));
    expect(rightTerminal.viewHeight, lessThan(leftTerminal.viewHeight));
    expect(
      rightTerminal.viewHeight,
      closeTo(controller.activeSession!.terminal!.viewHeight, 1),
    );
    expect(controller.tabs, hasLength(1));
    expect(
      tester.state<TerminalViewState>(_terminal(controller, first)),
      same(originalState),
    );
    expect(
      tester
          .widget<TerminalView>(_terminal(controller, third))
          .focusNode!
          .hasPrimaryFocus,
      isTrue,
    );
    tester.testTextInput.enterText('echo ');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    expect(engine.sessions.last.written.join(), 'echo ');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(engine.sessions.map((session) => session.written.join()), [
      '',
      '',
      'echo 中文\r',
    ]);
    await tester.tap(_terminal(controller, first));
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, first);
    tester.testTextInput.enterText('pwd');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(engine.sessions.first.written.join(), 'pwd\r');
    expect(engine.sessions[1].written, isEmpty);
    expect(engine.sessions.last.written.join(), 'echo 中文\r');
    for (var i = 0; i < engine.sessions.length; i++) {
      engine.sessions[i].output.add('rocky@example:~\$ session ${i + 1}\r\n');
    }
    await tester.pumpAndSettle();
    await _capture(tester, captureKey, 'terminal-nested-split');
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('拖动分隔条通知远端尺寸，嵌套、切换和关闭窗格保留比例及终端状态', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    final first = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    engine.sessions.first.output.add(
      List.generate(180, (index) => 'line $index\r\n').join(),
    );
    await tester.pumpAndSettle();
    final original = tester.widget<TerminalView>(_terminal(controller, first));
    final scroll = original.scrollController!;
    scroll.jumpTo(scroll.position.maxScrollExtent - 200);
    await tester.pumpAndSettle();
    await tester.tap(_button('split-horizontal'));
    await tester.pumpAndSettle();
    final second = controller.activeSessionId.value!;
    expect(
      tester
          .widget<TerminalView>(_terminal(controller, first))
          .scrollController,
      same(scroll),
    );
    final before = tester.getRect(_pane(first));
    final other = tester.getRect(_pane(second));
    final beforeColumns = controller.sessions.first.terminal!.viewWidth;
    expect(other.left, greaterThan(before.right));
    await tester.dragFrom(
      tester.getCenter(find.byType(shadcn.HorizontalResizableDragger)),
      const Offset(100, 0),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final resized = tester.getRect(_pane(first));
    expect(resized.width, greaterThan(before.width + 70));
    final terminal = controller.sessions.first.terminal!;
    expect(terminal.viewWidth, greaterThan(beforeColumns));
    expect(engine.sessions.first.sizes.last, (
      terminal.viewWidth,
      terminal.viewHeight,
    ));
    await tester.tap(_button('split-vertical'));
    await tester.pumpAndSettle();
    final third = controller.activeSessionId.value!;
    expect(tester.getRect(_pane(first)).width, closeTo(resized.width, 1));
    final offset = scroll.offset;
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    controller.activateTab(first);
    await tester.pumpAndSettle();
    expect(tester.getRect(_pane(first)).width, closeTo(resized.width, 1));
    expect(scroll.offset, closeTo(offset, 1));
    await tester.tap(find.byKey(ValueKey('terminal-pane-close-$third')));
    await tester.pumpAndSettle();
    expect(engine.sessions[2].closes, 1);
    expect(controller.tabs.first.sessionIds, [first, second]);
    expect(tester.getRect(_pane(first)).width, closeTo(resized.width, 1));
    await tester.tap(find.byKey(ValueKey('terminal-pane-close-$first')));
    await tester.pumpAndSettle();
    expect(controller.tabs.first.id, first);
    expect(controller.tabs.first.sessionIds, [second]);
    expect(engine.sessions[1].closes, 0);
    await tester.tap(find.byKey(ValueKey('session-tab-close-$first')));
    await tester.pumpAndSettle();
    expect(engine.sessions[1].closes, 1);
    expect(controller.tabs, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('上下分屏通过 Dragger 连续调高时两侧终端保持完整行并同步最终尺寸', (tester) async {
    final (controller, engine, captureKey) = await _mount(tester);
    final first = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('split-vertical'));
    await tester.pumpAndSettle();
    final second = controller.activeSessionId.value!;
    for (var index = 0; index < engine.sessions.length; index++) {
      engine.sessions[index].output.add(
        List.generate(
          100,
          (line) => 'session ${index + 1} line $line\r\n',
        ).join(),
      );
    }
    await tester.pumpAndSettle();
    await _capture(tester, captureKey, 'terminal-resize-before');
    final before = tester.getRect(_pane(first));
    final dragger = find.byType(shadcn.VerticalResizableDragger);
    expect(dragger, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(dragger));
    for (final dy in [11.0, 19.0, -7.0, 25.0, 32.0]) {
      await gesture.moveBy(Offset(0, dy));
      await tester.pump(const Duration(milliseconds: 40));
      for (final id in [first, second]) {
        final state = tester.state<TerminalViewState>(
          _terminal(controller, id),
        );
        final render = state.renderTerminal;
        final scroll = state.widget.scrollController!;
        final top = render.getCellOffset(Offset.zero);
        expect(
          render.getOffset(CellOffset(0, top.y)).dy,
          closeTo(0, .001),
          reason:
              'dy=$dy height=${render.size.height} line=${render.lineHeight} '
              'scroll=${scroll.offset}/${scroll.position.maxScrollExtent} '
              'rows=${state.widget.terminal.viewHeight}',
        );
      }
    }
    await _capture(tester, captureKey, 'terminal-resize-dragging');
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(_pane(first)).height,
      greaterThan(before.height + 60),
    );
    for (var index = 0; index < controller.sessions.length; index++) {
      final session = controller.sessions[index];
      final state = tester.state<TerminalViewState>(
        _terminal(controller, session.id),
      );
      final render = state.renderTerminal;
      final terminal = session.terminal!;
      expect(terminal.viewHeight, render.size.height ~/ render.lineHeight);
      expect(engine.sessions[index].sizes.last, (
        terminal.viewWidth,
        terminal.viewHeight,
      ));
      expect(
        render.getOffset(CellOffset(0, terminal.buffer.scrollBack)).dy,
        closeTo(0, .001),
      );
      expect(
        render.cursorOffset.dy + render.lineHeight,
        lessThanOrEqualTo(render.size.height),
      );
    }
    expect(tester.takeException(), isNull);
    await _capture(tester, captureKey, 'terminal-resize-after');
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('嵌套分屏短提示符在两个方向拖动及等待尺寸帧时保持可见', (tester) async {
    final (controller, engine, captureKey) = await _mount(tester);
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('split-vertical'));
    await tester.pumpAndSettle();
    await tester.tap(_button('split-horizontal'));
    await tester.pumpAndSettle();
    for (var i = 0; i < engine.sessions.length; i++) {
      engine.sessions[i].output.add(
        'Last login: session ${i + 1}\r\nrocky@host:~\$ ',
      );
    }
    await tester.pumpAndSettle();

    void expectPromptsVisible() {
      for (final session in controller.sessions) {
        final render = tester
            .state<TerminalViewState>(_terminal(controller, session.id))
            .renderTerminal;
        expect(render.getOffset(const CellOffset(0, 0)).dy, closeTo(0, .001));
        expect(render.cursorOffset.dy, closeTo(render.lineHeight, .001));
      }
    }

    for (final (dragger, direction) in [
      (find.byType(shadcn.VerticalResizableDragger), const Offset(0, 1)),
      (find.byType(shadcn.HorizontalResizableDragger), const Offset(1, 0)),
    ]) {
      final gesture = await tester.startGesture(tester.getCenter(dragger));
      for (final distance in [30.0, -11.0, 21.0, -45.0]) {
        await gesture.moveBy(direction * distance);
        await tester.pump(const Duration(milliseconds: 40));
        expectPromptsVisible();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expectPromptsVisible();
    }
    await _capture(tester, captureKey, 'terminal-short-nested-resize');
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('终端工具栏打开独立 SFTP 页签，重复点击复用页签并保留分屏', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    final first = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('split-vertical'));
    await tester.pumpAndSettle();
    final split = controller.activeSessionId.value!;
    expect(
      tester.widget<AppIconButton>(_button('open-sftp')).tooltip,
      '文件传输'.tr,
    );
    await tester.tap(_button('open-sftp'));
    await tester.pumpAndSettle();
    final transfer = controller.activeSessionId.value!;
    expect(controller.activeSession!.kind, SessionKind.fileTransfer);
    expect(controller.activeSession!.loginUsername, 'rocky');
    expect(controller.tabs, hasLength(2));
    expect(controller.tabs.first.sessionIds, [first, split]);
    expect(engine.sessions.map((session) => session.shellStarts), [1, 1, 0]);
    expect(find.text('本地文件'), findsOneWidget);
    expect(find.text('远程文件'), findsOneWidget);
    controller.activateTab(first);
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, split);
    await tester.tap(_button('open-sftp'));
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, transfer);
    expect(controller.tabs, hasLength(2));
    expect(engine.sessions, hasLength(3));
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('工具栏靠右且无标题，关闭按钮悬浮，工具栏与状态面板不随外壳主题变色', (tester) async {
    final (controller, engine, captureKey) = await _mount(tester);
    final first = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    final toolbar = find.byKey(const ValueKey('terminal-toolbar'));
    final toolbarBounds = tester.getRect(toolbar);
    final buttonBounds = [
      tester.getRect(_button('split-horizontal')),
      tester.getRect(_button('split-vertical')),
      tester.getRect(_button('open-sftp')),
      tester.getRect(_button('toolbar-docker')),
      tester.getRect(_button('toolbar-processes')),
      tester.getRect(_button('toolbar-status')),
    ];
    expect(
      find.descendant(of: toolbar, matching: find.byType(Text)),
      findsNothing,
    );
    expect(buttonBounds.first.left, greaterThan(toolbarBounds.center.dx));
    expect(buttonBounds.last.right, closeTo(toolbarBounds.right - 6, 1));
    for (final bounds in buttonBounds) {
      expect(bounds.size, buttonBounds.first.size);
      expect(bounds.center.dy, buttonBounds.first.center.dy);
    }
    expect(buttonBounds[0].right, lessThan(buttonBounds[1].left));
    expect(buttonBounds[1].right, lessThan(buttonBounds[2].left));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(buttonBounds.last.center);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('服务状态'.tr), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));
    await mouse.removePointer();
    await tester.pumpAndSettle();

    await tester.tap(_button('split-horizontal'));
    await tester.pumpAndSettle();
    final second = controller.activeSessionId.value!;
    final workspace = find.byType(TerminalTabWorkspace);
    expect(
      find.descendant(of: workspace, matching: find.text('rocky@example.test')),
      findsNothing,
    );
    for (final id in [first, second]) {
      final paneBounds = tester.getRect(_pane(id));
      final terminalBounds = tester.getRect(_terminal(controller, id));
      final closeBounds = tester.getRect(
        find.byKey(ValueKey('terminal-pane-close-$id')),
      );
      expect(terminalBounds.top - paneBounds.top, lessThan(8));
      expect(terminalBounds.contains(closeBounds.center), isTrue);
      expect(closeBounds.right, closeTo(paneBounds.right - 5, 1));
    }
    await tester.tap(_button('toolbar-status'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    final state = tester.state<TerminalViewState>(
      _terminal(controller, second),
    );
    final settings = Get.find<SettingsController>();
    for (final mode in [AppThemeMode.light, AppThemeMode.dark]) {
      await settings.setThemeMode(mode);
      await tester.pumpAndSettle();
      for (final area in [
        toolbar,
        find.byKey(const ValueKey('server-status-details')),
      ]) {
        final box = tester.widget<Container>(area).decoration! as BoxDecoration;
        expect(box.color, AppTheme.terminalBackground);
      }
      final colors = shadcn.Theme.of(tester.element(_button('toolbar-status')))
          .colorScheme;
      expect(colors.brightness, Brightness.dark);
      expect(colors.foreground, AppTheme.terminalForeground);
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const ValueKey('terminal-surface')))
            .color,
        AppTheme.terminalBackground,
      );
      final progressColors = find
          .byType(shadcn.LinearProgressIndicator)
          .evaluate()
          .map(
            (element) =>
                shadcn.ComponentTheme.maybeOf<
                      shadcn.LinearProgressIndicatorTheme
                    >(element)!
                    .color,
          );
      expect(progressColors, [
        AppTheme.terminalMutedForeground,
        AppTheme.serverStatusCpuColor,
        AppTheme.serverStatusMemoryColor,
        AppTheme.serverStatusDiskColor,
      ]);
      expect(
        DefaultTextStyle.of(tester.element(find.text('服务状态'.tr))).style.color,
        AppTheme.terminalForeground,
      );
      expect(
        tester.state<TerminalViewState>(_terminal(controller, second)),
        same(state),
      );
      expect(
        tester.widget<AppIconButton>(_button('toolbar-status')).tooltip,
        '服务状态'.tr,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, captureKey, 'terminal-status-${mode.name}');
    }
    expect(engine.sessions.map((session) => session.shellStarts), [1, 1, 0]);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('进程详情点击才读取、无定时查询、可手动刷新及关闭 ${locale.languageCode}', (
      tester,
    ) async {
      final (controller, engine, captureKey) = await _mount(tester);
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-processes'));
      await tester.pumpAndSettle();
      final source = engine.sessions.last;
      expect(source.detailsRead, isEmpty);
      source.detailsGate = Completer<ProcessDetails>();
      await tester.tap(find.byKey(const ValueKey('process-details-42')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在获取进程详情…'.tr), findsOneWidget);
      expect(source.detailsRead.single.pid, 42);
      await tester.pump(const Duration(seconds: 6));
      expect(source.detailsRead, hasLength(1));
      source.detailsGate!.complete(
        processDetails(process: source.detailsRead.single),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('process-details-path')),
        findsOneWidget,
      );
      expect(find.text('/usr/local/libexec/cpu-worker'), findsOneWidget);
      final path = find.byKey(const ValueKey('process-details-path'));
      expect(
        tester.getTopLeft(find.text('执行路径'.tr)).dy,
        closeTo(tester.getTopLeft(path).dy, 1),
      );
      expect(
        tester.getTopLeft(path).dx,
        closeTo(tester.getTopLeft(find.text('1-02:03:04')).dx, 1),
      );
      expect(find.text('父进程 PID'.tr), findsOneWidget);
      expect(find.text('1-02:03:04'), findsOneWidget);
      await _capture(
        tester,
        captureKey,
        'process-details-${locale.languageCode}',
      );
      await tester.pump(const Duration(seconds: 6));
      expect(source.detailsRead, hasLength(1));
      source.detailsGate = null;
      await tester.tap(find.byKey(const ValueKey('process-details-refresh')));
      await tester.pumpAndSettle();
      expect(source.detailsRead, hasLength(2));
      await tester.tap(find.byKey(const ValueKey('process-details-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('process-details-dialog')),
        findsNothing,
      );
      expect(source.terminated, isEmpty);
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('进程详情失败可重试，关闭后迟到结果不更新界面或发起额外查询', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-processes'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    source.detailsFailure = const SshEngineException('进程已退出，请刷新列表');
    await tester.tap(find.byKey(const ValueKey('process-details-81')));
    await tester.pumpAndSettle();
    expect(find.text('进程已退出，请刷新列表'), findsOneWidget);
    expect(source.closes, 0);
    source.detailsFailure = null;
    await tester.tap(find.byKey(const ValueKey('process-details-refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('process-details-error')), findsNothing);
    expect(source.detailsRead.map((p) => p.pid), [81, 81]);
    await tester.tap(find.byKey(const ValueKey('process-details-close')));
    await tester.pumpAndSettle();
    source.detailsGate = Completer<ProcessDetails>();
    await tester.tap(find.byKey(const ValueKey('process-details-42')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('process-details-close')));
    await tester.pumpAndSettle();
    source.detailsGate!.complete(
      processDetails(process: source.detailsRead.last),
    );
    await tester.pumpAndSettle();
    expect(source.detailsRead.map((p) => p.pid), [81, 81, 42]);
    expect(find.byKey(const ValueKey('process-details-dialog')), findsNothing);
    expect(find.byKey(const ValueKey('process-card-42')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('进程面板排序搜索、动画折叠、切换服务状态和分屏保留数据 ${locale.languageCode}', (
      tester,
    ) async {
      final (controller, engine, captureKey) = await _mount(tester);
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      final first = await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      final state = tester.state<TerminalViewState>(
        _terminal(controller, first),
      );
      final terminalWidth = state.widget.terminal.viewWidth;
      await tester.tap(_button('toolbar-processes'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final details = find.byKey(const ValueKey('process-manager-details'));
      expect(details, findsOneWidget);
      await tester.pumpAndSettle();
      final width = tester.getSize(details).width;
      final source = engine.sessions.last;
      expect(engine.sessions, hasLength(2));
      expect(source.shellStarts, 0);
      expect(source.processReads, 1);
      expect(source.samples, 0);
      expect(find.byKey(const ValueKey('server-status-details')), findsNothing);
      expect(find.text('150.0%'), findsOneWidget);
      expect(find.text('50.0%'), findsOneWidget);
      expect(find.byType(shadcn.Select<ProcessSort>), findsNothing);
      expect(find.byType(shadcn.RadioCard<ProcessSort>), findsNWidgets(2));
      for (final sort in ProcessSort.values) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('process-sort-${sort.name}')),
            matching: findAppIcon(AppIcons.arrowDown),
          ),
          findsOneWidget,
        );
      }
      final search = find.byKey(const ValueKey('process-manager-search'));
      expect(tester.getSize(search).height, lessThan(AppTheme.inputMinHeight));
      expect(find.byKey(const ValueKey('process-path-42')), findsNothing);
      expect(source.detailsRead, isEmpty);
      expect(find.byKey(const ValueKey('process-details-42')), findsOneWidget);
      final terminateButton = find.byKey(
        const ValueKey('process-terminate-42'),
      );
      final detailsButton = find.byKey(const ValueKey('process-details-42'));
      expect(
        tester.getCenter(terminateButton).dy,
        closeTo(tester.getCenter(detailsButton).dy, 1),
      );
      expect(
        tester.getBottomRight(detailsButton).dx,
        lessThan(tester.getTopLeft(terminateButton).dx),
      );
      expect(
        find.descendant(
          of: detailsButton,
          matching: findAppIcon(AppIcons.info),
        ),
        findsOneWidget,
      );
      final metrics = find.byKey(const ValueKey('process-metrics-42'));
      final cpu = find.descendant(of: metrics, matching: find.text('150.0%'));
      final memory = find.descendant(of: metrics, matching: find.text('9.8%'));
      final bytes = find.descendant(
        of: metrics,
        matching: find.text(' / 100.0 MiB'),
      );
      expect(tester.getCenter(cpu).dy, closeTo(tester.getCenter(memory).dy, 1));
      expect(
        tester.getCenter(memory).dy,
        closeTo(tester.getCenter(bytes).dy, 1),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('process-card-42'))).height,
        lessThan(100),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('process-card-81'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('process-card-42'))).dy,
        ),
      );
      await _capture(
        tester,
        captureKey,
        'process-manager-${locale.languageCode}',
      );
      expect(
        tester
            .widget<shadcn.RadioGroup<ProcessSort>>(
              find.byKey(const ValueKey('process-manager-sort')),
            )
            .value,
        ProcessSort.memory,
      );
      await tester.tap(find.byKey(const ValueKey('process-sort-cpu')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<shadcn.RadioGroup<ProcessSort>>(
              find.byKey(const ValueKey('process-manager-sort')),
            )
            .value,
        ProcessSort.cpu,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('process-card-42'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('process-card-81'))).dy,
        ),
      );
      await tester.enterText(search, 'MEMORY');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('process-card-81')), findsOneWidget);
      expect(find.byKey(const ValueKey('process-card-42')), findsNothing);
      final before = source.processReads;
      await tester.tap(_button('toolbar-processes'));
      await tester.pumpAndSettle();
      expect(details, findsNothing);
      expect(state.widget.terminal.viewWidth, terminalWidth);
      await tester.pump(const Duration(seconds: 6));
      expect(source.processReads, before);
      await tester.tap(_button('toolbar-processes'));
      await tester.pumpAndSettle();
      expect(tester.widget<AppTextFormField>(search).controller.text, 'MEMORY');
      expect(tester.getSize(details).width, width);
      await tester.tap(_button('toolbar-status'));
      await tester.pumpAndSettle();
      expect(details, findsNothing);
      expect(source.samples, 1);
      expect(engine.sessions, hasLength(2));
      final paused = source.processReads;
      await tester.pump(const Duration(seconds: 3));
      expect(source.processReads, paused);
      await tester.tap(_button('toolbar-processes'));
      await tester.pumpAndSettle();
      expect(tester.widget<AppTextFormField>(search).controller.text, 'MEMORY');
      final bounds = tester.getRect(details);
      await tester.tap(_button('split-horizontal'));
      await tester.pump();
      expect(tester.getRect(details), bounds);
      await tester.pumpAndSettle();
      final reads = source.processReads;
      controller.activate(first);
      await tester.pumpAndSettle();
      expect(source.processReads, reads);
      expect(
        tester.state<TerminalViewState>(_terminal(controller, first)),
        same(state),
      );
      await tester.dragFrom(
        tester.getCenter(
          find.byKey(const ValueKey('terminal-side-panel-dragger')),
        ),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(details).width,
        closeTo(AppTheme.serverStatusMinWidth, 1),
      );
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        captureKey,
        'process-manager-narrow-${locale.languageCode}',
      );
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
    });
  }

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('结束进程名称必须完全匹配，取消不发请求，成功后刷新，权限失败保持列表 ${locale.languageCode}', (
      tester,
    ) async {
      final (controller, engine, captureKey) = await _mount(tester);
      unawaited(Get.updateLocale(locale));
      await tester.pumpAndSettle();
      await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-processes'));
      await tester.pumpAndSettle();
      final source = engine.sessions.last;
      final end = find.byKey(const ValueKey('process-terminate-42'));
      await tester.tap(end);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('process-terminate-confirmation')),
        findsOneWidget,
      );
      expect(find.text('高危操作：结束进程'.tr), findsOneWidget);
      expect(source.terminated, isEmpty);
      final confirmation = find.byKey(
        const ValueKey('process-confirm-terminate'),
      );
      final nameInput = find.byKey(const ValueKey('process-terminate-name'));
      expect(
        tester.widget<shadcn.DestructiveButton>(confirmation).onPressed,
        isNull,
      );
      await _capture(
        tester,
        captureKey,
        'process-terminate-confirmation-${locale.languageCode}',
      );
      await tester.tap(find.text('取消'.tr));
      await tester.pumpAndSettle();
      expect(source.terminated, isEmpty);
      await tester.tap(end);
      await tester.pumpAndSettle();
      for (final wrong in ['', 'CPU-worker', 'cpu-worker ', ' cpu-worker']) {
        await tester.enterText(nameInput, wrong);
        await tester.pumpAndSettle();
        expect(
          tester.widget<shadcn.DestructiveButton>(confirmation).onPressed,
          isNull,
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(source.terminated, isEmpty);
        expect(nameInput, findsOneWidget);
        await tester.tap(nameInput);
        await tester.pumpAndSettle();
      }
      await tester.enterText(nameInput, 'cpu-worker');
      await tester.pumpAndSettle();
      expect(
        tester.widget<shadcn.DestructiveButton>(confirmation).onPressed,
        isNotNull,
      );
      final readsBeforeConfirmation = source.processReads;
      await tester.tap(confirmation);
      await tester.pumpAndSettle();
      expect(source.terminated.single.pid, 42);
      expect(source.terminated.single.startedAt, 'Fri Nov 6 14:20:00 2026');
      expect(find.text('已发送结束请求'.tr), findsOneWidget);
      expect(source.processReads, greaterThan(readsBeforeConfirmation));
      expect(
        tester
            .widget<AppIconButton>(
              find.byKey(const ValueKey('process-terminate-1')),
            )
            .onPressed,
        isNull,
      );
      source.terminationFailure = const SshEngineException(
        '无法结束进程，进程可能已退出或权限不足',
      );
      await tester.tap(find.byKey(const ValueKey('process-terminate-81')));
      await tester.pumpAndSettle();
      await tester.enterText(nameInput, 'Memory Worker');
      await tester.pumpAndSettle();
      await tester.tap(confirmation);
      await tester.pumpAndSettle();
      expect(find.text('无法结束进程，进程可能已退出或权限不足'.tr), findsOneWidget);
      expect(find.byKey(const ValueKey('process-card-81')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(source.terminated.map((p) => p.pid), [42, 81]);
      expect(tester.takeException(), isNull);
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('进程列表按需构建全部进程可检索，切换页签暂停采样', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    final first = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-processes'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    source.processList = [
      for (var i = 0; i < 2500; i++)
        remoteProcess(pid: i + 2, name: 'worker-${i + 2}'),
    ];
    await tester.tap(find.byKey(const ValueKey('process-manager-refresh')));
    await tester.pumpAndSettle();
    final visibleCards = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('process-card-'),
    );
    expect(visibleCards.evaluate().length, lessThan(30));
    expect(find.text('2500 / 2500 个进程'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('process-manager-search')),
      '2501',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('process-card-2501')), findsOneWidget);
    await controller.open(
      const Host(id: 'two', name: 'Other server', hostname: 'other.test'),
      _credentials,
    );
    await tester.pumpAndSettle();
    final reads = source.processReads;
    await tester.pump(const Duration(seconds: 6));
    expect(source.processReads, reads);
    controller.activateTab(first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('process-card-2501')), findsOneWidget);
    expect(source.processReads, reads + 1);
    expect(engine.sessions, hasLength(3));
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  for (final direction in ['horizontal', 'vertical']) {
    testWidgets('$direction 分屏连接期间服务面板持续显示且宽度不跳变', (tester) async {
      final (controller, engine, captureKey) = await _mount(tester);
      final first = await controller.open(_host, _credentials);
      await tester.pumpAndSettle();
      await tester.tap(_button('toolbar-status'));
      await tester.pumpAndSettle();
      final details = find.byKey(const ValueKey('server-status-details'));
      final dragger = find.byKey(const ValueKey('terminal-side-panel-dragger'));
      await tester.dragFrom(tester.getCenter(dragger), const Offset(-80, 0));
      await tester.pumpAndSettle();
      final originalBounds = tester.getRect(details);
      final originalElement = tester.element(details);
      final originalTerminal = tester.state<TerminalViewState>(
        _terminal(controller, first),
      );
      final statusSource = engine.sessions.last;
      final samples = statusSource.samples;
      final basic = find.byKey(const ValueKey('server-status-card-basic'));
      final basicElement = tester.element(basic);
      final gate = Completer<void>();
      engine.nextConnection = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      await tester.tap(_button('split-$direction'));
      final second = controller.activeSessionId.value!;
      expect(second, isNot(first));
      expect(controller.activeSession!.phase, SessionPhase.connecting);
      expect(controller.activeSession!.engineSession, isNull);
      for (final elapsed in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 200),
        const Duration(seconds: 3),
      ]) {
        await tester.pump(elapsed);
        expect(details, findsOneWidget);
        expect(find.text('连接建立后将显示服务状态'.tr), findsNothing);
        expect(find.text('正在获取服务状态…'.tr), findsNothing);
        expect(find.text('Ubuntu 24.04 LTS'), findsOneWidget);
        expect(tester.element(basic), same(basicElement));
        expect(tester.element(details), same(originalElement));
        expect(tester.getRect(details), originalBounds);
        expect(_pane(second), findsOneWidget);
        expect(
          tester.getRect(_pane(second)).right,
          lessThanOrEqualTo(originalBounds.left),
        );
        expect(
          tester.widget<AppIconButton>(_button('toolbar-status')).semanticLabel,
          '折叠服务状态'.tr,
        );
        expect(
          tester.state<TerminalViewState>(_terminal(controller, first)),
          same(originalTerminal),
        );
      }
      expect(statusSource.samples, samples + 1);
      expect(engine.sessions.first.samples, 0);
      await _capture(tester, captureKey, 'status-split-$direction-connecting');
      gate.complete();
      await tester.pumpAndSettle();
      expect(controller.activeSession!.phase, SessionPhase.ready);
      expect(tester.element(details), same(originalElement));
      expect(tester.getRect(details), originalBounds);
      expect(engine.sessions.last.samples, 0);
      expect(statusSource.samples, samples + 1);
      expect(engine.sessions, hasLength(3));
      await _capture(tester, captureKey, 'status-split-$direction-connected');
      await tester.tap(find.byKey(ValueKey('terminal-pane-close-$second')));
      await tester.pumpAndSettle();
      expect(tester.element(details), same(originalElement));
      expect(tester.getRect(details), originalBounds);
      expect(controller.activeSessionId.value, first);
      expect(tester.takeException(), isNull);
      await tester.runAsync(controller.closeAll);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('分屏连接期间可折叠服务面板，连接完成后保持折叠且不采样', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-status'));
    await tester.pumpAndSettle();
    final details = find.byKey(const ValueKey('server-status-details'));
    final statusSource = engine.sessions.last;
    final width = tester.getSize(details).width;
    final gate = Completer<void>();
    engine.nextConnection = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await tester.tap(_button('split-vertical'));
    await tester.pump();
    expect(details, findsOneWidget);
    final toggle = tester.widget<AppIconButton>(_button('toolbar-status'));
    expect(toggle.onPressed, isNotNull);
    await tester.tap(_button('toolbar-status'));
    await tester.pump();
    expect(details, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(details, findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(engine.sessions.last.samples, 0);
    expect(statusSource.samples, 1);
    await tester.tap(_button('toolbar-status'));
    await tester.pumpAndSettle();
    expect(tester.getSize(details).width, width);
    expect(statusSource.samples, 2);
    expect(engine.sessions, hasLength(3));
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
  });

  testWidgets('分屏切换共用页签独立状态连接并保留采样，关闭首个窗格后仍可用', (tester) async {
    final (controller, engine, _) = await _mount(tester);
    final first = await controller.open(_host, _credentials);
    await tester.pumpAndSettle();
    final second = (await controller.splitTerminal(
      first,
      SessionSplitAxis.horizontal,
    ))!;
    await tester.pumpAndSettle();
    await tester.tap(_button('toolbar-status'));
    await tester.pumpAndSettle();
    final source = engine.sessions.last;
    final details = find.byKey(const ValueKey('server-status-details'));
    final panelElement = tester.element(details);
    final card = find.byKey(const ValueKey('server-status-card-cpu'));
    final cpuElement = tester.element(card);
    expect(engine.sessions.map((session) => session.samples), [0, 0, 1]);
    expect(engine.sessions.map((session) => session.shellStarts), [1, 1, 0]);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('60.0%'), findsOneWidget);
    final updated = find.byKey(const ValueKey('server-status-updated'));
    final timestamp = tester.widget<Text>(updated).data;
    await tester.tap(_terminal(controller, first));
    for (final elapsed in [Duration.zero, const Duration(milliseconds: 16)]) {
      await tester.pump(elapsed);
      expect(tester.element(details), same(panelElement));
      expect(tester.element(card), same(cpuElement));
      expect(tester.widget<Text>(updated).data, timestamp);
      expect(find.text('60.0%'), findsOneWidget);
      expect(find.text('正在获取服务状态…'.tr), findsNothing);
    }
    expect(engine.sessions.map((session) => session.samples), [0, 0, 2]);
    await tester.tap(_terminal(controller, second));
    await tester.pumpAndSettle();
    expect(engine.sessions, hasLength(3));
    expect(source.samples, 2);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(engine.sessions.map((session) => session.samples), [0, 0, 3]);
    await tester.tap(find.byKey(ValueKey('terminal-pane-close-$first')));
    await tester.pumpAndSettle();
    expect(controller.activeSessionId.value, second);
    expect(source.samples, 3);
    expect(source.closes, 0);
    expect(tester.element(details), same(panelElement));
    expect(find.text('60.0%'), findsOneWidget);
    await controller.splitTerminal(second, SessionSplitAxis.horizontal);
    await tester.pumpAndSettle();
    await controller.splitTerminal(second, SessionSplitAxis.vertical);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(480, 360);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsNWidgets(3));
    expect(find.byKey(const ValueKey('server-status-details')), findsNothing);
    expect(
      find.byKey(const ValueKey('server-status-floating-toggle')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.runAsync(controller.closeAll);
    await tester.pumpAndSettle();
    expect(source.closes, 1);
  });
}
