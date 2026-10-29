import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/entities/forward_port.dart';
import '../../domain/entities/host.dart';
import '../../domain/repositories/host_repository.dart';
import 'app_database.dart';

/// 主机的 drift(SQLite) 持久化实现。tags 以换行符连接存储。
class DriftHostRepository implements HostRepository {
  DriftHostRepository(this._db, {this.gateways = false});

  final AppDatabase _db;
  final bool gateways;

  SimpleSelectStatement<$HostsTable, HostRow> get _query =>
      _db.select(_db.hosts)..where(
        (h) =>
            h.isGateway.equals(gateways) &
            (gateways
                ? h.gatewayType.isIn(['ssh', 'page'])
                : const Constant(true)),
      );

  Host _toEntity(HostRow row) => Host(
    id: row.id,
    name: row.name,
    hostname: row.hostname,
    port: row.port,
    username: row.username,
    note: row.note,
    tags: row.tags.isEmpty ? const [] : row.tags.split('\n'),
    folderId: row.folderId,
    identityId: row.identityId,
    gatewayId: row.gatewayId,
    gatewayType: gateways
        ? GatewayType.values.byName(row.gatewayType)
        : GatewayType.ssh,
    pageClientId: row.pageClientId,
    pageServerFingerprint: row.pageServerFingerprint,
    serviceType: gateways
        ? ServiceType.ssh
        : ServiceType.values.byName(row.gatewayType),
    rdpDomain: gateways ? '' : row.rdpDomain,
    colorValue: row.colorValue,
    sortOrder: row.sortOrder,
    forwardPorts: List.unmodifiable(
      (jsonDecode(row.forwardPortsJson) as List<dynamic>).map(
        (value) => ForwardPort.fromJson(value as Map<String, dynamic>),
      ),
    ),
  );

  @override
  Stream<List<Host>> watchAll() =>
      _query.watch().map((rows) => rows.map(_toEntity).toList());

  @override
  Future<List<Host>> getAll() async =>
      (await _query.get()).map(_toEntity).toList();

  @override
  Future<void> upsert(Host host) => _db.transaction(() async {
    ForwardPort.validateAll(host.forwardPorts);
    if (gateways && host.isDesktop) throw StateError('网关支持 SSH 或 Page 类型');
    if (gateways && host.gatewayId != null) {
      throw ArgumentError('网关不能引用其他网关');
    }
    final gatewayId = host.gatewayId;
    if (gatewayId != null) {
      final gateway =
          await (_db.select(_db.hosts)..where(
                (h) =>
                    h.id.equals(gatewayId) &
                    h.isGateway.equals(true) &
                    h.gatewayType.isIn(['ssh', 'page']),
              ))
              .getSingleOrNull();
      if (gateway == null) throw StateError('所选网关不可用，请检查服务的网关配置');
    }
    await _db
        .into(_db.hosts)
        .insertOnConflictUpdate(
          HostsCompanion.insert(
            id: host.id,
            name: host.name,
            hostname: host.hostname,
            port: Value(host.port),
            username: Value(host.username),
            note: Value(host.note),
            tags: Value(host.tags.join('\n')),
            folderId: Value(host.folderId),
            identityId: Value(host.identityId),
            gatewayId: Value(host.gatewayId),
            // Keep the historical column name so existing RDP services survive.
            gatewayType: Value(
              gateways ? host.gatewayType.name : host.serviceType.name,
            ),
            rdpDomain: Value(gateways ? '' : host.rdpDomain),
            pageClientId: Value(host.pageClientId),
            pageServerFingerprint: Value(host.pageServerFingerprint),
            isGateway: Value(gateways),
            colorValue: Value(host.colorValue),
            sortOrder: Value(host.sortOrder),
            forwardPortsJson: Value(
              jsonEncode(host.forwardPorts.map((p) => p.toJson()).toList()),
            ),
          ),
        );
  });

  @override
  Future<void> remove(String id) => _db.transaction(() async {
    if (gateways) {
      final references = await (_db.select(
        _db.hosts,
      )..where((h) => h.gatewayId.equals(id))).get();
      if (references.isNotEmpty) {
        throw StateError('网关正在被服务使用，请先修改服务的网关配置');
      }
    }
    await (_db.delete(
      _db.hosts,
    )..where((h) => h.id.equals(id) & h.isGateway.equals(gateways))).go();
  });
}
