import '../entities/app_proxy_settings.dart';

/// 解析当前操作系统会话的代理配置（只读，用于应用自动代理模式）。
abstract interface class SystemProxyLookup {
  Future<AppProxyEndpoint?> resolve(Uri target);
}
