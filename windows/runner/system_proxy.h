#ifndef RUNNER_SYSTEM_PROXY_H_
#define RUNNER_SYSTEM_PROXY_H_

#include <windows.h>
#include <wininet.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include <optional>
#include <string>

#include "system_proxy_settings.h"
#include "system_proxy_wininet.h"

class SystemNetworkProxy {
 public:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  using Settings = windows_proxy::Settings;
  using WinInetError = windows_proxy::WinInetError;
  static bool Read(Settings* settings, WinInetError* error = nullptr);
  static bool Write(const Settings& settings, WinInetError* error = nullptr);
  std::string owner_;
  std::optional<Settings> before_;
  std::optional<Settings> installed_;
};

#endif  // RUNNER_SYSTEM_PROXY_H_
