#ifndef RUNNER_RDP_TEXTURE_H_
#define RUNNER_RDP_TEXTURE_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

#include <memory>

class RdpTextureRegistry {
 public:
  static constexpr UINT kFrameMessage = WM_APP + 3;
  RdpTextureRegistry(flutter::FlutterEngine* engine, HWND window);
  ~RdpTextureRegistry();
  void MarkFrame(WPARAM texture_id);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_RDP_TEXTURE_H_
