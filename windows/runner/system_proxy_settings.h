#ifndef RUNNER_SYSTEM_PROXY_SETTINGS_H_
#define RUNNER_SYSTEM_PROXY_SETTINGS_H_

#include <algorithm>
#include <cstdint>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace windows_proxy {

// WinINet connection flags. Keep the settings logic testable without WinINet.
inline constexpr std::uint32_t kDirect = 0x1;
inline constexpr std::uint32_t kManual = 0x2;
inline constexpr std::uint32_t kPac = 0x4;
inline constexpr std::uint32_t kAutoDetect = 0x8;
inline constexpr auto kActive = kManual | kPac | kAutoDetect;

struct Settings {
  std::uint32_t flags = 0;
  std::wstring server, bypass;

  bool operator==(const Settings& other) const {
    return flags == other.flags && server == other.server &&
           bypass == other.bypass;
  }
};

struct UpstreamEndpoint {
  std::wstring protocol;
  std::wstring host;
  int port = 0;

  bool operator==(const UpstreamEndpoint& other) const {
    return protocol == other.protocol && host == other.host &&
           port == other.port;
  }
};

struct UpstreamProxy {
  std::optional<UpstreamEndpoint> http;
  std::optional<UpstreamEndpoint> https;
  std::optional<UpstreamEndpoint> socks5;
  std::vector<std::wstring> bypass;

  bool HasEndpoint() const {
    return http.has_value() || https.has_value() || socks5.has_value();
  }
};

// WinINet's INTERNET_PER_CONN_PROXY_SERVER silently drops socks=socks5://...
// entries on Windows 10/11 and interprets bare socks=host:port as SOCKS4.
// Only install HTTP/HTTPS entries into the Windows system proxy; local SOCKS5
// listeners remain available for explicit per-app configuration.
inline Settings LocalSettings(const Settings& before, int http, int https) {
  Settings settings;
  // WinINet's manual proxy flags include DIRECT for bypassed connections.
  // Clear WPAD/PAC bits while our manual proxy is active; RestoreManual puts
  // previously active WPAD back on stop.
  settings.flags = (before.flags & ~(kPac | kAutoDetect)) | kDirect | kManual;
  auto add = [&settings](const wchar_t* scheme, int port) {
    if (!port) return;
    if (!settings.server.empty()) settings.server += L';';
    settings.server +=
        std::wstring(scheme) + L"=127.0.0.1:" + std::to_wstring(port);
  };
  add(L"http", http);
  add(L"https", https);
  return settings;
}

namespace detail {

inline std::wstring_view Trim(std::wstring_view value) {
  constexpr auto space = L" \t\r\n\f\v";
  const auto first = value.find_first_not_of(space);
  if (first == std::wstring_view::npos) return {};
  return value.substr(first, value.find_last_not_of(space) - first + 1);
}

inline std::wstring ToLowerAscii(std::wstring value) {
  for (auto& ch : value) {
    if (ch >= L'A' && ch <= L'Z') {
      ch = static_cast<wchar_t>(ch + (L'a' - L'A'));
    }
  }
  return value;
}

inline bool IsIpv4Loopback(std::wstring_view host) {
  int octets = 0;
  size_t pos = 0;
  while (pos < host.size()) {
    const auto dot = host.find(L'.', pos);
    const auto part =
        dot == std::wstring_view::npos ? host.substr(pos) : host.substr(pos, dot - pos);
    if (part.empty() || part.size() > 3) return false;
    int value = 0;
    for (wchar_t ch : part) {
      if (ch < L'0' || ch > L'9') return false;
      value = value * 10 + (ch - L'0');
    }
    if (value > 255) return false;
    if (octets == 0 && value != 127) return false;
    ++octets;
    if (dot == std::wstring_view::npos) break;
    pos = dot + 1;
    if (pos == host.size()) return false;
  }
  return octets == 4;
}

using Entry = std::pair<std::wstring, std::wstring>;

inline std::vector<Entry> ParseServer(const std::wstring& server) {
  std::vector<Entry> entries;
  std::wistringstream stream(server);
  for (std::wstring entry; std::getline(stream, entry, L';');) {
    entry = ToLowerAscii(std::move(entry));
    const auto eq = entry.find(L'=');
    const std::wstring_view text(entry);
    const auto scheme =
        eq == std::wstring::npos ? std::wstring_view{} : Trim(text.substr(0, eq));
    auto endpoint = Trim(eq == std::wstring::npos ? text : text.substr(eq + 1));
    if (endpoint.empty()) continue;
    constexpr std::wstring_view http_prefix = L"http://";
    if ((scheme.empty() || scheme == L"http" || scheme == L"https") &&
        endpoint.substr(0, http_prefix.size()) == http_prefix) {
      endpoint.remove_prefix(http_prefix.size());
    }
    entries.emplace_back(scheme, endpoint);
  }
  return entries;
}

inline std::wstring_view Address(std::wstring_view endpoint) {
  const auto scheme = endpoint.find(L"://");
  if (scheme != std::wstring_view::npos) endpoint.remove_prefix(scheme + 3);
  if (!endpoint.empty() && endpoint.back() == L'/') endpoint.remove_suffix(1);
  return endpoint;
}

inline bool ParseUpstreamEndpoint(std::wstring raw,
                                  const wchar_t* default_protocol,
                                  UpstreamEndpoint* out) {
  auto trimmed = std::wstring(Trim(raw));
  if (trimmed.empty()) return false;
  std::wstring protocol = default_protocol;
  const auto scheme_end = trimmed.find(L"://");
  if (scheme_end != std::wstring::npos) {
    const auto scheme = ToLowerAscii(trimmed.substr(0, scheme_end));
    if (scheme == L"http" || scheme == L"https") {
      protocol = L"http";
    } else if (scheme == L"socks" || scheme == L"socks5" ||
               scheme == L"socks5h") {
      protocol = L"socks5";
    } else {
      return false;
    }
    trimmed = trimmed.substr(scheme_end + 3);
  }
  const auto slash = trimmed.find(L'/');
  if (slash != std::wstring::npos) trimmed = trimmed.substr(0, slash);
  // Reject credentials or userinfo in upstream proxy strings.
  if (trimmed.find(L'@') != std::wstring::npos) return false;
  std::wstring host;
  std::wstring port_text;
  if (!trimmed.empty() && trimmed.front() == L'[') {
    const auto close = trimmed.find(L']');
    if (close == std::wstring::npos || close + 1 >= trimmed.size() ||
        trimmed[close + 1] != L':') {
      return false;
    }
    host = ToLowerAscii(std::wstring(Trim(trimmed.substr(1, close - 1))));
    port_text = std::wstring(Trim(trimmed.substr(close + 2)));
  } else {
    const auto colon = trimmed.rfind(L':');
    if (colon == std::wstring::npos || colon == 0) return false;
    host = ToLowerAscii(std::wstring(Trim(trimmed.substr(0, colon))));
    port_text = std::wstring(Trim(trimmed.substr(colon + 1)));
  }
  if (host.empty() || port_text.empty() || port_text.size() > 5) return false;
  for (wchar_t ch : host) {
    if (ch <= L' ' || ch == L'/' || ch == L'\\') return false;
  }
  int port = 0;
  for (wchar_t ch : port_text) {
    if (ch < L'0' || ch > L'9') return false;
    port = port * 10 + (ch - L'0');
  }
  if (port < 1 || port > 65535) return false;
  out->protocol = std::move(protocol);
  out->host = std::move(host);
  out->port = port;
  return true;
}

}  // namespace detail

inline bool IsLoopbackHost(std::wstring_view raw_host) {
  auto host = detail::ToLowerAscii(std::wstring(detail::Trim(raw_host)));
  if (host.size() >= 2 && host.front() == L'[' && host.back() == L']') {
    host = host.substr(1, host.size() - 2);
  }
  while (!host.empty() && host.back() == L'.') host.pop_back();
  if (host == L"localhost" || host == L"::1") return true;
  constexpr std::wstring_view dot_localhost = L".localhost";
  if (host.size() > dot_localhost.size() &&
      host.compare(host.size() - dot_localhost.size(), dot_localhost.size(),
                   dot_localhost) == 0) {
    return true;
  }
  return detail::IsIpv4Loopback(host);
}

inline bool ParseUpstream(const Settings& current, UpstreamProxy* out) {
  *out = {};
  if (!(current.flags & kManual)) return true;
  std::wistringstream bypass_stream(current.bypass);
  for (std::wstring token; std::getline(bypass_stream, token, L';');) {
    const auto trimmed = detail::Trim(token);
    if (!trimmed.empty()) out->bypass.emplace_back(trimmed);
  }
  const auto server_view = detail::Trim(current.server);
  if (server_view.empty()) return true;
  const std::wstring server(server_view);
  if (server.find(L'=') == std::wstring::npos) {
    UpstreamEndpoint ep;
    if (!detail::ParseUpstreamEndpoint(server, L"http", &ep)) return false;
    if (ep.protocol == L"socks5") {
      out->socks5 = std::move(ep);
    } else {
      out->http = ep;
      out->https = std::move(ep);
    }
    return true;
  }
  std::wistringstream entries(server);
  for (std::wstring entry; std::getline(entries, entry, L';');) {
    const auto eq = entry.find(L'=');
    if (eq == std::wstring::npos) continue;
    const auto key =
        detail::ToLowerAscii(std::wstring(detail::Trim(entry.substr(0, eq))));
    const auto val = std::wstring(detail::Trim(entry.substr(eq + 1)));
    if (val.empty()) continue;
    UpstreamEndpoint ep;
    if (key == L"http") {
      if (!detail::ParseUpstreamEndpoint(val, L"http", &ep)) return false;
      out->http = std::move(ep);
    } else if (key == L"https") {
      if (!detail::ParseUpstreamEndpoint(val, L"http", &ep)) return false;
      out->https = std::move(ep);
    } else if (key == L"socks") {
      if (!detail::ParseUpstreamEndpoint(val, L"socks5", &ep)) return false;
      out->socks5 = std::move(ep);
    }
  }
  return out->HasEndpoint();
}

inline bool ConflictsWithLocalPorts(const UpstreamProxy& upstream, int http,
                                    int https, int socks) {
  auto hits = [&](const std::optional<UpstreamEndpoint>& ep) {
    if (!ep.has_value() || !IsLoopbackHost(ep->host)) return false;
    return (http > 0 && ep->port == http) ||
           (https > 0 && ep->port == https) ||
           (socks > 0 && ep->port == socks);
  };
  return hits(upstream.http) || hits(upstream.https) || hits(upstream.socks5);
}

inline bool MatchesInstalled(const Settings& current, const Settings& installed) {
  if ((current.flags & kActive) != (installed.flags & kActive) ||
      detail::Trim(current.bypass) != detail::Trim(installed.bypass)) {
    return false;
  }
  const auto actual = detail::ParseServer(current.server);
  const auto expected = detail::ParseServer(installed.server);
  if (expected.empty()) return false;
  if (actual.size() == 1 && actual.front().first.empty() &&
      expected.size() == 2 && expected[0].first == L"http" &&
      expected[1].first == L"https") {
    // The same HTTP endpoint can be stored as a single proxy for all schemes.
    return actual.front().second == expected[0].second &&
           actual.front().second == expected[1].second;
  }
  return std::is_permutation(actual.begin(), actual.end(), expected.begin(),
                             expected.end());
}

enum class ManualProxyOwner { kOther, kLocal, kMixed };

inline ManualProxyOwner ManualOwner(const Settings& current,
                                    const Settings& installed) {
  if (!(current.flags & kManual)) return ManualProxyOwner::kOther;
  const auto expected = detail::ParseServer(installed.server);
  constexpr std::wstring_view localhost = L"localhost:";
  constexpr std::wstring_view loopback = L"127.0.0.1:";
  bool local = false, other = false;
  for (const auto& entry : detail::ParseServer(current.server)) {
    // Match the listener address even when the proxy scheme has changed. A
    // fallback list may contain both our addresses and another proxy's.
    std::wistringstream endpoints(entry.second);
    for (std::wstring endpoint; std::getline(endpoints, endpoint, L',');) {
      const auto text = detail::Trim(endpoint);
      if (text.empty()) continue;
      const auto address = detail::Address(text);
      const bool matches = std::any_of(
          expected.begin(), expected.end(), [&](const detail::Entry& item) {
            const auto listener = detail::Address(item.second);
            return listener == address ||
                   (address.substr(0, localhost.size()) == localhost &&
                    listener.substr(0, loopback.size()) == loopback &&
                    listener.substr(loopback.size()) ==
                        address.substr(localhost.size()));
          });
      local |= matches;
      other |= !matches;
    }
  }
  if (!local) return ManualProxyOwner::kOther;
  return other ? ManualProxyOwner::kMixed : ManualProxyOwner::kLocal;
}

inline bool IsEmptyManualLeftover(const Settings& current,
                                  const Settings& before) {
  return !(before.flags & kManual) && (current.flags & kManual) &&
         detail::ParseServer(current.server).empty();
}

inline bool ShouldRestore(const Settings& current, const Settings& before,
                          const Settings& installed) {
  const auto owner = ManualOwner(current, installed);
  return owner == ManualProxyOwner::kLocal || current == before ||
         IsEmptyManualLeftover(current, before);
}

inline Settings RestoreManual(const Settings& current, const Settings& before,
                              const Settings& installed) {
  Settings restored = current;
  constexpr auto managed = kDirect | kManual;
  restored.flags = (current.flags & ~managed) | (before.flags & managed);
  if ((before.flags & kAutoDetect) && !(installed.flags & kAutoDetect) &&
      !(current.flags & kAutoDetect)) {
    restored.flags |= kAutoDetect;
  }
  restored.server = before.server;
  if (detail::Trim(current.bypass) == detail::Trim(installed.bypass)) {
    restored.bypass = before.bypass;
  }
  return restored;
}

}  // namespace windows_proxy

#endif  // RUNNER_SYSTEM_PROXY_SETTINGS_H_
