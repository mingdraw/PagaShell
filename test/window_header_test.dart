import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/presentation/configuration/configuration_transfer_dialog.dart';
import 'package:pagashell/presentation/shell/widgets/sidebar.dart';
import 'package:pagashell/presentation/shell/widgets/status_bar.dart';
import 'package:pagashell/presentation/shell/widgets/title_bar.dart';
import 'package:pagashell/presentation/shell/widgets/window_controls.dart';
import 'package:pagashell/presentation/shell/widgets/workspace.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:window_manager/window_manager.dart';

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  Future<void> pumpApp(WidgetTester tester, TargetPlatform platform) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: platform),
    );
    await tester.pumpAndSettle();
  }

  Finder captionButton(String label) => find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  );

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform 配置按钮位于侧栏左下角设置旁，收起隐藏且不触发拖窗', (tester) async {
      final calls = <String>[];
      const nativeChannel = MethodChannel('pagashell/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          nativeChannel,
          null,
        ),
      );
      await pumpApp(tester, platform);
      final settingsButton = find.byKey(const ValueKey('app-settings-button'));
      final importButton = find.byKey(const ValueKey('import-configuration'));
      final exportButton = find.byKey(const ValueKey('export-configuration'));
      expect(settingsButton, findsOneWidget);
      for (final button in [importButton, exportButton]) {
        expect(button, findsOneWidget);
        expect(
          tester.getCenter(button).dy,
          tester.getCenter(settingsButton).dy,
        );
        expect(
          tester.getRect(button).top,
          greaterThanOrEqualTo(800 - AppTheme.sidebarFooterHeight),
        );
        expect(tester.getRect(button).right, lessThan(AppTheme.sidebarWidth));
        await tester.drag(button, const Offset(40, 0));
      }
      expect(
        tester.getRect(importButton).left,
        greaterThanOrEqualTo(tester.getRect(settingsButton).right),
      );
      expect(
        tester.getRect(exportButton).left,
        greaterThanOrEqualTo(tester.getRect(importButton).right),
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      for (final entry in {
        settingsButton: '设置',
        importButton: '导入配置',
        exportButton: '导出配置',
      }.entries) {
        final iconButton = find.descendant(
          of: entry.key,
          matching: find.byType(shadcn.IconButton),
        );
        expect(iconButton, findsOneWidget);
        expect(
          tester.widget<shadcn.IconButton>(iconButton).variance,
          shadcn.ButtonVariance.ghost,
        );
        await mouse.moveTo(tester.getCenter(entry.key));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(shadcn.TooltipContainer), findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
      }
      await tester.tap(exportButton);
      await tester.pumpAndSettle();
      expect(find.byType(ConfigurationTransferDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(settingsButton, findsNothing);
      expect(importButton, findsNothing);
      expect(exportButton, findsNothing);
      await tester.tap(find.byKey(const ValueKey('sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(settingsButton, findsOneWidget);
      expect(importButton, findsOneWidget);
      expect(exportButton, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$platform 工作区铺满右侧，无标题栏状态栏，首尾标签不重建侧栏', (tester) async {
      await pumpApp(tester, platform);
      final sidebarState = tester.state(find.byType(Sidebar));
      final sessions = Get.find<SessionController>();
      final toggle = find.byKey(const ValueKey('sidebar-toggle'));
      final isMac = platform == TargetPlatform.macOS;
      for (final width in [800.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 800);
        for (final hasSession in [false, true]) {
          if (hasSession) {
            sessions.sessions.add(
              Session(
                id: 'session',
                host: const Host(
                  id: 'h',
                  name: 'test-session',
                  hostname: 'test',
                ),
                phase: SessionPhase.failed,
                error: 'fixture',
              ),
            );
            sessions.activeSessionId.value = 'session';
          }
          await tester.pumpAndSettle();
          expect(find.text('PagaShell'), findsNothing);
          expect(findAppIconButton('快速连接'), findsNothing);
          final pane = find.byType(shadcn.TabPane<String>);
          expect(pane, findsOneWidget);
          expect(tester.widget<shadcn.TabPane<String>>(pane).barHeight, isNull);
          final theme = shadcn.Theme.of(tester.element(pane));
          final defaultHeight =
              theme.density.baseContainerPadding * theme.scaling * 2;
          expect(defaultHeight, lessThan(44));
          final content = tester.widget<shadcn.TabPane<String>>(pane).child;
          final contentContainer = tester.widget<shadcn.OutlinedContainer>(
            find
                .ancestor(
                  of: find.byWidget(content),
                  matching: find.byType(shadcn.OutlinedContainer),
                )
                .first,
          );
          expect(contentContainer.theme?.borderWidth, isNull);
          expect(contentContainer.theme?.borderStyle, isNull);
          expect(tester.widget<shadcn.TabPane<String>>(pane).border, isNull);
          expect(
            contentContainer.theme?.borderRadius,
            AppTheme.sessionPaneRadius(tester.element(pane)),
          );
          final radius = contentContainer.theme!.borderRadius! as BorderRadius;
          expect(radius.topLeft, radius.topRight);
          expect(radius.bottomLeft, radius.topLeft);
          expect(radius.bottomRight, radius.topLeft);
          expect(
            radius.topLeft,
            Radius.circular(
              isMac ? AppTheme.macSessionPaneRadius : theme.radiusLg,
            ),
          );
          expect(
            find.ancestor(of: pane, matching: find.byType(OverflowBox)),
            findsNothing,
          );
          final contentBounds = tester.getRect(find.byWidget(content));
          expect(contentBounds.left, AppTheme.sidebarWidth + theme.scaling);
          expect(contentBounds.right, width - theme.scaling);
          expect(contentBounds.bottom, 800 - theme.scaling);
          expect(
            tester.getTopLeft(find.byWidget(content)).dy,
            closeTo(defaultHeight + AppTheme.sessionPaneTopMargin, 1),
          );
          expect(toggle, findsOneWidget);
          final titleBar = find.byType(TitleBar);
          expect(titleBar, findsNothing);
          expect(find.byType(StatusBar), findsNothing);
          final workspace = find.byType(Workspace);
          expect(
            tester.getTopLeft(workspace),
            const Offset(AppTheme.sidebarWidth, 0),
          );
          expect(
            tester.getSize(workspace),
            Size(width - AppTheme.sidebarWidth, 800),
          );
          final viewport = find.byKey(const ValueKey('sidebar-viewport'));
          expect(tester.getTopLeft(viewport).dy, 0);
          expect(tester.getSize(viewport).height, 800);
          expect(
            tester.getCenter(toggle).dy,
            closeTo(AppTheme.windowHeaderHeight / 2, 0.5),
          );
          expect(tester.state(find.byType(Sidebar)), same(sidebarState));
          expect(
            find.ancestor(of: toggle, matching: find.byType(DragToMoveArea)),
            findsNothing,
          );
          if (isMac) {
            expect(find.byType(WindowButtons), findsNothing);
            expect(
              tester.getTopLeft(toggle).dx,
              greaterThanOrEqualTo(AppTheme.macWindowControlsWidth),
            );
          } else {
            expect(find.byType(WindowButtons), findsOneWidget);
            expect(tester.getTopRight(find.byType(WindowButtons)).dx, width);
            expect(
              tester.getCenter(find.byType(WindowButtons)).dy,
              closeTo(AppTheme.windowHeaderHeight / 2, 0.5),
            );
          }
          if (hasSession) {
            final tab = find.byType(shadcn.KeyedTabItem<String>);
            expect(tester.getTopLeft(tab).dy, AppTheme.sessionPaneTopMargin);
            expect(
              tester.getTopLeft(tab).dx,
              greaterThanOrEqualTo(
                tester.getTopLeft(find.byType(Workspace)).dx,
              ),
            );
            expect(tester.getSize(tab).height, defaultHeight);
            await sessions.closeActive();
            await tester.pumpAndSettle();
            expect(tester.state(find.byType(Sidebar)), same(sidebarState));
          }
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('$platform 两侧收起后的展开入口贴边并避让窗口按钮', (tester) async {
      await pumpApp(tester, platform);
      final sessions = Get.find<SessionController>();
      sessions.sessions.add(
        Session(
          id: 'header',
          host: const Host(id: 'header', name: 'Header', hostname: 'test'),
          phase: SessionPhase.failed,
          error: 'fixture',
        ),
      );
      sessions.activate('header');
      await tester.pumpAndSettle();
      await tester.tap(findAppIconButton('隐藏侧边栏'));
      await tester.pumpAndSettle();
      for (final width in [800.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpAndSettle();
        final leftToggle = tester.getRect(
          find.byKey(const ValueKey('sidebar-toggle')),
        );
        final agentToggleFinder = find.byKey(const ValueKey('agent-toggle'));
        final agentToggle = tester.getRect(agentToggleFinder);
        expect(
          leftToggle.left,
          platform == TargetPlatform.macOS
              ? AppTheme.macWindowControlsWidth
              : 0,
        );
        expect(leftToggle.center.dy, agentToggle.center.dy);
        expect(
          find.descendant(
            of: agentToggleFinder,
            matching: find.byIcon(shadcn.LucideIcons.bot),
          ),
          findsOneWidget,
        );
        if (platform == TargetPlatform.macOS) {
          expect(agentToggle.right, width);
          expect(find.byType(WindowButtons), findsNothing);
        } else {
          final windowButtons = tester.getRect(find.byType(WindowButtons));
          expect(windowButtons.right, width);
          expect(agentToggle.right, windowButtons.left);
          expect(agentToggle.center.dy, windowButtons.center.dy);
        }
        final tab = tester.getRect(find.byType(shadcn.KeyedTabItem<String>));
        expect(tab.left, greaterThanOrEqualTo(leftToggle.right));
        expect(tab.right, lessThanOrEqualTo(agentToggle.left));
        expect(findAppIconButton('显示侧边栏').hitTestable(), findsOneWidget);
        expect(findAppIconButton('AI Agent').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform 拖动标签只调整顺序，空白区域仍可拖动窗口', (tester) async {
      final calls = <String>[];
      const channel = MethodChannel('window_manager');
      const nativeChannel = MethodChannel('pagashell/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          nativeChannel,
          null,
        ),
      );
      await pumpApp(tester, platform);
      final controller = Get.find<SessionController>();
      controller.sessions.assignAll([
        for (final name in ['Alpha', 'Beta', 'Gamma'])
          Session(
            id: name,
            host: Host(id: name, name: name, hostname: 'fixture.invalid'),
            phase: SessionPhase.failed,
            error: 'fixture',
          ),
      ]);
      controller.activate('Beta');
      await tester.pumpAndSettle();

      Finder tab(String id) => find.byWidgetPredicate(
        (widget) =>
            widget is shadcn.KeyedTabItem<String> && widget.tabKey == id,
      );
      expect(
        find.ancestor(of: tab('Alpha'), matching: find.byType(DragToMoveArea)),
        findsNothing,
      );
      final source = tester.getRect(tab('Alpha'));
      final target = tester.getRect(tab('Gamma'));
      calls.clear();
      final gesture = await tester.startGesture(
        source.centerLeft + const Offset(32, 0),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await gesture.moveTo(
        Offset(target.left + target.width * 0.75, target.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.sessions.map((session) => session.id), [
        'Beta',
        'Gamma',
        'Alpha',
      ]);
      expect(controller.activeSessionId.value, 'Alpha');
      expect(calls, isEmpty);
      calls.clear();
      await tester.drag(find.byType(WindowDragArea).last, const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(calls, [
        platform == TargetPlatform.macOS ? 'startWindowDrag' : 'startDragging',
      ]);
      calls.clear();
      final lastTab = tester.getRect(tab('Alpha'));
      final blankEnd =
          tester.getRect(find.byType(WindowDragArea).last).left - 8;
      final blankStart = lastTab.right + 24;
      expect(blankEnd, greaterThan(blankStart));
      final blank = Offset((blankStart + blankEnd) / 2, lastTab.center.dy);
      final blankGesture = await tester.startGesture(
        blank,
        kind: PointerDeviceKind.mouse,
      );
      await blankGesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await blankGesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await blankGesture.up();
      await tester.pumpAndSettle();
      expect(calls, [
        platform == TargetPlatform.macOS ? 'startWindowDrag' : 'startDragging',
      ]);
      calls.clear();
      await tester.drag(findAppIconButton('关闭标签').first, const Offset(40, 0));
      await tester.dragFrom(
        tester.getCenter(find.byType(Workspace)),
        const Offset(40, 0),
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(controller.sessions, hasLength(3));
      expect(tester.takeException(), isNull);
    });
  }

  for (final hasSessions in [false, true]) {
    testWidgets('macOS ${hasSessions ? '有' : '无'}标签时双击中间空白与顶部留白可放大还原', (
      tester,
    ) async {
      final calls = <String>[];
      final nativeCalls = <String>[];
      var maximized = false;
      const channel = MethodChannel('window_manager');
      const nativeChannel = MethodChannel('pagashell/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        switch (call.method) {
          case 'isMaximized':
            return maximized;
          case 'maximize':
            maximized = true;
          case 'unmaximize':
            maximized = false;
        }
        return null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        (call) async {
          nativeCalls.add(call.method);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          nativeChannel,
          null,
        );
      });
      await pumpApp(tester, TargetPlatform.macOS);
      final controller = Get.find<SessionController>();
      if (hasSessions) {
        controller.sessions.assignAll([
          for (final name in ['Alpha', 'Beta'])
            Session(
              id: name,
              host: Host(id: name, name: name, hostname: 'fixture.invalid'),
              phase: SessionPhase.failed,
              error: 'fixture',
            ),
        ]);
        controller.activate('Beta');
        await tester.pumpAndSettle();
      }
      calls.clear();
      nativeCalls.clear();

      Future<void> doubleTapAt(Offset position) async {
        await tester.tapAt(position);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(position);
        await tester.pumpAndSettle();
      }

      final trailing = tester.getRect(find.byType(WindowDragArea).last);
      final pane = tester.getRect(find.byType(shadcn.TabPane<String>));
      final blank = Offset(trailing.left - 40, trailing.center.dy);
      final topMargin = Offset(
        blank.dx,
        pane.top - AppTheme.sessionPaneTopMargin / 2,
      );
      for (final position in [blank, topMargin, trailing.center]) {
        await doubleTapAt(position);
        expect(calls, ['isMaximized', 'maximize']);
        expect(maximized, isTrue);
        calls.clear();
        await doubleTapAt(position);
        expect(calls, ['isMaximized', 'unmaximize']);
        expect(maximized, isFalse);
        calls.clear();
      }

      if (hasSessions) {
        final tab = find.byWidgetPredicate(
          (widget) =>
              widget is shadcn.KeyedTabItem<String> && widget.tabKey == 'Alpha',
        );
        await doubleTapAt(tester.getRect(tab).centerLeft + const Offset(32, 0));
        expect(controller.activeSessionId.value, 'Alpha');
        expect(controller.sessions, hasLength(2));
      }
      await doubleTapAt(tester.getCenter(find.byType(Workspace)));
      expect(calls, isEmpty);
      expect(nativeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Windows 窗口按钮调用原生操作，空白可拖动及双击缩放，交互按钮不触发拖动', (tester) async {
    final calls = <String>[];
    var maximized = false;
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isMaximized':
          return maximized;
        case 'maximize':
          maximized = true;
        case 'unmaximize':
          maximized = false;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await pumpApp(tester, TargetPlatform.windows);
    await tester.tap(captionButton('最小化'));
    await tester.tap(captionButton('最大化 / 还原'));
    await tester.pumpAndSettle();
    await tester.tap(captionButton('最大化 / 还原'));
    await tester.tap(captionButton('关闭'));
    await tester.pumpAndSettle();
    expect(calls, [
      'minimize',
      'isMaximized',
      'maximize',
      'isMaximized',
      'unmaximize',
      'close',
    ]);
    calls.clear();
    await tester.tap(findAppIconButton('隐藏侧边栏'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    final dragArea = find.byType(WindowDragArea).last;
    await tester.drag(dragArea, const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(calls, ['startDragging']);
    calls.clear();
    await tester.tap(dragArea);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(dragArea);
    await tester.pumpAndSettle();
    expect(calls, ['isMaximized', 'maximize']);
    expect(tester.takeException(), isNull);
  });
}
