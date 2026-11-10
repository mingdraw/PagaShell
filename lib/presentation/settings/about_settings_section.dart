import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:url_launcher/url_launcher.dart';

import '../../application/updates/app_update_controller.dart';
import '../../core/app_info.dart';
import '../components/app_icon.dart';
import '../navigation/app_notice.dart';
import '../theme/app_theme.dart';
import 'app_update_section.dart';

class AboutSettingsSection extends StatelessWidget {
  const AboutSettingsSection({super.key});

  Future<void> _openRepository() async {
    try {
      if (await launchUrl(
        Uri.parse(AppInfo.repository),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on Object {
      // 地址仍可在页面中选中复制。
    }
    AppNotice.error('无法打开项目主页，请复制地址后在浏览器中打开');
  }

  @override
  Widget build(BuildContext context) {
    final muted = shadcn.Theme.of(context).colorScheme.mutedForeground;
    return Column(
      key: const ValueKey('about-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppTheme.surface(context),
                border: Border.all(color: AppTheme.border(context)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const AppIcon(AppIcons.terminal, size: 26),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    AppInfo.name,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '本地优先的远程服务管理工具'.tr,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          '管理 SSH、SFTP、RDP 和 VNC 连接，集中维护服务、凭证与网关。'.tr,
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        const SizedBox(height: 8),
        Text(
          '配置与凭证保存在本机，可选 AI Agent 协助日常运维。'.tr,
          style: TextStyle(fontSize: 13, height: 1.6, color: muted),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: shadcn.OutlineButton(
            key: const ValueKey('about-github-link'),
            leading: const AppIcon(AppIcons.github, size: 16),
            trailing: const AppIcon(AppIcons.externalLink, size: 14),
            onPressed: _openRepository,
            child: Text('GitHub 项目主页'.tr),
          ),
        ),
        const SizedBox(height: 8),
        shadcn.SelectableText(
          AppInfo.repository,
          style: TextStyle(fontSize: 12, color: muted),
        ),
        if (Get.isRegistered<AppUpdateController>()) ...[
          const SizedBox(height: 24),
          Container(height: 1, color: AppTheme.border(context)),
          const SizedBox(height: 24),
          const AppUpdateSection(),
        ],
      ],
    );
  }
}
