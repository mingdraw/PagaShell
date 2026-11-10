import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/application/session/docker_manager_controller.dart';
import 'package:pagashell/domain/ssh/docker_manager.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';

import '../support/docker_fixture.dart';

class _Source
    implements
        DockerManagerSource,
        DockerContainerActions,
        DockerImageActions,
        DockerComposeActions {
  final reads = <(DockerResourceKind, Completer<List<DockerResource>>)>[];
  final details = <DockerResource>[];
  Completer<DockerDetails>? detailGate;
  Future<DockerDetails> Function(DockerResource)? detailsReader;
  final actions = <(DockerResource, DockerContainerAction, String?, bool)>[];
  final actionGate = Completer<DockerActionResult>();
  final imageActions = <(DockerImageAction, DockerResource?)>[];
  final imageActionGate = Completer<DockerActionResult>();
  final composeActions = <(DockerResource, DockerComposeAction)>[];
  final composeActionGate = Completer<DockerActionResult>();

  @override
  Future<DockerActionResult> runDockerComposeAction(
    DockerResource project,
    DockerComposeAction action,
  ) {
    composeActions.add((project, action));
    return composeActionGate.future;
  }

  @override
  Future<DockerActionResult> runDockerImageAction(
    DockerImageAction action, {
    DockerResource? image,
  }) {
    imageActions.add((action, image));
    return imageActionGate.future;
  }

  @override
  Future<DockerActionResult> runDockerContainerAction(
    DockerResource container,
    DockerContainerAction action, {
    String? targetImage,
    bool forcePull = false,
  }) {
    actions.add((container, action, targetImage, forcePull));
    return actionGate.future;
  }

  @override
  Future<List<DockerResource>> readDockerResources(DockerResourceKind kind) {
    final request = Completer<List<DockerResource>>();
    reads.add((kind, request));
    return request.future;
  }

  @override
  Future<DockerDetails> readDockerDetails(DockerResource resource) async {
    details.add(resource);
    if (detailsReader case final reader?) return reader(resource);
    return detailGate?.future ?? dockerDetails(resource);
  }
}

void main() {
  testWidgets('编排操作独占变更并暂停轮询，成功后刷新当前项目，失败等待手动刷新', (tester) async {
    for (final action in DockerComposeAction.values) {
      final source = _Source();
      final controller = DockerManagerController(source: source);
      controller.select(DockerResourceKind.compose);
      controller.setEnabled(true);
      final project = dockerResource(kind: DockerResourceKind.compose);
      source.reads.last.$2.complete([project]);
      await tester.pump();
      final request = controller.runComposeAction(project, action);
      expect(source.composeActions.single, (project, action));
      expect(controller.pendingAction.value?.composeAction, action);
      await expectLater(
        controller.runComposeAction(project, action),
        throwsA(isA<SshEngineException>()),
      );
      await tester.pump(const Duration(seconds: 20));
      expect(source.reads, hasLength(1));
      if (action == DockerComposeAction.rebuild) {
        final failure = expectLater(
          request,
          throwsA(isA<SshEngineException>()),
        );
        source.composeActionGate.completeError(
          const SshEngineException('编排配置校验失败，请检查原配置和环境文件'),
        );
        await failure;
        await tester.pump(const Duration(seconds: 20));
        expect(controller.current.resources.single, project);
        expect(source.reads, hasLength(1));
        final refresh = controller.refreshResources();
        source.reads.last.$2.complete([project]);
        await refresh;
      } else {
        source.composeActionGate.complete(const DockerActionResult());
        await tester.pump();
        expect(source.reads.last.$1, DockerResourceKind.compose);
        source.reads.last.$2.complete(
          action == DockerComposeAction.delete ? [] : [project],
        );
        await request;
        expect(
          controller.current.resources,
          action == DockerComposeAction.delete ? isEmpty : [project],
        );
      }
      controller.onClose();
    }
  });
  testWidgets('镜像删除和清理共用变更背压，成功刷新镜像列表，拒绝使用中或未知状态的删除', (tester) async {
    for (final action in DockerImageAction.values) {
      final source = _Source();
      final controller = DockerManagerController(source: source);
      controller.select(DockerResourceKind.image);
      controller.setEnabled(true);
      final unused = dockerImage(hex: 'b');
      final used = dockerImage(hex: 'a', inUse: true);
      source.reads.last.$2.complete([used, unused]);
      await tester.pump();
      for (final image in [used, dockerImage(hex: 'c', inUse: null)]) {
        await expectLater(
          controller.runImageAction(DockerImageAction.delete, image: image),
          throwsA(isA<SshEngineException>()),
        );
      }
      final request = controller.runImageAction(
        action,
        image: action == DockerImageAction.delete ? unused : null,
      );
      expect(controller.busy, isTrue);
      expect(source.imageActions.single, (
        action,
        action == DockerImageAction.delete ? unused : null,
      ));
      await expectLater(
        controller.runImageAction(DockerImageAction.pruneUntagged),
        throwsA(isA<SshEngineException>()),
      );
      await tester.pump(const Duration(seconds: 20));
      expect(source.reads, hasLength(1));
      source.imageActionGate.complete(const DockerActionResult());
      await tester.pump();
      expect(source.reads.last.$1, DockerResourceKind.image);
      source.reads.last.$2.complete([used]);
      await request;
      expect(controller.current.resources, [used]);
      controller.setEnabled(false);
      controller.onClose();
    }
  });

  testWidgets('镜像操作失败保留列表并暂停刷新，只有手动成功后恢复', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    controller.select(DockerResourceKind.image);
    controller.setEnabled(true);
    final image = dockerImage(hex: 'a');
    source.reads.last.$2.complete([image]);
    await tester.pump();
    final failure = expectLater(
      controller.runImageAction(DockerImageAction.pruneUntagged),
      throwsA(isA<SshEngineException>()),
    );
    source.imageActionGate.completeError(
      const SshEngineException('没有权限操作 Docker 镜像'),
    );
    await failure;
    await tester.pump(const Duration(seconds: 20));
    expect(source.reads, hasLength(1));
    expect(controller.current.resources.single, image);
    final refresh = controller.refreshResources();
    source.reads.last.$2.complete([image]);
    await refresh;
    await tester.pump(const Duration(seconds: 5));
    expect(source.reads, hasLength(3));
    source.reads.last.$2.complete([image]);
    await tester.pump();
    controller.setEnabled(false);
  });

  testWidgets('升级期间暂停刷新并拒绝重复提交，成功后重读新 ID 并恢复轮询', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    final old = dockerResource();
    controller.setEnabled(true);
    source.reads.first.$2.complete([old]);
    await tester.pump();
    final operation = controller.runContainerAction(
      old,
      DockerContainerAction.upgrade,
      targetImage: 'nginx:new',
      forcePull: true,
    );
    expect(controller.busy, isTrue);
    await tester.pump(const Duration(seconds: 30));
    expect(source.reads, hasLength(1));
    expect(source.actions.single, (
      old,
      DockerContainerAction.upgrade,
      'nginx:new',
      true,
    ));
    await expectLater(
      controller.runContainerAction(old, DockerContainerAction.delete),
      throwsA(isA<SshEngineException>()),
    );
    source.actionGate.complete(const DockerActionResult());
    await tester.pump();
    expect(source.reads, hasLength(2));
    final fresh = dockerResource(id: 'c'.padRight(64, 'c'));
    source.reads.last.$2.complete([fresh]);
    await operation;
    expect(controller.current.resources.single.id, fresh.id);
    await tester.pump(const Duration(seconds: 5));
    expect(source.reads, hasLength(3));
    source.reads.last.$2.complete([fresh]);
    await tester.pump();
    controller.setEnabled(false);
  });

  testWidgets('操作失败暂停所有自动刷新，保留错误与旧列表，手动成功后恢复', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    final resource = dockerResource();
    controller.setEnabled(true);
    source.reads.first.$2.complete([resource]);
    await tester.pump();
    final failed = expectLater(
      controller.runContainerAction(resource, DockerContainerAction.stop),
      throwsA(isA<SshEngineException>()),
    );
    source.actionGate.completeError(
      const SshEngineException('没有权限操作 Docker 容器'),
    );
    await failed;
    await tester.pump(const Duration(seconds: 30));
    expect(source.reads, hasLength(1));
    expect(controller.current.resources.single, same(resource));
    final refresh = controller.refreshResources();
    source.reads.last.$2.complete([resource]);
    await refresh;
    await tester.pump(const Duration(seconds: 5));
    expect(source.reads, hasLength(3));
    source.reads.last.$2.complete([resource]);
    await tester.pump();
    controller.setEnabled(false);
  });

  testWidgets('报错后跨分类、折叠重开均不自动查询，只有手动成功后恢复定时刷新', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    source.reads.first.$2.completeError(const SshEngineException('Docker 未运行'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    controller.setEnabled(false);
    controller.setEnabled(true);
    controller.select(DockerResourceKind.image);
    await tester.pump(const Duration(seconds: 30));
    expect(source.reads, hasLength(1));
    final failedRetry = controller.refreshResources();
    source.reads.last.$2.completeError(
      const SshEngineException('没有权限获取 Docker 信息'),
    );
    await tester.pump();
    await failedRetry;
    await tester.pump(const Duration(seconds: 30));
    expect(source.reads, hasLength(2));
    final retry = controller.refreshResources();
    source.reads.last.$2.complete([
      dockerResource(kind: DockerResourceKind.image),
    ]);
    await tester.pump();
    await retry;
    await tester.pump(const Duration(seconds: 5));
    expect(source.reads, hasLength(4));
    expect(source.reads.last.$1, DockerResourceKind.image);
    source.reads.last.$2.complete([
      dockerResource(kind: DockerResourceKind.image),
    ]);
    await tester.pump();
    controller.setEnabled(false);
  });

  testWidgets('在途请求失败会取消所有排队刷新，切换分类不会绕过暂停', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    controller.select(DockerResourceKind.network);
    controller.select(DockerResourceKind.volume);
    await controller.refreshResources();
    source.reads.first.$2.completeError(
      const SshEngineException('Docker 查询超时，请重试'),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(source.reads, hasLength(1));
    final retry = controller.refreshResources();
    source.reads.last.$2.complete([
      dockerResource(kind: DockerResourceKind.volume),
    ]);
    await tester.pump();
    await retry;
    controller.setEnabled(false);
  });

  testWidgets('详情失败暂停轮询，在途自动成功不能解除暂停，手动详情成功后恢复', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    final resource = dockerResource();
    controller.setEnabled(true);
    source.reads.first.$2.complete([resource]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    final gate = source.detailGate = Completer<DockerDetails>();
    final rejected = expectLater(
      controller.readDetails(resource),
      throwsA(isA<SshEngineException>()),
    );
    gate.completeError(const SshEngineException('没有权限获取 Docker 信息'));
    await tester.pump();
    await rejected;
    source.reads.last.$2.complete([resource]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(source.reads, hasLength(2));
    source.detailGate = null;
    await controller.readDetails(resource);
    await tester.pump(const Duration(seconds: 5));
    expect(source.reads, hasLength(3));
    source.reads.last.$2.complete([resource]);
    await tester.pump();
    controller.setEnabled(false);
  });

  testWidgets('旧容器消失后按完整同名读取新 ID，更新列表且不被旧轮询结果覆盖', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    final stale = dockerResource();
    final fresh = dockerResource(id: 'b'.padRight(64, 'b'));
    source.detailsReader = (resource) async {
      if (resource.id == stale.id) {
        throw const SshEngineException('Docker 资源可能已移除，请刷新后重试');
      }
      return dockerDetails(resource);
    };
    controller.setEnabled(true);
    source.reads.first.$2.complete([stale]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    final pending = controller.readDetails(stale);
    await tester.pump();
    expect(source.reads, hasLength(3));
    source.reads.last.$2.complete([fresh]);
    await tester.pump();
    expect((await pending).resource.id, fresh.id);
    expect(controller.current.resources.single.id, fresh.id);
    source.reads[1].$2.complete([stale]);
    await tester.pump();
    expect(controller.current.resources.single.id, fresh.id);
    expect(source.details.map((resource) => resource.id), [stale.id, fresh.id]);
    await controller.readDetails(controller.current.resources.single);
    expect(source.reads, hasLength(3));
    controller.setEnabled(false);
  });

  testWidgets('详情重查与较新的列表请求交错时，两种返回顺序都保留新请求的结果', (tester) async {
    for (final newerFirst in [false, true]) {
      final source = _Source();
      final controller = DockerManagerController(source: source);
      final stale = dockerResource();
      final replacement = dockerResource(id: 'b'.padRight(64, 'b'));
      final newest = dockerResource(id: 'c'.padRight(64, 'c'));
      source.detailsReader = (resource) async {
        if (resource.id == stale.id) {
          throw const SshEngineException('Docker 资源可能已移除，请刷新后重试');
        }
        return dockerDetails(resource);
      };
      controller.setEnabled(true);
      source.reads.first.$2.complete([stale]);
      await tester.pump();
      final details = controller.readDetails(stale);
      await tester.pump();
      final lookup = source.reads.last.$2;
      final refresh = controller.refreshResources();
      final newer = source.reads.last.$2;
      expect(source.reads, hasLength(3));
      if (newerFirst) {
        newer.complete([newest]);
        await tester.pump();
        await refresh;
        lookup.complete([replacement]);
        await tester.pump();
        await details;
      } else {
        lookup.complete([replacement]);
        await tester.pump();
        await details;
        expect(controller.current.resources.single.id, replacement.id);
        newer.complete([newest]);
        await tester.pump();
        await refresh;
      }
      expect(controller.current.resources.single.id, newest.id);
      controller.setEnabled(false);
      controller.onClose();
    }
  });

  testWidgets('容器只接受完整同名新 ID，类似名称、未更新 ID 和错误身份均不替换缓存', (tester) async {
    final stale = dockerResource();
    final fresh = dockerResource(id: 'b'.padRight(64, 'b'));
    for (final scenario in ['similar', 'same-id', 'wrong-id', 'renamed']) {
      final source = _Source();
      final controller = DockerManagerController(source: source);
      source.detailsReader = (resource) async {
        if (resource.id == stale.id) {
          throw const SshEngineException('Docker 资源可能已移除，请刷新后重试');
        }
        return dockerDetails(
          scenario == 'wrong-id'
              ? dockerResource(id: 'c'.padRight(64, 'c'))
              : dockerResource(id: fresh.id, name: 'another-name'),
        );
      };
      controller.setEnabled(true);
      source.reads.first.$2.complete([stale]);
      await tester.pump();
      final rejected = expectLater(
        controller.readDetails(stale),
        throwsA(isA<SshEngineException>()),
      );
      await tester.pump();
      source.reads.last.$2.complete([
        switch (scenario) {
          'similar' => dockerResource(id: fresh.id, name: '${stale.name}-copy'),
          'same-id' => stale,
          _ => fresh,
        },
      ]);
      await tester.pump();
      await rejected;
      expect(controller.current.resources.single.id, stale.id);
      await tester.pump(const Duration(seconds: 30));
      expect(source.reads, hasLength(2));
      controller.setEnabled(false);
      controller.onClose();
    }
  });

  testWidgets('权限、超时、其他详情错误与非容器资源不会按名重查', (tester) async {
    for (final message in [
      '没有权限获取 Docker 信息',
      'Docker 查询超时，请重试',
      '无法读取 Docker 详情，请重试',
      'Docker 资源可能已移除，请刷新后重试',
    ]) {
      final source = _Source();
      final controller = DockerManagerController(source: source);
      final resource = dockerResource(
        kind: message == 'Docker 资源可能已移除，请刷新后重试'
            ? DockerResourceKind.image
            : DockerResourceKind.container,
      );
      controller.select(resource.kind);
      source.detailsReader = (_) async => throw SshEngineException(message);
      controller.setEnabled(true);
      source.reads.first.$2.complete([resource]);
      await tester.pump();
      await expectLater(
        controller.readDetails(resource),
        throwsA(isA<SshEngineException>()),
      );
      await tester.pump(const Duration(seconds: 30));
      expect(source.reads, hasLength(1));
      expect(source.details, hasLength(1));
      controller.setEnabled(false);
      controller.onClose();
    }
  });

  testWidgets('重查新容器列表超时后，不再从迟到列表发起详情查询', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(
      source: source,
      interval: const Duration(hours: 1),
    );
    addTearDown(controller.onClose);
    final stale = dockerResource();
    final fresh = dockerResource(id: 'b'.padRight(64, 'b'));
    source.detailsReader = (_) async =>
        throw const SshEngineException('Docker 资源可能已移除，请刷新后重试');
    controller.setEnabled(true);
    source.reads.first.$2.complete([stale]);
    await tester.pump();
    final rejected = expectLater(
      controller.readDetails(stale),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          'Docker 查询超时，请重试',
        ),
      ),
    );
    await tester.pump();
    final lookup = source.reads.last.$2;
    await tester.pump(dockerQueryTimeout);
    await rejected;
    final retry = controller.refreshResources();
    source.reads.last.$2.complete([fresh]);
    await tester.pump();
    await retry;
    lookup.complete([fresh]);
    await tester.pump();
    expect(source.details, hasLength(1));
    expect(controller.current.resources.single.id, fresh.id);
    controller.setEnabled(false);
  });

  testWidgets('列表总超时结束加载、保留数据并可重试，迟到结果不覆盖新数据', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(
      source: source,
      interval: const Duration(hours: 1),
    );
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    source.reads.first.$2.complete([dockerResource(name: 'previous')]);
    await tester.pump();
    final previousUpdate = controller.current.updatedAt.value;
    final stalled = controller.refreshResources();
    await tester.pump(dockerQueryTimeout - const Duration(milliseconds: 1));
    expect(controller.current.loading.value, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    await stalled;
    expect(controller.current.loading.value, isFalse);
    expect(controller.current.error.value, 'Docker 查询超时，请重试');
    expect(controller.current.resources.single.name, 'previous');
    expect(controller.current.updatedAt.value, previousUpdate);
    final retry = controller.refreshResources();
    expect(source.reads, hasLength(3));
    source.reads.last.$2.complete([dockerResource(name: 'fresh')]);
    await tester.pump();
    await retry;
    source.reads[1].$2.complete([dockerResource(name: 'stale')]);
    await tester.pump();
    expect(controller.current.resources.single.name, 'fresh');
    expect(controller.current.error.value, isNull);
    controller.setEnabled(false);
  });

  testWidgets('详情读取总超时报错，可再次读取，超时后迟到错误不会影响重试', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(
      source: source,
      interval: const Duration(hours: 1),
    );
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    final resource = dockerResource();
    source.reads.single.$2.complete([resource]);
    await tester.pump();
    final gate = source.detailGate = Completer<DockerDetails>();
    final rejected = expectLater(
      controller.readDetails(resource),
      throwsA(
        isA<SshEngineException>().having(
          (e) => e.message,
          'message',
          'Docker 查询超时，请重试',
        ),
      ),
    );
    await tester.pump(dockerQueryTimeout);
    await rejected;
    source.detailGate = null;
    expect((await controller.readDetails(resource)).resource.id, resource.id);
    gate.completeError(const SshEngineException('Docker 管理连接已关闭'));
    await tester.pump();
    expect(source.details, hasLength(2));
    controller.setEnabled(false);
  });

  testWidgets('按需启动，分类各自保留搜索和列表，周期只查询当前分类', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    expect(source.reads, isEmpty);
    controller.setEnabled(true);
    source.reads.last.$2.complete([dockerResource()]);
    await tester.pump();
    controller.current.query.value = 'NGINX';
    expect(controller.current.visibleResources, hasLength(1));
    controller.select(DockerResourceKind.image);
    source.reads.last.$2.complete([
      dockerResource(kind: DockerResourceKind.image),
    ]);
    await tester.pump();
    controller.current.query.value = 'missing';
    expect(controller.current.visibleResources, isEmpty);
    await tester.pump(const Duration(seconds: 5));
    expect(source.reads.map((read) => read.$1), [
      DockerResourceKind.container,
      DockerResourceKind.image,
      DockerResourceKind.image,
    ]);
    source.reads.last.$2.complete([
      dockerResource(kind: DockerResourceKind.image),
    ]);
    await tester.pump();
    controller.select(DockerResourceKind.container);
    expect(controller.current.query.value, 'NGINX');
    expect(controller.current.resources, hasLength(1));
    source.reads.last.$2.completeError(
      const SshEngineException('Docker 查询超时，请重试'),
    );
    await tester.pump();
    expect(controller.current.resources, hasLength(1));
    expect(controller.current.updatedAt.value, isNotNull);
    expect(controller.current.error.value, 'Docker 查询超时，请重试');
    expect(source.details, isEmpty);
    controller.setEnabled(false);
  });

  testWidgets('分类在途切换不并发，迟到列表写入原分类并接着查询当前分类', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    addTearDown(controller.onClose);
    controller.setEnabled(true);
    controller.select(DockerResourceKind.network);
    controller.select(DockerResourceKind.volume);
    await controller.refreshResources();
    expect(source.reads, hasLength(1));
    source.reads.first.$2.complete([dockerResource()]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(source.reads, hasLength(2));
    expect(source.reads.last.$1, DockerResourceKind.volume);
    expect(
      controller.states[DockerResourceKind.container]!.resources,
      hasLength(1),
    );
    expect(controller.current.resources, isEmpty);
    source.reads.last.$2.complete([
      dockerResource(kind: DockerResourceKind.volume),
    ]);
    await tester.pump();
    controller.setEnabled(false);
    await tester.pump(const Duration(seconds: 20));
    expect(source.reads, hasLength(2));
  });

  testWidgets('隐藏或关闭时忽略在途结果，重新展开只补一次刷新', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    controller.setEnabled(true);
    controller.setEnabled(false);
    controller.setEnabled(true);
    source.reads.first.$2.complete([dockerResource()]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.current.resources, isEmpty);
    expect(source.reads, hasLength(2));
    source.reads.last.$2.complete([dockerResource()]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    controller.onClose();
    source.reads.last.$2.completeError(Exception('/local/private/path'));
    await tester.pump(const Duration(seconds: 20));
    expect(source.reads, hasLength(3));
    expect(controller.current.resources, hasLength(1));
    expect(controller.current.error.value, isNull);
  });

  testWidgets('详情仅点击读取，核对身份，关闭拒绝查询和迟到详情', (tester) async {
    final source = _Source();
    final controller = DockerManagerController(source: source);
    controller.setEnabled(true);
    source.reads.single.$2.complete([dockerResource()]);
    await tester.pump();
    final resource = controller.current.resources.single;
    expect((await controller.readDetails(resource)).resource.id, resource.id);
    expect(source.details, [resource]);
    source.detailGate = Completer<DockerDetails>();
    final pending = controller.readDetails(resource);
    final rejected = expectLater(pending, throwsA(isA<SshEngineException>()));
    controller.setEnabled(false);
    source.detailGate!.complete(dockerDetails(resource));
    await rejected;
    controller.onClose();
    await expectLater(
      controller.readDetails(resource),
      throwsA(isA<SshEngineException>()),
    );
    expect(source.details, hasLength(2));
  });
}
