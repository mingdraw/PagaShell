import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException, ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/src/rust/api/docker.dart' as docker;
import 'package:pagashell/src/rust/api/ssh.dart' as native;
import 'package:pagashell/src/rust/frb_generated.dart';

const _nativeLibrary = String.fromEnvironment('PAGASHELL_NATIVE_LIBRARY');

void main() {
  test(
    '真实容器操作桥接校验参数，失败不执行 Docker 操作',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(_nativeLibrary));
      addTearDown(RustLib.dispose);
      for (final (id, action, image, force, message) in [
        (
          'invalid',
          docker.DockerContainerAction.start,
          null,
          false,
          'Docker 资源标识无效，请刷新列表',
        ),
        (
          'aabbccddeeff',
          docker.DockerContainerAction.upgrade,
          null,
          false,
          '请输入目标镜像',
        ),
        (
          'aabbccddeeff',
          docker.DockerContainerAction.upgrade,
          r'$(id)',
          true,
          '目标镜像格式无效',
        ),
        (
          'aabbccddeeff',
          docker.DockerContainerAction.start,
          'nginx:latest',
          false,
          'Docker 操作参数无效',
        ),
        (
          'aabbccddeeff',
          docker.DockerContainerAction.start,
          null,
          false,
          'Docker 操作连接已关闭',
        ),
      ]) {
        await expectLater(
          docker.sshRunDockerContainerAction(
            sessionId: 0,
            containerId: id,
            action: action,
            targetImage: image,
            forcePull: force,
          ),
          throwsA(
            isA<AnyhowException>().having(
              (error) => error.message,
              'message',
              message,
            ),
          ),
        );
      }
      for (final (action, image, message) in [
        (docker.DockerImageAction.delete, null, '请选择要删除的镜像'),
        (docker.DockerImageAction.delete, r'$(id)', 'Docker 资源标识无效，请刷新列表'),
        (
          docker.DockerImageAction.pruneUntagged,
          'aabbccddeeff',
          'Docker 操作参数无效',
        ),
        (docker.DockerImageAction.delete, 'aabbccddeeff', 'Docker 操作连接已关闭'),
        (docker.DockerImageAction.pruneUntagged, null, 'Docker 操作连接已关闭'),
        (docker.DockerImageAction.pruneUnused, 'aabbccddeeff', 'Docker 操作参数无效'),
        (docker.DockerImageAction.pruneUnused, null, 'Docker 操作连接已关闭'),
      ]) {
        await expectLater(
          docker.sshRunDockerImageAction(
            sessionId: 0,
            action: action,
            imageId: image,
          ),
          throwsA(
            isA<AnyhowException>().having(
              (error) => error.message,
              'message',
              message,
            ),
          ),
        );
      }
    },
    skip: _nativeLibrary.isEmpty
        ? '通过 PAGASHELL_NATIVE_LIBRARY 指定已构建的原生库'
        : false,
  );

  test(
    '真实原生桥接把容器启动失败送入错误流并正常结束，不产生未捕获 Future 错误',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(_nativeLibrary));
      addTearDown(RustLib.dispose);

      // 不建立 SSH 连接：分别覆盖预检前校验失败和预检执行失败。
      for (final (id, message) in [
        ('invalid', 'Docker 资源标识无效，请刷新列表'),
        ('aabbccddeeff', 'Docker 管理连接已关闭'),
      ]) {
        await expectLater(
          native.sshStartDockerTerminal(
            sessionId: 0,
            containerId: id,
            cols: 80,
            rows: 24,
            scrollback: 100,
          ),
          emitsInOrder([
            emitsError(
              isA<AnyhowException>().having(
                (error) => error.message,
                'message',
                message,
              ),
            ),
            emitsDone,
          ]),
        ).timeout(const Duration(seconds: 5));
      }
      // 同时让桥接返回的后台 Future 完成，测试框架会捕获其中的未处理异常。
      await Future<void>.delayed(Duration.zero);
    },
    skip: _nativeLibrary.isEmpty
        ? '通过 PAGASHELL_NATIVE_LIBRARY 指定已构建的原生库'
        : false,
  );
}
