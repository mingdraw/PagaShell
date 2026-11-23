import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ai/command_classifier.dart';

void main() {
  test('only literal, allowlisted diagnostics are automatic', () {
    for (final command in [
      'uname -a',
      'df -h',
      'ss -lntp',
      'sudo -n sysctl -n fs.file-max',
      'systemctl show mysql.service -pLimitNOFILE',
      'cat /proc/901/limits | grep -i "open files"',
      "mysql -e 'SHOW GLOBAL STATUS'",
      'redis-cli INFO memory',
    ]) {
      expect(
        classifyShellCommand(command),
        AgentCommandRisk.readOnly,
        reason: command,
      );
    }
    for (final command in [
      'systemctl show mysql.service',
      'sysctl -w vm.swappiness=0',
      'cat /etc/shadow',
      'cat /proc/self/environ',
      'uname -a > system.txt',
      'uname -a && touch system.txt',
      'uname -a\nls',
      r'uname $(date)',
      'df -h | sort -o result.txt',
      'ps -ef',
      'docker inspect app',
      "mysql -e 'SELECT * FROM users'",
      'redis-cli CONFIG GET "*"',
      'sudo --stdin uname -a',
      'sudo uname -a',
    ]) {
      expect(
        classifyShellCommand(command),
        isNot(AgentCommandRisk.readOnly),
        reason: command,
      );
    }
  });

  test(
    'destructive commands and config validators are separately recognized',
    () {
      for (final command in [
        'sudo -n rm -rf /tmp/folder',
        'shutdown -r now',
        'systemctl stop sshd',
        'redis-cli FLUSHALL',
      ]) {
        expect(
          classifyShellCommand(command),
          AgentCommandRisk.highRisk,
          reason: command,
        );
      }
      expect(isAgentValidationCommand('sudo -n nginx -t'), isTrue);
      expect(isAgentValidationCommand('mysqld --validate-config'), isTrue);
      expect(isAgentValidationCommand('nginx -t | head'), isFalse);
      expect(isAgentValidationCommand('nginx -T'), isFalse);
      expect(
        isAgentValidationCommand('nginx -t && systemctl restart nginx'),
        isFalse,
      );
    },
  );
}
