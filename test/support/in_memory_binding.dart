import 'package:get/get.dart';
import 'package:pagashell/application/ai/agent_controller.dart';
import 'package:pagashell/application/ai/ai_settings_controller.dart';
import 'package:pagashell/application/configuration/configuration_transfer.dart';
import 'package:pagashell/application/folders/folder_controller.dart';
import 'package:pagashell/application/gateways/gateway_controller.dart';
import 'package:pagashell/application/hosts/host_controller.dart';
import 'package:pagashell/application/hosts/host_tree_controller.dart';
import 'package:pagashell/application/identities/identity_controller.dart';
import 'package:pagashell/application/identities/identity_folder_controller.dart';
import 'package:pagashell/application/identities/identity_tree_controller.dart';
import 'package:pagashell/application/network/app_connect.dart';
import 'package:pagashell/application/session/session_controller.dart';
import 'package:pagashell/application/settings/settings_controller.dart';
import 'package:pagashell/application/transfer/transfer_controller.dart';
import 'package:pagashell/domain/entities/host.dart';
import 'package:pagashell/domain/entities/sidebar_state.dart';
import 'package:pagashell/domain/proxy/system_proxy.dart';
import 'package:pagashell/domain/rdp/rdp_engine.dart';
import 'package:pagashell/domain/repositories/folder_repository.dart';
import 'package:pagashell/domain/repositories/host_repository.dart';
import 'package:pagashell/domain/repositories/host_tree_repository.dart';
import 'package:pagashell/domain/repositories/identity_folder_repository.dart';
import 'package:pagashell/domain/repositories/identity_repository.dart';
import 'package:pagashell/domain/repositories/identity_tree_repository.dart';
import 'package:pagashell/domain/repositories/known_host_repository.dart';
import 'package:pagashell/domain/repositories/local_file_repository.dart';
import 'package:pagashell/domain/repositories/settings_repository.dart';
import 'package:pagashell/domain/ssh/host_key.dart';
import 'package:pagashell/domain/ssh/ssh_engine.dart';
import 'package:pagashell/domain/vault/secret_store.dart';
import 'package:pagashell/domain/vnc/vnc_engine.dart';
import 'package:pagashell/infrastructure/db/in_memory_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_host_tree_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_folder_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_repository.dart';
import 'package:pagashell/infrastructure/db/in_memory_identity_tree_repository.dart';
import 'package:pagashell/infrastructure/vault/in_memory_secret_store.dart';

import 'in_memory_agent_conversation_repository.dart';
import 'in_memory_ai_settings_repository.dart';
import 'in_memory_configuration_repository.dart';
import 'in_memory_local_file_repository.dart';
import 'in_memory_settings_repository.dart';

/// 测试用装配：全部内存实现，SSH 引擎为不可连接的桩，避免触碰原生依赖。
class InMemoryBinding extends Bindings {
  InMemoryBinding({
    SettingsRepository? settingsRepository,
    this.sshEngine = const _StubEngine(),
    this.rdpEngine,
    this.vncEngine,
    this.knownHosts,
    this.systemProxy,
    LocalFileRepository? localFiles,
    SecretStore? secretStore,
  }) : settingsRepository = settingsRepository ?? InMemorySettingsRepository(),
       secretStore = secretStore ?? InMemorySecretStore(),
       localFiles = localFiles ?? InMemoryLocalFileRepository();

  final SettingsRepository settingsRepository;
  final SshEngine sshEngine;
  final RdpEngine? rdpEngine;
  final VncEngine? vncEngine;
  final KnownHostRepository? knownHosts;
  final SystemProxy? systemProxy;
  final SecretStore secretStore;
  final LocalFileRepository localFiles;

  @override
  void dependencies() {
    final HostRepository hostRepository = InMemoryHostRepository();
    final FolderRepository folderRepository = InMemoryFolderRepository();
    final HostTreeRepository treeRepository = InMemoryHostTreeRepository(
      folders: folderRepository,
      hosts: hostRepository,
    );
    final gatewayRepository = InMemoryHostRepository();
    final IdentityRepository identityRepository = InMemoryIdentityRepository(
      services: hostRepository,
      gateways: gatewayRepository,
    );
    final gatewayFolders = InMemoryFolderRepository();
    final gatewayTree = InMemoryHostTreeRepository(
      folders: gatewayFolders,
      hosts: gatewayRepository,
    );
    final transfers = Get.put(TransferController());
    final sessions = Get.put(
      SessionController(
        engine: sshEngine,
        transfers: transfers,
        rdpEngine: rdpEngine,
        vncEngine: vncEngine,
        knownHosts: knownHosts,
        systemProxy: systemProxy,
      ),
    );
    final gateways = Get.put(
      GatewayController(
        repository: gatewayRepository,
        secretStore: secretStore,
        treeRepository: gatewayTree,
        services: hostRepository,
        sessions: sessions,
      ),
    );
    final gatewayFolderController = Get.put(
      GatewayFolderController(
        folderRepository: gatewayFolders,
        hostRepository: gatewayRepository,
        treeRepository: gatewayTree,
      ),
    );
    Get.put(
      GatewayTreeController(
        repository: gatewayTree,
        folders: gatewayFolderController,
        hosts: gateways,
      ),
    );
    final IdentityFolderRepository identityFolders =
        InMemoryIdentityFolderRepository();
    final IdentityTreeRepository identityTree = InMemoryIdentityTreeRepository(
      folders: identityFolders,
      identities: identityRepository,
    );
    Get.put(
      ConfigurationTransfer(
        repository: InMemoryConfigurationRepository(
          serviceFolders: folderRepository,
          services: hostRepository,
          gatewayFolders: gatewayFolders,
          gateways: gatewayRepository,
          identityFolders: identityFolders,
          identities: identityRepository,
          secretStore: secretStore,
        ),
      ),
    );

    Get.put<HostRepository>(hostRepository);
    Get.put<IdentityRepository>(identityRepository);
    Get.put<FolderRepository>(folderRepository);
    Get.put<HostTreeRepository>(treeRepository);
    Get.put<SecretStore>(secretStore);
    Get.put<IdentityFolderRepository>(identityFolders);
    Get.put<IdentityTreeRepository>(identityTree);
    Get.put<SshEngine>(sshEngine);
    Get.put<LocalFileRepository>(localFiles);
    Get.put<SettingsRepository>(settingsRepository);
    final settings = Get.put(
      SettingsController(repository: settingsRepository),
    );
    final aiSettings = Get.put(
      AiSettingsController(
        repository: InMemoryAiSettingsRepository(),
        secretStore: secretStore,
      ),
    );
    Get.lazyPut<GetConnect>(AppConnect.new, tag: 'ai');
    Get.lazyPut<AgentController>(
      () => AgentController(
        connect: Get.find<GetConnect>(tag: 'ai'),
        settings: aiSettings,
        secretStore: secretStore,
        sessions: sessions,
        conversations: InMemoryAgentConversationRepository(),
      ),
    );
    final hosts = Get.put(
      HostController(
        repository: hostRepository,
        secretStore: secretStore,
        treeRepository: treeRepository,
        sessions: sessions,
      ),
    );
    final folders = Get.put(
      FolderController(
        folderRepository: folderRepository,
        hostRepository: hostRepository,
        treeRepository: treeRepository,
      ),
    );
    final identities = Get.put(
      IdentityController(
        repository: identityRepository,
        secretStore: secretStore,
        treeRepository: identityTree,
      ),
    );
    final credentialFolders = Get.put(
      IdentityFolderController(
        repository: identityFolders,
        treeRepository: identityTree,
      ),
    );
    settings.trackSidebarFolders(SidebarSection.services, folders.expanded);
    settings.trackSidebarFolders(
      SidebarSection.identities,
      credentialFolders.expanded,
    );
    settings.trackSidebarFolders(
      SidebarSection.gateways,
      gatewayFolderController.expanded,
    );
    Get.put(
      IdentityTreeController(
        repository: identityTree,
        folders: credentialFolders,
        identities: identities,
      ),
    );
    Get.put(
      HostTreeController(
        repository: treeRepository,
        folders: folders,
        hosts: hosts,
      ),
    );
  }
}

class _StubEngine implements SshEngine {
  const _StubEngine();

  @override
  Future<SshEngineSession> connect(
    Host host,
    SshCredentials credentials, {
    HostKeyVerifier? verifyHostKey,
    Future<void>? cancelled,
    SshGateway? gateway,
  }) => throw const SshEngineException('测试桩不建立真实连接');
}
