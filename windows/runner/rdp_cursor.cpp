#include "rdp_cursor.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>

#include <limits>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;

template <typename T>
const T* Argument(const Map& args, const char* key) {
  auto found = args.find(Value(key));
  return found == args.end() ? nullptr : std::get_if<T>(&found->second);
}

HCURSOR CreateRdpCursor(const Map& args) {
  const auto* w = Argument<int32_t>(args, "width");
  const auto* h = Argument<int32_t>(args, "height");
  const auto* x = Argument<int32_t>(args, "hotspotX");
  const auto* y = Argument<int32_t>(args, "hotspotY");
  const auto* rgba = Argument<std::vector<uint8_t>>(args, "rgba");
  if (!w || !h || !x || !y || !rgba || *w < 1 || *h < 1 || *w > 384 ||
      *h > 384 || *x < 0 || *y < 0 || *x >= *w || *y >= *h ||
      rgba->size() != static_cast<size_t>(*w) * *h * 4)
    return nullptr;

  BITMAPV5HEADER info{};
  info.bV5Size = static_cast<DWORD>(sizeof(info));
  info.bV5Width = *w;
  info.bV5Height = -*h;
  info.bV5Planes = 1;
  info.bV5BitCount = 32;
  info.bV5Compression = BI_BITFIELDS;
  info.bV5RedMask = 0x00ff0000;
  info.bV5GreenMask = 0x0000ff00;
  info.bV5BlueMask = 0x000000ff;
  info.bV5AlphaMask = 0xff000000;
  void* raw = nullptr;
  const HBITMAP color =
      CreateDIBSection(nullptr, reinterpret_cast<const BITMAPINFO*>(&info),
                       DIB_RGB_COLORS, &raw, nullptr, 0);
  if (!color) return nullptr;
  auto* bgra = static_cast<uint8_t*>(raw);
  // A monochrome bitmap needs rows aligned to 16 bits.
  const auto mask_pitch = static_cast<size_t>((*w + 15) / 16) * 2;
  std::vector<uint8_t> mask_bits(mask_pitch * *h, 0);
  for (int row = 0; row < *h; ++row) {
    for (int col = 0; col < *w; ++col) {
      const auto offset = (static_cast<size_t>(row) * *w + col) * 4;
      bgra[offset] = (*rgba)[offset + 2];
      bgra[offset + 1] = (*rgba)[offset + 1];
      bgra[offset + 2] = (*rgba)[offset];
      bgra[offset + 3] = (*rgba)[offset + 3];
      if (bgra[offset + 3] == 0) {
        mask_bits[static_cast<size_t>(row) * mask_pitch + col / 8] |=
            static_cast<uint8_t>(0x80u >> (col % 8));
      }
    }
  }
  const HBITMAP mask = CreateBitmap(*w, *h, 1, 1, mask_bits.data());
  ICONINFO icon{};
  icon.xHotspot = static_cast<DWORD>(*x);
  icon.yHotspot = static_cast<DWORD>(*y);
  icon.hbmColor = color;
  icon.hbmMask = mask;
  const HCURSOR cursor = mask ? CreateIconIndirect(&icon) : nullptr;
  if (mask) DeleteObject(mask);
  DeleteObject(color);
  return cursor;
}
}  // namespace

RdpCursorRegistry::RdpCursorRegistry(flutter::BinaryMessenger* messenger,
                                     HWND view)
    : view_(view),
      installed_(SetWindowSubclass(view, CursorProc, 1,
                                   reinterpret_cast<DWORD_PTR>(this)) != 0),
      channel_(messenger, "pagashell/rdpCursor",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
                                       std::unique_ptr<Result> result) {
    if (call.method_name() == "create") {
      const auto* args =
          call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (!installed_ || !args || cursors_.size() >= 128 ||
          next_id_ == std::numeric_limits<int32_t>::max()) {
        result->Success();
        return;
      }
      const HCURSOR cursor = CreateRdpCursor(*args);
      if (!cursor) {
        result->Success();
        return;
      }
      const int32_t id = next_id_++;
      cursors_.emplace(id, cursor);
      result->Success(Value(id));
      return;
    }
    const auto* id =
        call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
    if (!id) {
      result->NotImplemented();
    } else if (call.method_name() == "activate") {
      if (cursors_.find(*id) != cursors_.end()) {
        active_ = *id;
        Apply();
      }
      result->Success();
    } else if (call.method_name() == "deactivate") {
      if (active_ == *id) {
        active_ = 0;
        SetCursor(LoadCursorW(nullptr, IDC_ARROW));
      }
      result->Success();
    } else if (call.method_name() == "release") {
      Release(*id);
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

RdpCursorRegistry::~RdpCursorRegistry() {
  channel_.SetMethodCallHandler(nullptr);
  if (installed_) RemoveWindowSubclass(view_, CursorProc, 1);
  while (!cursors_.empty()) Release(cursors_.begin()->first);
}

bool RdpCursorRegistry::Apply() {
  const auto found = cursors_.find(active_);
  if (found == cursors_.end() ||
      GetForegroundWindow() != GetAncestor(view_, GA_ROOT))
    return false;
  POINT position{};
  if (!GetCursorPos(&position) || WindowFromPoint(position) != view_)
    return false;
  SetCursor(found->second);
  return true;
}

void RdpCursorRegistry::Release(int32_t id) {
  const auto found = cursors_.find(id);
  if (found == cursors_.end()) return;
  if (active_ == id) active_ = 0;
  if (GetCursor() == found->second) SetCursor(LoadCursorW(nullptr, IDC_ARROW));
  DestroyIcon(found->second);
  cursors_.erase(found);
}

LRESULT CALLBACK RdpCursorRegistry::CursorProc(HWND hwnd, UINT message,
                                               WPARAM wparam, LPARAM lparam,
                                               UINT_PTR id, DWORD_PTR self) {
  auto& cursors = *reinterpret_cast<RdpCursorRegistry*>(self);
  if (message == WM_SETCURSOR && LOWORD(lparam) == HTCLIENT && cursors.Apply())
    return TRUE;
  if (message == WM_NCDESTROY) {
    cursors.installed_ = false;
    RemoveWindowSubclass(hwnd, CursorProc, id);
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}
