import '../entities/host.dart';

/// 主机存储的抽象接口。
///
/// M0/M1 使用内存实现，M2 切换为 drift(SQLite) 实现，上层无感知。
abstract interface class HostRepository {
  /// 监听全量主机列表（含首帧当前值）。
  Stream<List<Host>> watchAll();

  Future<List<Host>> getAll();

  /// 新增或按 id 覆盖。
  Future<void> upsert(Host host);

  Future<void> remove(String id);
}
