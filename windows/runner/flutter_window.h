#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"

class SystemNetworkProxy;
class WindowsSystemTray;
class RdpTextureRegistry;
class RdpCursorRegistry;
class RdpKeyboardCapture;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void StopClipboardListener();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> clipboard_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> rdp_keyboard_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> clipboard_changes_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> clipboard_sink_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> system_proxy_channel_;
  std::unique_ptr<SystemNetworkProxy> system_proxy_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  std::unique_ptr<WindowsSystemTray> system_tray_;
  std::unique_ptr<RdpTextureRegistry> rdp_textures_;
  std::unique_ptr<RdpCursorRegistry> rdp_cursors_;
  std::unique_ptr<RdpKeyboardCapture> rdp_keyboard_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
