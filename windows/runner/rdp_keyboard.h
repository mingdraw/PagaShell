#ifndef RUNNER_RDP_KEYBOARD_H_
#define RUNNER_RDP_KEYBOARD_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <imm.h>

class RdpKeyboardCapture {
 public:
  static constexpr UINT kKeyMessage = WM_APP + 4;

  RdpKeyboardCapture(HWND window, HWND view,
                     flutter::MethodChannel<flutter::EncodableValue>* channel);
  ~RdpKeyboardCapture();
  bool Start(int32_t owner);
  void Stop(int32_t owner, bool notify);
  void Deactivate() { Stop(owner_, true); }
  void CheckFocus();
  void Dispatch(WPARAM key, LPARAM owner);

 private:
  bool CanCapture() const;
  static LRESULT CALLBACK Hook(int code, WPARAM message, LPARAM details);
  static LRESULT CALLBACK ViewProc(HWND hwnd, UINT message, WPARAM wparam,
                                   LPARAM lparam, UINT_PTR id, DWORD_PTR data);

  static thread_local RdpKeyboardCapture* active_;
  HWND window_;
  HWND view_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  HHOOK hook_ = nullptr;
  HIMC ime_ = nullptr;
  int32_t owner_ = 0;
  bool watching_view_ = false;
};

#endif  // RUNNER_RDP_KEYBOARD_H_
