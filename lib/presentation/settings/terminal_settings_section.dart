import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/settings/settings_controller.dart';
import '../components/app_select_field.dart';
import '../navigation/app_notice.dart';

class TerminalSettingsSection extends StatelessWidget {
  const TerminalSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();
    final muted = shadcn.Theme.of(context).colorScheme.mutedForeground;
    final closeLabel = '断开后自动关闭窗格'.tr;
    return Obx(() {
      final fontSize = settings.terminalFontSize.value.round();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSelectField<int>(
            key: ValueKey('terminal-font-size-$fontSize'),
            label: '终端字号'.tr,
            initialValue: fontSize,
            items: [
              for (final size in [10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24])
                AppSelectOption(value: size, child: Text('$size px')),
            ],
            onChanged: (value) async {
              if (value == null) return;
              try {
                await settings.setTerminalFontSize(value.toDouble());
              } on Object {
                AppNotice.error('保存失败，请重试');
              }
            },
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      closeLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '开启后关闭断开的 SSH 窗格；最后一个窗格断开时关闭标签。未开启时保留历史输出并提示重连。'.tr,
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Semantics(
                label: closeLabel,
                child: shadcn.Switch(
                  key: const ValueKey('close-terminal-on-disconnect'),
                  value: settings.closeTerminalOnDisconnect.value,
                  onChanged: settings.savingCloseTerminalOnDisconnect.value
                      ? null
                      : (value) async {
                          try {
                            await settings.setCloseTerminalOnDisconnect(value);
                          } on Object {
                            AppNotice.error('保存失败，请重试');
                          }
                        },
                ),
              ),
            ],
          ),
        ],
      );
    });
  }
}
