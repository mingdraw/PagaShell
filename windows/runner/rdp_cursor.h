#ifndef RUNNER_RDP_CURSOR_H_
#define RUNNER_RDP_CURSOR_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <unordered_map>

class RdpCursorRegistry {
 public:
  RdpCursorRegistry(flutter::BinaryMessenger* messenger, HWND view);
  ~RdpCursorRegistry();

 private:
  void Release(int32_t id);
  bool Apply();
  static LRESULT CALLBACK CursorProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam, UINT_PTR id,
                                     DWORD_PTR self);

  HWND view_;
  bool installed_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  std::unordered_map<int32_t, HCURSOR> cursors_;
  int32_t next_id_ = 1;
  int32_t active_ = 0;
};

#endif
