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
    for (final resume in [true, false]) {
      test(
        '真实 Rust ${upload ? '上传' : '下载'}${resume ? '续传' : '新传'}连接异常在进度流报错，保留原文件',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'pagashell-transfer-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = File('${directory.path}/original.txt');
          await file.writeAsString('original contents');
          final stream = upload
              ? rust.sftpUpload(
                  sessionId: 0,
                  transferId: 100,
                  localPath: file.path,
                  remotePath: '/unused',
                  resume: resume,
                )
              : rust.sftpDownload(
                  sessionId: 0,
                  transferId: 101,
                  localPath: file.path,
                  remotePath: '/unused',
                  resume: resume,
                );
          await expectLater(
            stream,
            emitsInOrder([
              emitsError(
                isA<AnyhowException>().having(
                  (error) => error.message,
                  'message',
                  contains('SSH连接已断开'),
                ),
              ),
              emitsDone,
            ]),
          );
          expect(await file.readAsString(), 'original contents');
        },
        skip: library == null
            ? '设置 PAGASHELL_TEST_NATIVE_LIBRARY 后执行真实 FFI 回归'
            : false,
      );
    }
  }
}
