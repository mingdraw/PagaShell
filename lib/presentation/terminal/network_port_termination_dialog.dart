import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/network_ports.dart';
import '../../domain/ssh/process_manager.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';

class NetworkPortTerminationDialog extends StatefulWidget {
  const NetworkPortTerminationDialog({
    required this.port,
    required this.processes,
    super.key,
  });
  final ListeningNetworkPort port;
  final List<RemoteProcess> processes;

  @override
  State<NetworkPortTerminationDialog> createState() =>
      _NetworkPortTerminationDialogState();
}

class _NetworkPortTerminationDialogState
    extends State<NetworkPortTerminationDialog> {
  final _groups = <String, List<int>>{};
  late final Map<String, TextEditingController> _names;

  @override
  void initState() {
    super.initState();
    for (final process in widget.processes) {
      final basename = process.name.split('/').last;
      (_groups[basename.isEmpty ? process.name : basename] ??= []).add(
        process.pid,
      );
    }
    _names = {
      for (final name in _groups.keys)
        name: TextEditingController()..addListener(_changed),
    };
  }

  bool get _valid =>
      _names.isNotEmpty && _names.entries.every((e) => e.value.text == e.key);
  void _changed() => setState(() {});
  void _confirm() {
    if (_valid) AppNavigation.closeDialog(result: true);
  }

  @override
  void dispose() {
    for (final controller in _names.values) {
      controller.removeListener(_changed);
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Row(
      children: [
        const AppIcon(
          AppIcons.triangleAlert,
          size: 20,
          color: StatusColors.failed,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text('高危操作：结束全部进程'.tr)),
      ],
    ),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '将结束 @protocol 端口 @port 对应的全部 @count 个进程。'.trParams({
            'protocol': widget.port.protocol.name.toUpperCase(),
            'port': '${widget.port.port}',
            'count': '${widget.processes.length}',
          }),
        ),
        const SizedBox(height: 12),
        Text(
          '结束进程可能中断服务并导致未保存的数据丢失。'.tr,
          style: const TextStyle(color: StatusColors.failed),
        ),
        const SizedBox(height: 16),
        for (final entry in _groups.entries) ...[
          Text(
            '${entry.key} · PID ${entry.value.join(', ')}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            '请输入进程名称「@name」以确认，必须完全一致（区分大小写）。'.trParams({'name': entry.key}),
          ),
          const SizedBox(height: 8),
          AppTextFormField(
            key: ValueKey('network-port-terminate-name-${entry.value.first}'),
            controller: _names[entry.key]!,
            autofocus: entry.key == _groups.keys.first,
            enableSuggestions: false,
            autocorrect: false,
            smartPunctuation: false,
            decoration: AppInputDecoration(hintText: '输入进程名称'.tr),
            onFieldSubmitted: (_) => _confirm(),
          ),
          const SizedBox(height: 16),
        ],
      ],
    ),
    actions: [
      shadcn.OutlineButton(
        onPressed: () => AppNavigation.closeDialog(result: false),
        child: Text('取消'.tr),
      ),
      shadcn.DestructiveButton(
        key: const ValueKey('network-port-confirm-terminate-all'),
        onPressed: _valid ? _confirm : null,
        child: Text('结束全部进程'.tr),
      ),
    ],
  );
}
