import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/application/network/app_connect.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/application/updates/app_update_controller.dart';

import '../support/in_memory_settings_repository.dart';
import '../support/update_fixtures.dart';

void main() {
  late SettingsController settings;
  late TestUpdateInstaller installer;
  late UpdateConnect connect;
  late AppUpdateController updates;
  late HttpServer server;
  late Uri url;

  setUp(() async {
    settings = SettingsController(repository: InMemorySettingsRepository());
    installer = TestUpdateInstaller();
    connect = UpdateConnect();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://127.0.0.1:${server.port}/fixture');
    updates = AppUpdateController(
      connect: connect,
      createDownloadConnect: () => AppConnect(followRedirects: true),
      settings: settings,
      installer: installer,
    );
    updates.exitForUpdate = (commit) async {
      await commit();
      return true;
    };
    await settings.ready;
  });

  tearDown(() async {
    updates.onClose();
    settings.onClose();
    connect.dispose();
    await server.close(force: true);
    await installer.cleanup();
  });

  void serve({List<int> bytes = const [1, 2, 3, 4], int? length}) {
    server.listen((request) async {
      if (length != null) request.response.contentLength = length;
      request.response.add(bytes);
      await request.response.close();
    });
  }

  test('自动更新关闭时启动无请求，手动检查仍可用', () async {
    await settings.setAutomaticUpdates(false);
    expect(await updates.checkOnStartup(), isNull);
    expect(connect.calls, 0);
    expect((await updates.check())?.version, '0.3.0');
    expect(connect.calls, 1);
  });

  test('启动只检查一次，重复提示受保护，手动仍可再次提示', () async {
    final release = (await updates.checkOnStartup())!;
    expect(await updates.checkOnStartup(), isNull);
    expect(connect.calls, 1);
    expect(updates.beginPrompt(release, automatic: true), isTrue);
    expect(updates.beginPrompt(release, automatic: false), isFalse);
    updates.endPrompt();
    expect(updates.beginPrompt(release, automatic: true), isFalse);
    expect(updates.beginPrompt(release, automatic: false), isTrue);
    updates.endPrompt();
  });

  test('合并并发检查，检查期间关闭开关会抑制启动结果', () async {
    final response = Completer<Response<Map<String, dynamic>>>();
    connect = UpdateConnect(handler: () => response.future);
    updates = AppUpdateController(
      connect: connect,
      createDownloadConnect: AppConnect.new,
      settings: settings,
      installer: installer,
    );
    final startup = updates.checkOnStartup();
    await Future<void>.delayed(Duration.zero);
    final manual = updates.check();
    expect(connect.calls, 1);
    await settings.setAutomaticUpdates(false);
    response.complete(Response(statusCode: 200, body: releaseJson()));
    expect(await startup, isNull);
    expect((await manual)?.version, '0.3.0');
  });

  test('同号构建不会重复更新，HTTP 失败能重试', () async {
    var fails = false;
    connect = UpdateConnect(
      handler: () => fails
          ? const Response(statusCode: 403)
          : Response(statusCode: 200, body: releaseJson(version: '0.2.1')),
    );
    updates = AppUpdateController(
      connect: connect,
      createDownloadConnect: AppConnect.new,
      settings: settings,
      installer: installer,
    );
    expect(await updates.check(), isNull);
    expect(updates.message.value, '当前已是最新版本');
    fails = true;
    expect(await updates.check(), isNull);
    expect(updates.message.value, '检查更新失败，请检查网络后重试');
    expect(updates.busy, isFalse);
  });

  test('真实 HTTP 流完整下载并校验，准备成功后才提交退出', () async {
    serve(length: 4);
    updates.exitForUpdate = (commit) async {
      expect(installer.events, ['prepare']);
      expect(installer.pending.commits, 0);
      await commit();
      return true;
    };
    await updates.install(downloadRelease(url));
    expect(installer.preparedBytes, [1, 2, 3, 4]);
    expect(installer.pending.commits, 1);
    expect(installer.pending.cancels, 0);
    expect(installer.events, ['prepare']);
    expect(updates.message.value, isEmpty);
    expect(updates.progress.value, 1);
  });

  test('SHA-256 错误、大小错误和不完整下载均不交给安装器', () async {
    serve();
    for (final release in [
      downloadRelease(url, digest: '0' * 64),
      downloadRelease(url, size: 3),
      downloadRelease(url, size: 5),
    ]) {
      await updates.install(release);
      expect(installer.events, isNot(contains('prepare')));
      expect(updates.message.value, contains('重新下载'));
      expect(updates.busy, isFalse);
    }
    expect(installer.events, ['discard', 'discard', 'discard']);
  });

  test('退出被取消不提交，提交后原生退出失败会撤销安装', () async {
    serve();
    updates.exitForUpdate = (_) async => false;
    await updates.install(downloadRelease(url));
    expect(installer.pending.commits, 0);
    expect(installer.pending.cancels, 1);
    expect(updates.message.value, '更新已取消');
    updates.exitForUpdate = (commit) async {
      await commit();
      throw StateError('native close failed');
    };
    await updates.install(downloadRelease(url));
    expect(installer.pending.commits, 1);
    expect(installer.pending.cancels, 2);
    expect(installer.events.where((e) => e == 'discard'), hasLength(2));
    expect(updates.busy, isFalse);
  });

  test('清理异常仍恢复状态，允许重新检查', () async {
    serve();
    installer.cleanupFails = true;
    await updates.install(downloadRelease(url, digest: '0' * 64));
    expect(updates.message.value, '安装包校验失败，请重新下载');
    expect(updates.busy, isFalse);
    expect(await updates.check(), isNotNull);
  });

  test('下载中取消会停止流、清理残包且不提交', () async {
    final started = Completer<void>();
    server.listen((request) async {
      request.response.add([1, 2]);
      await request.response.flush();
      started.complete();
    });
    final installing = updates.install(downloadRelease(url));
    await started.future;
    await updates.cancelDownload().timeout(const Duration(seconds: 5));
    await installing;
    expect(updates.message.value, '更新已取消');
    expect(installer.events, ['discard']);
    expect(installer.pending.commits, 0);
    expect(updates.busy, isFalse);
  });
}
