import 'dart:ui' as ui;

import 'package:colorful_iconify_flutter/icons/logos.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:pagashell/presentation/terminal/server_system_logo.dart';

import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  for (final (system, release, svg) in [
    ('Linux', 'Rocky Linux 10.2', Logos.rocky_linux_icon),
    ('Linux', '  ROCKY LINUX 9.5  ', Logos.rocky_linux_icon),
    ('Linux', 'Ubuntu 24.04 LTS', Logos.ubuntu),
    ('Linux', 'Debian GNU/Linux 12', Logos.debian),
    ('Linux', 'Fedora Linux 42', Logos.fedora),
    ('Linux', 'CentOS Stream 10', Logos.centos_icon),
    ('Linux', 'Red Hat Enterprise Linux 9.6', Logos.redhat_icon),
    ('Linux', 'Arch Linux', Logos.archlinux),
    ('Linux', 'Linux Mint 22.1', Logos.linux_mint),
    ('Linux', 'Manjaro Linux', Logos.manjaro),
    ('Darwin', 'macOS 15.0.1', Logos.macosx),
    ('Darwin', null, Logos.macosx),
    ('macOS', 'macOS 15.0.1', Logos.macosx),
    ('Windows_NT', 'Windows Server 2022', Logos.microsoft_windows),
    ('FreeBSD', '14.2-RELEASE', Logos.freebsd),
    ('Linux', 'AlmaLinux 10', Logos.linux_tux),
    ('Linux', 'Alpine Linux 3.22', Logos.linux_tux),
    ('Linux', 'Custom OS based on Ubuntu', Logos.linux_tux),
    ('Linux', null, Logos.linux_tux),
    ('Unknown', '', Logos.linux_tux),
  ]) {
    testWidgets('$system ${release ?? '无版本'} 选择独立系统 Logo', (tester) async {
      await tester.pumpWidget(
        ShadcnTestApp(
          home: Center(
            child: ServerSystemLogo(system: system, systemRelease: release),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final logo = tester.widget<Iconify>(find.byType(Iconify));
      expect(logo.icon, svg);
      expect(logo.color, isNull);
      expect(
        tester.getSize(find.byType(ServerSystemLogo)),
        const Size.square(15),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Rocky Logo 保留绿色，采样更新后切换系统并回退 Tux', (tester) async {
    final boundaryKey = GlobalKey();
    Future<void> showLogo(String release) async {
      await tester.pumpWidget(
        ShadcnTestApp(
          home: Center(
            child: IconTheme(
              data: const IconThemeData(color: Color(0xFFFF00FF)),
              child: RepaintBoundary(
                key: boundaryKey,
                child: ServerSystemLogo(
                  system: 'Linux',
                  systemRelease: release,
                  size: 32,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await showLogo('Rocky Linux 10.2');
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var originalGreenPixels = 0;
        for (var i = 0; i < bytes.lengthInBytes; i += 4) {
          if (bytes.getUint8(i) == 0x10 &&
              bytes.getUint8(i + 1) == 0xB9 &&
              bytes.getUint8(i + 2) == 0x81 &&
              bytes.getUint8(i + 3) == 0xFF) {
            originalGreenPixels++;
          }
        }
        expect(originalGreenPixels, greaterThan(0));
      } finally {
        image.dispose();
      }
    });

    await showLogo('Ubuntu 24.04 LTS');
    expect(tester.widget<Iconify>(find.byType(Iconify)).icon, Logos.ubuntu);
    await showLogo('Unknown Linux 1.0');
    expect(tester.widget<Iconify>(find.byType(Iconify)).icon, Logos.linux_tux);
    expect(tester.takeException(), isNull);
  });
}
