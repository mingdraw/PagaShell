#ifndef RUNNER_SYSTEM_PROXY_WININET_H_
#define RUNNER_SYSTEM_PROXY_WININET_H_

#include <windows.h>
#include <wininet.h>

#include "system_proxy_settings.h"

namespace windows_proxy {

struct WinInetError {
  const char* stage = "";
  DWORD code = 0;
  DWORD option_error = 0;

  bool IsPermissionDenied() const {
    return code == ERROR_ACCESS_DENIED || code == ERROR_PRIVILEGE_NOT_HELD;
  }
};

inline void FreePerConnValues(INTERNET_PER_CONN_OPTIONW* options) {
  for (size_t i = 1; i < 3; ++i) {
    if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
    options[i].Value.pszValue = nullptr;
  }
}

inline bool ReadWinInet(Settings* settings, WinInetError* error = nullptr) {
  if (error) *error = {};
  INTERNET_PER_CONN_OPTIONW options[3]{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS_UI;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 3;
  list.pOptions = options;
  DWORD size = sizeof(list);
  // NULL connection selects the current user's default LAN/Internet settings.
  SetLastError(0);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, &size)) {
    FreePerConnValues(options);
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    list.dwOptionError = 0;
    size = sizeof(list);
    SetLastError(0);
    if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                              &list, &size)) {
      if (error) {
        error->stage = "query";
        error->code = GetLastError();
        error->option_error = list.dwOptionError;
      }
      FreePerConnValues(options);
      return false;
    }
  }
  settings->flags = options[0].Value.dwValue;
  settings->server =
      options[1].Value.pszValue ? options[1].Value.pszValue : L"";
  settings->bypass =
      options[2].Value.pszValue ? options[2].Value.pszValue : L"";
  FreePerConnValues(options);
  return true;
}

inline bool WriteWinInet(const Settings& settings,
                         WinInetError* error = nullptr) {
  if (error) *error = {};
  // Only manage the manual proxy fields; leave saved or active PAC URLs alone.
  INTERNET_PER_CONN_OPTIONW options[3]{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = settings.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<wchar_t*>(settings.server.c_str());
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = const_cast<wchar_t*>(settings.bypass.c_str());
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 3;
  list.pOptions = options;
  SetLastError(0);
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list,
                          sizeof(list))) {
    if (error) {
      error->stage = "set";
      error->code = GetLastError();
      error->option_error = list.dwOptionError;
    }
    return false;
  }
  SetLastError(0);
  const bool changed = InternetSetOptionW(
                           nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr,
                           0) != FALSE;
  const DWORD changed_err = changed ? 0 : GetLastError();
  SetLastError(0);
  const bool refreshed =
      InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0) != FALSE;
  const DWORD refreshed_err = refreshed ? 0 : GetLastError();
  if (!changed) {
    if (error) {
      error->stage = "changed";
      error->code = changed_err;
    }
    return false;
  }
  if (!refreshed) {
    if (error) {
      error->stage = "refresh";
      error->code = refreshed_err;
    }
    return false;
  }
  return true;
}

}  // namespace windows_proxy

#endif  // RUNNER_SYSTEM_PROXY_WININET_H_
