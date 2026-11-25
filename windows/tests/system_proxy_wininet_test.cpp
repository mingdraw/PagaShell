#include <windows.h>
#include <wininet.h>

#include <cstdlib>
#include <cwchar>
#include <iostream>
#include <sstream>
#include <string>

#include "../runner/system_proxy_settings.h"
#include "../runner/system_proxy_wininet.h"

namespace {

using windows_proxy::IsEmptyManualLeftover;
using windows_proxy::LocalSettings;
using windows_proxy::ManualOwner;
using windows_proxy::ManualProxyOwner;
using windows_proxy::MatchesInstalled;
using windows_proxy::ReadWinInet;
using windows_proxy::RestoreManual;
using windows_proxy::Settings;
using windows_proxy::ShouldRestore;
using windows_proxy::WinInetError;
using windows_proxy::WriteWinInet;

constexpr wchar_t kInternetSettingsPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";

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

std::string FormatSettings(const Settings& s) {
  std::ostringstream oss;
  oss << "flags=0x" << std::hex << s.flags << std::dec << " server=\""
      << WideToUtf8(s.server) << "\" bypass=\"" << WideToUtf8(s.bypass) << "\"";
  return oss.str();
}

bool WriteRegString(const wchar_t* name, const wchar_t* value) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsPath, 0, KEY_SET_VALUE,
                    &key) != ERROR_SUCCESS) {
    return false;
  }
  LONG rc = ERROR_SUCCESS;
  if (value) {
    const DWORD bytes =
        static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t));
    rc = RegSetValueExW(key, name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(value), bytes);
  } else {
    rc = RegDeleteValueW(key, name);
    if (rc == ERROR_FILE_NOT_FOUND) rc = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return rc == ERROR_SUCCESS;
}

bool WriteWinInetPac(const wchar_t* pac_url) {
  INTERNET_PER_CONN_OPTIONW opt{};
  opt.dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  opt.Value.pszValue = const_cast<wchar_t*>(pac_url ? pac_url : L"");
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 1;
  list.pOptions = &opt;
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list,
                          sizeof(list))) {
    return false;
  }
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  return true;
}

bool ReadWinInetPac(std::wstring* out) {
  INTERNET_PER_CONN_OPTIONW opt{};
  opt.dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 1;
  list.pOptions = &opt;
  DWORD size = sizeof(list);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, &size)) {
    return false;
  }
  *out = opt.Value.pszValue ? opt.Value.pszValue : L"";
  if (opt.Value.pszValue) GlobalFree(opt.Value.pszValue);
  return true;
}

void Check(bool condition, const char* name, const std::string& detail = "") {
  if (condition) return;
  std::cerr << "FAIL [" << name << "]";
  if (!detail.empty()) std::cerr << ": " << detail;
  std::cerr << '\n';
  std::exit(EXIT_FAILURE);
}

void TestRoundTrip(const char* name, const Settings& seed, int http,
                   int https) {
  WinInetError err;
  Check(WriteWinInet(seed, &err), name, "write seed failed");
  Settings before;
  Check(ReadWinInet(&before, &err), name, "read before failed");

  const auto desired = LocalSettings(before, http, https);
  Check(WriteWinInet(desired, &err), name, "write desired failed");

  Settings verified;
  Check(ReadWinInet(&verified, &err), name, "read verified failed");
  Check(MatchesInstalled(verified, desired), name,
        "verified did not match desired: verified=(" + FormatSettings(verified) +
            ") desired=(" + FormatSettings(desired) + ")");
  Check(ManualOwner(verified, desired) == ManualProxyOwner::kLocal, name,
        "manual owner should be kLocal");
  Check(ShouldRestore(verified, before, desired), name,
        "ShouldRestore should be true");

  const auto restored_target = RestoreManual(verified, before, desired);
  Check(WriteWinInet(restored_target, &err), name, "write restore failed");
  Settings after_restore;
  Check(ReadWinInet(&after_restore, &err), name, "read after_restore failed");
  Check(after_restore == before, name,
        "after_restore mismatch: got=(" + FormatSettings(after_restore) +
            ") expected=(" + FormatSettings(before) + ")");
  Check(ManualOwner(after_restore, desired) == ManualProxyOwner::kOther &&
            !IsEmptyManualLeftover(after_restore, before),
        name, "restore did not clear local manual proxy ownership");
  std::cout << "PASS [" << name << "] verified=(" << FormatSettings(verified)
            << ")\n";
}

}  // namespace

int main() {
  Settings initial;
  WinInetError err;
  const bool had_initial = ReadWinInet(&initial, &err);
  Check(had_initial, "read_initial", "could not read initial WinINet state");
  std::wstring initial_pac;
  const bool had_pac = ReadWinInetPac(&initial_pac) && !initial_pac.empty();

  TestRoundTrip("clean_http_https", {windows_proxy::kDirect, L"", L""}, 18080,
                18080);
  TestRoundTrip("v2rayn_leftover_http_https",
                {windows_proxy::kDirect, L"127.0.0.1:10809",
                 L"localhost;127.*;10.*;172.16.*;<local>"},
                18080, 18080);
  TestRoundTrip("http_only", {windows_proxy::kDirect, L"", L"<local>"}, 18080,
                0);
  TestRoundTrip("https_only", {windows_proxy::kDirect, L"", L"<local>"}, 0,
                18443);
  TestRoundTrip("separate_http_https_ports",
                {windows_proxy::kDirect, L"saved.invalid:3128", L"*.corp"},
                18080, 18443);
  TestRoundTrip("flags_zero_before", {0, L"", L"<local>"}, 18080, 18080);

  // Saved inactive AutoConfigURL must remain untouched while manual proxy runs.
  Check(WriteWinInetPac(L"http://127.0.0.1:65535/saved.pac"),
        "seed_inactive_pac");
  TestRoundTrip("preserve_inactive_pac_url",
                {windows_proxy::kDirect, L"", L""}, 18080, 18080);
  std::wstring pac_after;
  Check(ReadWinInetPac(&pac_after) &&
            pac_after == L"http://127.0.0.1:65535/saved.pac",
        "verify_inactive_pac_preserved",
        "got=\"" + WideToUtf8(pac_after) + "\"");

  // Direct registry ProxyOverride mutation (e.g. from external tools) must be
  // cleared on enable and restored afterward.
  Check(WriteWinInet({windows_proxy::kDirect, L"127.0.0.1:10809", L""}, &err),
        "seed_reg_override");
  Check(WriteRegString(L"ProxyOverride", L"localhost;127.*;10.*;<local>"),
        "write_reg_override");
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  Settings reg_before;
  Check(ReadWinInet(&reg_before, &err) &&
            reg_before.bypass == L"localhost;127.*;10.*;<local>",
        "read_reg_override_before");
  const auto reg_desired = LocalSettings(reg_before, 18080, 18080);
  Check(WriteWinInet(reg_desired, &err), "write_reg_override_desired");
  Settings reg_verified;
  Check(ReadWinInet(&reg_verified, &err) &&
            MatchesInstalled(reg_verified, reg_desired),
        "verify_reg_override_cleared");
  Check(WriteWinInet(RestoreManual(reg_verified, reg_before, reg_desired), &err),
        "restore_reg_override");
  Settings reg_restored;
  Check(ReadWinInet(&reg_restored, &err) && reg_restored == reg_before,
        "verify_reg_override_restored");
  std::cout << "PASS [direct_reg_override_roundtrip]\n";

  // Verify rollback of an empty manual proxy leftover (ProxyEnable=1, server="").
  const Settings before_empty{windows_proxy::kDirect, L"127.0.0.1:10809",
                              L"<local>"};
  const Settings empty_manual{windows_proxy::kDirect | windows_proxy::kManual,
                              L"", L""};
  Check(WriteWinInet(empty_manual, &err), "seed_empty_manual");
  Settings read_empty;
  Check(ReadWinInet(&read_empty, &err), "read_empty_manual");
  Check(IsEmptyManualLeftover(read_empty, before_empty),
        "detect_empty_manual_leftover");
  Check(ShouldRestore(read_empty, before_empty,
                      LocalSettings(before_empty, 18080, 18080)),
        "should_restore_empty_manual");
  Check(WriteWinInet(
            RestoreManual(read_empty, before_empty,
                          LocalSettings(before_empty, 18080, 18080)),
            &err),
        "restore_empty_manual");
  Settings after_empty;
  Check(ReadWinInet(&after_empty, &err) && after_empty == before_empty,
        "verify_empty_manual_restored");
  std::cout << "PASS [empty_manual_leftover_rollback]\n";

  // Restore runner's original WinINet state.
  WriteWinInetPac(had_pac ? initial_pac.c_str() : L"");
  WriteWinInet(initial, &err);
  std::cout << "ALL WININET PROXY TESTS PASSED\n";
  return EXIT_SUCCESS;
}
