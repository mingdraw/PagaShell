import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/src/rust/api/ssh.dart' as rust;
import 'package:pagashell/src/rust/frb_generated.dart';

// 指定 cargo build --lib 生成的库，核验实际 FRB 错误通道。
void main() {
  final library = Platform.environment['PAGASHELL_TEST_NATIVE_LIBRARY'];
  setUpAll(() async {
    if (library != null) {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    }
  });
  tearDownAll(() {
    if (library != null) RustLib.dispose();
  });

  for (final upload in [true, false]) {
    test(
      '真实 Rust ${upload ? '上传' : '下载'}错误在进度流报错，不会静默结束',
      () async {
        final stream = upload
            ? rust.sftpUpload(
                sessionId: 0,
                transferId: 100,
                localPath: '/unused',
                remotePath: '/unused',
              )
            : rust.sftpDownload(
                sessionId: 0,
                transferId: 101,
                localPath: '/unused',
                remotePath: '/unused',
              );
        await expectLater(
          stream,
          emitsInOrder([
            emitsError(
              isA<AnyhowException>().having(
                (error) => error.message,
                'message',
                contains('会话不存在'),
              ),
            ),
            emitsDone,
          ]),
        );
      },
      skip: library == null
          ? '设置 PAGASHELL_TEST_NATIVE_LIBRARY 后执行真实 FFI 回归'
          : false,
    );
  }
}
