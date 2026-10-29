import 'package:pagashell/domain/ai/agent_conversation.dart';
import 'package:pagashell/domain/repositories/agent_conversation_repository.dart';

class InMemoryAgentConversationRepository
    implements AgentConversationRepository {
  final items = <String, AgentConversation>{};
  bool failSave = false;
  bool failDelete = false;

  @override
  Future<List<AgentConversation>> readAll() async => items.values.toList();

  @override
  Future<void> save(AgentConversation conversation) async {
    if (failSave) throw StateError('Save unavailable');
    items[conversation.id] = conversation;
  }

  @override
  Future<void> remove(String id) async {
    if (failDelete) throw StateError('Delete unavailable');
    items.remove(id);
  }
}
