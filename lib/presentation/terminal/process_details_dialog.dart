import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/process_manager.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';

class ProcessDetailsDialog extends StatefulWidget {
  const ProcessDetailsDialog({
    required this.process,
    required this.readDetails,
    super.key,
  });

  final RemoteProcess process;
  final Future<ProcessDetails> Function(RemoteProcess) readDetails;

  @override
  State<ProcessDetailsDialog> createState() => _ProcessDetailsDialogState();
}

class _ProcessDetailsDialogState extends State<ProcessDetailsDialog> {
  late Future<ProcessDetails> _details;

  @override
  void initState() {
    super.initState();
    _details = widget.readDetails(widget.process);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ProcessDetails>(
    future: _details,
    builder: (context, snapshot) {
      final loading = snapshot.connectionState != ConnectionState.done;
      return AppDialog(
        title: Text('进程详情'.tr),
        maxWidth: AppTheme.processDetailsDialogMaxWidth,
        scrollable: true,
        content: loading
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox.square(
                      dimension: 16,
                      child: shadcn.CircularProgressIndicator(),
                    ),
                    const SizedBox(width: 10),
                    Text('正在获取进程详情…'.tr),
                  ],
                ),
              )
            : snapshot.hasError
            ? Text(
                AppTranslations.error(
                  snapshot.error is SshEngineException
                      ? (snapshot.error! as SshEngineException).message
                      : '无法读取进程详情，请重试',
                ),
                key: const ValueKey('process-details-error'),
                style: TextStyle(
                  color: shadcn.Theme.of(context).colorScheme.destructive,
                ),
              )
            : _content(snapshot.requireData),
        actions: [
          shadcn.OutlineButton(
            key: const ValueKey('process-details-refresh'),
            onPressed: loading
                ? null
                : () => setState(() {
                    _details = widget.readDetails(widget.process);
                  }),
            child: Text((snapshot.hasError ? '重试' : '刷新').tr),
          ),
          shadcn.PrimaryButton(
            key: const ValueKey('process-details-close'),
            onPressed: () => AppNavigation.closeDialog<void>(),
            child: Text('关闭'.tr),
          ),
        ],
      );
    },
  );

  Widget _content(ProcessDetails details) {
    final process = details.process;
    final name = process.name.split('/').last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _row('进程名称'.tr, name.isEmpty ? process.name : name),
        _row('PID', '${process.pid}'),
        _row('父进程 PID'.tr, '${details.parentPid}'),
        _row('用户名'.tr, process.user),
        _row('进程状态'.tr, details.state),
        _row('启动时间'.tr, process.startedAt),
        _row('运行时长'.tr, details.elapsed),
        _row('CPU', '${process.cpuPercent.toStringAsFixed(1)}%'),
        _row(
          '内存占用'.tr,
          '${details.memoryPercent.toStringAsFixed(1)}% / ${_bytes(process.memoryBytes)}',
        ),
        _row('虚拟内存'.tr, _bytes(details.virtualMemoryBytes)),
        _row('Nice 值'.tr, '${details.nice}'),
        _row(
          '执行路径'.tr,
          details.executablePath ?? '路径不可用'.tr,
          valueKey: const ValueKey('process-details-path'),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {Key? valueKey}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: shadcn.SelectableText(
            value,
            key: valueKey,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );

  static String _bytes(int value) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var amount = value.toDouble();
    var index = 0;
    while (amount >= 1024 && index < units.length - 1) {
      amount /= 1024;
      index++;
    }
    return '${amount.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
  }
}
