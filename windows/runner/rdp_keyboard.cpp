#include "rdp_keyboard.h"

#include <commctrl.h>
#include <memory>

namespace {
using Value = flutter::EncodableValue;
constexpr WPARAM kExtended = 0x100;
constexpr WPARAM kDown = 0x200;
constexpr WPARAM kLost = 0x400;
}  // namespace

thread_local RdpKeyboardCapture* RdpKeyboardCapture::active_ = nullptr;

RdpKeyboardCapture::RdpKeyboardCapture(
    HWND window, HWND view, flutter::MethodChannel<Value>* channel)
    : window_(window), view_(view), channel_(channel) {
  watching_view_ = SetWindowSubclass(view_, ViewProc, 1,
                                     reinterpret_cast<DWORD_PTR>(this)) != 0;
}

RdpKeyboardCapture::~RdpKeyboardCapture() {
  Stop(owner_, false);
  if (watching_view_) RemoveWindowSubclass(view_, ViewProc, 1);
}

bool RdpKeyboardCapture::CanCapture() const {
  if (GetForegroundWindow() != window_ || !IsWindowVisible(window_) ||
      !IsWindowVisible(view_) || IsIconic(window_)) return false;
  const HWND focus = GetFocus();
  if (focus != view_ && !IsChild(view_, focus)) return false;

  RECT rect{};
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetClientRect(window_, &rect) ||
      !GetMonitorInfoW(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST),
                       &monitor)) return false;
  POINT top_left{rect.left, rect.top};
  POINT bottom_right{rect.right, rect.bottom};
  return ClientToScreen(window_, &top_left) &&
         ClientToScreen(window_, &bottom_right) &&
         top_left.x <= monitor.rcMonitor.left && top_left.y <= monitor.rcMonitor.top &&
         bottom_right.x >= monitor.rcMonitor.right &&
         bottom_right.y >= monitor.rcMonitor.bottom;
}

bool RdpKeyboardCapture::Start(int32_t owner) {
  if (owner <= 0 || !watching_view_ || !CanCapture()) return false;
  if (owner_ == owner) return true;
  if (active_) active_->Stop(active_->owner_, true);
  HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, Hook, GetModuleHandleW(nullptr), 0);
  if (!hook) return false;
  HIMC ime = ImmGetContext(view_);
  if (ime) ImmReleaseContext(view_, ime);
  if (!ImmAssociateContextEx(view_, nullptr, 0)) {
    UnhookWindowsHookEx(hook);
    return false;
  }
  ime_ = ime;
  hook_ = hook;
  owner_ = owner;
  active_ = this;
  return true;
}

void RdpKeyboardCapture::Stop(int32_t owner, bool notify) {
  if (!hook_ || owner_ != owner) return;
  active_ = nullptr;
  owner_ = 0;
  UnhookWindowsHookEx(hook_);
  hook_ = nullptr;
  if (IsWindow(view_)) ImmAssociateContext(view_, ime_);
  ime_ = nullptr;
  if (notify) channel_->InvokeMethod("captureLost", std::make_unique<Value>(owner));
}

void RdpKeyboardCapture::CheckFocus() {
  if (hook_ && !CanCapture()) Stop(owner_, true);
}

LRESULT CALLBACK RdpKeyboardCapture::ViewProc(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam,
                                             UINT_PTR id, DWORD_PTR data) {
  auto* capture = reinterpret_cast<RdpKeyboardCapture*>(data);
  if (message == WM_KILLFOCUS && !IsChild(hwnd, reinterpret_cast<HWND>(wparam))) {
    capture->Deactivate();
  } else if (message == WM_NCDESTROY) {
    capture->Stop(capture->owner_, false);
    capture->watching_view_ = false;
    RemoveWindowSubclass(hwnd, ViewProc, id);
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK RdpKeyboardCapture::Hook(int code, WPARAM message, LPARAM details) {
  auto* capture = active_;
  if (code == HC_ACTION && capture) {
    if (!capture->CanCapture()) {
      PostMessageW(capture->window_, kKeyMessage, kLost, capture->owner_);
    } else {
      const auto& key = *reinterpret_cast<const KBDLLHOOKSTRUCT*>(details);
      if (!(key.flags & LLKHF_INJECTED) && key.scanCode > 0 && key.scanCode <= 0xff &&
          (message == WM_KEYDOWN || message == WM_SYSKEYDOWN ||
           message == WM_KEYUP || message == WM_SYSKEYUP)) {
        const WPARAM scan = key.scanCode |
            ((key.flags & LLKHF_EXTENDED) ? kExtended : 0) |
            ((key.flags & LLKHF_UP) ? 0 : kDown);
        // Do not send through Flutter, wait for I/O, or allocate in the hook.
        if (PostMessageW(capture->window_, kKeyMessage, scan, capture->owner_)) return 1;
      }
    }
  }
  return CallNextHookEx(nullptr, code, message, details);
}

void RdpKeyboardCapture::Dispatch(WPARAM key, LPARAM owner) {
  if (!hook_ || owner != owner_) return;
  if (key == kLost || !CanCapture()) {
    Stop(owner_, true);
    return;
  }
  auto args = flutter::EncodableList{
      Value(owner_), Value(static_cast<int32_t>(key & 0x1ff)), Value((key & kDown) != 0)};
  channel_->InvokeMethod("captureKey", std::make_unique<Value>(std::move(args)));
}
