import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/terminal/docker_manager_panel.dart';

import 'support/docker_fixture.dart';
import 'support/shadcn_test_app.dart';

class _Source implements DockerManagerSource, DockerComposeActions {
  DockerResource? project = dockerResource(kind: DockerResourceKind.compose);
  final actions = <DockerComposeAction>[];
  final reads = <DockerResourceKind>[];
  final details = <DockerResource>[];
  Completer<DockerActionResult>? gate;

  @override
  Future<List<DockerResource>> readDockerResources(
    DockerResourceKind kind,
  ) async {
    reads.add(kind);
    return kind == DockerResourceKind.compose && project != null
        ? [project!]
        : [];
  }

  @override
  Future<DockerDetails> readDockerDetails(DockerResource resource) async {
    details.add(resource);
    return dockerDetails(resource);
  }

  @override
  Future<DockerActionResult> runDockerComposeAction(
    DockerResource project,
    DockerComposeAction action,
  ) async {
    actions.add(action);
    if (gate != null) return gate!.future;
    if (action == DockerComposeAction.delete) {
      this.project = null;
    } else {
      this.project = dockerResource(
        kind: DockerResourceKind.compose,
        fields: {
          ...project.fields,
          DockerField.state: action == DockerComposeAction.stop
              ? 'exited'
              : 'running',
        },
      );
    }
    return const DockerActionResult();
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

Future<GlobalKey> _open(
  WidgetTester tester,
  _Source source,
  Locale locale, {
  double width = 420,
}) async {
  final captureKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: ShadcnTestApp(
        locale: locale,
        home: Center(
          child: SizedBox(
            width: width,
            height: 650,
            child: DockerManagerPanel(source: source, active: true),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('docker-tab-compose')));
  await tester.pumpAndSettle();
  return captureKey;
}

Future<void> _menu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('docker-more-compose:app')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() async {
    if (_captureDir.isEmpty) return;
    await (FontLoader('packages/shadcn_flutter/GeistSans')..addFont(
          rootBundle.load(
            'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
          ),
        ))
        .load();
    final cjk = File('/System/Library/Fonts/STHeiti Light.ttc');
    if (cjk.existsSync()) {
      await (FontLoader(
        'PingFang SC',
      )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  tearDown(Get.reset);

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('编排位于容器之前，支持信息、单个启停按钮和更多菜单 $locale', (tester) async {
      final source = _Source();
      final capture = await _open(tester, source, locale);
      await _capture(tester, capture, 'compose-${locale.languageCode}');
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('docker-tab-compose'))).dx,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('docker-tab-container')))
              .dx,
        ),
      );
      expect(
        find.byKey(const ValueKey('docker-stop-compose:app')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('docker-start-compose:app')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('docker-details-compose:app')),
      );
      await tester.pumpAndSettle();
      expect(source.details.single.id, 'app');
      await _capture(tester, capture, 'compose-details-${locale.languageCode}');
      expect(find.text('/srv/app/compose.yaml'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('docker-details-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('docker-stop-compose:app')));
      await tester.pumpAndSettle();
      expect(source.actions, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('docker-compose-confirm-stop')),
      );
      await tester.pumpAndSettle();
      expect(source.actions, [DockerComposeAction.stop]);
      await tester.tap(find.byKey(const ValueKey('docker-start-compose:app')));
      await tester.pumpAndSettle();
      expect(source.actions.last, DockerComposeAction.start);
      await _menu(tester);
      expect(find.text('重建'.tr), findsOneWidget);
      expect(find.text('删除'.tr), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('重建需要确认，等待期间禁止重复执行，显示具体失败且不自动刷新', (tester) async {
    final source = _Source()..gate = Completer<DockerActionResult>();
    final capture = await _open(
      tester,
      source,
      const Locale('zh', 'CN'),
      width: 260,
    );
    await _capture(tester, capture, 'compose-narrow');
    expect(tester.takeException(), isNull);
    await _menu(tester);
    await tester.tap(find.text('重建'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无缓存构建'), findsOneWidget);
    await _capture(tester, capture, 'compose-rebuild');
    expect(source.actions, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey('docker-compose-confirm-rebuild')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('docker-compose-confirm-rebuild')),
    );
    await tester.pump();
    expect(source.actions, [DockerComposeAction.rebuild]);
    source.gate!.completeError(
      const SshEngineException('未安装 Docker Compose，请安装 Compose 插件后重试'),
    );
    await tester.pumpAndSettle();
    expect(find.text('未安装 Docker Compose，请安装 Compose 插件后重试'), findsWidgets);
    final reads = source.reads.length;
    await tester.pump(const Duration(seconds: 20));
    expect(source.reads, hasLength(reads));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('docker-card-compose:app')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('删除必须输入完全一致的编排名，成功重新读取列表', (tester) async {
    final source = _Source();
    await _open(tester, source, const Locale('zh', 'CN'));
    await _menu(tester);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('docker-compose-confirm-delete'));
    await tester.tap(confirm);
    expect(source.actions, isEmpty);
    final input = tester.widget<AppTextFormField>(
      find.byKey(const ValueKey('docker-compose-delete-name')),
    );
    input.controller.text = 'APP';
    await tester.pump();
    await tester.tap(confirm);
    expect(source.actions, isEmpty);
    input.controller.text = 'app';
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(source.actions, [DockerComposeAction.delete]);
    expect(find.byKey(const ValueKey('docker-card-compose:app')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
