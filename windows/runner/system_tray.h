#ifndef RUNNER_SYSTEM_TRAY_H_
#define RUNNER_SYSTEM_TRAY_H_

#include <windows.h>
#include <shellapi.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

class WindowsSystemTray {
 public:
  WindowsSystemTray(
      HWND hwnd,
      flutter::MethodChannel<flutter::EncodableValue>* channel);
  ~WindowsSystemTray();

  WindowsSystemTray(const WindowsSystemTray&) = delete;
  WindowsSystemTray& operator=(const WindowsSystemTray&) = delete;

  void Handle(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

  void Dispose();

 private:
  struct MenuItem {
    std::string id;
    std::string label;
    std::string kind;
    bool enabled = true;
    bool checked = false;
    std::vector<MenuItem> children;
  };

  bool Initialize();
  void UpdateTooltip(const std::string& tooltip);
  void ReloadIcon();
  void ShowContextMenu();
  HMENU BuildPopupMenu(const std::vector<MenuItem>& items,
                       std::vector<std::string>* command_ids) const;
  static std::vector<MenuItem> ParseMenuItems(
      const flutter::EncodableList& list);

  HWND hwnd_ = nullptr;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
  NOTIFYICONDATAW nid_{};
  HICON icon_ = nullptr;
  bool owns_icon_ = false;
  bool has_active_services_ = false;
  bool initialized_ = false;
  bool active_ = false;
  bool disposed_ = false;
  bool menu_open_ = false;
  UINT taskbar_created_message_ = 0;
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  std::vector<MenuItem> items_;
};

#endif  // RUNNER_SYSTEM_TRAY_H_
