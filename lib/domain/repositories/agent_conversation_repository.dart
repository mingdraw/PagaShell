import '../ai/agent_conversation.dart';

abstract interface class AgentConversationRepository {
  Future<List<AgentConversationSummary>> readSummaries();
  Future<AgentConversation?> read(String id);
  Future<void> save(AgentConversation conversation);
  Future<void> remove(String id);
}
