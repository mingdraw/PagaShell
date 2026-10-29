import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/identity.dart';
import 'package:pagashell/domain/repositories/host_repository.dart';
import 'package:pagashell/domain/repositories/identity_repository.dart';
import 'package:pagashell/infrastructure/db/app_database.dart';
import 'package:pagashell/infrastructure/db/drift_host_repository.dart';
import 'package:pagashell/infrastructure/db/drift_identity_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';

void main() {
  for (final sqlite in [false, true]) {
    for (final viaGateway in [false, true]) {
      test(
        '${sqlite ? 'SQLite' : '内存'}：${viaGateway ? '网关' : '服务'}引用凭证时仓库拒删，解绑后可删除',
        () async {
          final HostRepository services;
          final HostRepository gateways;
          final IdentityRepository identities;
          if (sqlite) {
            final db = AppDatabase.forTesting(NativeDatabase.memory());
            addTearDown(db.close);
            services = DriftHostRepository(db);
            gateways = DriftHostRepository(db, gateways: true);
            identities = DriftIdentityRepository(db);
          } else {
            final memoryServices = InMemoryHostRepository();
            final memoryGateways = InMemoryHostRepository();
            final memoryIdentities = InMemoryIdentityRepository(
              services: memoryServices,
              gateways: memoryGateways,
            );
            addTearDown(memoryServices.dispose);
            addTearDown(memoryGateways.dispose);
            addTearDown(memoryIdentities.dispose);
            services = memoryServices;
            gateways = memoryGateways;
            identities = memoryIdentities;
          }
          const identity = Identity(
            id: 'shared',
            name: 'Shared credential',
            username: 'deploy',
            authType: AuthType.password,
            secretRef: 'sec-shared',
          );
          const unused = Identity(
            id: 'unused',
            name: 'Unused credential',
            username: 'deploy',
            authType: AuthType.password,
          );
          final hosts = viaGateway ? gateways : services;
          const host = Host(
            id: 'endpoint',
            name: 'Endpoint',
            hostname: 'endpoint.test',
            identityId: 'shared',
          );
          await identities.upsert(identity);
          await identities.upsert(unused);
          await hosts.upsert(host);

          expect(await identities.isReferenced(identity.id), isTrue);
          await expectLater(
            identities.remove(identity.id),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                '凭证正在被网关或服务使用，请先修改对应的凭证配置',
              ),
            ),
          );
          expect(await identities.getAll(), hasLength(2));
          expect((await hosts.getAll()).single.identityId, identity.id);

          expect(await identities.isReferenced(unused.id), isFalse);
          await identities.remove(unused.id);
          expect((await identities.getAll()).single.secretRef, 'sec-shared');

          await hosts.upsert(host.copyWith(identityId: null));
          expect(await identities.isReferenced(identity.id), isFalse);
          await identities.remove(identity.id);
          expect(await identities.getAll(), isEmpty);
          expect((await hosts.getAll()).single.identityId, isNull);
        },
      );
    }
  }
}
