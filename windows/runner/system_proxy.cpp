#include "system_proxy.h"

#include <cstdint>
#include <vector>
#include <sstream>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
const Value* Argument(const Map& map, const char* name) {
  const auto found = map.find(Value(name));
  return found == map.end() ? nullptr : &found->second;
}
int Port(const Map& map, const char* name) {
  const auto* value = Argument(map, name);
  if (!value) return -1;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) {
    return *number >= 0 && *number <= 65535 ? static_cast<int>(*number) : -1;
  }
  return -1;
}
void FreeValues(INTERNET_PER_CONN_OPTIONW* options) {
  for (size_t i = 1; i < 4; ++i) {
    if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
    options[i].Value.pszValue = nullptr;
  }
}
}  // namespace

bool SystemNetworkProxy::Read(Settings* settings) {
  INTERNET_PER_CONN_OPTIONW options[4]{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS_UI;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  DWORD size = sizeof(list);
  // NULL connection selects the current user's default LAN/Internet settings.
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size)) {
    FreeValues(options);
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    size = sizeof(list);
    if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size)) {
      FreeValues(options);
      return false;
    }
  }
  settings->flags = options[0].Value.dwValue;
  settings->server = options[1].Value.pszValue ? options[1].Value.pszValue : L"";
  settings->bypass = options[2].Value.pszValue ? options[2].Value.pszValue : L"";
  settings->pac = options[3].Value.pszValue ? options[3].Value.pszValue : L"";
  FreeValues(options);
  return true;
}

bool SystemNetworkProxy::Write(const Settings& settings) {
  INTERNET_PER_CONN_OPTIONW options[4]{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = settings.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<wchar_t*>(settings.server.c_str());
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = const_cast<wchar_t*>(settings.bypass.c_str());
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = const_cast<wchar_t*>(settings.pac.c_str());
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list))) return false;
  const bool changed = InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) != FALSE;
  const bool refreshed = InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0) != FALSE;
  return changed && refreshed;
}

void SystemNetworkProxy::Handle(const flutter::MethodCall<Value>& call,
                               std::unique_ptr<Result> result) {
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  const auto* id_value = args ? Argument(*args, "owner") : nullptr;
  const auto* id = id_value ? std::get_if<std::string>(id_value) : nullptr;
  if (!args || !id) { result->Error("proxy_failed", "Invalid proxy request"); return; }
  if (call.method_name() == "restore") {
    if (owner_ != *id || !before_ || !installed_) { result->Success(); return; }
    Settings current;
    if (!Read(&current)) { result->Error("proxy_failed", "Could not read system proxy"); return; }
    constexpr DWORD active = PROXY_TYPE_PROXY | PROXY_TYPE_AUTO_PROXY_URL | PROXY_TYPE_AUTO_DETECT;
    const bool ours = (current.flags & active) == PROXY_TYPE_PROXY && current.server == installed_->server;
    Settings restored = current;
    if (ours) {
      restored.flags = before_->flags;
      restored.server = before_->server;
      if (current.bypass == installed_->bypass) restored.bypass = before_->bypass;
      if (current.pac == installed_->pac) restored.pac = before_->pac;
    } else if (current.flags & PROXY_TYPE_PROXY) {
      // A partially changed proxy map may still reference our listener. Keep it
      // alive for retry rather than clear another app's entries or leave dead ports.
      std::wistringstream entries(installed_->server);
      std::wstring entry;
      const std::wstring padded = L";" + current.server + L";";
      while (std::getline(entries, entry, L';')) {
        if (padded.find(L";" + entry + L";") != std::wstring::npos) {
          result->Error("proxy_restore_conflict", "System proxy map partially changed; remove remaining PagaShell entries before retrying");
          return;
        }
      }
    }
    // A different app's full proxy/PAC/WPAD configuration takes precedence.
    if ((ours || current == *before_) && !Write(restored)) {
      result->Error("proxy_failed", "Could not restore system proxy");
      return;
    }
    owner_.clear();
    before_.reset();
    installed_.reset();
    result->Success();
    return;
  }
  if (call.method_name() != "enable") { result->NotImplemented(); return; }
  const int http = Port(*args, "httpPort"), https = Port(*args, "httpsPort"), socks = Port(*args, "socksPort");
  if (http < 0 || http > 65535 || https < 0 || https > 65535 || socks < 0 || socks > 65535 || !(http || https || socks)) {
    result->Error("proxy_failed", "Invalid proxy ports"); return;
  }
  Settings current;
  if (!Read(&current)) { result->Error("proxy_failed", "Could not read system proxy"); return; }
  constexpr DWORD active = PROXY_TYPE_PROXY | PROXY_TYPE_AUTO_PROXY_URL | PROXY_TYPE_AUTO_DETECT;
  if (!owner_.empty() || (current.flags & active)) {
    result->Error("proxy_conflict", "A system proxy is already active"); return;
  }
  Settings desired;
  desired.flags = PROXY_TYPE_PROXY;
  auto add = [&desired](const wchar_t* protocol, const std::wstring& endpoint) {
    if (!desired.server.empty()) desired.server += L";";
    desired.server += std::wstring(protocol) + L"=" + endpoint;
  };
  if (http) add(L"http", L"127.0.0.1:" + std::to_wstring(http));
  if (https) add(L"https", L"127.0.0.1:" + std::to_wstring(https));
  // Explicit version: bare socks= is interpreted as SOCKS4 by Chromium.
  if (socks) add(L"socks", L"socks5://127.0.0.1:" + std::to_wstring(socks));
  owner_ = *id;
  before_ = current;
  installed_ = desired;
  // Retain snapshots if writing/refreshing fails so Dart can roll back or retry.
  if (!Write(desired)) { result->Error("proxy_failed", "Could not set system proxy"); return; }
  Settings verified;
  if (!Read(&verified) || !(verified == desired)) {
    result->Error("proxy_failed", "System proxy changed during setup"); return;
  }
  result->Success();
}
