#include "system_proxy.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <sstream>
#include <vector>

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

std::string ToLowerAscii(std::string text) {
  std::transform(text.begin(), text.end(), text.begin(), [](unsigned char ch) {
    return static_cast<char>(std::tolower(ch));
  });
  return text;
}

std::string TrimAscii(const std::string& text) {
  size_t start = 0;
  while (start < text.size() &&
         std::isspace(static_cast<unsigned char>(text[start]))) {
    ++start;
  }
  size_t end = text.size();
  while (end > start &&
         std::isspace(static_cast<unsigned char>(text[end - 1]))) {
    --end;
  }
  return text.substr(start, end - start);
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return "";
  const int needed = WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (needed <= 0) return "";
  std::string out(static_cast<size_t>(needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      out.data(), needed, nullptr, nullptr);
  return out;
}

bool WildcardMatch(const std::string& pattern, const std::string& text) {
  size_t p = 0, t = 0, star = std::string::npos, match = 0;
  while (t < text.size()) {
    if (p < pattern.size() && pattern[p] == text[t]) {
      ++p;
      ++t;
    } else if (p < pattern.size() && pattern[p] == '*') {
      star = p++;
      match = t;
    } else if (star != std::string::npos) {
      p = star + 1;
      t = ++match;
    } else {
      return false;
    }
  }
  while (p < pattern.size() && pattern[p] == '*') ++p;
  return p == pattern.size();
}

void ExtractUrlParts(const std::string& raw, std::string* scheme,
                     std::string* host) {
  const auto scheme_end = raw.find("://");
  size_t host_start = 0;
  if (scheme_end != std::string::npos) {
    *scheme = ToLowerAscii(raw.substr(0, scheme_end));
    host_start = scheme_end + 3;
  } else {
    *scheme = "http";
  }
  const auto path_start = raw.find_first_of("/?#", host_start);
  std::string authority = path_start == std::string::npos
                              ? raw.substr(host_start)
                              : raw.substr(host_start, path_start - host_start);
  const auto at = authority.rfind('@');
  if (at != std::string::npos) authority = authority.substr(at + 1);
  if (!authority.empty() && authority.front() == '[') {
    const auto close = authority.find(']');
    if (close != std::string::npos) {
      *host = ToLowerAscii(authority.substr(1, close - 1));
      return;
    }
  }
  const auto colon = authority.rfind(':');
  if (colon != std::string::npos) authority = authority.substr(0, colon);
  *host = ToLowerAscii(authority);
}

bool IsBypassed(const std::string& bypass, const std::string& host) {
  if (bypass.empty() || host.empty()) return false;
  std::istringstream stream(bypass);
  std::string token;
  while (std::getline(stream, token, ';')) {
    const std::string rule = ToLowerAscii(TrimAscii(token));
    if (rule.empty()) continue;
    if (rule == "<local>") {
      if (host.find('.') == std::string::npos) return true;
      continue;
    }
    if (WildcardMatch(rule, host)) return true;
  }
  return false;
}

bool ParseEndpoint(std::string value, std::string default_protocol,
                   std::string* protocol, std::string* host, int* port) {
  value = TrimAscii(value);
  if (value.empty()) return false;
  *protocol = std::move(default_protocol);
  const auto scheme_end = value.find("://");
  if (scheme_end != std::string::npos) {
    const std::string scheme = ToLowerAscii(value.substr(0, scheme_end));
    if (scheme == "socks" || scheme == "socks5" || scheme == "socks5h") {
      *protocol = "socks5";
    } else if (scheme == "http" || scheme == "https") {
      *protocol = "http";
    } else {
      return false;
    }
    value = value.substr(scheme_end + 3);
  }
  const auto slash = value.find('/');
  if (slash != std::string::npos) value = value.substr(0, slash);
  if (!value.empty() && value.front() == '[') {
    const auto close = value.find(']');
    if (close == std::string::npos || close + 1 >= value.size() ||
        value[close + 1] != ':') {
      return false;
    }
    *host = value.substr(1, close - 1);
    value = value.substr(close + 2);
  } else {
    const auto colon = value.rfind(':');
    if (colon == std::string::npos || colon == 0) return false;
    *host = TrimAscii(value.substr(0, colon));
    value = value.substr(colon + 1);
  }
  if (host->empty() || value.empty()) return false;
  for (unsigned char ch : value) {
    if (!std::isdigit(ch)) return false;
  }
  try {
    *port = std::stoi(value);
  } catch (...) {
    return false;
  }
  return *port >= 1 && *port <= 65535;
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
  if (call.method_name() == "resolve") {
    const auto* url_value = args ? Argument(*args, "url") : nullptr;
    const auto* raw_url = url_value ? std::get_if<std::string>(url_value) : nullptr;
    if (!raw_url || raw_url->empty()) {
      result->Error("proxy_failed", "Invalid proxy lookup request");
      return;
    }
    Settings current;
    if (!Read(&current) || !(current.flags & PROXY_TYPE_PROXY) ||
        current.server.empty()) {
      result->Success();
      return;
    }
    std::string scheme, host;
    ExtractUrlParts(*raw_url, &scheme, &host);
    if (IsBypassed(WideToUtf8(current.bypass), host)) {
      result->Success();
      return;
    }
    const std::string server = WideToUtf8(current.server);
    std::string protocol, proxy_host;
    int proxy_port = 0;
    if (server.find('=') == std::string::npos) {
      if (!ParseEndpoint(server, "http", &protocol, &proxy_host, &proxy_port)) {
        result->Success();
        return;
      }
    } else {
      std::string http_ep, https_ep, socks_ep;
      std::istringstream entries(server);
      std::string entry;
      while (std::getline(entries, entry, ';')) {
        const auto eq = entry.find('=');
        if (eq == std::string::npos) continue;
        const std::string key = ToLowerAscii(TrimAscii(entry.substr(0, eq)));
        const std::string val = TrimAscii(entry.substr(eq + 1));
        if (key == "http") http_ep = val;
        else if (key == "https") https_ep = val;
        else if (key == "socks") socks_ep = val;
      }
      bool matched = false;
      if (scheme == "https") {
        matched =
            (!https_ep.empty() &&
             ParseEndpoint(https_ep, "http", &protocol, &proxy_host, &proxy_port)) ||
            (!http_ep.empty() &&
             ParseEndpoint(http_ep, "http", &protocol, &proxy_host, &proxy_port)) ||
            (!socks_ep.empty() &&
             ParseEndpoint(socks_ep, "socks5", &protocol, &proxy_host, &proxy_port));
      } else {
        matched =
            (!http_ep.empty() &&
             ParseEndpoint(http_ep, "http", &protocol, &proxy_host, &proxy_port)) ||
            (!socks_ep.empty() &&
             ParseEndpoint(socks_ep, "socks5", &protocol, &proxy_host, &proxy_port));
      }
      if (!matched) {
        result->Success();
        return;
      }
    }
    result->Success(Value(Map{
        {Value("protocol"), Value(protocol)},
        {Value("host"), Value(proxy_host)},
        {Value("port"), Value(proxy_port)},
    }));
    return;
  }
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
