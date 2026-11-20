import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/domain/ai/agent_skill.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:pagashell/presentation/localization/app_translations.dart';
import 'package:pagashell/presentation/ssh/host_key_confirmation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/in_memory_binding.dart';
import 'support/in_memory_settings_repository.dart';
import 'support/shadcn_test_app.dart';

class _FailingLanguageRepository extends InMemorySettingsRepository {
  @override
  Future<void> saveLanguageCode(String code) async {
    throw StateError('fixture write failure');
  }
}

void main() {
  setUp(() {
    Get.locale = AppTranslations.defaultLocale;
    Get.fallbackLocale = AppTranslations.defaultLocale;
  });
  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  testWidgets('左下角通用设置切换中英文，保留控制器和用户数据', (tester) async {
    final settings = InMemorySettingsRepository();
    Future<void> mount() => tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(settingsRepository: settings),
        platform: TargetPlatform.macOS,
      ),
    );
    await mount();
    await tester.pumpAndSettle();
    final controller = Get.find<HostController>();
    await controller.save(
      const Host(
        id: 'host',
        name: '生产主机',
        hostname: 'example.test',
        username: 'root',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(shadcn.Select<Locale>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // GetX 4 的语言刷新走 performReassemble，需离开 fakeAsync 时钟。
    await tester.runAsync(() async {
      await tester.tap(find.text('English').last);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(settings.languageCode, 'en');
    expect(Get.locale, AppTranslations.englishLocale);
    expect(find.text('Services'), findsOneWidget);
    expect(find.text('Credentials'), findsOneWidget);
    expect(find.text('生产主机'), findsOneWidget);
    expect(Get.find<HostController>(), same(controller));
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(shadcn.OutlineButton, 'Close'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    Get.reset();
    Get.locale = AppTranslations.defaultLocale;
    await mount();
    await tester.pump();
    expect(find.text('服务'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Services'), findsOneWidget);
    expect(Get.locale, AppTranslations.englishLocale);
    final restartedController = Get.find<HostController>();

    await tester.tap(findAppIconButton('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(shadcn.Select<Locale>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await tester.tap(find.text('简体中文').last);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.text('服务'), findsOneWidget);
    expect(settings.languageCode, 'zh');
    expect(Get.find<HostController>(), same(restartedController));
  });

  testWidgets('切换语言保留打开的表单与输入，校验使用当前语言', (tester) async {
    await tester.pumpWidget(
      PagaShellApp(binding: InMemoryBinding(), platform: TargetPlatform.macOS),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('服务组操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(shadcn.MenuButton, '新建服务'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(AppTextFormField, '名称'),
      '数据库-01',
    );
    await tester.runAsync(() async {
      unawaited(Get.updateLocale(AppTranslations.englishLocale));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsOneWidget);
    expect(find.text('数据库-01'), findsOneWidget);
    expect(
      find.widgetWithText(AppTextFormField, 'Service address'),
      findsOneWidget,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(AppTextFormField, 'Service address'),
      '10.0.0.8',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(AppDialog), findsNothing);
    expect(Get.find<HostController>().hosts.single.name, '数据库-01');
  });

  testWidgets('语言写入失败时保留当前译文和选择', (tester) async {
    await tester.pumpWidget(
      PagaShellApp(
        binding: InMemoryBinding(
          settingsRepository: _FailingLanguageRepository(),
        ),
        platform: TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAppIconButton('设置'));
    await tester.pumpAndSettle();
    final selector = find.byType(shadcn.Select<Locale>);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(find.text('语言设置保存失败，请重试'), findsOneWidget);
    expect(find.text('服务'), findsOneWidget);
    expect(
      tester.widget<shadcn.Select<Locale>>(selector).value,
      AppTranslations.defaultLocale,
    );
    expect(
      find.descendant(of: selector, matching: find.text('简体中文')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('英文主机密钥变更提示保留指纹并阻止信任', (tester) async {
    bool? trusted;
    await tester.pumpWidget(
      ShadcnTestApp(
        locale: AppTranslations.englishLocale,
        home: shadcn.Scaffold(
          child: HostKeyConfirmation(
            review: const HostKeyReview(
              presented: SshHostKey(
                hostname: 'example.test',
                port: 22,
                keyType: 'ssh-ed25519',
                fingerprint: 'SHA256:new',
              ),
              trusted: SshHostKey(
                hostname: 'example.test',
                port: 22,
                keyType: 'ssh-ed25519',
                fingerprint: 'SHA256:old',
              ),
            ),
            onDecision: (value) => trusted = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Host key changed — connection blocked'), findsOneWidget);
    expect(find.text('SHA256:new'), findsOneWidget);
    expect(find.text('SHA256:old'), findsOneWidget);
    expect(find.text('Trust and connect'), findsNothing);
    await tester.tap(find.text('Reject connection'));
    expect(trusted, isFalse);
  });

  test('GetX 参数翻译、语言回退及已知错误翻译', () {
    Get.addTranslations(AppTranslations().keys);
    Get.locale = AppTranslations.englishLocale;
    expect('删除文件夹「@name」？'.trParams({'name': '生产环境'}), 'Delete folder “生产环境”?');
    expect(
      AppTranslations.error('连接超时: example.test:22'),
      'Connection timed out: example.test:22',
    );
    expect(
      AppTranslations.error('无法读取远程目录，请重试'),
      'Unable to read the remote directory. Please try again.',
    );
    expect(AppTranslations.error('unknown diagnostic'), 'unknown diagnostic');
    Get.locale = const Locale('fr', 'FR');
    expect('新建服务'.tr, '新建服务');
  });

  test('RDP 认证和初始化错误保留状态码，并翻译嵌套网关错误', () {
    Get.addTranslations(AppTranslations().keys);
    const code =
        'STATUS_LOGON_FAILURE / 0xC000006D; SSPI LogonDenied / 0x8009030C';
    const nla = 'RDP NLA 认证失败：Windows 拒绝了登录（$code）';
    expect(AppTranslations.error(nla), nla);
    Get.locale = AppTranslations.englishLocale;
    expect(
      AppTranslations.error(nla),
      'RDP NLA authentication failed: Windows rejected the sign-in ($code)',
    );
    expect(
      AppTranslations.error('RDP 服务连接失败：$nla'),
      'RDP service connection failed: RDP NLA authentication failed: '
      'Windows rejected the sign-in ($code)',
    );
    expect(
      AppTranslations.error('RDP 会话初始化失败：连接读写失败（IO UnexpectedEof）'),
      'RDP session initialization failed: Reading or writing the connection '
      'failed (IO UnexpectedEof)',
    );
  });

  test('英文发送与代理模式按语境翻译，原生错误保留底层诊断', () {
    Get.addTranslations(AppTranslations().keys);
    Get.locale = AppTranslations.englishLocale;
    expect('发送'.tr, 'Send');
    expect('已发送'.tr, 'Sent');
    expect('关闭代理'.tr, 'Off');
    expect('关闭'.tr, 'Close');
    expect('停止'.tr, 'Stop');
    expect('测试'.tr, 'Test');
    expect(
      '@kind（@phase）'.trParams({'kind': 'Terminal', 'phase': 'Connected'}),
      'Terminal (Connected)',
    );
    for (final skill in AgentSkill.builtIn) {
      expect(skill.description.tr, isNot(skill.description));
    }
    expect(
      AppTranslations.error('所选网关不可用'),
      'The selected gateway is unavailable',
    );
    expect(
      AppTranslations.error('RDP 服务连接失败：RDP TCP 连接失败: Connection refused'),
      'RDP service connection failed: The RDP TCP connection failed: Connection refused',
    );
    expect(
      AppTranslations.error('传输失败：远程服务无响应，已达到重试上限（2 次，30 秒）'),
      contains('retry limit was reached'),
    );
  });
}
