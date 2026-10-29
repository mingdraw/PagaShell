import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/session/session.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/forward_port.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';
import 'package:pagashell/domain/repositories/host_tree_repository.dart';
import 'package:pagashell/domain/repositories/identity_tree_repository.dart';
import 'package:pagashell/presentation/components/app_icon_button.dart';
import 'package:pagashell/presentation/shell/widgets/sidebar.dart';
import 'package:pagashell/presentation/shell/widgets/workspace.dart';
import 'package:pagashell/presentation/theme/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:window_manager/window_manager.dart';
import 'package:xterm/xterm.dart';

import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';
import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  testWidgets('窗口栏切换侧栏带宽度动画，隐藏后无空白且保留树和终端实例，重启恢复隐藏', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = InMemorySettingsRepository();
    Future<void> launch() async {
      await tester.pumpWidget(
        PagaShellApp(
          binding: InMemoryBinding(settingsRepository: repository),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();
    }

    await launch();
    final terminal = Terminal()..write('Preserved terminal output');
    final sessions = Get.find<SessionController>();
    sessions.sessions.add(
      Session(
        id: 'terminal',
        host: const Host(id: 'h', name: 'Terminal', hostname: 'test'),
        phase: SessionPhase.ready,
        terminal: terminal,
      ),
    );
    sessions.activeSessionId.value = 'terminal';
    await tester.pumpAndSettle();
    final treeState = tester.state(find.byType(Sidebar));
    final terminalState = tester.state(find.byType(TerminalView));
    final viewport = find.byKey(const ValueKey('sidebar-viewport'));
    final toggle = find.byKey(const ValueKey('sidebar-toggle'));
    final pane = find.byType(shadcn.TabPane<String>);
    final expandedPaneRadius = tester
        .widget<shadcn.TabPane<String>>(pane)
        .borderRadius;
    final fullWidth = tester.getSize(viewport).width;
    final workspaceWidth = tester.getSize(find.byType(Workspace)).width;
    expect(fullWidth, greaterThanOrEqualTo(AppTheme.sidebarWidth));
    expect(
      tester.getTopLeft(toggle).dx,
      greaterThanOrEqualTo(AppTheme.macWindowControlsWidth),
    );
    expect(find.text('PagaShell'), findsNothing);
    expect(
      find.ancestor(of: toggle, matching: find.byType(DragToMoveArea)),
      findsNothing,
    );
    expect(tester.widget<AppIconButton>(toggle).tooltip, isNull);
    await tester.tap(findAppIconButton('隐藏侧边栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(viewport).width, inExclusiveRange(0, fullWidth));
    expect(
      tester.getSize(find.byType(Workspace)).width,
      greaterThan(workspaceWidth),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(viewport).width, 0);
    final paneRadius =
        tester.widget<shadcn.TabPane<String>>(pane).borderRadius!
            as BorderRadius;
    expect(paneRadius, AppTheme.sessionPaneRadius(tester.element(pane)));
    expect(
      paneRadius.bottomLeft,
      const Radius.circular(AppTheme.macSessionPaneRadius),
    );
    expect(paneRadius, expandedPaneRadius);
    expect(paneRadius.topLeft, paneRadius.bottomLeft);
    expect(paneRadius.topRight, paneRadius.bottomLeft);
    expect(paneRadius.bottomRight, paneRadius.bottomLeft);
    expect(
      tester.getSize(find.byType(Workspace)).width,
      closeTo(workspaceWidth + fullWidth, 0.1),
    );
    expect(tester.state(find.byType(Sidebar)), same(treeState));
    expect(tester.state(find.byType(TerminalView)), same(terminalState));
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
      same(terminal),
    );
    await tester.tap(findAppIconButton('显示侧边栏'));
    await tester.pumpAndSettle();
    expect(tester.getSize(viewport).width, fullWidth);
    expect(tester.state(find.byType(Sidebar)), same(treeState));
    expect(tester.state(find.byType(TerminalView)), same(terminalState));
    await tester.tap(findAppIconButton('隐藏侧边栏'));
    await tester.pumpAndSettle();
    await Get.find<SettingsController>().sidebarSaved;
    expect(repository.sidebarState.visible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    Get.reset();
    await launch();
    expect(tester.getSize(viewport).width, 0);
    expect(findAppIconButton('显示侧边栏'), findsOneWidget);
    await tester.tap(findAppIconButton('显示侧边栏'));
    await tester.pumpAndSettle();
    expect(tester.getSize(viewport).width, fullWidth);
    expect(tester.takeException(), isNull);
  });

  testWidgets('三个分组目录在重启后恢复，服务端口映射不产生独立叶子，搜索不改变折叠偏好', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = InMemorySettingsRepository();

    Future<void> launch() async {
      await tester.pumpWidget(
        PagaShellApp(
          binding: InMemoryBinding(settingsRepository: repository),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();
      final folders = {
        SidebarSection.services: Get.find<HostTreeRepository>().saveFolder,
        SidebarSection.identities:
            Get.find<IdentityTreeRepository>().saveFolder,
        SidebarSection.gateways:
            Get.find<GatewayFolderController>().treeRepository.saveFolder,
      };
      for (final entry in folders.entries) {
        final prefix = entry.key.name;
        await entry.value(Folder(id: '$prefix-outer', name: '$prefix outer'));
        await entry.value(
          Folder(
            id: '$prefix-inner',
            name: '$prefix inner',
            parentId: '$prefix-outer',
          ),
        );
      }
      await Get.find<HostController>().save(
        const Host(
          id: 'service',
          name: 'Service leaf',
          hostname: 'service.test',
          folderId: 'services-inner',
          forwardPorts: [ForwardPort(localPort: 13306, targetPort: 3306)],
        ),
      );
      await Get.find<GatewayController>().save(
        const Host(
          id: 'gateway',
          name: 'Gateway leaf',
          hostname: 'gateway.test',
          folderId: 'gateways-inner',
        ),
      );
      await Get.find<IdentityController>().saveWithPassword(
        name: 'Credential leaf',
        username: 'root',
        password: 'fixture',
        folderId: 'identities-inner',
      );
      await tester.pumpAndSettle();
    }

    Future<void> toggle(String name) async {
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    await launch();
    for (final section in SidebarSection.values) {
      await toggle('${section.name} outer');
    }
    await toggle('services inner');
    await toggle('gateways inner');
    expect(find.text('Service leaf'), findsOneWidget);
    expect(find.text('Gateway leaf'), findsOneWidget);
    expect(find.text('端口转发'), findsNothing);
    expect(find.text('Credential leaf'), findsNothing);
    await toggle('服务');
    await toggle('网关');
    expect(find.text('Service leaf'), findsNothing);
    expect(find.text('Gateway leaf'), findsNothing);
    final hosts = Get.find<HostController>();
    hosts.searchQuery.value = 'Service leaf';
    await tester.pumpAndSettle();
    expect(find.text('Service leaf'), findsOneWidget);
    hosts.searchQuery.value = '';
    await tester.pumpAndSettle();
    expect(find.text('Service leaf'), findsNothing);
    await Get.find<SettingsController>().sidebarSaved;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    Get.reset();
    await launch();
    expect(find.text('services outer'), findsNothing);
    expect(find.text('gateways outer'), findsNothing);
    expect(find.text('identities outer'), findsOneWidget);
    expect(find.text('identities inner'), findsOneWidget);
    expect(find.text('Credential leaf'), findsNothing);
    await toggle('服务');
    await toggle('网关');
    expect(find.text('services inner'), findsOneWidget);
    expect(find.text('Service leaf'), findsOneWidget);
    expect(find.text('gateways inner'), findsOneWidget);
    expect(find.text('Gateway leaf'), findsOneWidget);
    await toggle('identities inner');
    expect(find.text('Credential leaf'), findsOneWidget);
    await Get.find<SettingsController>().sidebarSaved;
    expect(repository.sidebarState.expandedFolders(SidebarSection.identities), {
      'identities-outer',
      'identities-inner',
    });
    expect(repository.sidebarState.expandedFolders(SidebarSection.services), {
      'services-outer',
      'services-inner',
    });
    expect(tester.takeException(), isNull);
  });
}
