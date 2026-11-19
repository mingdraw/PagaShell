import 'dart:io';

typedef SshEndpoint = ({String hostname, String? username, int? port});

/// Extracts a destination from a plain address or a simple SSH invocation.
/// Deliberately rejects command options that the service form cannot represent.
SshEndpoint? parseSshEndpoint(String input) {
  var destination = input.trim();
  int? commandPort;
  var explicit = false;
  if (RegExp(r'^ssh\s').hasMatch(destination)) {
    final args = destination.split(RegExp(r'\s+'));
    var index = 1;
    if (args[index].startsWith('-p')) {
      final option = args[index++];
      if (option == '-p' && index >= args.length) return null;
      commandPort = int.tryParse(
        option == '-p' ? args[index++] : option.substring(2),
      );
      if (commandPort == null || commandPort < 1 || commandPort > 65535) {
        return null;
      }
    }
    if (args.length != index + 1) return null;
    destination = args[index];
    explicit = true;
  }
  final match = RegExp(
    r'^(?:([\w.][\w.\\-]*)@)?(\[[^\[\]]+\]|[\w.:][\w.:%-]*)(?::(\d+))?$',
  ).firstMatch(destination);
  if (match == null) return null;
  final username = match[1];
  var hostname = match[2]!;
  var port = match[3] == null ? null : int.tryParse(match[3]!);
  if (hostname.startsWith('[')) {
    hostname = hostname.substring(1, hostname.length - 1);
    if (!hostname.contains(':') ||
        InternetAddress.tryParse(hostname.split('%').first)?.type !=
            InternetAddressType.IPv6) {
      return null;
    }
    explicit = true;
  } else if (hostname.contains(':')) {
    if (':'.allMatches(hostname).length == 1) {
      final parts = hostname.split(':');
      hostname = parts.first;
      port = int.tryParse(parts.last);
      if (hostname.isEmpty || port == null) return null;
    } else if (InternetAddress.tryParse(hostname.split('%').first)?.type !=
        InternetAddressType.IPv6) {
      return null;
    }
  }
  if (port != null && (port < 1 || port > 65535 || commandPort != null)) {
    return null;
  }
  if (!explicit && username == null && port == null) return null;
  return (hostname: hostname, username: username, port: port ?? commandPort);
}
