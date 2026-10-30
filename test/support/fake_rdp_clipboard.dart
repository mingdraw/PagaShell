import 'dart:async';

import 'package:pagashell/domain/rdp/rdp_clipboard.dart';

import 'fake_rdp_engine.dart';

class FakeClipboardSession extends FakeRdpSession
    implements RdpClipboardSession {
  final clipboardOutput = StreamController<RdpClipboardEvent>.broadcast(
    sync: true,
  );
  final clipboardChanges = <ClipboardContent>[];
  final clipboardActive = <bool>[];
  final operations = <String>[];
  Future<void> Function(ClipboardContent)? onClipboardUpdate;
  Future<void> Function(bool)? onClipboardActive;
  int cancelledTransfers = 0;
  @override
  Stream<RdpClipboardEvent> get clipboardEvents => clipboardOutput.stream;
  @override
  Future<void> setClipboardActive(bool active) async {
    clipboardActive.add(active);
    await onClipboardActive?.call(active);
  }

  @override
  Future<void> updateClipboard(ClipboardContent content) async {
    operations.add('clipboard');
    clipboardChanges.add(content);
    await onClipboardUpdate?.call(content);
  }

  @override
  Future<void> key(
    int scanCode, {
    required bool down,
    bool extended = false,
  }) async {
    operations.add('key:$scanCode:$down:$extended');
    await super.key(scanCode, down: down, extended: extended);
  }

  @override
  Future<void> cancelClipboardTransfer() async => cancelledTransfers++;
  @override
  Future<void> close() async {
    unawaited(clipboardOutput.close());
    await super.close();
  }
}

class FakeLocalClipboard implements LocalClipboard {
  ClipboardSnapshot current = const ClipboardSnapshot(
    '0',
    ClipboardContent(text: 'initial'),
  );
  int revision = 0;
  int reads = 0;
  final writes = <ClipboardContent>[];
  void Function()? beforeWrite;
  Future<ClipboardSnapshot> Function()? onRead;
  void copy(ClipboardContent content) {
    current = ClipboardSnapshot((++revision).toString(), content);
  }

  @override
  Future<ClipboardSnapshot> read() async {
    reads++;
    return await onRead?.call() ?? current;
  }

  @override
  Future<ClipboardSnapshot?> write(
    ClipboardContent content, {
    required String expectedChangeId,
  }) async {
    beforeWrite?.call();
    if (current.changeId != expectedChangeId) return null;
    writes.add(content);
    copy(content);
    return current;
  }
}
