import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:get/get.dart';

import '../../domain/entities/app_proxy_settings.dart';
import '../../domain/entities/app_theme_mode.dart';
import '../../domain/entities/sidebar_state.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/vault/secret_store.dart';

class ProxySettingsException implements Exception {
  const ProxySettingsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SettingsController extends GetxController {
  SettingsController({required this._repository, this._secretStore});

  final SettingsRepository _repository;
  final SecretStore? _secretStore;
  final themeMode = AppThemeMode.system.obs;
  final languageCode = RxnString();
  final savingLanguage = false.obs;
  final sidebarState = SidebarState().obs;

  /// 侧边栏是否显示，从 [sidebarState] 派生。标题栏、标签栏、AI 工作区等
  /// 只关心显隐，单独订阅它，展开/折叠文件夹时不再跟着重建。
  final sidebarVisible = true.obs;
  final sidebarWidth = SidebarState.defaultWidth.obs;
  final terminalFontSize = SidebarState.defaultTerminalFontSize.obs;
  final closeTerminalOnDisconnect = false.obs;
  final savingCloseTerminalOnDisconnect = false.obs;
  final isLoaded = false.obs;
  final automaticUpdates = true.obs;
  final savingAutomaticUpdates = false.obs;
  final proxySettings = const AppProxySettings().obs;
  final proxyLoadFailed = false.obs;
  final savingProxySettings = false.obs;
  late final Future<void> ready = _load();
  Future<void> _pendingSave = Future<void>.value();
  Future<void> _pendingSidebarSave = Future<void>.value();
  Future<void> _pendingProxySave = Future<void>.value();
  final _sidebarFolders = <SidebarSection, RxSet<String>>{};
  final _sidebarWorkers = <Worker>[];

  /// 当前已排队的显示偏好写入，用于退出或测试时等待落盘。
  Future<void> get sidebarSaved => _pendingSidebarSave;

  @override
  void onInit() {
    super.onInit();
    unawaited(ready);
  }

  Future<void> _load() async {
    // 各项偏好相互独立，并行读取；各自失败只回退该项，不影响其他项与启动。
    await (
      _repository.readThemeMode().then<void>(
        (saved) {
          if (!isClosed) themeMode.value = saved;
        },
        // 偏好读取失败时使用自动模式，仍允许打开应用和重新选择。
        onError: (Object _) {},
      ),
      _repository.readLanguageCode().then<void>((saved) {
        if (!isClosed) languageCode.value = saved;
      }, onError: (Object _) {}),
      _repository.readSidebarState().then<void>(
        (saved) {
          if (!isClosed) {
            sidebarState.value = saved;
            sidebarVisible.value = saved.visible;
            sidebarWidth.value = saved.width;
            terminalFontSize.value = saved.terminalFontSize;
          }
        },
        // 显示偏好不可读时保留默认布局，不影响主题和启动。
        onError: (Object _) {},
      ),
      _repository.readCloseTerminalOnDisconnect().then<void>((saved) {
        if (!isClosed) closeTerminalOnDisconnect.value = saved;
      }, onError: (Object _) {}),
      _repository.readAutomaticUpdates().then<void>(
        (saved) {
          if (!isClosed) automaticUpdates.value = saved;
        },
        // 无法确认已保存的选择时，不主动发起启动检查。
        onError: (Object _) {
          if (!isClosed) automaticUpdates.value = false;
        },
      ),
      _repository.readProxySettings().then<void>(
        (saved) {
          if (!isClosed) proxySettings.value = saved;
        },
        onError: (Object _) {
          if (!isClosed) proxyLoadFailed.value = true;
        },
      ),
    ).wait;
    if (isClosed) return;
    for (final entry in _sidebarFolders.entries) {
      entry.value.assignAll(sidebarState.value.expandedFolders(entry.key));
    }
    isLoaded.value = true;
    if (!proxyLoadFailed.value &&
        proxySettings.value.pendingSecretDeletes.isNotEmpty) {
      unawaited(_cleanProxySecrets().catchError((Object _) {}));
    }
  }

  /// 追踪共享目录控制器的展开集合，覆盖点击、新建与拖入后的自动展开。
  /// 启动恢复完成前的赋值不会触发写入，避免默认值覆盖已保存的布局。
  void trackSidebarFolders(SidebarSection section, RxSet<String> expanded) {
    _sidebarFolders[section] = expanded;
    if (isLoaded.value) {
      expanded.assignAll(sidebarState.value.expandedFolders(section));
    }
    _sidebarWorkers.add(
      ever(expanded, (_) {
        if (!isLoaded.value) return;
        final next = sidebarState.value.withFolders(section, expanded.toSet());
        unawaited(
          _saveSidebarState(next).catchError((Object _) {
            // 保留当前显示；后续展开/折叠会重新保存完整快照。
          }),
        );
      }),
    );
  }

  Future<void> setSidebarVisible(bool visible) {
    if (sidebarState.value.visible == visible) return _pendingSidebarSave;
    return _saveSidebarState(sidebarState.value.withVisibility(visible));
  }

  Future<void> setSidebarWidth(double width) {
    final next = sidebarState.value.withWidth(width);
    if (sidebarState.value.width == next.width) return _pendingSidebarSave;
    return _saveSidebarState(next);
  }

  Future<void> setTerminalFontSize(double fontSize) {
    final next = sidebarState.value.withTerminalFontSize(fontSize);
    if (sidebarState.value.terminalFontSize == next.terminalFontSize) {
      return _pendingSidebarSave;
    }
    return _saveSidebarState(next);
  }

  Future<void> setSidebarSectionExpanded(
    SidebarSection section,
    bool expanded,
  ) {
    if (sidebarState.value.isSectionExpanded(section) == expanded) {
      return _pendingSidebarSave;
    }
    return _saveSidebarState(sidebarState.value.withSection(section, expanded));
  }

  Future<void> recordRecentHost(String hostId) {
    final current = sidebarState.value.recentHostIds;
    if (current.isNotEmpty && current.first == hostId) {
      return _pendingSidebarSave;
    }
    return _saveSidebarState(sidebarState.value.withRecentHost(hostId));
  }

  Future<void> _saveSidebarState(SidebarState state) {
    final previous = sidebarState.value;
    sidebarState.value = state;
    if (previous.visible != state.visible) {
      sidebarVisible.value = state.visible;
    }
    if (previous.width != state.width) {
      sidebarWidth.value = state.width;
    }
    if (previous.terminalFontSize != state.terminalFontSize) {
      terminalFontSize.value = state.terminalFontSize;
    }
    // 点击立即更新界面，快照按顺序写入，避免快速操作后旧状态覆盖新状态。
    final save = _pendingSidebarSave.then((_) async {
      await ready;
      await _repository.saveSidebarState(state);
    });
    _pendingSidebarSave = save.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return save;
  }

  @override
  void onClose() {
    for (final worker in _sidebarWorkers) {
      worker.dispose();
    }
    super.onClose();
  }

  Future<void> setCloseTerminalOnDisconnect(bool enabled) async {
    if (isClosed || savingCloseTerminalOnDisconnect.value) return;
    savingCloseTerminalOnDisconnect.value = true;
    try {
      await ready;
      if (isClosed || closeTerminalOnDisconnect.value == enabled) return;
      await _repository.saveCloseTerminalOnDisconnect(enabled);
      if (!isClosed) closeTerminalOnDisconnect.value = enabled;
    } finally {
      if (!isClosed) savingCloseTerminalOnDisconnect.value = false;
    }
  }

  /// 保存成功后再应用开关；写入期间禁用重复操作。
  Future<void> setAutomaticUpdates(bool enabled) async {
    if (savingAutomaticUpdates.value) return;
    savingAutomaticUpdates.value = true;
    try {
      await ready;
      await _repository.saveAutomaticUpdates(enabled);
      if (!isClosed) automaticUpdates.value = enabled;
    } finally {
      if (!isClosed) savingAutomaticUpdates.value = false;
    }
  }

  /// 顺序保存快速连续的选择；保存成功后再应用，失败时保留原模式。
  Future<void> setThemeMode(AppThemeMode mode) {
    final save = _pendingSave.then((_) async {
      await ready;
      if (isClosed || themeMode.value == mode) return;
      await _repository.saveThemeMode(mode);
      if (!isClosed) themeMode.value = mode;
    });
    _pendingSave = save.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return save;
  }

  Future<void> setLanguageCode(String code) async {
    if (isClosed || savingLanguage.value) return;
    savingLanguage.value = true;
    try {
      if (!isLoaded.value) await ready;
      if (isClosed || languageCode.value == code) return;
      await _repository.saveLanguageCode(code);
      if (!isClosed) languageCode.value = code;
    } finally {
      if (!isClosed) savingLanguage.value = false;
    }
  }

  Future<String?> readProxyPassword() async {
    await ready;
    final ref = proxySettings.value.passwordSecretRef;
    if (ref.isEmpty || _secretStore == null) return null;
    return _secretStore.read(ref);
  }

  Future<void> reloadProxySettings() => _queueProxy(() async {
    final saved = await _repository.readProxySettings();
    if (isClosed) return;
    proxySettings.value = saved;
    proxyLoadFailed.value = false;
    await _cleanProxySecrets();
  }, allowFailedLoad: true);

  Future<void> saveProxySettings({
    required AppProxyMode mode,
    AppProxyProtocol? protocol,
    String? address,
    String? username,
    String? password,
    bool clearPassword = false,
  }) => _queueProxy(() async {
    final current = proxySettings.value;
    if (mode != AppProxyMode.manual) {
      final next = current.copyWith(mode: mode);
      await _repository.saveProxySettings(next);
      if (!isClosed) proxySettings.value = next;
      return;
    }

    final nextProtocol = protocol ?? current.protocol;
    final trimmedAddress = (address ?? current.address).trim();
    final addressError = AppProxySettings.validateAddress(trimmedAddress);
    if (addressError != null) {
      throw ProxySettingsException(addressError);
    }
    final nextUsername = (username ?? current.username).trim();
    final usernameError = AppProxySettings.validateCredential(nextUsername);
    if (usernameError != null) {
      throw ProxySettingsException(usernameError);
    }
    final rawPassword = password ?? '';
    if (rawPassword.isNotEmpty) {
      final passwordError = AppProxySettings.validateCredential(rawPassword);
      if (passwordError != null) {
        throw ProxySettingsException(passwordError);
      }
    }

    final replacingPassword = rawPassword.isNotEmpty;
    final removingPassword = clearPassword && !replacingPassword;
    var nextSecretRef = current.passwordSecretRef;
    final pendingDeletes = [...current.pendingSecretDeletes];
    if (replacingPassword) {
      final store = _secretStore;
      if (store == null) {
        throw const ProxySettingsException('代理设置保存失败，请重试');
      }
      final ref = 'proxy-auth-${_randomId()}';
      await _commitProxy(
        current.copyWith(pendingSecretDeletes: [...pendingDeletes, ref]),
      );
      try {
        await store.put(ref, rawPassword);
      } on Object {
        await _cleanProxySecrets();
        rethrow;
      }
      if (current.passwordSecretRef.isNotEmpty) {
        pendingDeletes.add(current.passwordSecretRef);
      }
      nextSecretRef = ref;
    } else if (removingPassword && current.passwordSecretRef.isNotEmpty) {
      pendingDeletes.add(current.passwordSecretRef);
      nextSecretRef = '';
    }

    final next = AppProxySettings(
      mode: AppProxyMode.manual,
      protocol: nextProtocol,
      address: trimmedAddress,
      username: nextUsername,
      passwordSecretRef: nextSecretRef,
      pendingSecretDeletes: pendingDeletes
          .where((ref) => ref != nextSecretRef)
          .toList(),
    );
    try {
      await _repository.saveProxySettings(next);
    } on Object {
      if (replacingPassword) await _cleanProxySecrets();
      rethrow;
    }
    if (!isClosed) proxySettings.value = next;
    await _cleanProxySecrets();
  });

  Future<void> _queueProxy(
    Future<void> Function() action, {
    bool allowFailedLoad = false,
  }) {
    final result = _pendingProxySave.then((_) async {
      await ready;
      if (isClosed) return;
      savingProxySettings.value = true;
      try {
        if (proxyLoadFailed.value && !allowFailedLoad) {
          throw const ProxySettingsException('代理设置读取失败，请重试');
        }
        try {
          await action();
        } on ProxySettingsException {
          rethrow;
        } on Object {
          throw const ProxySettingsException('代理设置保存失败，请重试');
        }
      } finally {
        if (!isClosed) savingProxySettings.value = false;
      }
    });
    _pendingProxySave = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _commitProxy(AppProxySettings next) async {
    await _repository.saveProxySettings(next);
    if (!isClosed) proxySettings.value = next;
  }

  Future<void> _cleanProxySecrets() async {
    final store = _secretStore;
    if (store == null) return;
    final current = proxySettings.value;
    if (current.pendingSecretDeletes.isEmpty) return;
    final remaining = <String>[];
    for (final ref in current.pendingSecretDeletes.toSet()) {
      if (ref == current.passwordSecretRef) continue;
      try {
        await store.delete(ref);
      } on Object {
        remaining.add(ref);
      }
    }
    if (remaining.length != current.pendingSecretDeletes.length) {
      try {
        await _commitProxy(
          proxySettings.value.copyWith(pendingSecretDeletes: remaining),
        );
      } on Object {
        /* 已保存待删引用，重启后重试。 */
      }
    }
  }

  static String _randomId() => base64UrlEncode(
    List<int>.generate(18, (_) => Random.secure().nextInt(256)),
  );
}
