import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/configuration/configuration_transfer.dart';
import 'package:pagashell/domain/entities/connection_configuration.dart';
import 'package:pagashell/domain/entities/folder.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/repositories/configuration_repository.dart';
import 'package:pagashell/presentation/configuration/configuration_transfer_dialog.dart';
import 'package:pagashell/presentation/navigation/app_navigation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

class _Repository implements ConfigurationRepository {
  int merges = 0;

  @override
  Future<ConnectionConfiguration> read() async =>
      const ConnectionConfiguration();

  @override
  Future<void> merge(ConnectionConfiguration configuration) async => merges++;
}

class _Transfer extends ConfigurationTransfer {
  _Transfer(ConfigurationRepository repository) : super(repository: repository);
  int exports = 0;
  int reads = 0;
  bool encryptedFile = true;
  String? exportedPassword;
  String? importedPassword;
  Object? failure;
  Completer<Uint8List>? pendingExport;

  @override
  Future<Uint8List> exportFile([String? password]) async {
    exports++;
    exportedPassword = password;
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
  tearDown(Get.reset);

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
}
