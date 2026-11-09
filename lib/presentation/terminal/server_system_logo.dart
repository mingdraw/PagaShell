import 'package:colorful_iconify_flutter/icons/logos.dart';
import 'package:flutter/widgets.dart';
import 'package:iconify_flutter/iconify_flutter.dart';

/// 根据远端系统选择 SVG Logos 的独立图形，保持原色和正方形占位。
class ServerSystemLogo extends StatelessWidget {
  const ServerSystemLogo({
    required this.system,
    this.systemRelease,
    this.size = 15,
    super.key,
  });

  final String system;
  final String? systemRelease;
  final double size;

  String get _svg {
    final kernel = system.trim().toLowerCase();
    if (kernel == 'darwin' || kernel == 'macos') return Logos.macosx;
    if (kernel == 'freebsd') return Logos.freebsd;
    if (kernel == 'windows' || kernel == 'windows_nt') {
      return Logos.microsoft_windows;
    }
    final release = systemRelease?.trim();
    final label = (release == null || release.isEmpty ? system : release)
        .trim()
        .toLowerCase();
    bool matches(String name) => label == name || label.startsWith('$name ');

    if (matches('rocky')) return Logos.rocky_linux_icon;
    if (matches('ubuntu')) return Logos.ubuntu;
    if (matches('debian')) return Logos.debian;
    if (matches('fedora')) return Logos.fedora;
    if (matches('centos')) return Logos.centos_icon;
    if (matches('red hat') || matches('rhel')) return Logos.redhat_icon;
    if (matches('arch') || matches('archlinux')) return Logos.archlinux;
    if (matches('linux mint')) return Logos.linux_mint;
    if (matches('manjaro')) return Logos.manjaro;
    if (matches('freebsd')) return Logos.freebsd;
    if (matches('windows') ||
        matches('microsoft windows') ||
        matches('windows_nt')) {
      return Logos.microsoft_windows;
    }
    if (matches('macos') || matches('mac os x') || matches('os x')) {
      return Logos.macosx;
    }
    return Logos.linux_tux;
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: Iconify(_svg, size: size),
    ),
  );
}
