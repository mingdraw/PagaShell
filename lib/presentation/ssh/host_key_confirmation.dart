import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/host_key.dart';
import '../components/app_copy_button.dart';
import '../components/app_icon.dart';
import '../theme/app_theme.dart';

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
                AppIcon(
                  changed ? AppIcons.triangleAlert : AppIcons.shieldCheck,
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
                _codeBox(
                  context,
                  '${key.hostname}:${key.port} · ${key.keyType}',
                  copyLabel: '复制主机信息'.tr,
                  copyKey: const ValueKey('host-key-copy-host'),
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
                  const SizedBox(height: 6),
                  _codeBox(
                    context,
                    review.trusted!.fingerprint,
                    copyLabel: '复制已保存指纹'.tr,
                    copyKey: const ValueKey('host-key-copy-trusted'),
                  ),
                ],
                const SizedBox(height: 16),
                Text(changed ? '本次服务器指纹'.tr : '服务器指纹'.tr),
                const SizedBox(height: 6),
                _codeBox(
                  context,
                  key.fingerprint,
                  copyLabel: '复制服务器指纹'.tr,
                  copyKey: const ValueKey('host-key-copy-fingerprint'),
                ),
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

  Widget _codeBox(
    BuildContext context,
    String text, {
    required String copyLabel,
    Key? copyKey,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: AppTheme.surface(context),
      border: Border.all(color: AppTheme.border(context)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      children: [
        Expanded(
          child: shadcn.SelectableText(
            text,
            style: const TextStyle(
              fontFamily: 'FiraCode Nerd Font Mono',
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 8),
        AppCopyButton(
          key: copyKey,
          text: text,
          size: 12,
          semanticLabel: copyLabel,
        ),
      ],
    ),
  );
}
