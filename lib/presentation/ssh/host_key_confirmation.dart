import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/host_key.dart';

/// 会话内确认界面，多个待确认连接可通过标签分别处理。
class HostKeyConfirmation extends StatelessWidget {
  const HostKeyConfirmation({
    required this.review,
    required this.onDecision,
    super.key,
  });

  final HostKeyReview review;
  final ValueChanged<bool> onDecision;

  @override
  Widget build(BuildContext context) {
    final key = review.presented;
    if (key.isRdp) {
      return Center(child: Text('请在证书提示框中确认是否继续连接。'.tr));
    }
    final changed = review.hasChanged;
    final colors = shadcn.Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: shadcn.Card(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  changed
                      ? shadcn.LucideIcons.triangleAlert
                      : shadcn.LucideIcons.shieldCheck,
                  color: changed ? colors.destructive : colors.primary,
                  size: 40,
                ),
                const SizedBox(height: 16),
                Text(
                  (key.isRdp
                          ? (changed ? 'RDP 证书已变更，连接已阻止' : '首次连接：确认 RDP 证书')
                          : (changed ? '主机指纹已变更，连接已阻止' : '首次连接：确认主机指纹'))
                      .tr,
                  style: shadcn.Theme.of(context).typography.large
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                shadcn.SelectableText(
                  '${key.hostname}:${key.port} · ${key.keyType}',
                ),
                const SizedBox(height: 12),
                Text(
                  changed
                      ? '服务器密钥与已保存记录不一致，可能存在中间人攻击或服务器重装。请联系管理员，通过可信渠道核验；本次连接不会发送密码。'
                            .tr
                      : '请通过可信渠道与服务器管理员核对下方 SHA-256 指纹。确认后保存可信记录，后续连接自动校验。'.tr,
                ),
                if (changed) ...[
                  const SizedBox(height: 16),
                  Text('已保存指纹'.tr),
                  shadcn.SelectableText(review.trusted!.fingerprint),
                ],
                const SizedBox(height: 16),
                Text(changed ? '本次服务器指纹'.tr : '服务器指纹'.tr),
                shadcn.SelectableText(key.fingerprint),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    shadcn.OutlineButton(
                      onPressed: () => onDecision(false),
                      child: Text(changed ? '拒绝连接'.tr : '取消连接'.tr),
                    ),
                    if (!changed)
                      shadcn.PrimaryButton(
                        onPressed: () => onDecision(true),
                        child: Text('信任并连接'.tr),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
