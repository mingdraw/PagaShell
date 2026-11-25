#include "../runner/system_proxy_settings.h"

#include <cstdlib>
#include <iostream>

namespace {

void Check(bool condition, const char* test) {
  if (condition) return;
  std::cerr << test << '\n';
  std::exit(EXIT_FAILURE);
}

}  // namespace

int main() {
  using namespace windows_proxy;
  const Settings before{kDirect, L"saved-proxy.example:3128", L"<local>"};
  const auto installed = LocalSettings(before, 18080, 18080);
  Check(installed.flags == (kDirect | kManual), "write WinINet manual flags");
  Check(installed.server == L"http=127.0.0.1:18080;https=127.0.0.1:18080",
        "install HTTP(S) proxy entries without WinINet-unsupported SOCKS5 URI");
  Check(installed.bypass.empty(), "clear bypass list for dynamic proxy routing");

  const Settings readback{
      kManual,
      L" HTTPS = HTTP://127.0.0.1:18080 ; http=127.0.0.1:18080;ftp=;", L""};
  Check(MatchesInstalled(readback, installed), "accept equivalent readback");
  Check(ManualOwner(readback, installed) == ManualProxyOwner::kLocal,
        "recognize our reformatted proxy entries");
  Check(ShouldRestore(readback, before, installed),
        "restore when manual proxy points to local listener");
  Check(RestoreManual(readback, before, installed) == before,
        "restore saved address and bypass list");
  Check(MatchesInstalled({kDirect | kManual, L"127.0.0.1:18080", L""},
                         installed),
        "recognize a shared HTTP(S) proxy address");

  Check(LocalSettings(before, 18080, 0).server == L"http=127.0.0.1:18080",
        "support HTTP-only WinINet mapping");
  Check(LocalSettings(before, 0, 18443).server == L"https=127.0.0.1:18443",
        "support HTTPS-only WinINet mapping");
  Check(!MatchesInstalled({kDirect | kManual, L"", L""},
                          LocalSettings(before, 0, 0)),
        "never verify an empty expected proxy server");

  const Settings empty_leftover{kDirect | kManual, L"", L""};
  Check(IsEmptyManualLeftover(empty_leftover, before),
        "detect empty manual proxy leftover when previously disabled");
  Check(ShouldRestore(empty_leftover, before, installed),
        "roll back an empty manual proxy leftover");
  Check(RestoreManual(empty_leftover, before, installed) == before,
        "restore saved state from empty manual proxy leftover");

  const Settings new_auto{kDirect | kManual | kPac | kAutoDetect, readback.server,
                          L"*.corp.example"};
  Check(!MatchesInstalled(new_auto, installed),
        "do not verify a setup overridden by automatic proxy settings");
  Check(ManualOwner(new_auto, installed) == ManualProxyOwner::kLocal,
        "new automatic settings do not own our manual entries");
  const auto restored = RestoreManual(new_auto, before, installed);
  Check(restored.flags == (kDirect | kPac | kAutoDetect) &&
            restored.server == before.server && restored.bypass == new_auto.bypass,
        "preserve new automatic settings and bypass changes while restoring");

  const Settings mixed{kDirect | kManual,
                       L"https=remote.example:18080;http=http://localhost:18080",
                       L""};
  Check(ManualOwner(mixed, installed) == ManualProxyOwner::kMixed,
        "preserve another proxy alongside a local listener reference");
  Check(!ShouldRestore(mixed, before, installed),
        "do not overwrite mixed manual proxy ownership");
  Check(ManualOwner({kManual, L"http=127.0.0.1:18080,direct://", L""}, installed) ==
            ManualProxyOwner::kMixed,
        "preserve an external fallback next to a local listener");
  const Settings taken_over{kManual, L"http=remote.example:18080", L""};
  Check(ManualOwner(taken_over, installed) == ManualProxyOwner::kOther,
        "allow cleanup after the local references are removed");
  Check(!ShouldRestore(taken_over, before, installed),
        "do not overwrite another application's manual proxy");
  Check(ManualOwner({kDirect, installed.server, L""}, installed) ==
            ManualProxyOwner::kOther,
        "ignore stored addresses when manual proxy is disabled");
}
