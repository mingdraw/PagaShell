import 'package:get/get.dart';

/// 全局 HTTP 配置与生命周期；请求和响应直接使用 GetConnect 原生 API。
class AppConnect extends GetConnect {
  AppConnect({super.timeout = const Duration(seconds: 15)})
    : super(followRedirects: false);

  @override
  void onClose() {
    // GetConnect 4 的默认 onClose 不释放底层 HTTP 客户端。
    dispose();
    super.onClose();
  }
}
