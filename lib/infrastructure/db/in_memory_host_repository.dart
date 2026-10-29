import 'dart:async';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/repositories/host_repository.dart';

/// 内存版主机存储：M2 引入 drift(SQLite) 前的临时实现。
class InMemoryHostRepository implements HostRepository {
  final Map<String, Host> _hosts = {};
  final StreamController<List<Host>> _changes =
      StreamController<List<Host>>.broadcast();

  List<Host> get _snapshot => List.unmodifiable(_hosts.values);

  @override
  Stream<List<Host>> watchAll() async* {
    yield _snapshot;
    yield* _changes.stream;
  }

  @override
  Future<List<Host>> getAll() async => _snapshot;

  @override
  Future<void> upsert(Host host) async {
    ForwardPort.validateAll(host.forwardPorts);
    _hosts[host.id] = host;
    _changes.add(_snapshot);
  }

  @override
  Future<void> remove(String id) async {
    _hosts.remove(id);
    _changes.add(_snapshot);
  }

  void dispose() {
    _changes.close();
  }
}
