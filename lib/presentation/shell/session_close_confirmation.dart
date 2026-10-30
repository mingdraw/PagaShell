import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../components/app_dialog.dart';
import '../navigation/app_navigation.dart';

Future<void> requestSessionTabClose(
  SessionController controller,
  Iterable<String> sessionIds, {
  String? keepSessionId,
}) => controller.requestTabClose(
  sessionIds,
  confirm: _confirmStopAndClose,
  keepSessionId: keepSessionId,
);

Future<bool> _confirmStopAndClose(List<Session> running) async =>
    await AppNavigation.dialog<bool>(
      AppDialog(
        key: const ValueKey('session-close-confirmation'),
        title: Text('停止并关闭标签？'.tr),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('关闭标签将自动停止以下端口转发或动态代理，是否继续？'.tr),
            const SizedBox(height: 16),
            for (final session in running)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '@name（@kind）'.trParams({
                    'name': session.host.name,
                    'kind': session.kind == SessionKind.portForward
                        ? '端口转发'.tr
                        : '动态代理'.tr,
                  }),
                ),
              ),
          ],
        ),
        actions: [
          shadcn.OutlineButton(
            onPressed: () => AppNavigation.closeDialog(result: false),
            child: Text('取消'.tr),
          ),
          shadcn.DestructiveButton(
            key: const ValueKey('session-stop-and-close'),
            onPressed: () => AppNavigation.closeDialog(result: true),
            child: Text('停止并关闭'.tr),
          ),
        ],
      ),
    ) ==
    true;
