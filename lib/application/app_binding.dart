import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

import '../domain/entities/sidebar_state.dart';
import '../domain/repositories/folder_repository.dart';
import '../domain/repositories/host_repository.dart';
import '../domain/repositories/host_tree_repository.dart';
import '../domain/repositories/identity_folder_repository.dart';
import '../domain/repositories/identity_repository.dart';
import '../domain/repositories/identity_tree_repository.dart';
import '../domain/repositories/known_host_repository.dart';
import '../domain/repositories/local_file_repository.dart';
import '../domain/repositories/settings_repository.dart';
import '../domain/ssh/ssh_engine.dart';
import '../domain/vault/secret_store.dart';
import '../infrastructure/db/app_database.dart';
import '../infrastructure/db/drift_agent_conversation_repository.dart';
import '../infrastructure/db/drift_ai_settings_repository.dart';
import '../infrastructure/db/drift_configuration_repository.dart';
import '../infrastructure/db/drift_folder_repository.dart';
import '../infrastructure/db/drift_host_repository.dart';
import '../infrastructure/db/drift_host_tree_repository.dart';
import '../infrastructure/db/drift_identity_folder_repository.dart';
import '../infrastructure/db/drift_identity_repository.dart';
import '../infrastructure/db/drift_identity_tree_repository.dart';
import '../infrastructure/db/drift_known_host_repository.dart';
import '../infrastructure/db/drift_settings_repository.dart';
import '../infrastructure/files/io_local_file_repository.dart';
import '../infrastructure/ssh/rust_ssh_engine.dart';
import '../infrastructure/vault/encrypted_secret_store.dart';
import '../infrastructure/vault/encrypted_vault_storage.dart';
import '../infrastructure/vault/secure_secret_store.dart';
import 'ai/agent_controller.dart';
import 'ai/ai_settings_controller.dart';
import 'configuration/configuration_transfer.dart';
import 'folders/folder_controller.dart';
import 'gateways/gateway_controller.dart';
import 'hosts/host_controller.dart';
import 'hosts/host_tree_controller.dart';
import 'identities/identity_controller.dart';
import 'identities/identity_folder_controller.dart';
import 'identities/identity_tree_controller.dart';
import 'network/app_connect.dart';
import 'session/session_controller.dart';
import 'settings/settings_controller.dart';
import 'transfer/transfer_controller.dart';

/// 全局依赖装配：唯一允许把 infrastructure 实现绑定到 domain 接口的地方。
///
/// 持久化：drift(SQLite) 存文件夹/主机/凭证元数据（连接惰性打开），
/// macOS 凭据存加密保险库、主密钥存钥匙串；其他平台使用系统安全存储。
/// 控制器一律构造函数注入，不在内部调用 Get.find，保证可脱离容器单测。
class AppBinding extends Bindings {
  AppBinding({this.localHomeDirectory});

  final String? localHomeDirectory;

  @override
  void dependencies() {
    final db = AppDatabase();
    final HostRepository hostRepository = DriftHostRepository(db);
    final IdentityRepository identityRepository = DriftIdentityRepository(db);
    final FolderRepository folderRepository = DriftFolderRepository(db);
    final HostTreeRepository treeRepository = DriftHostTreeRepository(db);
    final IdentityFolderRepository identityFolders =
        DriftIdentityFolderRepository(db);
    final IdentityTreeRepository identityTree = DriftIdentityTreeRepository(db);
    final KnownHostRepository knownHosts = DriftKnownHostRepository(db);
    final SettingsRepository settingsRepository = DriftSettingsRepository(db);
    // macOS 上默认的 Data Protection Keychain 需要 keychain-access-groups
    // 授权 + 开发者证书签名，否则写入报 -34018（A required entitlement isn't
    // present）。改用传统 login keychain：无需特殊授权，密文仍由系统钥匙串加密。
    const keychain = SecureSecretStore(
      FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      ),
    );
    // 传统钥匙串逐条授权；只托管一把主密钥，更新后无需对每个服务再次授权。
    final SecretStore secretStore = Platform.isMacOS
        ? EncryptedSecretStore(
            keychain: keychain,
            storage: FileEncryptedVaultStorage(),
          )
        : keychain;
    const sshEngine = RustSshEngine();

    final gatewayRepository = DriftHostRepository(db, gateways: true);
    final gatewayFolders = DriftFolderRepository(db, gateways: true);
    final gatewayTree = DriftHostTreeRepository(db, gateways: true);
    Get.put<ConfigurationTransfer>(
      ConfigurationTransfer(
        repository: DriftConfigurationRepository(db, secretStore),
      ),
      permanent: true,
    );
    final gateways = Get.put<GatewayController>(
      GatewayController(
        repository: gatewayRepository,
        secretStore: secretStore,
        treeRepository: gatewayTree,
        services: hostRepository,
      ),
      permanent: true,
    );
    final gatewayFolderController = Get.put<GatewayFolderController>(
      GatewayFolderController(
        folderRepository: gatewayFolders,
        hostRepository: gatewayRepository,
        treeRepository: gatewayTree,
      ),
      permanent: true,
    );
    Get.put<GatewayTreeController>(
      GatewayTreeController(
        repository: gatewayTree,
        folders: gatewayFolderController,
        hosts: gateways,
      ),
      permanent: true,
    );

    Get.put<AppDatabase>(db, permanent: true);
    Get.put<HostRepository>(hostRepository, permanent: true);
    Get.put<IdentityRepository>(identityRepository, permanent: true);
    Get.put<FolderRepository>(folderRepository, permanent: true);
    Get.put<HostTreeRepository>(treeRepository, permanent: true);
    Get.put<IdentityFolderRepository>(identityFolders, permanent: true);
    Get.put<IdentityTreeRepository>(identityTree, permanent: true);
    Get.put<SecretStore>(secretStore, permanent: true);
    Get.put<KnownHostRepository>(knownHosts, permanent: true);
    Get.put<SettingsRepository>(settingsRepository, permanent: true);
    Get.put<SshEngine>(sshEngine, permanent: true);
    Get.put<LocalFileRepository>(
      IoLocalFileRepository(userHomeDirectory: localHomeDirectory),
      permanent: true,
    );
    // 仅注册工厂，不创建连接或发起后台请求；首次显式使用时才初始化。
    Get.lazyPut<GetConnect>(AppConnect.new, fenix: true);

    final settings = Get.put<SettingsController>(
      SettingsController(repository: settingsRepository),
      permanent: true,
    );
    final aiSettings = Get.put<AiSettingsController>(
      AiSettingsController(
        repository: DriftAiSettingsRepository(db),
        secretStore: secretStore,
      ),
      permanent: true,
    );
    Get.lazyPut<GetConnect>(
      () => AppConnect(timeout: const Duration(seconds: 90)),
      tag: 'ai',
      fenix: true,
    );
    final transfers = Get.put<TransferController>(
      TransferController(),
      permanent: true,
    );
    final sessions = Get.put<SessionController>(
      SessionController(
        engine: sshEngine,
        rdpEngine: const RustRdpEngine(),
        vncEngine: const RustVncEngine(),
        knownHosts: knownHosts,
        transfers: transfers,
      ),
      permanent: true,
    );
    Get.lazyPut<AgentController>(
      () => AgentController(
        connect: Get.find<GetConnect>(tag: 'ai'),
        settings: aiSettings,
        secretStore: secretStore,
        sessions: sessions,
        conversations: DriftAgentConversationRepository(db, secretStore),
      ),
      fenix: true,
    );
    final hosts = Get.put<HostController>(
      HostController(
        repository: hostRepository,
        secretStore: secretStore,
        treeRepository: treeRepository,
        sessions: sessions,
      ),
      permanent: true,
    );
    final folders = Get.put<FolderController>(
      FolderController(
        folderRepository: folderRepository,
        hostRepository: hostRepository,
        treeRepository: treeRepository,
      ),
      permanent: true,
    );
    final identities = Get.put<IdentityController>(
      IdentityController(
        repository: identityRepository,
        secretStore: secretStore,
        privateKeyValidator: sshEngine,
        treeRepository: identityTree,
      ),
      permanent: true,
    );
    final credentialFolders = Get.put<IdentityFolderController>(
      IdentityFolderController(
        repository: identityFolders,
        treeRepository: identityTree,
      ),
      permanent: true,
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
    Get.put<IdentityTreeController>(
      IdentityTreeController(
        repository: identityTree,
        folders: credentialFolders,
        identities: identities,
      ),
      permanent: true,
    );
    Get.put<HostTreeController>(
      HostTreeController(
        repository: treeRepository,
        folders: folders,
        hosts: hosts,
      ),
      permanent: true,
    );
  }
}
