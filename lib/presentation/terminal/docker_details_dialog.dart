import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/ssh/docker_manager.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../components/app_dialog.dart';
import '../localization/app_translations.dart';
import '../navigation/app_navigation.dart';
import 'docker_resource_labels.dart';

class DockerDetailsDialog extends StatefulWidget {
  const DockerDetailsDialog({
    required this.resource,
    required this.readDetails,
    super.key,
  });

  final DockerResource resource;
  final Future<DockerDetails> Function(DockerResource) readDetails;

  @override
  State<DockerDetailsDialog> createState() => _DockerDetailsDialogState();
}

class _DockerDetailsDialogState extends State<DockerDetailsDialog> {
  late Future<DockerDetails> _details;

  @override
  void initState() {
    super.initState();
    _details = widget.readDetails(widget.resource);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<DockerDetails>(
    future: _details,
    builder: (context, snapshot) {
      final loading = snapshot.connectionState != ConnectionState.done;
      return AppDialog(
        title: Text(widget.resource.kind.detailsTitle),
        maxWidth: 680,
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
                    Flexible(child: Text('正在获取 Docker 详情…'.tr)),
                  ],
                ),
              )
            : snapshot.hasError
            ? Text(
                AppTranslations.error(
                  snapshot.error is SshEngineException
                      ? (snapshot.error! as SshEngineException).message
                      : '无法读取 Docker 详情，请重试',
                ),
                key: const ValueKey('docker-details-error'),
                style: TextStyle(
                  color: shadcn.Theme.of(context).colorScheme.destructive,
                ),
              )
            : _content(snapshot.requireData.resource),
        actions: [
          shadcn.OutlineButton(
            key: const ValueKey('docker-details-refresh'),
            onPressed: loading
                ? null
                : () => setState(() {
                    _details = widget.readDetails(widget.resource);
                  }),
            child: Text((snapshot.hasError ? '重试' : '刷新').tr),
          ),
          shadcn.PrimaryButton(
            key: const ValueKey('docker-details-close'),
            onPressed: () => AppNavigation.closeDialog<void>(),
            child: Text('关闭'.tr),
          ),
        ],
      );
    },
  );

  Widget _content(DockerResource resource) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      _row('名称'.tr, resource.name, 'name'),
      _row('ID', resource.id, 'id'),
      for (final field in resource.fields.entries)
        _row(field.key.label, field.key.display(field.value), field.key.name),
    ],
  );

  Widget _row(String label, String value, String name) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
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
            key: ValueKey('docker-detail-$name'),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );
}
