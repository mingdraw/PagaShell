import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/presentation/rdp/rdp_desktop_panel.dart';
import 'package:pagashell/presentation/rdp/rdp_surface.dart';

import 'support/fake_rdp_engine.dart';
import 'support/shadcn_test_app.dart';

class _TrackedSession extends FakeRdpSession {
  _TrackedSession() {
    updates = StreamController<RdpFrame>(
      onPause: () => pauses++,
      onResume: () => resumes++,
    );
  }
  late final StreamController<RdpFrame> updates;
  int pauses = 0;
  int resumes = 0;
  @override
  Stream<RdpFrame> get frames => updates.stream;
  @override
  Future<void> close() async {
    unawaited(updates.close());
    await super.close();
  }
}

void main() {
  tearDown(Get.reset);

  Future<void> settlePixels(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
  }

  RdpSurface current(WidgetTester tester) =>
      (tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('rdp-desktop-image')),
                  )
                  .painter!
              as RdpSurfacePainter)
          .surface;

  testWidgets('局部像素更新保留其余画面，跳帧恢复和分辨率变化可完整替换', (tester) async {
    final session = FakeRdpSession();
    final errors = <String>[];
    await tester.pumpWidget(
      ShadcnTestApp(
        home: RdpDesktopPanel(
          session: session,
          active: true,
          onError: errors.add,
        ),
      ),
    );
    session.output.add(
      RdpFrame(
        width: 4,
        height: 3,
        rgba: Uint8List.fromList(List.filled(4 * 3 * 4, 255)),
      ),
    );
    await settlePixels(tester);
    session.output.add(
      RdpFrame(
        width: 4,
        height: 3,
        x: 2,
        y: 1,
        patchWidth: 1,
        patchHeight: 1,
        rgba: Uint8List.fromList([255, 0, 0, 255]),
      ),
    );
    await settlePixels(tester);
    final data = await tester.runAsync(() async {
      final surface = current(tester);
      final recorder = ui.PictureRecorder();
      surface.paint(ui.Canvas(recorder));
      final picture = recorder.endRecording();
      final image = await picture.toImage(surface.width, surface.height);
      try {
        return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
        picture.dispose();
      }
    });
    final bytes = data!.buffer.asUint8List();
    expect(bytes.sublist((1 * 4 + 2) * 4, (1 * 4 + 3) * 4), [255, 0, 0, 255]);
    expect(bytes.sublist(0, 4), [255, 255, 255, 255]);
    expect(bytes.sublist(bytes.length - 4), [255, 255, 255, 255]);
    session.output.add(
      RdpFrame(
        width: 6,
        height: 2,
        rgba: Uint8List.fromList(List.filled(6 * 2 * 4, 255)),
      ),
    );
    await settlePixels(tester);
    expect(current(tester).width, 6);
    expect(current(tester).height, 2);
    expect(errors, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });

  testWidgets('光标形状单独更新，移动鼠标不重新解码桌面', (tester) async {
    final session = FakeRdpSession();
    final errors = <String>[];
    await tester.pumpWidget(
      ShadcnTestApp(
        home: RdpDesktopPanel(
          session: session,
          active: true,
          onError: errors.add,
        ),
      ),
    );
    session.output.add(
      RdpFrame(
        width: 64,
        height: 32,
        rgba: Uint8List.fromList(List.filled(64 * 32 * 4, 255)),
      ),
    );
    await settlePixels(tester);
    final generation = current(tester).generation;
    session.output.add(
      RdpFrame(
        width: 64,
        height: 32,
        patchWidth: 0,
        patchHeight: 0,
        rgba: Uint8List(0),
        cursor: RdpCursor(
          kind: RdpCursorKind.bitmap,
          width: 2,
          height: 2,
          hotspotX: 1,
          hotspotY: 1,
          rgba: Uint8List.fromList(List.filled(16, 255)),
        ),
      ),
    );
    await settlePixels(tester);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    final center = tester.getCenter(
      find.byKey(const ValueKey('rdp-desktop-image')),
    );
    await mouse.addPointer(location: center);
    await tester.pump();
    expect(find.byKey(const ValueKey('rdp-cursor-image')), findsOneWidget);
    final oldPosition = tester.getTopLeft(
      find.byKey(const ValueKey('rdp-cursor-image')),
    );
    await mouse.moveTo(center + const Offset(20, 10));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('rdp-cursor-image'))),
      oldPosition + const Offset(20, 10),
    );
    expect(current(tester).generation, generation);
    expect(errors, isEmpty);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });

  testWidgets('待发送鼠标移动被切换标签取消后，返回标签仍继续发送移动', (tester) async {
    final session = FakeRdpSession();
    final errors = <String>[];
    Widget panel(bool active) => ShadcnTestApp(
      home: RdpDesktopPanel(
        session: session,
        active: active,
        onError: errors.add,
      ),
    );
    await tester.pumpWidget(panel(true));
    session.output.add(
      RdpFrame(
        width: 64,
        height: 32,
        rgba: Uint8List.fromList(List.filled(64 * 32 * 4, 255)),
      ),
    );
    await settlePixels(tester);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    final center = tester.getCenter(
      find.byKey(const ValueKey('rdp-desktop-image')),
    );
    await mouse.addPointer(location: center);
    await mouse.moveTo(center + const Offset(10, 0));
    await tester.pumpWidget(panel(false));
    await tester.pumpWidget(panel(true));
    session.pointers.clear();
    await mouse.moveTo(center + const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 20));
    expect(session.pointers.where((p) => p.$3 == 0x0800), hasLength(1));
    expect(errors, isEmpty);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });

  testWidgets('后台桌面暂停帧订阅，恢复激活后继续处理', (tester) async {
    final session = _TrackedSession();
    final errors = <String>[];
    Widget panel(bool active) => ShadcnTestApp(
      home: RdpDesktopPanel(
        session: session,
        active: active,
        onError: errors.add,
      ),
    );
    await tester.pumpWidget(panel(false));
    await tester.pump();
    expect(session.pauses, 1);
    await tester.pumpWidget(panel(true));
    await tester.pump();
    expect(session.resumes, 1);
    session.updates.add(
      RdpFrame(
        width: 4,
        height: 3,
        rgba: Uint8List.fromList(List.filled(48, 255)),
      ),
    );
    await settlePixels(tester);
    expect(current(tester).width, 4);
    final pauses = session.pauses;
    await tester.pumpWidget(panel(false));
    await tester.pump();
    expect(session.pauses, pauses + 1);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });
}
