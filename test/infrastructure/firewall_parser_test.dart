import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/firewall.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/infrastructure/ssh/firewall_parser.dart';

void main() {
  test('解析 firewalld 端口规则、富规则、优先级及已使用监听进程', () {
    const raw = '''
PAGA_FIREWALL_V1
BACKEND firewalld
STATE active
VERSION 2.4.3
ZONE public
POLICY 
SERVICE_ACTIONS disable,reload
---RULES---
FIREWALLD_PORTS
10458/tcp 8080-8089/udp
FIREWALLD_RICH_RULES
rule family="ipv4" port port="443" protocol="tcp" accept
rule priority="-10" family="ipv6" source address="2001:db8::/64" port port="51322" protocol="tcp" accept
rule family="ipv4" source address="10.0.0.5" port port="3306" protocol="tcp" drop
rule family="ipv4" source address="192.168.1.0/24" icmp-block name="echo-request"
---LISTENERS---
SS4
tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("openresty",pid=101,fd=5))
tcp LISTEN 0 128 0.0.0.0:51322 0.0.0.0:* users:(("sshd",pid=42,fd=3))
udp UNCONN 0 0 0.0.0.0:8085 0.0.0.0:* users:(("relay",pid=77,fd=8))
SS6
tcp LISTEN 0 128 [::]:10458 [::]:* users:(("1panel-core",pid=88,fd=6))
END_FIREWALL
''';
    final snapshot = parseFirewallSnapshot(raw);
    expect(snapshot.backend, FirewallBackend.firewalld);
    expect(snapshot.isActive, isTrue);
    expect(snapshot.version, '2.4.3');
    expect(snapshot.zone, 'public');
    expect(snapshot.serviceActions, {
      FirewallServiceAction.disable,
      FirewallServiceAction.reload,
    });
    expect(snapshot.rules, hasLength(5));

    final portRule = snapshot.rules[0];
    expect(portRule.port, '10458');
    expect(portRule.protocol, FirewallProtocol.tcp);
    expect(portRule.priority, isNull);
    expect(portRule.source, '0.0.0.0/0, ::/0');
    expect(portRule.rawRule, 'port:10458/tcp');
    expect(portRule.usedProcesses.map((p) => p.label), ['1panel-core (10458)']);

    final rangeRule = snapshot.rules[1];
    expect(rangeRule.port, '8080-8089');
    expect(rangeRule.protocol, FirewallProtocol.udp);
    expect(rangeRule.usedProcesses.map((p) => p.label), ['relay (8085)']);

    final richDefault = snapshot.rules[2];
    expect(richDefault.port, '443');
    expect(richDefault.priority, 0);
    expect(richDefault.source, '0.0.0.0/0');
    expect(richDefault.usedProcesses.map((p) => p.label), ['openresty (443)']);

    final richV6 = snapshot.rules[3];
    expect(richV6.priority, -10);
    expect(richV6.family, FirewallAddressFamily.ipv6);
    expect(richV6.source, '2001:db8::/64');
    expect(richV6.coversSsh, isTrue);

    final richDrop = snapshot.rules[4];
    expect(richDrop.action, FirewallAction.deny);
    expect(richDrop.source, '10.0.0.5');
    expect(richDrop.port, '3306');
  });

  test('解析 ufw 编号规则、端口段、IPv6、注释并跳过出站与应用名规则', () {
    const raw = '''
PAGA_FIREWALL_V1
BACKEND ufw
AVAILABLE ufw,iptables
STATE active
VERSION 0.36.2
ZONE 
POLICY 
SERVICE_ACTIONS disable,reload
---RULES---
UFW_STATUS
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere                   # SSH access
[ 2] 8080:8089/udp              DENY IN     192.168.1.0/24             # block test
[ 3] 443                        ALLOW IN    Anywhere (v6)
[ 4] 53/udp                     ALLOW OUT   Anywhere
[ 5] OpenSSH                    ALLOW IN    Anywhere
[ 6] 80,443/tcp on eth0         ALLOW IN    Anywhere
---LISTENERS---
END_FIREWALL
''';
    final snapshot = parseFirewallSnapshot(raw);
    expect(snapshot.backend, FirewallBackend.ufw);
    expect(snapshot.rules, hasLength(4));

    expect(snapshot.rules[0].port, '22');
    expect(snapshot.rules[0].protocol, FirewallProtocol.tcp);
    expect(snapshot.rules[0].comment, 'SSH access');
    expect(
      snapshot.rules[0].rawRule,
      'ufw:1:22/tcp                     ALLOW IN    Anywhere                   # SSH access',
    );

    expect(snapshot.rules[1].port, '8080-8089');
    expect(snapshot.rules[1].action, FirewallAction.deny);
    expect(snapshot.rules[1].source, '192.168.1.0/24');
    expect(snapshot.rules[1].comment, 'block test');

    expect(snapshot.rules[2].port, '443');
    expect(snapshot.rules[2].protocol, FirewallProtocol.tcpUdp);
    expect(snapshot.rules[2].family, FirewallAddressFamily.ipv6);
    expect(snapshot.rules[2].source, '::/0');

    expect(snapshot.rules[3].port, '80,443');
  });

  test('解析 nftables input 过滤链、端口集合、双协议、句柄与默认策略', () {
    const raw = '''
PAGA_FIREWALL_V1
BACKEND nftables
AVAILABLE nftables,iptables
STATE active
VERSION 1.0.9
ZONE 
POLICY 
SERVICE_ACTIONS disable,reload
---RULES---
NFT_RULESET
table inet filter { # handle 1
	chain input { # handle 1
		type filter hook input priority filter; policy drop;
		ct state established,related accept # handle 4
		tcp dport 22 accept # handle 5
		tcp dport { 80, 443 } accept comment "web ports" # handle 6
		ip saddr 10.0.0.0/8 udp dport 8080-8089 drop comment "block udp" # handle 7
		meta l4proto { tcp, udp } th dport 53 accept # handle 8
	}
	chain output { # handle 2
		type filter hook output priority filter; policy accept;
		tcp dport 443 accept # handle 10
	}
}
---LISTENERS---
END_FIREWALL
''';
    final snapshot = parseFirewallSnapshot(raw);
    expect(snapshot.backend, FirewallBackend.nftables);
    expect(snapshot.policy, 'DROP');
    expect(snapshot.rules, hasLength(4));

    expect(snapshot.rules[0].port, '22');
    expect(snapshot.rules[0].source, '0.0.0.0/0, ::/0');
    expect(snapshot.rules[0].rawRule, 'nft:inet|filter|input|5');

    expect(snapshot.rules[1].port, '80,443');
    expect(snapshot.rules[1].comment, 'web ports');

    expect(snapshot.rules[2].action, FirewallAction.deny);
    expect(snapshot.rules[2].source, '10.0.0.0/8');
    expect(snapshot.rules[2].port, '8080-8089');
    expect(snapshot.rules[2].comment, 'block udp');

    expect(snapshot.rules[3].protocol, FirewallProtocol.tcpUdp);
    expect(snapshot.rules[3].port, '53');
  });

  test('解析 iptables 与 ip6tables INPUT 规则、多端口和带空格注释', () {
    const raw = '''
PAGA_FIREWALL_V1
BACKEND iptables
AVAILABLE iptables
STATE active
VERSION 1.8.9 (nf_tables)
ZONE 
POLICY DROP
SERVICE_ACTIONS none
---RULES---
IPTABLES_V4
-P INPUT DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -s 192.168.1.10/32 -p tcp -m tcp --dport 8080:8089 -m comment --comment "web app" -j ACCEPT
-A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
-A INPUT -j DOCKER-USER
IPTABLES_V6
-P INPUT ACCEPT
-A INPUT -s 2001:db8::1/128 -p udp -m udp --dport 51820 -j DROP
---LISTENERS---
END_FIREWALL
''';
    final snapshot = parseFirewallSnapshot(raw);
    expect(snapshot.backend, FirewallBackend.iptables);
    expect(snapshot.policy, 'DROP');
    expect(snapshot.rules, hasLength(4));

    expect(snapshot.rules[0].port, '22');
    expect(
      snapshot.rules[0].rawRule,
      'iptables:v4:2:-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT',
    );

    expect(snapshot.rules[1].source, '192.168.1.10');
    expect(snapshot.rules[1].port, '8080-8089');
    expect(snapshot.rules[1].comment, 'web app');

    expect(snapshot.rules[2].port, '80,443');

    expect(snapshot.rules[3].family, FirewallAddressFamily.ipv6);
    expect(snapshot.rules[3].source, '2001:db8::1');
    expect(snapshot.rules[3].action, FirewallAction.deny);
    expect(
      snapshot.rules[3].rawRule,
      'iptables:v6:1:-A INPUT -s 2001:db8::1/128 -p udp -m udp --dport 51820 -j DROP',
    );
  });

  test('格式损坏的防火墙快照抛出 SshEngineException', () {
    expect(
      () => parseFirewallSnapshot('BAD_HEADER\nEND_FIREWALL'),
      throwsA(isA<SshEngineException>()),
    );
  });

  test('FirewallRuleInput 校验端口、IP/CIDR、优先级和描述', () {
    expect(FirewallRuleInput.parsePortSpecs('80,443,8080-8089'), [
      '80',
      '443',
      '8080-8089',
    ]);
    expect(FirewallRuleInput.parsePortSpecs('0'), isNull);
    expect(FirewallRuleInput.parsePortSpecs('8089-8080'), isNull);
    expect(FirewallRuleInput.parsePortSpecs('70000'), isNull);

    expect(FirewallRuleInput.normalizeSource(''), '');
    expect(FirewallRuleInput.normalizeSource('172.16.10.11'), '172.16.10.11');
    expect(FirewallRuleInput.normalizeSource('172.16.0.0/24'), '172.16.0.0/24');
    expect(FirewallRuleInput.normalizeSource('2001:db8::/64'), '2001:db8::/64');
    expect(FirewallRuleInput.normalizeSource('172.16.0.0/33'), isNull);
    expect(FirewallRuleInput.normalizeSource('2001:db8::/129'), isNull);
    expect(FirewallRuleInput.normalizeSource('invalid'), isNull);

    expect(FirewallRuleInput.isValidPriority(''), isTrue);
    expect(FirewallRuleInput.isValidPriority('-32768'), isTrue);
    expect(FirewallRuleInput.isValidPriority('32767'), isTrue);
    expect(FirewallRuleInput.isValidPriority('32768'), isFalse);

    expect(FirewallRuleInput.validateComment('放行 Web 服务'), isNull);
    expect(FirewallRuleInput.validateComment('bad"quote'), isNotNull);
    expect(FirewallRuleInput.validateComment('a' * 129), isNotNull);
  });
}
