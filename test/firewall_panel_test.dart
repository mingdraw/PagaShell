import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/app.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/ssh/firewall.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/presentation/terminal/firewall_panel.dart';

import 'support/fake_sftp_session.dart';
import 'support/in_memory_binding.dart';
import 'support/shadcn_test_app.dart';

class _FakeFirewallSource implements FirewallSource {
  _FakeFirewallSource(this.snapshot);

  FirewallSnapshot snapshot;
  final added = <(FirewallBackend, List<FirewallRuleInput>)>[];
  final deleted = <FirewallRule>[];
  final serviceActions = <(FirewallBackend, FirewallServiceAction)>[];
  final requestedBackends = <FirewallBackend?>[];

  @override
  Future<FirewallSnapshot> readFirewall({FirewallBackend? backend}) async {
    requestedBackends.add(backend);
    if (backend != null && backend != snapshot.backend) {
      snapshot = FirewallSnapshot(
        backend: backend,
        availableBackends: snapshot.availableBackends,
        state: snapshot.state,
        version: snapshot.version,
        rules: snapshot.rules,
      );
    }
    return snapshot;
  }

  @override
  Future<void> addFirewallRules(
    FirewallBackend backend,
    List<FirewallRuleInput> rules,
  ) async {
    added.add((backend, rules));
    snapshot = FirewallSnapshot(
      backend: snapshot.backend,
      availableBackends: snapshot.availableBackends,
      state: snapshot.state,
      version: snapshot.version,
      zone: snapshot.zone,
      policy: snapshot.policy,
      serviceActions: snapshot.serviceActions,
      rules: [
        ...snapshot.rules,
        for (var i = 0; i < rules.length; i++)
          FirewallRule(
            id: 'added-$i-${rules[i].port}',
            backend: backend,
            action: rules[i].action,
            protocol: rules[i].protocol,
            port: rules[i].port,
            source: rules[i].source.isEmpty
                ? '0.0.0.0/0, ::/0'
                : rules[i].source,
            family: FirewallAddressFamily.any,
            priority: rules[i].priority,
            comment: rules[i].comment,
            rawRule: 'port:${rules[i].port}/tcp',
          ),
      ],
    );
  }

  @override
  Future<void> deleteFirewallRule(FirewallRule rule) async {
    deleted.add(rule);
    snapshot = FirewallSnapshot(
      backend: snapshot.backend,
      availableBackends: snapshot.availableBackends,
      state: snapshot.state,
      version: snapshot.version,
      zone: snapshot.zone,
      policy: snapshot.policy,
      serviceActions: snapshot.serviceActions,
      rules: snapshot.rules.where((item) => item.id != rule.id).toList(),
    );
  }

  @override
  Future<void> runFirewallServiceAction(
    FirewallBackend backend,
    FirewallServiceAction action,
  ) async {
    serviceActions.add((backend, action));
    if (action == FirewallServiceAction.disable) {
      snapshot = FirewallSnapshot(
        backend: backend,
        availableBackends: snapshot.availableBackends,
        state: FirewallServiceState.inactive,
        version: snapshot.version,
        serviceActions: const {FirewallServiceAction.enable},
      );
    } else if (action == FirewallServiceAction.enable) {
      snapshot = FirewallSnapshot(
        backend: backend,
        availableBackends: snapshot.availableBackends,
        state: FirewallServiceState.active,
        version: snapshot.version,
        serviceActions: const {
          FirewallServiceAction.disable,
          FirewallServiceAction.reload,
        },
        rules: snapshot.rules,
      );
    }
  }
}

FirewallSnapshot _sampleFirewalldSnapshot() => const FirewallSnapshot(
  backend: FirewallBackend.firewalld,
  availableBackends: [FirewallBackend.firewalld, FirewallBackend.nftables],
  state: FirewallServiceState.active,
  version: '2.4.3',
  zone: 'public',
  serviceActions: {FirewallServiceAction.disable, FirewallServiceAction.reload},
  rules: [
    FirewallRule(
      id: 'ssh-rule',
      backend: FirewallBackend.firewalld,
      action: FirewallAction.allow,
      protocol: FirewallProtocol.tcp,
      port: '22',
      source: '0.0.0.0/0, ::/0',
      family: FirewallAddressFamily.any,
      zone: 'public',
      rawRule: 'port:22/tcp',
      usedProcesses: [FirewallUsedProcess(port: 22, name: 'sshd', pid: 42)],
    ),
    FirewallRule(
      id: 'udp-deny',
      backend: FirewallBackend.firewalld,
      action: FirewallAction.deny,
      protocol: FirewallProtocol.udp,
      port: '3478',
      source: '10.0.0.0/8',
      family: FirewallAddressFamily.ipv4,
      priority: 10,
      zone: 'public',
      rawRule: 'rich:rule priority="10" family="ipv4" source address="10.0.0.0/8" port port="3478" protocol="udp" drop',
    ),
  ],
);

class _OsSession extends FakeSftpSession implements FirewallSource {
  _OsSession(this.system, this.firewall);

  final String system;
  final _FakeFirewallSource firewall;

  @override
  Future<FirewallSnapshot> readFirewall({FirewallBackend? backend}) async {
    if (system != 'Linux') {
      throw const SshEngineException(firewallUnsupportedSystemMessage);
    }
    return firewall.readFirewall(backend: backend);
  }

  @override
  Future<void> addFirewallRules(
    FirewallBackend backend,
    List<FirewallRuleInput> rules,
  ) => firewall.addFirewallRules(backend, rules);

  @override
  Future<void> deleteFirewallRule(FirewallRule rule) =>
      firewall.deleteFirewallRule(rule);

  @override
  Future<void> runFirewallServiceAction(
    FirewallBackend backend,
    FirewallServiceAction action,
  ) => firewall.runFirewallServiceAction(backend, action);
}

class _OsEngine implements SshEngine {
  _OsEngine(this.systemsByHostId);

  final Map<String, String> systemsByHostId;
  final firewall = _FakeFirewallSource(_sampleFirewalldSnapshot());

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) async => _OsSession(systemsByHostId[host.id] ?? 'Linux', firewall);
}

void main() {
  tearDown(() {
    Get.reset();
    Get.locale = null;
    Get.fallbackLocale = null;
    Get.clearTranslations();
  });

  testWidgets('防火墙面板展示规则、筛选搜索、批量创建、删除及 SSH 警告，不提供编辑', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final source = _FakeFirewallSource(_sampleFirewalldSnapshot());
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Center(
          child: SizedBox(
            width: 340,
            height: 680,
            child: FirewallPanel(source: source, active: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('firewall-backend-name')), findsOneWidget);
    expect(find.text('firewalld'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.text('v2.4.3'), findsOneWidget);
    expect(find.text('sshd (22)'), findsOneWidget);
    expect(find.text('2 / 2 条规则'), findsOneWidget);
    final disableCenter = tester.getCenter(
      find.byKey(const ValueKey('firewall-service-disable')),
    );
    final reloadCenter = tester.getCenter(
      find.byKey(const ValueKey('firewall-service-reload')),
    );
    final backendRect = tester.getRect(
      find.byKey(const ValueKey('firewall-backend-name')),
    );
    expect(disableCenter.dy, closeTo(reloadCenter.dy, 1));
    expect(disableCenter.dx, greaterThan(backendRect.right));

    // Filter by deny -> only 3478 visible.
    await tester.tap(find.byKey(const ValueKey('firewall-filter-action-deny')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2 条规则'), findsOneWidget);
    expect(find.text('3478'), findsOneWidget);
    expect(find.text('22'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('firewall-filter-action-all')));
    await tester.pumpAndSettle();

    // Create multiple rules (comma ports + IP + priority).
    await tester.tap(find.byKey(const ValueKey('firewall-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-ip-0')),
      '172.16.0.0/24',
    );
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-port-0')),
      '80,443',
    );
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-priority')),
      '-5',
    );
    await tester.tap(find.byKey(const ValueKey('firewall-rule-submit')));
    await tester.pumpAndSettle();

    expect(source.added, hasLength(1));
    expect(source.added.single.$1, FirewallBackend.firewalld);
    expect(source.added.single.$2.map((r) => r.port).toList(), ['80', '443']);
    expect(source.added.single.$2.first.source, '172.16.0.0/24');
    expect(source.added.single.$2.first.priority, -5);
    expect(find.text('4 / 4 条规则'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('firewall-rule-edit-udp-deny')),
      findsNothing,
    );

    // Delete SSH rule shows SSH risk warning.
    await tester.tap(
      find.byKey(const ValueKey('firewall-rule-delete-ssh-rule')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('firewall-delete-ssh-warning')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('firewall-confirm-delete')));
    await tester.pumpAndSettle();
    expect(source.deleted.map((r) => r.id), ['ssh-rule']);

    // Disable firewall service via confirmation dialog.
    await tester.tap(find.byKey(const ValueKey('firewall-service-disable')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('firewall-confirm-service-disable')),
    );
    await tester.pumpAndSettle();
    expect(source.serviceActions, [
      (FirewallBackend.firewalld, FirewallServiceAction.disable),
    ]);
    expect(find.text('未启用'), findsOneWidget);
  });

  testWidgets('Linux 与 macOS 终端均显示防火墙图标，macOS 打开提示不支持的防火墙', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const linuxHost = Host(
      id: 'linux-host',
      name: 'Linux 主机',
      hostname: 'linux.test',
      username: 'root',
    );
    const macHost = Host(
      id: 'mac-host',
      name: 'Mac 主机',
      hostname: 'mac.test',
      username: 'dev',
    );
    const creds = SshCredentials.password('secret');
    final engine = _OsEngine({'linux-host': 'Linux', 'mac-host': 'Darwin'});
    final binding = InMemoryBinding(sshEngine: engine);

    await tester.pumpWidget(PagaShellApp(binding: binding));
    await tester.pumpAndSettle();
    final sessions = Get.find<SessionController>();

    // Open macOS session -> firewall toolbar button is visible and shows unsupported message.
    final macId = await sessions.open(macHost, creds);
    await tester.pumpAndSettle();
    final fwButton = find.byKey(const ValueKey('terminal-toolbar-firewall'));
    expect(fwButton, findsOneWidget);
    await tester.tap(fwButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('firewall-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('firewall-unsupported')), findsOneWidget);
    expect(find.text('不支持当前系统的防火墙'), findsOneWidget);

    // Open Linux session -> firewall panel displays rules.
    await sessions.open(linuxHost, creds);
    await tester.pumpAndSettle();
    expect(fwButton, findsOneWidget);
    await tester.tap(fwButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('firewall-panel')), findsOneWidget);
    expect(find.text('firewalld'), findsOneWidget);

    await tester.runAsync(() async {
      await sessions.close(macId);
      await sessions.closeAll();
    });
    await tester.pumpAndSettle();
  });

  testWidgets('多后端未锁定状态支持切换后端，非 firewalld 显示描述字段并校验输入', (tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final source = _FakeFirewallSource(
      const FirewallSnapshot(
        backend: FirewallBackend.nftables,
        availableBackends: [FirewallBackend.nftables, FirewallBackend.iptables],
        state: FirewallServiceState.active,
        version: '1.0.9',
        policy: 'DROP',
        rules: [
          FirewallRule(
            id: 'nft-1',
            backend: FirewallBackend.nftables,
            action: FirewallAction.allow,
            protocol: FirewallProtocol.tcp,
            port: '80',
            source: '0.0.0.0/0, ::/0',
            family: FirewallAddressFamily.any,
            comment: 'web http',
            chain: 'inet/filter/input',
            rawRule: 'nft:inet|filter|input|6',
          ),
        ],
      ),
    );

    // Mount at minimum side panel width (220px) to verify zero overflow.
    await tester.pumpWidget(
      ShadcnTestApp(
        home: Center(
          child: SizedBox(
            width: 220,
            height: 600,
            child: FirewallPanel(source: source, active: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('nftables'), findsOneWidget);
    expect(find.text('web http'), findsOneWidget);
    expect(find.text('默认 DROP'), findsOneWidget);

    // Switch backend from nftables -> iptables.
    await tester.tap(find.byKey(const ValueKey('firewall-backend-switcher')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('iptables').last);
    await tester.pumpAndSettle();
    expect(source.requestedBackends, contains(FirewallBackend.iptables));
    expect(find.text('iptables'), findsOneWidget);

    // Open create dialog: iptables shows comment field and hides priority field.
    await tester.tap(find.byKey(const ValueKey('firewall-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('firewall-rule-priority')), findsNothing);
    expect(find.byKey(const ValueKey('firewall-rule-comment')), findsOneWidget);

    // Invalid port and IP are rejected by form validation.
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-ip-0')),
      '999.0.0.1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-port-0')),
      '70000',
    );
    await tester.tap(find.byKey(const ValueKey('firewall-rule-submit')));
    await tester.pumpAndSettle();
    expect(source.added, isEmpty);
    expect(find.text('IP 或网段格式无效，请检查后重试'), findsOneWidget);

    // Fix inputs + add second port row + comment.
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-ip-0')),
      '10.0.0.0/24',
    );
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-port-0')),
      '8080-8089',
    );
    await tester.tap(find.byKey(const ValueKey('firewall-rule-port-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-port-1')),
      '9000',
    );
    await tester.enterText(
      find.byKey(const ValueKey('firewall-rule-comment')),
      'app cluster',
    );
    await tester.tap(find.byKey(const ValueKey('firewall-rule-submit')));
    await tester.pumpAndSettle();

    expect(source.added, hasLength(1));
    expect(source.added.single.$1, FirewallBackend.iptables);
    expect(source.added.single.$2.map((r) => r.port).toList(), [
      '8080-8089',
      '9000',
    ]);
    expect(source.added.single.$2.first.comment, 'app cluster');
    expect(tester.takeException(), isNull);
  });
}
