#ifndef PAGASHELL_RDP_TEXTURE_H_
#define PAGASHELL_RDP_TEXTURE_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Layout matches DesktopTile and FrameView in Rust. The view and its
// storage are borrowed only during the synchronous submit callback.
typedef struct {
  uint16_t x, y, width, height, source_x, source_y;
} PagaRdpTile;

typedef struct {
  uint16_t width, height, bitmap_width, bitmap_height;
  const uint8_t* rgba;
  size_t rgba_len;
  const PagaRdpTile* tiles;
  size_t tile_count;
} PagaRdpFrameView;

typedef enum {
  PAGA_RDP_GPU_SURFACE_NONE = 0,
  PAGA_RDP_GPU_SURFACE_CV_PIXEL_BUFFER = 1,
  PAGA_RDP_GPU_SURFACE_DXGI_SHARED_HANDLE = 2,
} PagaRdpGpuSurfaceKind;

typedef struct {
  uint32_t kind;
  uint16_t width;
  uint16_t height;
  uint64_t handle;
  uint64_t generation;
} PagaRdpGpuSurfaceView;

typedef bool (*PagaRdpTextureSubmit)(void*, const PagaRdpFrameView*);
typedef bool (*PagaRdpTextureSubmitGpu)(void*, const PagaRdpGpuSurfaceView*);
typedef void (*PagaRdpTextureRelease)(void*);
typedef bool (*PagaRdpTextureAttach)(uint32_t, int64_t, void*,
                                    PagaRdpTextureSubmit, PagaRdpTextureRelease);
typedef bool (*PagaRdpTextureAttachGpu)(uint32_t, PagaRdpTextureSubmitGpu,
                                       uint64_t);
typedef void (*PagaRdpTextureDetach)(uint32_t);

// Transfers one owning reference to Rust on success. Either callback may run
// on a worker thread; detach does not wait for callbacks already in progress.
bool pagashell_rdp_texture_attach(uint32_t, int64_t, void*, PagaRdpTextureSubmit,
                                  PagaRdpTextureRelease);
bool pagashell_rdp_texture_attach_gpu(uint32_t, PagaRdpTextureSubmitGpu,
                                      uint64_t adapter_luid);
void pagashell_rdp_texture_detach(uint32_t);

static inline bool PagaRdpFrameIsFull(const PagaRdpFrameView* frame) {
  return frame->tile_count == 0 && frame->width == frame->bitmap_width &&
         frame->height == frame->bitmap_height;
}

// Pixel frames only. A cursor-only update is handled without touching the
// backing image.
static inline bool PagaRdpFrameHasValidPixels(const PagaRdpFrameView* frame) {
  if (!frame->rgba || !frame->width || !frame->height ||
      (size_t)frame->width * frame->height > 24000000 ||
      frame->rgba_len != (size_t)frame->bitmap_width * frame->bitmap_height * 4 ||
      frame->tile_count > 8192 || (frame->tile_count && !frame->tiles) ||
      (!frame->tile_count && !PagaRdpFrameIsFull(frame))) {
    return false;
  }
  for (size_t i = 0; i < frame->tile_count; ++i) {
    const PagaRdpTile* tile = &frame->tiles[i];
    if (!tile->width || !tile->height ||
        tile->x + tile->width > frame->width ||
        tile->y + tile->height > frame->height ||
        tile->source_x + tile->width > frame->bitmap_width ||
        tile->source_y + tile->height > frame->bitmap_height) {
      return false;
    }
  }
  return true;
}

#ifdef __cplusplus
}
#endif

#endif  // PAGASHELL_RDP_TEXTURE_H_
