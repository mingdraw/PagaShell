import '../ai/agent_conversation.dart';

abstract interface class AgentConversationRepository {
  Future<List<AgentConversation>> readAll();
  Future<void> save(AgentConversation conversation);
  Future<void> remove(String id);
}
