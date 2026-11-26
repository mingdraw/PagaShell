#include "flutter_window.h"
#include "rdp_cursor.h"
#include "rdp_keyboard.h"
#include "rdp_texture.h"
#include "system_proxy.h"
#include "system_tray.h"

#include <optional>
#include <algorithm>
#include <cstring>
#include <cstdint>
#include <cwchar>
#include <string>
#include <vector>
#include <shlobj.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Result = flutter::MethodResult<Value>;
using EventError = flutter::StreamHandlerError<Value>;
constexpr size_t kMaxText = 16 * 1024 * 1024;
constexpr UINT kDestroyWindowMessage = WM_APP + 1;

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string result(length, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), length, nullptr, nullptr);
  return result;
}

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), length);
  return result;
}

const Value* Argument(const Map& args, const char* name) {
  const auto found = args.find(Value(name));
  return found == args.end() ? nullptr : &found->second;
}

bool SameChange(const Map& args, const char* key) {
  const auto* value = Argument(args, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text && *text == std::to_string(GetClipboardSequenceNumber());
}

bool PutClipboard(UINT format, const void* bytes, size_t size) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!memory) return false;
  void* data = GlobalLock(memory);
  if (!data) { GlobalFree(memory); return false; }
  std::memcpy(data, bytes, size);
  GlobalUnlock(memory);
  if (!SetClipboardData(format, memory)) { GlobalFree(memory); return false; }
  return true;
}

void ClipboardCall(HWND window, const flutter::MethodCall<Value>& call,
                   std::unique_ptr<Result> result) {
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (!args || (call.method_name() != "read" && call.method_name() != "write")) {
    result->NotImplemented();
    return;
  }
  if (!OpenClipboard(window)) {
    result->Error("clipboard_busy", "Clipboard is busy");
    return;
  }
  struct Close { ~Close() { CloseClipboard(); } } close;
  if (call.method_name() == "read") {
    if (SameChange(*args, "afterChangeId")) { result->Success(); return; }
    const auto change = std::to_string(GetClipboardSequenceNumber());
    List files;
    Value text;
    if (auto drop = static_cast<HDROP>(GetClipboardData(CF_HDROP))) {
      const UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
      if (count > 4096) { result->Error("clipboard_limit", "Too many clipboard files"); return; }
      for (UINT i = 0; i < count; i++) {
        const UINT length = DragQueryFileW(drop, i, nullptr, 0);
        if (length > 32767) { result->Error("clipboard_limit", "Clipboard path too long"); return; }
        std::vector<wchar_t> path(length + 1);
        DragQueryFileW(drop, i, path.data(), length + 1);
        files.emplace_back(Utf8(std::wstring(path.data(), length)));
      }
    }
    if (files.empty()) {
      if (HANDLE handle = GetClipboardData(CF_UNICODETEXT)) {
        const SIZE_T bytes = GlobalSize(handle);
        if (bytes > kMaxText * 2) { result->Error("clipboard_limit", "Clipboard text too large"); return; }
        const auto* data = static_cast<const wchar_t*>(GlobalLock(handle));
        if (data) {
          const auto* end = std::find(data, data + bytes / sizeof(wchar_t), L'\0');
          auto value = Utf8(std::wstring(data, end));
          GlobalUnlock(handle);
          if (value.size() > kMaxText) { result->Error("clipboard_limit", "Clipboard text too large"); return; }
          text = Value(value);
        }
      }
    }
    result->Success(Value(Map{{Value("changeId"), Value(change)},
        {Value("text"), text}, {Value("files"), Value(files)}}));
    return;
  }
  if (!SameChange(*args, "expectedChangeId")) { result->Success(); return; }
  const auto* file_value = Argument(*args, "files");
  const auto* files = file_value ? std::get_if<List>(file_value) : nullptr;
  const auto* text_value = Argument(*args, "text");
  const auto* text = text_value ? std::get_if<std::string>(text_value) : nullptr;
  if ((files && files->size() > 4096) || (text && text->size() > kMaxText)) {
    result->Error("clipboard_limit", "Clipboard content too large");
    return;
  }
  std::vector<wchar_t> paths;
  if (files) {
    for (const auto& file : *files) {
      const auto* value = std::get_if<std::string>(&file);
      const auto path = value ? Wide(*value) : std::wstring();
      if (path.empty() || path.size() > 32767) {
        result->Error("clipboard_invalid", "Invalid clipboard file");
        return;
      }
      paths.insert(paths.end(), path.begin(), path.end());
      paths.push_back(L'\0');
    }
  }
  if (!EmptyClipboard()) { result->Error("clipboard_write", "Clipboard write failed"); return; }
  bool ok = true;
  if (!paths.empty()) {
    paths.push_back(L'\0');
    std::vector<uint8_t> bytes(sizeof(DROPFILES) + paths.size() * sizeof(wchar_t), 0);
    DROPFILES drop{};
    drop.pFiles = sizeof(DROPFILES);
    drop.fWide = TRUE;
    std::memcpy(bytes.data(), &drop, sizeof(drop));
    std::memcpy(bytes.data() + sizeof(drop), paths.data(), paths.size() * sizeof(wchar_t));
    ok = PutClipboard(CF_HDROP, bytes.data(), bytes.size());
    const DWORD effect = DROPEFFECT_COPY;
    if (ok) PutClipboard(RegisterClipboardFormatW(L"Preferred DropEffect"), &effect, sizeof(effect));
  } else if (text) {
    auto wide = Wide(*text);
    wide.push_back(L'\0');
    ok = PutClipboard(CF_UNICODETEXT, wide.data(), wide.size() * sizeof(wchar_t));
  }
  if (ok) result->Success(Value(std::to_string(GetClipboardSequenceNumber())));
  else result->Error("clipboard_write", "Clipboard write failed");
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // Run the derived cleanup before member destruction, including on startup
  // failure. Win32Window's destructor cannot dispatch to this OnDestroy().
  Destroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  rdp_textures_ = std::make_unique<RdpTextureRegistry>(
      flutter_controller_->engine(), GetHandle());
  window_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "pagashell/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
        if (call.method_name() == "showWindow") {
          HWND hwnd = GetHandle();
          if (hwnd) {
            if (IsIconic(hwnd)) {
              ShowWindow(hwnd, SW_RESTORE);
            } else {
              ShowWindow(hwnd, SW_SHOW);
            }
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
          }
          result->Success();
          return;
        }
        if (call.method_name() == "hideWindow") {
          HWND hwnd = GetHandle();
          if (hwnd) {
            ShowWindow(hwnd, SW_HIDE);
          }
          result->Success();
          return;
        }
        if (call.method_name() != "destroy" &&
            call.method_name() != "destroyWindow") {
          result->NotImplemented();
          return;
        }
        // Leave the method-channel callback before destroying its engine. Keep
        // the message loop and COM alive until the view/plugins are released.
        if (!PostMessage(GetHandle(), kDestroyWindowMessage, 0, 0)) {
          result->Error("window_close_failed", "Could not schedule window destruction");
          return;
        }
        result->Success();
      });
  tray_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "pagashell/tray",
      &flutter::StandardMethodCodec::GetInstance());
  system_tray_ =
      std::make_unique<WindowsSystemTray>(GetHandle(), tray_channel_.get());
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
        system_tray_->Handle(call, std::move(result));
      });
  system_proxy_ = std::make_unique<SystemNetworkProxy>();
  system_proxy_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "pagashell/system_proxy",
      &flutter::StandardMethodCodec::GetInstance());
  system_proxy_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
        system_proxy_->Handle(call, std::move(result));
      });
  clipboard_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "pagashell/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
        ClipboardCall(GetHandle(), call, std::move(result));
      });
  rdp_keyboard_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "pagashell/rdpKeyboard",
      &flutter::StandardMethodCodec::GetInstance());
  rdp_keyboard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
        if (call.method_name() == "captureStart" || call.method_name() == "captureStop") {
          const auto* owner = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
          if (!owner || !rdp_keyboard_) { result->Success(Value(false)); return; }
          if (call.method_name() == "captureStart") {
            result->Success(Value(rdp_keyboard_->Start(*owner)));
          } else {
            rdp_keyboard_->Stop(*owner, false);
            result->Success();
          }
          return;
        }
        if (call.method_name() != "state") {
          result->NotImplemented();
          return;
        }
        const int32_t flags = (GetKeyState(VK_SCROLL) & 1) |
                              ((GetKeyState(VK_NUMLOCK) & 1) << 1) |
                              ((GetKeyState(VK_CAPITAL) & 1) << 2);
        wchar_t name[KL_NAMELENGTH] = {};
        const int64_t layout = GetKeyboardLayoutNameW(name)
            ? std::wcstoul(name, nullptr, 16) : 0;
        result->Success(Value(Map{{Value("toggleFlags"), Value(flags)},
                                  {Value("layout"), Value(layout)}}));
      });
  clipboard_changes_ = std::make_unique<flutter::EventChannel<Value>>(
      flutter_controller_->engine()->messenger(), "pagashell/clipboardChanges",
      &flutter::StandardMethodCodec::GetInstance());
  clipboard_changes_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<Value>>(
          [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink)
              -> std::unique_ptr<EventError> {
            StopClipboardListener();
            if (!AddClipboardFormatListener(GetHandle())) {
              sink->Error("clipboard_listener_unavailable", "Clipboard messages unavailable");
              sink->EndOfStream();
            } else {
              clipboard_sink_ = std::move(sink);
              // Catch a change between Dart's initial read and registration.
              clipboard_sink_->Success();
            }
            return nullptr;
          },
          [this](const Value*) -> std::unique_ptr<EventError> {
            StopClipboardListener();
            return nullptr;
          }));
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  rdp_keyboard_ = std::make_unique<RdpKeyboardCapture>(
      GetHandle(), flutter_controller_->view()->GetNativeWindow(), rdp_keyboard_channel_.get());
  rdp_cursors_ = std::make_unique<RdpCursorRegistry>(
      flutter_controller_->engine()->messenger(),
      flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::StopClipboardListener() {
  if (!clipboard_sink_) return;
  if (HWND window = GetHandle()) {
    RemoveClipboardFormatListener(window);
  }
  clipboard_sink_.reset();
}

void FlutterWindow::OnDestroy() {
  rdp_keyboard_.reset();
  rdp_cursors_.reset();
  rdp_textures_.reset();
  StopClipboardListener();
  if (clipboard_changes_) {
    clipboard_changes_->SetStreamHandler(nullptr);
    clipboard_changes_.reset();
  }
  if (system_tray_) {
    system_tray_->Dispose();
    system_tray_.reset();
  }
  tray_channel_.reset();
  window_channel_.reset();
  system_proxy_channel_.reset();
  system_proxy_.reset();
  clipboard_channel_.reset();
  rdp_keyboard_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (rdp_keyboard_) {
    if (message == RdpKeyboardCapture::kKeyMessage) {
      rdp_keyboard_->Dispatch(wparam, lparam);
      return 0;
    }
    if ((message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) ||
        (message == WM_ACTIVATEAPP && !wparam) ||
        (message == WM_SHOWWINDOW && !wparam) ||
        (message == WM_SIZE && wparam == SIZE_MINIMIZED)) {
      rdp_keyboard_->Deactivate();
    } else if (message == WM_WINDOWPOSCHANGED) {
      rdp_keyboard_->CheckFocus();
    }
  }
  if (message == RdpTextureRegistry::kFrameMessage) {
    if (rdp_textures_) rdp_textures_->MarkFrame(wparam);
    return 0;
  }
  if (message == WM_CLIPBOARDUPDATE) {
    if (clipboard_sink_) clipboard_sink_->Success();
    return 0;
  }
  if (message == kDestroyWindowMessage) {
    // Dart has finished saving data and restoring the system proxy. Remove the
    // window now, then shut down Flutter while the native loop still exists.
    if (system_tray_) {
      system_tray_->Dispose();
    }
    ShowWindow(hwnd, SW_HIDE);
    Destroy();
    return 0;
  }

  if (system_tray_) {
    std::optional<LRESULT> tray_result =
        system_tray_->HandleMessage(hwnd, message, wparam, lparam);
    if (tray_result) {
      return *tray_result;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
