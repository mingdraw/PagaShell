import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/configuration/configuration_transfer.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/identities/identity_folder_controller.dart';
import 'package:pagashell/domain/entities/connection_configuration.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/repositories/configuration_repository.dart';
import 'package:pagashell/presentation/configuration/configuration_transfer_dialog.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _Repository implements ConfigurationRepository {
  int merges = 0;

  @override
  Future<ConnectionConfiguration> read({
    ConfigurationExportScope scope = const ConfigurationExportScope.all(),
  }) async => const ConnectionConfiguration();

  @override
  Future<void> merge(ConnectionConfiguration configuration) async => merges++;
}

class _Transfer extends ConfigurationTransfer {
  _Transfer(ConfigurationRepository repository) : super(repository: repository);
  int exports = 0;
  int reads = 0;
  bool encryptedFile = true;
  String? exportedPassword;
  ConfigurationExportScope? exportedScope;
  String? importedPassword;
  Object? failure;
  Completer<Uint8List>? pendingExport;

  @override
  Future<Uint8List> exportFile([
    String? password,
    ConfigurationExportScope scope = const ConfigurationExportScope.all(),
  ]) async {
    exports++;
    exportedPassword = password;
    exportedScope = scope;
    if (failure case final error?) throw error;
    return pendingExport?.future ?? Uint8List.fromList([1, 2, 3]);
  }

  @override
  bool isEncrypted(Uint8List bytes) => encryptedFile;

  @override
  Future<ConnectionConfiguration> readFile(
    Uint8List bytes, [
    String? password,
  ]) async {
    reads++;
    importedPassword = password;
    if (failure case final error?) throw error;
    return const ConnectionConfiguration(
      serviceFolders: [Folder(id: 'folder', name: 'Folder')],
      services: [
        Host(
          id: 'host',
          name: 'Service',
          hostname: 'test.example',
          folderId: 'folder',
        ),
      ],
    );
  }
}

void main() {
  late _Repository repository;
  late _Transfer transfer;
  setUp(() {
    Get.testMode = true;
    repository = _Repository();
    transfer = _Transfer(repository);
    Get.put<ConfigurationTransfer>(transfer);
  });
  tearDown(() {
    Get.reset();
    Get.locale = null;
  });

  Future<void> mount(
    WidgetTester tester, {
    bool importing = false,
    Future<bool> Function(Uint8List, String)? saveFile,
    Locale locale = const Locale('zh', 'CN'),
    Size size = const Size(800, 700),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ShadcnTestApp(
        locale: locale,
        home: shadcn.Scaffold(
          child: shadcn.PrimaryButton(
            key: const ValueKey('open-transfer'),
            onPressed: () => unawaited(
              importing
                  ? showConfigurationImportDialog(
                      pickFile: () async =>
                          XFile.fromData(Uint8List(1), name: 'test.pagashell'),
                    )
                  : AppNavigation.dialog<void>(
                      ConfigurationTransferDialog(
                        saveFile: saveFile ?? (_, _) async => false,
                      ),
                    ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-transfer')));
    await tester.pumpAndSettle();
  }

  Finder input(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(EditableText),
  );
  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('configuration-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets('导出密码与确认校验完成后才加密并保存', (tester) async {
    Uint8List? saved;
    String? filename;
    await mount(
      tester,
      saveFile: (bytes, name) async {
        saved = bytes;
        filename = name;
        return true;
      },
    );
    await tester.tap(find.byKey(const ValueKey('config-encryption')));
    await tester.pumpAndSettle();
    await submit(tester);
    expect(transfer.exports, 0);
    expect(find.text('必填'), findsOneWidget);
    await tester.enterText(input('config-password'), 'short');
    await tester.enterText(input('config-confirm-password'), 'short');
    await submit(tester);
    expect(find.text('导出密码至少需要 8 个字符'), findsOneWidget);
    expect(transfer.exports, 0);
    await tester.enterText(input('config-password'), 'test-export-password');
    await submit(tester);
    expect(find.text('两次输入的密码不一致'), findsOneWidget);
    await tester.enterText(
      input('config-confirm-password'),
      'test-export-password',
    );
    await submit(tester);
    expect(transfer.exports, 1);
    expect(transfer.exportedPassword, 'test-export-password');
    expect(saved, [1, 2, 3]);
    expect(filename, endsWith('.pagashell'));
    expect(find.byType(ConfigurationTransferDialog), findsNothing);
    expect(repository.merges, 0);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('取消保存不关闭弹框，处理中禁止重复导出', (tester) async {
    final pending = Completer<Uint8List>();
    transfer.pendingExport = pending;
    await mount(tester);
    await submit(tester);
    expect(transfer.exports, 1);
    expect(find.text('处理中…'), findsOneWidget);
    final submitButton = tester.widget<shadcn.PrimaryButton>(
      find.byKey(const ValueKey('configuration-submit')),
    );
    expect(submitButton.onPressed, isNull);
    expect(
      tester
          .widget<shadcn.OutlineButton>(
            find.widgetWithText(shadcn.OutlineButton, '取消'),
          )
          .onPressed,
      isNull,
    );
    pending.complete(Uint8List.fromList([1]));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigurationTransferDialog), findsOneWidget);
    expect(find.text('处理中…'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigurationTransferDialog), findsNothing);
  });

  testWidgets('加密文件自动弹出密码框，取消不写入，输入密码后直接导入', (tester) async {
    await mount(tester, importing: true);
    expect(input('config-password'), findsOneWidget);
    expect(find.byKey(const ValueKey('config-encryption')), findsNothing);
    expect(transfer.reads, 0);
    expect(repository.merges, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repository.merges, 0);
    await tester.tap(find.byKey(const ValueKey('open-transfer')));
    await tester.pumpAndSettle();
    await submit(tester);
    expect(find.text('必填'), findsOneWidget);
    expect(transfer.reads, 0);
    await tester.enterText(input('config-password'), 'test-export-password');
    await submit(tester);
    expect(transfer.reads, 1);
    expect(transfer.importedPassword, 'test-export-password');
    expect(repository.merges, 1);
    expect(find.byType(ConfigurationTransferDialog), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('解密失败可重试，平台异常不出现在界面', (tester) async {
    transfer.failure = const ConfigurationException('无法解密配置文件，请检查密码或文件是否完整');
    await mount(tester, importing: true);
    await tester.enterText(input('config-password'), 'wrong-password');
    await submit(tester);
    expect(find.text('无法解密配置文件，请检查密码或文件是否完整'), findsOneWidget);
    expect(repository.merges, 0);
    transfer.failure = StateError('sensitive-file-path');
    await submit(tester);
    expect(find.text('配置操作失败，请检查钥匙串或文件权限后重试'), findsOneWidget);
    expect(find.textContaining('sensitive-file-path'), findsNothing);
    transfer.failure = null;
    await submit(tester);
    expect(repository.merges, 1);
    expect(find.byType(ConfigurationTransferDialog), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('默认不加密直接导出，不显示或校验密码框', (tester) async {
    await mount(tester, saveFile: (_, _) async => true);
    expect(
      tester
          .widget<shadcn.Checkbox>(
            find.byKey(const ValueKey('config-encryption')),
          )
          .state,
      shadcn.CheckboxState.unchecked,
    );
    expect(input('config-password'), findsNothing);
    expect(input('config-confirm-password'), findsNothing);
    await submit(tester);
    expect(transfer.exports, 1);
    expect(transfer.exportedPassword, isNull);
    expect(find.byType(ConfigurationTransferDialog), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('取消加密后隐藏密码框并按未加密格式导出', (tester) async {
    await mount(tester, saveFile: (_, _) async => true);
    final checkbox = find.byKey(const ValueKey('config-encryption'));
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await tester.enterText(input('config-password'), 'short');
    await submit(tester);
    expect(transfer.exports, 0);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(input('config-password'), findsNothing);
    expect(input('config-confirm-password'), findsNothing);
    await submit(tester);
    expect(transfer.exportedPassword, isNull);
    expect(transfer.exports, 1);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('未加密文件选择后直接导入，不弹出密码框', (tester) async {
    transfer.encryptedFile = false;
    await mount(tester, importing: true);
    expect(find.byType(ConfigurationTransferDialog), findsNothing);
    expect(input('config-password'), findsNothing);
    expect(transfer.reads, 1);
    expect(transfer.importedPassword, isNull);
    expect(repository.merges, 1);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('$locale 小窗口内容可滚动，操作按钮始终可见', (tester) async {
      await mount(tester, locale: locale, size: const Size(540, 420));
      await tester.tap(find.byKey(const ValueKey('config-encryption')));
      await tester.pumpAndSettle();
      final submitButton = find.byKey(const ValueKey('configuration-submit'));
      expect(tester.getRect(submitButton).bottom, lessThanOrEqualTo(420));
      await tester.ensureVisible(input('config-confirm-password'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(input('config-confirm-password')).bottom,
        lessThan(tester.getRect(submitButton).top),
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('导出建议文件名规范化特殊字符并在无效名称时回退默认格式', () {
    final now = DateTime(2026, 11, 25);
    expect(
      suggestedConfigurationFileName(now: now),
      'PagaShell-2026-11-25.pagashell',
    );
    expect(
      suggestedConfigurationFileName(
        now: now,
        scope: const ConfigurationExportScope.service('s1'),
        targetName: '生产 / api:01',
      ),
      'PagaShell-生产_api_01-2026-11-25.pagashell',
    );
    expect(
      suggestedConfigurationFileName(
        now: now,
        scope: const ConfigurationExportScope.serviceFolder('f1'),
        targetName: '...///...',
      ),
      'PagaShell-2026-11-25.pagashell',
    );
  });

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    testWidgets('$locale 单项与文件夹导出弹框展示范围说明并传递导出范围与建议文件名', (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ShadcnTestApp(
          locale: locale,
          home: const shadcn.Scaffold(child: SizedBox.shrink()),
        ),
      );
      await tester.pumpAndSettle();

      final isZh = locale.languageCode == 'zh';
      for (final (scope, name, zhSnippet, enSnippet) in [
        (
          const ConfigurationExportScope.service('s1'),
          'prod-api',
          '导出服务「prod-api」及其关联的凭证、网关和凭据。',
          'Export service “prod-api” with its linked credentials, gateway, and secrets.',
        ),
        (
          const ConfigurationExportScope.serviceFolder('sf1'),
          '生产环境',
          '导出服务文件夹「生产环境」及其中全部子文件夹、服务，以及关联的凭证、网关和凭据。',
          'Export service folder “生产环境” with all subfolders, services, and their linked credentials, gateways, and secrets.',
        ),
        (
          const ConfigurationExportScope.identity('i1'),
          '部署密钥',
          '导出凭证「部署密钥」及其密码或私钥。',
          'Export credential “部署密钥” with its password or private key.',
        ),
        (
          const ConfigurationExportScope.identityFolder('if1'),
          '凭证目录',
          '导出凭证文件夹「凭证目录」及其中全部子文件夹和凭证，包含密码和私钥。',
          'Export credential folder “凭证目录” with all subfolders and credentials, including passwords and private keys.',
        ),
        (
          const ConfigurationExportScope.gateway('g1'),
          'jump-01',
          '导出网关「jump-01」及其关联的凭证、端口映射、动态代理配置和凭据。',
          'Export gateway “jump-01” with its linked credential, port mappings, proxy settings, and secrets.',
        ),
        (
          const ConfigurationExportScope.gatewayFolder('gf1'),
          '网关目录',
          '导出网关文件夹「网关目录」及其中全部子文件夹、网关，以及关联的凭证和凭据。',
          'Export gateway folder “网关目录” with all subfolders, gateways, and their linked credentials and secrets.',
        ),
      ]) {
        String? savedName;
        transfer.exportedScope = null;
        unawaited(
          showConfigurationExportDialog(
            scope: scope,
            targetName: name,
            saveFile: (_, filename) async {
              savedName = filename;
              return true;
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(isZh ? zhSnippet : enSnippet), findsOneWidget);
        await submit(tester);
        expect(transfer.exportedScope, scope);
        expect(savedName, startsWith('PagaShell-$name-'));
        expect(savedName, endsWith('.pagashell'));
        expect(find.byType(ConfigurationTransferDialog), findsNothing);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('侧边栏服务/凭证/网关及其文件夹菜单均提供导出配置，且导出文件可经全局导入恢复', (tester) async {
    Get.reset();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    final serviceFolders = Get.find<FolderController>();
    final identityFolders = Get.find<IdentityFolderController>();
    final gatewayFolders = Get.find<GatewayFolderController>();
    final hosts = Get.find<HostController>();
    final identities = Get.find<IdentityController>();
    final gateways = Get.find<GatewayController>();

    final sFolder = await serviceFolders.create(name: '服务目录');
    final iFolder = await identityFolders.create(name: '凭证目录');
    final gFolder = await gatewayFolders.create(name: '网关目录');
    serviceFolders.expanded.add(sFolder.id);
    identityFolders.expanded.add(iFolder.id);
    gatewayFolders.expanded.add(gFolder.id);

    final identity = await identities.saveWithPassword(
      name: '共享凭证',
      username: 'ops',
      password: 'cred-password',
      folderId: iFolder.id,
    );
    await gateways.save(
      Host(
        id: 'gw-1',
        name: '跳板网关',
        hostname: 'jump.example',
        folderId: gFolder.id,
        identityId: identity.id,
      ),
    );
    await hosts.save(
      Host(
        id: 'svc-1',
        name: '生产服务',
        hostname: 'app.example',
        folderId: sFolder.id,
        identityId: identity.id,
        gatewayId: 'gw-1',
      ),
    );
    await tester.pumpAndSettle();

    Future<void> verifyContextExport(
      String label,
      ConfigurationExportScope expectedScope,
    ) async {
      await tester.tap(find.text(label), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      final exportMenu = find.widgetWithText(shadcn.MenuButton, '导出配置');
      expect(exportMenu, findsOneWidget);
      expect(
        (tester.widget<shadcn.MenuButton>(exportMenu).leading! as AppIcon).icon,
        AppIcons.fileExport,
      );
      await tester.tap(exportMenu);
      await tester.pumpAndSettle();
      final dialog = tester.widget<ConfigurationTransferDialog>(
        find.byType(ConfigurationTransferDialog),
      );
      expect(dialog.exportScope, expectedScope);
      expect(dialog.exportTargetName, label);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }

    await verifyContextExport(
      '服务目录',
      ConfigurationExportScope.serviceFolder(sFolder.id),
    );
    await verifyContextExport(
      '生产服务',
      const ConfigurationExportScope.service('svc-1'),
    );
    await verifyContextExport(
      '凭证目录',
      ConfigurationExportScope.identityFolder(iFolder.id),
    );
    await verifyContextExport(
      '共享凭证',
      ConfigurationExportScope.identity(identity.id),
    );
    await verifyContextExport(
      '网关目录',
      ConfigurationExportScope.gatewayFolder(gFolder.id),
    );
    await verifyContextExport(
      '跳板网关',
      const ConfigurationExportScope.gateway('gw-1'),
    );

    // 验证文件夹行内「更多」按钮菜单也包含导出配置。
    await tester.tap(findAppIcon(AppIcons.ellipsis).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(shadcn.MenuButton, '导出配置'), findsOneWidget);
    await tester.tap(find.widgetWithText(shadcn.MenuButton, '导出配置'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ConfigurationTransferDialog>(
            find.byType(ConfigurationTransferDialog),
          )
          .exportScope,
      ConfigurationExportScope.serviceFolder(sFolder.id),
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 真实导出单个服务并在全新应用中通过全局导入弹框导入。
    final exportedBytes = await Get.find<ConfigurationTransfer>().exportFile(
      null,
      const ConfigurationExportScope.service('svc-1'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    Get.reset();
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();

    await tester.runAsync(
      () => showConfigurationImportDialog(
        pickFile: () async => XFile.fromData(
          exportedBytes,
          name: 'PagaShell-生产服务-2026-11-25.pagashell',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(Get.find<HostController>().hosts.map((h) => h.id), ['svc-1']);
    expect(Get.find<GatewayController>().hosts.map((g) => g.id), ['gw-1']);
    expect(Get.find<IdentityController>().identities.map((i) => i.id), [
      identity.id,
    ]);
    expect(find.text('生产服务'), findsOneWidget);
    expect(find.text('跳板网关'), findsOneWidget);
    expect(find.text('共享凭证'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
