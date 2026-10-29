import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/presentation/ssh/host_key_confirmation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

const _key = SshHostKey(
  hostname: 'example.com',
  port: 2222,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:new',
);

void main() {
  testWidgets('首次确认显示地址和指纹，可明确接受或取消', (tester) async {
    bool? accepted;
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: HostKeyConfirmation(
            review: const HostKeyReview(presented: _key),
            onDecision: (value) => accepted = value,
          ),
        ),
      ),
    );
    expect(find.text('example.com:2222 · ssh-ed25519'), findsOneWidget);
    expect(find.text('SHA256:new'), findsOneWidget);
    await tester.tap(find.text('信任并连接'));
    expect(accepted, isTrue);
    await tester.tap(find.text('取消连接'));
    expect(accepted, isFalse);
  });

  testWidgets('密钥变化显示旧新指纹，仅提供拒绝按钮', (tester) async {
    bool? accepted;
    await tester.pumpWidget(
      ShadcnTestApp(
        home: shadcn.Scaffold(
          child: HostKeyConfirmation(
            review: const HostKeyReview(
              presented: _key,
              trusted: SshHostKey(
                hostname: 'example.com',
                port: 2222,
                keyType: 'ssh-ed25519',
                fingerprint: 'SHA256:old',
              ),
            ),
            onDecision: (value) => accepted = value,
          ),
        ),
      ),
    );
    expect(find.text('SHA256:old'), findsOneWidget);
    expect(find.text('SHA256:new'), findsOneWidget);
    expect(find.text('信任并连接'), findsNothing);
    await tester.tap(find.text('拒绝连接'));
    expect(accepted, isFalse);
  });
}
