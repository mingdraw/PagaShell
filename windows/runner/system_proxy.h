#ifndef RUNNER_SYSTEM_PROXY_H_
#define RUNNER_SYSTEM_PROXY_H_

#include <windows.h>
#include <wininet.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include <optional>
#include <string>

class SystemNetworkProxy {
 public:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  struct Settings {
    DWORD flags = 0;
    std::wstring server, bypass, pac;
    bool operator==(const Settings& other) const {
      return flags == other.flags && server == other.server &&
             bypass == other.bypass && pac == other.pac;
    }
  };
  static bool Read(Settings* settings);
  static bool Write(const Settings& settings);
  std::string owner_;
  std::optional<Settings> before_;
  std::optional<Settings> installed_;
};

#endif  // RUNNER_SYSTEM_PROXY_H_
