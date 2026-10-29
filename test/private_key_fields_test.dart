import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/ssh/private_key_fields.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

class _UnreadableFile extends XFile {
  _UnreadableFile() : super('sensitive-file-path');

  @override
  Future<int> length() async => throw StateError('sensitive-file-path');
}

class _GrowingFile extends XFile {
  _GrowingFile() : super('test-key');

  @override
  Future<int> length() async => 1;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      'x'.padRight(1024 * 1024 + 1, 'x');
}

void main() {
  late TextEditingController privateKey;
  late TextEditingController passphrase;
  late GlobalKey<FormState> form;

  setUp(() {
    privateKey = TextEditingController();
    passphrase = TextEditingController();
    form = GlobalKey<FormState>();
  });

  tearDown(() {
    privateKey.dispose();
    passphrase.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    Future<XFile?> Function()? pickFile,
    bool preserveExisting = false,
    Future<String?> Function()? loadPrivateKey,
    Future<bool> Function(Uint8List, String)? saveFile,
    String exportName = 'id_pagashell',
  }) => tester.pumpWidget(
    ShadcnTestApp(
      home: shadcn.Scaffold(
        child: Form(
          key: form,
          child: PrivateKeyFields(
            privateKey: privateKey,
            passphrase: passphrase,
            pickFile: pickFile,
            preserveExisting: preserveExisting,
            loadPrivateKey: loadPrivateKey,
            exportName: exportName,
            saveFile: saveFile ?? (_, _) async => true,
          ),
        ),
      ),
    ),
  );

  testWidgets('导入文件后填入隐藏私钥，仅展示文件名', (tester) async {
    await mount(
      tester,
      pickFile: () async => XFile.fromData(
        Uint8List.fromList(utf8.encode('test-private-key')),
        name: 'id_test',
        path: 'id_test',
      ),
    );
    await tester.tap(find.text('导入私钥文件'));
    await tester.pumpAndSettle();
    expect(privateKey.text, 'test-private-key');
    expect(find.text('已导入：id_test'), findsOneWidget);
    final field = tester.widget<shadcn.TextField>(
      find.descendant(
        of: find.widgetWithText(AppTextFormField, '私钥内容'),
        matching: find.byType(shadcn.TextField),
      ),
    );
    expect(field.obscureText, isTrue);
    expect(form.currentState!.validate(), isTrue);
  });

  testWidgets('超过大小限制的文件不替换已有输入', (tester) async {
    privateKey.text = 'old-key';
    await mount(
      tester,
      pickFile: () async =>
          XFile.fromData(Uint8List(1024 * 1024 + 1), name: 'oversized'),
    );
    await tester.tap(find.text('导入私钥文件'));
    await tester.pumpAndSettle();
    expect(privateKey.text, 'old-key');
    expect(find.text('私钥文件不能超过 1 MiB'), findsOneWidget);
  });

  testWidgets('读取期间变大的文件仍被大小限制拒绝', (tester) async {
    await mount(tester, pickFile: () async => _GrowingFile());
    await tester.tap(find.text('导入私钥文件'));
    await tester.pumpAndSettle();
    expect(privateKey.text, isEmpty);
    expect(find.text('私钥文件不能超过 1 MiB'), findsOneWidget);
  });

  testWidgets('导入失败隐藏平台异常和路径；取消保留输入', (tester) async {
    privateKey.text = 'old-key';
    await mount(tester, pickFile: () async => _UnreadableFile());
    await tester.tap(find.text('导入私钥文件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法读取私钥'), findsOneWidget);
    expect(find.textContaining('sensitive-file-path'), findsNothing);
    expect(privateKey.text, 'old-key');
    await mount(tester, pickFile: () async => null);
    await tester.tap(find.text('导入私钥文件'));
    await tester.pumpAndSettle();
    expect(privateKey.text, 'old-key');
  });

  testWidgets('新建要求私钥，编辑留空保留，但不能单独更换口令', (tester) async {
    await mount(tester);
    expect(form.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('请导入或粘贴私钥'), findsOneWidget);
    await mount(tester, preserveExisting: true);
    expect(form.currentState!.validate(), isTrue);
    passphrase.text = 'replacement';
    expect(form.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('更换口令时请重新导入私钥'), findsOneWidget);
    privateKey.text = 'replacement-key';
    expect(form.currentState!.validate(), isTrue);
  });

  testWidgets('编辑留空时导出保存的私钥，不把密文或口令填回表单', (tester) async {
    Uint8List? saved;
    String? filename;
    var reads = 0;
    await mount(
      tester,
      preserveExisting: true,
      exportName: '共享 / 密钥',
      loadPrivateKey: () async {
        reads++;
        return 'saved-encrypted-key-marker';
      },
      saveFile: (bytes, name) async {
        saved = bytes;
        filename = name;
        return true;
      },
    );
    expect(reads, 0);
    await tester.tap(find.text('导出私钥文件'));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(utf8.decode(saved!), 'saved-encrypted-key-marker');
    expect(filename, '共享___密钥.key');
    expect(privateKey.text, isEmpty);
    expect(passphrase.text, isEmpty);
    expect(find.text('saved-encrypted-key-marker'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('当前编辑优先于已保存内容，PPK 保留原文，不导出口令', (tester) async {
    privateKey.text = 'PuTTY-User-Key-File-3: test-marker';
    passphrase.text = 'separate-test-passphrase';
    Uint8List? saved;
    String? filename;
    await mount(
      tester,
      loadPrivateKey: () async => throw StateError('should-not-read-keychain'),
      exportName: 'shared',
      saveFile: (bytes, name) async {
        saved = bytes;
        filename = name;
        return true;
      },
    );
    await tester.tap(find.text('导出私钥文件'));
    await tester.pumpAndSettle();
    expect(utf8.decode(saved!), privateKey.text);
    expect(utf8.decode(saved!).contains(passphrase.text), isFalse);
    expect(filename, 'shared.ppk');
    expect(passphrase.text, 'separate-test-passphrase');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('取消导出不修改表单，导出失败不泄露路径和平台错误', (tester) async {
    privateKey.text = 'test-key-marker';
    passphrase.text = 'unchanged-passphrase';
    await mount(tester, saveFile: (_, _) async => false);
    await tester.tap(find.text('导出私钥文件'));
    await tester.pumpAndSettle();
    expect(privateKey.text, 'test-key-marker');
    expect(find.text('私钥文件已导出'), findsNothing);
    await mount(
      tester,
      saveFile: (_, _) async => throw StateError('sensitive-export-file-path'),
    );
    await tester.tap(find.text('导出私钥文件'));
    await tester.pumpAndSettle();
    expect(find.text('私钥导出失败，请检查钥匙串和文件写入权限'), findsOneWidget);
    expect(find.textContaining('sensitive-export-file-path'), findsNothing);
    expect(privateKey.text, 'test-key-marker');
    expect(passphrase.text, 'unchanged-passphrase');
  });

  testWidgets('缺失或过大的保存私钥不会打开文件保存窗口', (tester) async {
    var saves = 0;
    Future<bool> save(Uint8List _, String _) async {
      saves++;
      return true;
    }

    await mount(tester, loadPrivateKey: () async => null, saveFile: save);
    await tester.tap(find.text('导出私钥文件'));
    await tester.pumpAndSettle();
    expect(find.text('没有可导出的私钥，请先导入或保存私钥'), findsOneWidget);
    await mount(
      tester,
      loadPrivateKey: () async => 'x' * (1024 * 1024 + 1),
      saveFile: save,
    );
    await tester.tap(find.text('导出私钥文件'));
    await tester.pumpAndSettle();
    expect(find.text('私钥内容不能超过 1 MiB'), findsOneWidget);
    expect(saves, 0);
    expect(privateKey.text, isEmpty);
  });
}
