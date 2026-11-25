#include "system_tray.h"

#include <cstdlib>
#include <cstring>
#include <cwchar>

#include "resource.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Result = flutter::MethodResult<Value>;

constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayCallbackMessage = WM_APP + 2;

const Value* FindArgument(const Map& map, const char* name) {
  const auto found = map.find(Value(name));
  return found == map.end() ? nullptr : &found->second;
}

std::string ReadString(const Map& map, const char* name,
                       const std::string& fallback = {}) {
  const auto* value = FindArgument(map, name);
  if (!value) return fallback;
  const auto* text = std::get_if<std::string>(value);
  return text ? *text : fallback;
}

bool ReadBool(const Map& map, const char* name, bool fallback) {
  const auto* value = FindArgument(map, name);
  if (!value) return fallback;
  const auto* flag = std::get_if<bool>(value);
  return flag ? *flag : fallback;
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(
      CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring out(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      out.data(), length);
  return out;
}

std::wstring EscapeMenuLabel(const std::wstring& label) {
  std::wstring escaped;
  escaped.reserve(label.size());
  for (wchar_t ch : label) {
    if (ch == L'&') {
      escaped.push_back(L'&');
    }
    escaped.push_back(ch);
  }
  return escaped;
}

bool IsSystemTaskbarLight() {
  DWORD light_theme = 0;
  DWORD size = sizeof(light_theme);
  const LSTATUS status = RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light_theme, &size);
  return status == ERROR_SUCCESS && light_theme != 0;
}

HICON LoadTrayIcon(bool has_active_services, bool* owns_icon) {
  const int cx = GetSystemMetrics(SM_CXSMICON);
  const int cy = GetSystemMetrics(SM_CYSMICON);
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  const bool light_taskbar = IsSystemTaskbarLight();
  const auto load = [&](WORD resource_id) {
    return static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(resource_id),
                                        IMAGE_ICON, cx, cy, LR_DEFAULTCOLOR));
  };
  HICON icon = nullptr;
  if (has_active_services) {
    icon = load(light_taskbar ? IDI_TRAY_ICON_DARK_ACTIVE
                              : IDI_TRAY_ICON_LIGHT_ACTIVE);
  }
  if (!icon) {
    icon = load(light_taskbar ? IDI_TRAY_ICON_DARK : IDI_TRAY_ICON_LIGHT);
  }
  if (!icon) {
    icon = load(IDI_APP_ICON);
  }
  if (icon) {
    *owns_icon = true;
    return icon;
  }
  *owns_icon = false;
  return static_cast<HICON>(LoadImageW(nullptr, IDI_APPLICATION, IMAGE_ICON, cx,
                                       cy, LR_SHARED));
}
}  // namespace

WindowsSystemTray::WindowsSystemTray(
    HWND hwnd,
    flutter::MethodChannel<flutter::EncodableValue>* channel)
    : hwnd_(hwnd), channel_(channel) {}

WindowsSystemTray::~WindowsSystemTray() { Dispose(); }

void WindowsSystemTray::Handle(const flutter::MethodCall<Value>& call,
                               std::unique_ptr<Result> result) {
  if (call.method_name() == "initialize") {
    Initialize();
    result->Success();
    return;
  }
  if (call.method_name() == "update") {
    const auto* args =
        call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (!args) {
      result->Error("tray_invalid", "Invalid tray payload");
      return;
    }
    if (!initialized_) {
      Initialize();
    }
    const bool has_active_services =
        ReadBool(*args, "hasActiveServices", false);
    if (has_active_services_ != has_active_services) {
      has_active_services_ = has_active_services;
      ReloadIcon();
    }
    UpdateTooltip(ReadString(*args, "tooltip", "PagaShell"));
    const auto* raw_items = FindArgument(*args, "items");
    const auto* item_list =
        raw_items ? std::get_if<List>(raw_items) : nullptr;
    items_ = item_list ? ParseMenuItems(*item_list) : std::vector<MenuItem>{};
    result->Success();
    return;
  }
  if (call.method_name() == "setBackgroundMode") {
    result->Success();
    return;
  }
  if (call.method_name() == "dispose") {
    Dispose();
    result->Success();
    return;
  }
  result->NotImplemented();
}

bool WindowsSystemTray::Initialize() {
  if (disposed_ || !hwnd_) return false;
  if (initialized_) return active_;
  initialized_ = true;

  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  ChangeWindowMessageFilterEx(hwnd_, kTrayCallbackMessage, MSGFLT_ALLOW,
                              nullptr);
  if (taskbar_created_message_ != 0) {
    ChangeWindowMessageFilterEx(hwnd_, taskbar_created_message_, MSGFLT_ALLOW,
                                nullptr);
  }

  icon_ = LoadTrayIcon(has_active_services_, &owns_icon_);
  ZeroMemory(&nid_, sizeof(nid_));
  nid_.cbSize = sizeof(nid_);
  nid_.hWnd = hwnd_;
  nid_.uID = kTrayIconId;
  nid_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid_.uCallbackMessage = kTrayCallbackMessage;
  nid_.hIcon = icon_;
  constexpr size_t kTipCapacity = sizeof(nid_.szTip) / sizeof(nid_.szTip[0]);
  wcsncpy_s(nid_.szTip, kTipCapacity, L"PagaShell", _TRUNCATE);

  active_ = Shell_NotifyIconW(NIM_ADD, &nid_) == TRUE;
  return active_;
}

void WindowsSystemTray::UpdateTooltip(const std::string& tooltip) {
  if (disposed_ || !hwnd_) return;
  std::wstring wide = Utf8ToWide(tooltip.empty() ? "PagaShell" : tooltip);
  constexpr size_t kTipCapacity = sizeof(nid_.szTip) / sizeof(nid_.szTip[0]);
  constexpr size_t kMaxChars = kTipCapacity - 1;
  if (wide.size() > kMaxChars) {
    size_t cut = kMaxChars;
    if (cut > 0 && wide[cut - 1] >= 0xD800 && wide[cut - 1] <= 0xDBFF) {
      --cut;
    }
    wide.resize(cut);
  }
  wcsncpy_s(nid_.szTip, kTipCapacity, wide.c_str(), _TRUNCATE);
  if (active_) {
    nid_.uFlags = NIF_TIP;
    Shell_NotifyIconW(NIM_MODIFY, &nid_);
    nid_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  }
}

void WindowsSystemTray::ReloadIcon() {
  if (disposed_ || !initialized_ || !hwnd_) return;
  bool next_owns = false;
  HICON next_icon = LoadTrayIcon(has_active_services_, &next_owns);
  if (!next_icon) return;
  HICON previous = icon_;
  bool previous_owns = owns_icon_;
  icon_ = next_icon;
  owns_icon_ = next_owns;
  nid_.hIcon = icon_;
  if (active_) {
    nid_.uFlags = NIF_ICON;
    Shell_NotifyIconW(NIM_MODIFY, &nid_);
    nid_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  }
  if (previous && previous_owns) {
    DestroyIcon(previous);
  }
}

std::optional<LRESULT> WindowsSystemTray::HandleMessage(HWND hwnd,
                                                        UINT message,
                                                        WPARAM wparam,
                                                        LPARAM lparam) {
  if (disposed_ || hwnd != hwnd_) return std::nullopt;

  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    if (initialized_) {
      nid_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
      active_ = Shell_NotifyIconW(NIM_ADD, &nid_) == TRUE;
    }
    return 0;
  }

  if (message == WM_DPICHANGED && active_) {
    ReloadIcon();
    return std::nullopt;
  }

  if (message == WM_SETTINGCHANGE && active_) {
    const auto* section = reinterpret_cast<LPCWSTR>(lparam);
    if (!section || _wcsicmp(section, L"ImmersiveColorSet") == 0) {
      ReloadIcon();
    }
    return std::nullopt;
  }

  if (message != kTrayCallbackMessage || wparam != kTrayIconId) {
    return std::nullopt;
  }

  const UINT event = LOWORD(lparam);
  if (event == WM_LBUTTONUP) {
    if (channel_) {
      channel_->InvokeMethod("onIconActivated", nullptr);
    }
    return 0;
  }
  if (event == WM_RBUTTONUP || event == WM_CONTEXTMENU) {
    ShowContextMenu();
    return 0;
  }
  return 0;
}

void WindowsSystemTray::ShowContextMenu() {
  if (disposed_ || menu_open_ || !hwnd_ || items_.empty()) return;
  menu_open_ = true;

  std::vector<std::string> command_ids;
  HMENU menu = BuildPopupMenu(items_, &command_ids);
  if (!menu) {
    menu_open_ = false;
    return;
  }

  const auto alive = alive_;
  const HWND hwnd = hwnd_;
  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(hwnd);
  const UINT selected = static_cast<UINT>(TrackPopupMenuEx(
      menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, cursor.x, cursor.y,
      hwnd, nullptr));
  DestroyMenu(menu);
  if (!*alive) return;
  PostMessageW(hwnd, WM_NULL, 0, 0);
  menu_open_ = false;

  if (!disposed_ && channel_ && selected >= 1 &&
      selected <= command_ids.size()) {
    const std::string& item_id = command_ids[selected - 1];
    channel_->InvokeMethod(
        "onMenuItemSelected",
        std::make_unique<Value>(Map{{Value("id"), Value(item_id)}}));
  }
}

HMENU WindowsSystemTray::BuildPopupMenu(
    const std::vector<MenuItem>& items,
    std::vector<std::string>* command_ids) const {
  HMENU menu = CreatePopupMenu();
  if (!menu) return nullptr;

  for (const auto& item : items) {
    if (item.kind == "separator") {
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      continue;
    }

    const std::wstring label = EscapeMenuLabel(Utf8ToWide(item.label));
    if (item.kind == "submenu") {
      HMENU submenu = BuildPopupMenu(item.children, command_ids);
      if (!submenu) continue;
      UINT flags = MF_POPUP | MF_STRING;
      if (!item.enabled) flags |= MF_GRAYED;
      if (!AppendMenuW(menu, flags, reinterpret_cast<UINT_PTR>(submenu),
                       label.c_str())) {
        DestroyMenu(submenu);
      }
      continue;
    }

    UINT flags = MF_STRING;
    if (!item.enabled || item.id.empty()) {
      flags |= MF_GRAYED;
    }
    if (item.kind == "checkbox") {
      flags |= item.checked ? MF_CHECKED : MF_UNCHECKED;
    }

    UINT_PTR command_id = 0;
    if (item.enabled && !item.id.empty()) {
      command_ids->push_back(item.id);
      command_id = static_cast<UINT_PTR>(command_ids->size());
    }
    AppendMenuW(menu, flags, command_id, label.c_str());
  }

  return menu;
}

std::vector<WindowsSystemTray::MenuItem> WindowsSystemTray::ParseMenuItems(
    const List& list) {
  std::vector<MenuItem> parsed;
  parsed.reserve(list.size());
  for (const auto& entry : list) {
    const auto* map = std::get_if<Map>(&entry);
    if (!map) continue;
    MenuItem item;
    item.id = ReadString(*map, "id");
    item.label = ReadString(*map, "label");
    item.kind = ReadString(*map, "kind", "normal");
    item.enabled = ReadBool(*map, "enabled", true);
    item.checked = ReadBool(*map, "checked", false);
    if (const auto* raw_children = FindArgument(*map, "children")) {
      if (const auto* children = std::get_if<List>(raw_children)) {
        item.children = ParseMenuItems(*children);
      }
    }
    parsed.push_back(std::move(item));
  }
  return parsed;
}

void WindowsSystemTray::Dispose() {
  if (disposed_) return;
  disposed_ = true;
  if (alive_) {
    *alive_ = false;
  }
  if (menu_open_) {
    EndMenu();
  }
  if (active_ && hwnd_) {
    Shell_NotifyIconW(NIM_DELETE, &nid_);
    active_ = false;
  }
  if (icon_ && owns_icon_) {
    DestroyIcon(icon_);
  }
  icon_ = nullptr;
  owns_icon_ = false;
  channel_ = nullptr;
  items_.clear();
}
