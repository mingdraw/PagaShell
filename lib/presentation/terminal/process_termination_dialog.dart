import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/process_manager.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';

class ProcessTerminationDialog extends StatefulWidget {
  const ProcessTerminationDialog({
    required this.process,
    required this.name,
    super.key,
  });

  final RemoteProcess process;
  final String name;

  @override
  State<ProcessTerminationDialog> createState() =>
      _ProcessTerminationDialogState();
}

class _ProcessTerminationDialogState extends State<ProcessTerminationDialog> {
  final _confirmation = TextEditingController();

  void _confirm() {
    if (_confirmation.text == widget.name) {
      AppNavigation.closeDialog(result: true);
    }
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final danger = shadcn.Theme.of(context).colorScheme.destructive;
    return AppDialog(
      title: Row(
        children: [
          AppIcon(AppIcons.triangleAlert, size: 20, color: danger),
          const SizedBox(width: 8),
          Expanded(child: Text('高危操作：结束进程'.tr)),
        ],
      ),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text('PID ${widget.process.pid} · ${widget.process.user}'),
          const SizedBox(height: 16),
          Text('结束进程可能中断服务并导致未保存的数据丢失。'.tr, style: TextStyle(color: danger)),
          const SizedBox(height: 16),
          Text(
            '请输入进程名称「@name」以确认，必须完全一致（区分大小写）。'.trParams({'name': widget.name}),
          ),
          const SizedBox(height: 8),
          AppTextFormField(
            key: const ValueKey('process-terminate-name'),
            controller: _confirmation,
            autofocus: true,
            enableSuggestions: false,
            autocorrect: false,
            smartPunctuation: false,
            decoration: AppInputDecoration(hintText: '输入进程名称'.tr),
            onFieldSubmitted: (_) => _confirm(),
          ),
        ],
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog(result: false),
          child: Text('取消'.tr),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _confirmation,
          builder: (_, value, _) => shadcn.DestructiveButton(
            key: const ValueKey('process-confirm-terminate'),
            onPressed: value.text == widget.name ? _confirm : null,
            child: Text('结束进程'.tr),
          ),
        ),
      ],
    );
  }
}
