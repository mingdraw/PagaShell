#include "flutter_window.h"
#include "system_proxy.h"

#include <optional>
#include <algorithm>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <shlobj.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Result = flutter::MethodResult<Value>;
constexpr size_t kMaxText = 16 * 1024 * 1024;

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

FlutterWindow::~FlutterWindow() {}

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  system_proxy_channel_.reset();
  system_proxy_.reset();
  clipboard_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
