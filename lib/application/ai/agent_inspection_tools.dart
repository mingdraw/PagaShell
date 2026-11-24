part of 'agent_controller.dart';

const _missingSshTarget =
    'No selected ready SSH session. Specify session_id from CURRENT_CONTEXT when multiple sessions are referenced. Nothing executed.';

const _inspectionLabels = {
  'inspect_server_profile': '采集服务器基线',
  'get_processes': '读取服务器进程',
  'get_network_ports': '读取服务器监听端口',
  'get_docker_resources': '读取 Docker 资源',
  'list_remote_dir': '读取远程目录',
};

bool _readySshTarget(Session? target) => isReadySshSession(target);

bool _validAgentPath(Object? value, {bool directory = false}) =>
    isValidAgentPath(value, directory: directory);

extension _AgentInspectionOperations on AgentController {
  Future<String> _inspectSsh(AgentToolCall call, Session target) async {
    final outcome = await runSshInspectionTool(
      call.name,
      call.arguments,
      target,
      resolveLiveSession: () => _boundSession(target),
      missingTargetMessage: _missingSshTarget,
    );
    return outcome.error ?? outcome.json!;
  }
}
