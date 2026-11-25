#include "system_proxy.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <sstream>

namespace {
static_assert(windows_proxy::kDirect == PROXY_TYPE_DIRECT &&
              windows_proxy::kManual == PROXY_TYPE_PROXY &&
              windows_proxy::kPac == PROXY_TYPE_AUTO_PROXY_URL &&
              windows_proxy::kAutoDetect == PROXY_TYPE_AUTO_DETECT);

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
std::string FormatWinInetError(const char* prefix,
                               const windows_proxy::WinInetError& err) {
  std::ostringstream oss;
  oss << prefix << " (stage=" << (err.stage && *err.stage ? err.stage : "unknown")
      << ", win32=" << err.code;
  if (err.option_error) oss << ", option=" << err.option_error;
  oss << ")";
  return oss.str();
}

const char* ErrorCodeFor(const windows_proxy::WinInetError& err) {
  return err.IsPermissionDenied() ? "proxy_permission" : "proxy_failed";
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

bool SystemNetworkProxy::Read(Settings* settings, WinInetError* error) {
  return windows_proxy::ReadWinInet(settings, error);
}

bool SystemNetworkProxy::Write(const Settings& settings, WinInetError* error) {
  return windows_proxy::WriteWinInet(settings, error);
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
    WinInetError err;
    if (!Read(&current, &err)) {
      result->Error(ErrorCodeFor(err), FormatWinInetError("Could not read system proxy", err));
      return;
    }
    using windows_proxy::ManualProxyOwner;
    auto owner = windows_proxy::ManualOwner(current, *installed_);
    if (windows_proxy::ShouldRestore(current, *before_, *installed_)) {
      // Repeat the refresh if an earlier attempt restored the fields but
      // failed to notify WinINet. Leave a full takeover alone.
      const auto restored =
          windows_proxy::RestoreManual(current, *before_, *installed_);
      if (!Write(restored, &err) || !Read(&current, &err)) {
        result->Error(ErrorCodeFor(err), FormatWinInetError("Could not restore system proxy", err));
        return;
      }
      owner = windows_proxy::ManualOwner(current, *installed_);
    }
    if (owner == ManualProxyOwner::kMixed) {
      result->Error("proxy_restore_conflict",
                    "System proxy map partially changed; remove remaining PagaShell entries before retrying");
      return;
    }
    if (owner == ManualProxyOwner::kLocal ||
        windows_proxy::IsEmptyManualLeftover(current, *before_)) {
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
  if (!(http || https)) {
    result->Error("proxy_windows_http_required",
                  "Windows system proxy requires HTTP(S); configure SOCKS5 manually");
    return;
  }
  Settings current;
  WinInetError err;
  if (!Read(&current, &err)) {
    result->Error(ErrorCodeFor(err), FormatWinInetError("Could not read system proxy", err));
    return;
  }
  if (!owner_.empty() || (current.flags & windows_proxy::kActive)) {
    result->Error("proxy_conflict", "A system proxy is already active"); return;
  }
  const auto desired = windows_proxy::LocalSettings(current, http, https);
  owner_ = *id;
  before_ = current;
  installed_ = desired;
  // Retain snapshots if writing/refreshing fails so Dart can roll back or retry.
  if (!Write(desired, &err)) {
    result->Error(ErrorCodeFor(err), FormatWinInetError("Could not set system proxy", err));
    return;
  }
  Settings verified;
  if (!Read(&verified, &err)) {
    result->Error(ErrorCodeFor(err), FormatWinInetError("Could not verify system proxy", err));
    return;
  }
  if (!windows_proxy::MatchesInstalled(verified, desired)) {
    const bool flags_match = (verified.flags & windows_proxy::kActive) ==
                             (desired.flags & windows_proxy::kActive);
    const bool bypass_match = windows_proxy::detail::Trim(verified.bypass) ==
                              windows_proxy::detail::Trim(desired.bypass);
    std::ostringstream oss;
    oss << "System proxy changed during setup (flagsMatch="
        << (flags_match ? 1 : 0) << ", bypassMatch=" << (bypass_match ? 1 : 0)
        << ")";
    result->Error("proxy_failed", oss.str());
    return;
  }
  result->Success();
}
