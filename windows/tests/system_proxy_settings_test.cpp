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
  const auto installed = LocalSettings(before, 18080, 18080, 1080);
  Check(installed.flags == (kDirect | kManual), "write WinINet manual flags");
  Check(installed.server == L"http=127.0.0.1:18080;https=127.0.0.1:18080;"
                            L"socks=socks5://127.0.0.1:1080",
        "install HTTP(S) and SOCKS5 together");

  const Settings readback{
      kManual,
      L" SOCKS = SOCKS5://127.0.0.1:1080 ; HTTPS = HTTP://127.0.0.1:18080;"
      L"http=127.0.0.1:18080;ftp=;",
      L""};
  Check(MatchesInstalled(readback, installed), "accept equivalent readback");
  Check(ManualOwner(readback, installed) == ManualProxyOwner::kLocal,
        "recognize our reformatted proxy entries");
  Check(RestoreManual(readback, before, installed) == before,
        "restore saved address and bypass list");
  Check(MatchesInstalled({kDirect | kManual, L"127.0.0.1:18080", L""},
                         LocalSettings(before, 18080, 18080, 0)),
        "recognize a shared HTTP(S) proxy address");

  const Settings partial{kDirect | kManual, L"socks=127.0.0.1:1080", L""};
  Check(!MatchesInstalled(partial, LocalSettings(before, 0, 0, 1080)),
        "bare SOCKS replacement does not verify as SOCKS5");
  Check(ManualOwner(partial, installed) == ManualProxyOwner::kLocal,
        "a failed installation can still restore its own addresses");

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
  Check(ManualOwner({kManual, L"http=127.0.0.1:18080,direct://", L""}, installed) ==
            ManualProxyOwner::kMixed,
        "preserve an external fallback next to a local listener");
  Check(ManualOwner({kManual, L"http=remote.example:18080", L""}, installed) ==
            ManualProxyOwner::kOther,
        "allow cleanup after the local references are removed");
  Check(ManualOwner({kDirect, installed.server, L""}, installed) ==
            ManualProxyOwner::kOther,
        "ignore stored addresses when manual proxy is disabled");
}
