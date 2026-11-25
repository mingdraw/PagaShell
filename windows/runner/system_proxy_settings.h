#ifndef RUNNER_SYSTEM_PROXY_SETTINGS_H_
#define RUNNER_SYSTEM_PROXY_SETTINGS_H_

#include <algorithm>
#include <cstdint>
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

inline Settings LocalSettings(const Settings& before, int http, int https,
                              int socks) {
  Settings settings;
  // WinINet's manual proxy flags include DIRECT for bypassed connections.
  settings.flags = before.flags | kDirect | kManual;
  auto add = [&settings](const wchar_t* scheme, const wchar_t* prefix, int port) {
    if (!port) return;
    if (!settings.server.empty()) settings.server += L';';
    settings.server += std::wstring(scheme) + L"=" + prefix + L"127.0.0.1:" +
                       std::to_wstring(port);
  };
  add(L"http", L"", http);
  add(L"https", L"", https);
  // Chromium interprets a bare socks= address as SOCKS4.
  add(L"socks", L"socks5://", socks);
  return settings;
}

namespace detail {

inline std::wstring_view Trim(std::wstring_view value) {
  constexpr auto space = L" \t\r\n\f\v";
  const auto first = value.find_first_not_of(space);
  if (first == std::wstring_view::npos) return {};
  return value.substr(first, value.find_last_not_of(space) - first + 1);
}

using Entry = std::pair<std::wstring, std::wstring>;

inline std::vector<Entry> ParseServer(const std::wstring& server) {
  std::vector<Entry> entries;
  std::wistringstream stream(server);
  for (std::wstring entry; std::getline(stream, entry, L';');) {
    for (auto& ch : entry) {
      if (ch >= L'A' && ch <= L'Z') {
        ch = static_cast<wchar_t>(ch + (L'a' - L'A'));
      }
    }
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

}  // namespace detail

inline bool MatchesInstalled(const Settings& current, const Settings& installed) {
  if ((current.flags & kActive) != (installed.flags & kActive) ||
      detail::Trim(current.bypass) != detail::Trim(installed.bypass)) {
    return false;
  }
  const auto actual = detail::ParseServer(current.server);
  const auto expected = detail::ParseServer(installed.server);
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

inline Settings RestoreManual(const Settings& current, const Settings& before,
                              const Settings& installed) {
  Settings restored = current;
  constexpr auto managed = kDirect | kManual;
  restored.flags = (current.flags & ~managed) | (before.flags & managed);
  restored.server = before.server;
  if (detail::Trim(current.bypass) == detail::Trim(installed.bypass)) {
    restored.bypass = before.bypass;
  }
  return restored;
}

}  // namespace windows_proxy

#endif  // RUNNER_SYSTEM_PROXY_SETTINGS_H_
