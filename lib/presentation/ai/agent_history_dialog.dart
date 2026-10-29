import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/ai/agent_controller.dart';
import '../../domain/ai/agent_conversation.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../navigation/app_navigation.dart';

Future<bool?> showAgentHistory(AgentController agent) =>
    AppNavigation.dialog<bool>(_AgentHistoryDialog(agent: agent));

class _AgentHistoryDialog extends StatefulWidget {
  const _AgentHistoryDialog({required this.agent});
  final AgentController agent;

  @override
  State<_AgentHistoryDialog> createState() => _AgentHistoryDialogState();
}

class _AgentHistoryDialogState extends State<_AgentHistoryDialog> {
  final _deleting = <String>{};

  @override
  void initState() {
    super.initState();
    widget.agent.loadConversations();
  }

  Future<void> _delete(AgentConversation conversation) async {
    final confirmed = await AppNavigation.dialog<bool>(
      AppDialog(
        title: Text('删除对话'.tr),
        content: Text(
          '删除对话“@title”？此操作无法撤销。'.trParams({'title': conversation.title}),
        ),
        actions: [
          shadcn.OutlineButton(
            onPressed: () => AppNavigation.closeDialog(result: false),
            child: Text('取消'.tr),
          ),
          shadcn.DestructiveButton(
            key: const ValueKey('agent-history-confirm-delete'),
            onPressed: () => AppNavigation.closeDialog(result: true),
            child: Text('删除'.tr),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _deleting.add(conversation.id));
    await widget.agent.deleteConversation(conversation.id);
    if (mounted) setState(() => _deleting.remove(conversation.id));
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final muted = shadcn.Theme.of(context).colorScheme.mutedForeground;
    return AppDialog(
      title: Text('历史对话'.tr),
      maxWidth: 560,
      content: SizedBox(
        width: 560,
        height: 400,
        child: Obx(() {
          final conversations = agent.conversations.toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (agent.historyError.value != null) ...[
                Text(
                  agent.historyError.value!.tr,
                  key: const ValueKey('agent-history-error'),
                  style: const TextStyle(fontSize: 12),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: shadcn.GhostButton(
                    onPressed: agent.loadingHistory.value
                        ? null
                        : agent.retryHistory,
                    child: Text('重试'.tr),
                  ),
                ),
              ],
              Expanded(
                child: agent.loadingHistory.value
                    ? const Center(child: shadcn.CircularProgressIndicator())
                    : conversations.isEmpty
                    ? Center(child: Text('暂无历史对话'.tr))
                    : ListView.separated(
                        key: const ValueKey('agent-history-list'),
                        itemCount: conversations.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (_, index) {
                          final item = conversations[index];
                          final deleting = _deleting.contains(item.id);
                          return Row(
                            children: [
                              Expanded(
                                child: shadcn.GhostButton(
                                  key: ValueKey(
                                    'agent-history-open-${item.id}',
                                  ),
                                  onPressed: deleting
                                      ? null
                                      : () {
                                          if (agent.openConversation(item.id)) {
                                            AppNavigation.closeDialog(
                                              result: true,
                                            );
                                          }
                                        },
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                item.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (agent
                                                    .currentConversationId
                                                    .value ==
                                                item.id) ...[
                                              const SizedBox(width: 8),
                                              Text(
                                                '当前对话'.tr,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: muted,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 5),
                                        Text(
                                          '${item.updatedAt.toLocal().toString().substring(0, 16)} · ${item.model}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: muted,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '@count 条消息'.trParams({
                                            'count': '${item.messages.length}',
                                          }),
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              AppIconButton(
                                key: ValueKey(
                                  'agent-history-delete-${item.id}',
                                ),
                                semanticLabel: '删除对话'.tr,
                                tooltip: '删除对话'.tr,
                                icon: const Icon(
                                  shadcn.LucideIcons.trash2,
                                  size: 15,
                                ),
                                onPressed: deleting
                                    ? null
                                    : () => _delete(item),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          );
        }),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog<void>(),
          child: Text('关闭'.tr),
        ),
      ],
    );
  }
}
