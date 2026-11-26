#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  uint16_t left;
  uint16_t top;
  uint16_t right;
  uint16_t bottom;
} PagaMetalRect;

typedef struct {
  uint16_t x;
  uint16_t y;
} PagaMetalPoint;

static const size_t kMaxBudgetBytes = 256u * 1024u * 1024u;
static const uint32_t kMaxOutputPixels = 16777216u;

static NSString* const kMetalShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct Avc420Params {\n"
"  uint src_x;\n"
"  uint src_y;\n"
"  uint dst_x;\n"
"  uint dst_y;\n"
"  uint width;\n"
"  uint height;\n"
"};\n"
"\n"
"struct Avc444MainParams {\n"
"  uint area_left;\n"
"  uint area_top;\n"
"  uint area_width;\n"
"  uint area_height;\n"
"  uint rect_left;\n"
"  uint rect_top;\n"
"  uint rect_right;\n"
"  uint rect_bottom;\n"
"};\n"
"\n"
"struct Avc444AuxParams {\n"
"  uint area_left;\n"
"  uint area_top;\n"
"  uint area_width;\n"
"  uint area_height;\n"
"  uint half_w;\n"
"  uint quarter_w;\n"
"};\n"
"\n"
"struct RectParams {\n"
"  uint x;\n"
"  uint y;\n"
"  uint width;\n"
"  uint height;\n"
"};\n"
"\n"
"struct SolidFillParams {\n"
"  uint x;\n"
"  uint y;\n"
"  uint width;\n"
"  uint height;\n"
"  float r;\n"
"  float g;\n"
"  float b;\n"
"};\n"
"\n"
"struct BlitScaledParams {\n"
"  uint dst_x;\n"
"  uint dst_y;\n"
"  uint dst_w;\n"
"  uint dst_h;\n"
"  uint src_w;\n"
"  uint src_h;\n"
"};\n"
"\n"
"static inline float4 egfx_yuv_to_rgba(int y, int u, int v) {\n"
"  int luma = 256 * y;\n"
"  int uu = u - 128;\n"
"  int vv = v - 128;\n"
"  int r = clamp((luma + 403 * vv) >> 8, 0, 255);\n"
"  int g = clamp((luma - 48 * uu - 120 * vv) >> 8, 0, 255);\n"
"  int b = clamp((luma + 475 * uu) >> 8, 0, 255);\n"
"  return float4(float(r) / 255.0f, float(g) / 255.0f, float(b) / 255.0f, 1.0f);\n"
"}\n"
"\n"
"static inline int reverse_filter(int avg, int right, int below, int diag) {\n"
"  int rev = clamp(4 * avg - right - below - diag, 0, 255);\n"
"  return abs(rev - avg) < 30 ? avg : rev;\n"
"}\n"
"\n"
"kernel void avc420_to_bgra(\n"
"    texture2d<float, access::read> y_tex [[texture(0)]],\n"
"    texture2d<float, access::read> uv_tex [[texture(1)]],\n"
"    texture2d<float, access::write> dst_tex [[texture(2)]],\n"
"    constant Avc420Params& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.width || gid.y >= p.height) return;\n"
"  uint sx = p.src_x + gid.x;\n"
"  uint sy = p.src_y + gid.y;\n"
"  uint dx = p.dst_x + gid.x;\n"
"  uint dy = p.dst_y + gid.y;\n"
"  if (sx >= y_tex.get_width() || sy >= y_tex.get_height() ||\n"
"      dx >= dst_tex.get_width() || dy >= dst_tex.get_height()) {\n"
"    return;\n"
"  }\n"
"  uint cx = min(sx >> 1, uv_tex.get_width() - 1);\n"
"  uint cy = min(sy >> 1, uv_tex.get_height() - 1);\n"
"  int y = int(round(y_tex.read(uint2(sx, sy)).r * 255.0f));\n"
"  float2 uv = uv_tex.read(uint2(cx, cy)).rg;\n"
"  int u = int(round(uv.x * 255.0f));\n"
"  int v = int(round(uv.y * 255.0f));\n"
"  dst_tex.write(egfx_yuv_to_rgba(y, u, v), uint2(dx, dy));\n"
"}\n"
"\n"
"kernel void avc444_apply_main(\n"
"    texture2d<float, access::read> y_in [[texture(0)]],\n"
"    texture2d<float, access::read> uv_in [[texture(1)]],\n"
"    texture2d<float, access::write> y_out [[texture(2)]],\n"
"    texture2d<float, access::write> u_out [[texture(3)]],\n"
"    texture2d<float, access::write> v_out [[texture(4)]],\n"
"    constant Avc444MainParams& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.area_width || gid.y >= p.area_height) return;\n"
"  uint col = p.area_left + gid.x;\n"
"  uint row = p.area_top + gid.y;\n"
"  if (col >= y_in.get_width() || row >= y_in.get_height() ||\n"
"      col >= y_out.get_width() || row >= y_out.get_height()) {\n"
"    return;\n"
"  }\n"
"  if (col >= p.rect_left && col < p.rect_right &&\n"
"      row >= p.rect_top && row < p.rect_bottom) {\n"
"    float luma = y_in.read(uint2(col, row)).r;\n"
"    y_out.write(float4(luma, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"  }\n"
"  uint cx = min(col >> 1, uv_in.get_width() - 1);\n"
"  uint cy = min(row >> 1, uv_in.get_height() - 1);\n"
"  float2 uv = uv_in.read(uint2(cx, cy)).rg;\n"
"  u_out.write(float4(uv.x, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"  v_out.write(float4(uv.y, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"}\n"
"\n"
"kernel void avc444_apply_aux_v1(\n"
"    texture2d<float, access::read> y_aux [[texture(0)]],\n"
"    texture2d<float, access::read> uv_aux [[texture(1)]],\n"
"    texture2d<float, access::write> u_out [[texture(2)]],\n"
"    texture2d<float, access::write> v_out [[texture(3)]],\n"
"    constant Avc444AuxParams& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.area_width || gid.y >= p.area_height) return;\n"
"  uint col = p.area_left + gid.x;\n"
"  uint row = p.area_top + gid.y;\n"
"  if (col >= u_out.get_width() || row >= u_out.get_height()) return;\n"
"  if ((row & 1u) == 1u) {\n"
"    uint u_row = (row - (row & 15u)) + ((row & 15u) >> 1);\n"
"    uint v_row = u_row + 8u;\n"
"    if (col < y_aux.get_width() && v_row < y_aux.get_height()) {\n"
"      float u_val = y_aux.read(uint2(col, u_row)).r;\n"
"      float v_val = y_aux.read(uint2(col, v_row)).r;\n"
"      u_out.write(float4(u_val, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"      v_out.write(float4(v_val, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"    }\n"
"  } else if ((col & 1u) == 1u) {\n"
"    uint cx = col >> 1;\n"
"    uint cy = row >> 1;\n"
"    if (cx < uv_aux.get_width() && cy < uv_aux.get_height()) {\n"
"      float2 uv = uv_aux.read(uint2(cx, cy)).rg;\n"
"      u_out.write(float4(uv.x, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"      v_out.write(float4(uv.y, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"    }\n"
"  }\n"
"}\n"
"\n"
"kernel void avc444_apply_aux_v2(\n"
"    texture2d<float, access::read> y_aux [[texture(0)]],\n"
"    texture2d<float, access::read> uv_aux [[texture(1)]],\n"
"    texture2d<float, access::write> u_out [[texture(2)]],\n"
"    texture2d<float, access::write> v_out [[texture(3)]],\n"
"    constant Avc444AuxParams& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.area_width || gid.y >= p.area_height) return;\n"
"  uint col = p.area_left + gid.x;\n"
"  uint row = p.area_top + gid.y;\n"
"  if (col >= u_out.get_width() || row >= u_out.get_height()) return;\n"
"  if ((col & 1u) == 1u) {\n"
"    uint ux = col >> 1;\n"
"    uint vx = p.half_w + ux;\n"
"    if (vx < y_aux.get_width() && row < y_aux.get_height()) {\n"
"      float u_val = y_aux.read(uint2(ux, row)).r;\n"
"      float v_val = y_aux.read(uint2(vx, row)).r;\n"
"      u_out.write(float4(u_val, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"      v_out.write(float4(v_val, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"    }\n"
"  } else if ((row & 1u) == 1u) {\n"
"    uint ux = col >> 2;\n"
"    uint vx = p.quarter_w + ux;\n"
"    uint cy = row >> 1;\n"
"    if (vx < uv_aux.get_width() && cy < uv_aux.get_height()) {\n"
"      float u_val, v_val;\n"
"      if ((col & 3u) == 0u) {\n"
"        u_val = uv_aux.read(uint2(ux, cy)).r;\n"
"        v_val = uv_aux.read(uint2(vx, cy)).r;\n"
"      } else {\n"
"        u_val = uv_aux.read(uint2(ux, cy)).g;\n"
"        v_val = uv_aux.read(uint2(vx, cy)).g;\n"
"      }\n"
"      u_out.write(float4(u_val, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"      v_out.write(float4(v_val, 0.0f, 0.0f, 1.0f), uint2(col, row));\n"
"    }\n"
"  }\n"
"}\n"
"\n"
"kernel void avc444_to_bgra(\n"
"    texture2d<float, access::read> y_tex [[texture(0)]],\n"
"    texture2d<float, access::read> u_tex [[texture(1)]],\n"
"    texture2d<float, access::read> v_tex [[texture(2)]],\n"
"    texture2d<float, access::write> dst_tex [[texture(3)]],\n"
"    constant RectParams& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.width || gid.y >= p.height) return;\n"
"  uint col = p.x + gid.x;\n"
"  uint row = p.y + gid.y;\n"
"  if (col >= dst_tex.get_width() || row >= dst_tex.get_height() ||\n"
"      col >= y_tex.get_width() || row >= y_tex.get_height()) {\n"
"    return;\n"
"  }\n"
"  int y = int(round(y_tex.read(uint2(col, row)).r * 255.0f));\n"
"  int u = int(round(u_tex.read(uint2(col, row)).r * 255.0f));\n"
"  int v = int(round(v_tex.read(uint2(col, row)).r * 255.0f));\n"
"  if (((row & 1u) == 0u) && ((col & 1u) == 0u) &&\n"
"      (col + 1u) < u_tex.get_width() && (row + 1u) < u_tex.get_height()) {\n"
"    int ur = int(round(u_tex.read(uint2(col + 1u, row)).r * 255.0f));\n"
"    int ub = int(round(u_tex.read(uint2(col, row + 1u)).r * 255.0f));\n"
"    int ud = int(round(u_tex.read(uint2(col + 1u, row + 1u)).r * 255.0f));\n"
"    u = reverse_filter(u, ur, ub, ud);\n"
"    int vr = int(round(v_tex.read(uint2(col + 1u, row)).r * 255.0f));\n"
"    int vb = int(round(v_tex.read(uint2(col, row + 1u)).r * 255.0f));\n"
"    int vd = int(round(v_tex.read(uint2(col + 1u, row + 1u)).r * 255.0f));\n"
"    v = reverse_filter(v, vr, vb, vd);\n"
"  }\n"
"  dst_tex.write(egfx_yuv_to_rgba(y, u, v), uint2(col, row));\n"
"}\n"
"\n"
"kernel void copy_opaque(\n"
"    texture2d<float, access::read> src_tex [[texture(0)]],\n"
"    texture2d<float, access::write> dst_tex [[texture(1)]],\n"
"    constant RectParams& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.width || gid.y >= p.height) return;\n"
"  uint dx = p.x + gid.x;\n"
"  uint dy = p.y + gid.y;\n"
"  if (dx >= dst_tex.get_width() || dy >= dst_tex.get_height()) return;\n"
"  float4 c = src_tex.read(gid);\n"
"  dst_tex.write(float4(c.rgb, 1.0f), uint2(dx, dy));\n"
"}\n"
"\n"
"kernel void clearcodec_composite(\n"
"    texture2d<float, access::read> src_tex [[texture(0)]],\n"
"    texture2d<float, access::write> dst_tex [[texture(1)]],\n"
"    constant RectParams& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.width || gid.y >= p.height) return;\n"
"  uint dx = p.x + gid.x;\n"
"  uint dy = p.y + gid.y;\n"
"  if (dx >= dst_tex.get_width() || dy >= dst_tex.get_height()) return;\n"
"  float4 c = src_tex.read(gid);\n"
"  if (c.a > 0.0f) {\n"
"    dst_tex.write(float4(c.rgb, 1.0f), uint2(dx, dy));\n"
"  }\n"
"}\n"
"\n"
"kernel void solid_fill(\n"
"    texture2d<float, access::write> dst_tex [[texture(0)]],\n"
"    constant SolidFillParams& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.width || gid.y >= p.height) return;\n"
"  uint dx = p.x + gid.x;\n"
"  uint dy = p.y + gid.y;\n"
"  if (dx >= dst_tex.get_width() || dy >= dst_tex.get_height()) return;\n"
"  dst_tex.write(float4(p.r, p.g, p.b, 1.0f), uint2(dx, dy));\n"
"}\n"
"\n"
"kernel void blit_scaled(\n"
"    texture2d<float, access::sample> src_tex [[texture(0)]],\n"
"    texture2d<float, access::write> dst_tex [[texture(1)]],\n"
"    constant BlitScaledParams& p [[buffer(0)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= p.dst_w || gid.y >= p.dst_h) return;\n"
"  uint dx = p.dst_x + gid.x;\n"
"  uint dy = p.dst_y + gid.y;\n"
"  if (dx >= dst_tex.get_width() || dy >= dst_tex.get_height()) return;\n"
"  constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);\n"
"  float2 uv = float2((float(gid.x) + 0.5f) / float(p.dst_w),\n"
"                     (float(gid.y) + 0.5f) / float(p.dst_h));\n"
"  float4 c = src_tex.sample(s, uv);\n"
"  dst_tex.write(float4(c.rgb, 1.0f), uint2(dx, dy));\n"
"}\n";

@interface PagaMetalSurface : NSObject
@property(nonatomic, assign) uint16_t surfaceId;
@property(nonatomic, assign) uint16_t width;
@property(nonatomic, assign) uint16_t height;
@property(nonatomic, strong) id<MTLTexture> color;
@property(nonatomic, strong) id<MTLTexture> avcY;
@property(nonatomic, strong) id<MTLTexture> avcU;
@property(nonatomic, strong) id<MTLTexture> avcV;
@property(nonatomic, assign) size_t bytes;
@property(nonatomic, assign) BOOL mapped;
@property(nonatomic, assign) uint32_t originX;
@property(nonatomic, assign) uint32_t originY;
@property(nonatomic, assign) uint32_t targetW;
@property(nonatomic, assign) uint32_t targetH;
@property(nonatomic, assign) BOOL painted;
@end

@implementation PagaMetalSurface
@end

@interface PagaMetalCacheEntry : NSObject
@property(nonatomic, assign) uint16_t width;
@property(nonatomic, assign) uint16_t height;
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, assign) size_t bytes;
@end

@implementation PagaMetalCacheEntry
@end

@interface PagaMetalState : NSObject {
 @public
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  CVMetalTextureCacheRef textureCache;
  id<MTLComputePipelineState> avc420Pipe;
  id<MTLComputePipelineState> avc444MainPipe;
  id<MTLComputePipelineState> avc444AuxV1Pipe;
  id<MTLComputePipelineState> avc444AuxV2Pipe;
  id<MTLComputePipelineState> avc444ToBgraPipe;
  id<MTLComputePipelineState> copyOpaquePipe;
  id<MTLComputePipelineState> clearCodecPipe;
  id<MTLComputePipelineState> solidFillPipe;
  id<MTLComputePipelineState> blitScaledPipe;
  NSMutableDictionary<NSNumber*, PagaMetalSurface*>* surfaces;
  NSMutableArray<NSNumber*>* mapOrder;
  NSMutableDictionary<NSNumber*, PagaMetalCacheEntry*>* cache;
  size_t budgetUsed;
  uint16_t outputWidth;
  uint16_t outputHeight;
  CVPixelBufferPoolRef outputPool;
  id<MTLCommandBuffer> pendingCmd;
  BOOL dirty;
}
@end

@implementation PagaMetalState
- (void)dealloc {
  if (pendingCmd) {
    [pendingCmd commit];
    [pendingCmd waitUntilCompleted];
    pendingCmd = nil;
  }
  if (outputPool) {
    CVPixelBufferPoolRelease(outputPool);
    outputPool = NULL;
  }
  if (textureCache) {
    CFRelease(textureCache);
    textureCache = NULL;
  }
}
@end

typedef struct {
  uint32_t src_x, src_y, dst_x, dst_y, width, height;
} Avc420Params;

typedef struct {
  uint32_t area_left, area_top, area_width, area_height;
  uint32_t rect_left, rect_top, rect_right, rect_bottom;
} Avc444MainParams;

typedef struct {
  uint32_t area_left, area_top, area_width, area_height;
  uint32_t half_w, quarter_w;
} Avc444AuxParams;

typedef struct {
  uint32_t x, y, width, height;
} RectParams;

typedef struct {
  uint32_t x, y, width, height;
  float r, g, b;
} SolidFillParams;

typedef struct {
  uint32_t dst_x, dst_y, dst_w, dst_h, src_w, src_h;
} BlitScaledParams;

static id<MTLComputePipelineState> make_pipeline(id<MTLDevice> device, id<MTLLibrary> lib,
                                                 NSString* name) {
  id<MTLFunction> fn = [lib newFunctionWithName:name];
  if (!fn) return nil;
  NSError* err = nil;
  return [device newComputePipelineStateWithFunction:fn error:&err];
}

static void dispatch_2d(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pipe,
                        uint32_t width, uint32_t height) {
  if (width == 0 || height == 0) return;
  MTLSize tg = MTLSizeMake(16, 16, 1);
  MTLSize grid = MTLSizeMake((width + 15u) / 16u, (height + 15u) / 16u, 1);
  [enc setComputePipelineState:pipe];
  [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
}

static id<MTLCommandBuffer> ensure_cmd(PagaMetalState* s) {
  if (!s->pendingCmd) {
    s->pendingCmd = [s->queue commandBuffer];
  }
  return s->pendingCmd;
}

static id<MTLTexture> make_texture(id<MTLDevice> device, MTLPixelFormat fmt,
                                   uint32_t width, uint32_t height, MTLTextureUsage usage,
                                   MTLStorageMode storage) {
  MTLTextureDescriptor* desc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  desc.usage = usage;
  desc.storageMode = storage;
  return [device newTextureWithDescriptor:desc];
}

static bool fill_texture_solid(PagaMetalState* s, id<MTLTexture> tex,
                               uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                               float r, float g, float b) {
  id<MTLCommandBuffer> cmd = ensure_cmd(s);
  if (!cmd) return false;
  id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
  if (!enc) return false;
  SolidFillParams p = {x, y, w, h, r, g, b};
  [enc setTexture:tex atIndex:0];
  [enc setBytes:&p length:sizeof(p) atIndex:0];
  dispatch_2d(enc, s->solidFillPipe, w, h);
  [enc endEncoding];
  return true;
}

static bool wrap_nv12(PagaMetalState* s, CVPixelBufferRef pb,
                      CVMetalTextureRef* out_y, CVMetalTextureRef* out_uv) {
  *out_y = NULL;
  *out_uv = NULL;
  if (!pb || CVPixelBufferGetPlaneCount(pb) != 2) return false;
  size_t y_w = CVPixelBufferGetWidthOfPlane(pb, 0);
  size_t y_h = CVPixelBufferGetHeightOfPlane(pb, 0);
  size_t uv_w = CVPixelBufferGetWidthOfPlane(pb, 1);
  size_t uv_h = CVPixelBufferGetHeightOfPlane(pb, 1);
  if (!y_w || !y_h || !uv_w || !uv_h) return false;
  CVReturn r1 = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, s->textureCache, pb, NULL, MTLPixelFormatR8Unorm, y_w, y_h, 0, out_y);
  CVReturn r2 = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, s->textureCache, pb, NULL, MTLPixelFormatRG8Unorm, uv_w, uv_h, 1, out_uv);
  if (r1 != kCVReturnSuccess || r2 != kCVReturnSuccess || !*out_y || !*out_uv) {
    if (*out_y) CFRelease(*out_y);
    if (*out_uv) CFRelease(*out_uv);
    *out_y = NULL;
    *out_uv = NULL;
    return false;
  }
  return true;
}

static bool ensure_avc444_planes(PagaMetalState* s, PagaMetalSurface* surf) {
  if (surf.avcY && surf.avcU && surf.avcV) return true;
  uint32_t pw = ((uint32_t)surf.width + 15u) & ~15u;
  uint32_t ph = ((uint32_t)surf.height + 15u) & ~15u;
  size_t extra = (size_t)pw * (size_t)ph * 3u;
  if (s->budgetUsed + extra > kMaxBudgetBytes) return false;
  MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> y = make_texture(s->device, MTLPixelFormatR8Unorm, pw, ph, usage, MTLStorageModePrivate);
  id<MTLTexture> u = make_texture(s->device, MTLPixelFormatR8Unorm, pw, ph, usage, MTLStorageModePrivate);
  id<MTLTexture> v = make_texture(s->device, MTLPixelFormatR8Unorm, pw, ph, usage, MTLStorageModePrivate);
  if (!y || !u || !v) return false;
  // Initialize Y=0, U=128/255, V=128/255.
  if (!fill_texture_solid(s, y, 0, 0, pw, ph, 0.0f, 0.0f, 0.0f) ||
      !fill_texture_solid(s, u, 0, 0, pw, ph, 128.0f / 255.0f, 0.0f, 0.0f) ||
      !fill_texture_solid(s, v, 0, 0, pw, ph, 128.0f / 255.0f, 0.0f, 0.0f)) {
    return false;
  }
  surf.avcY = y;
  surf.avcU = u;
  surf.avcV = v;
  surf.bytes += extra;
  s->budgetUsed += extra;
  return true;
}

static void mark_painted(PagaMetalState* s, PagaMetalSurface* surf) {
  surf.painted = YES;
  if (surf.mapped) s->dirty = YES;
}

void* paga_metal_compositor_new(void) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return NULL;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) return NULL;
    CVMetalTextureCacheRef cache = NULL;
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &cache) !=
            kCVReturnSuccess ||
        !cache) {
      return NULL;
    }
    NSError* err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:kMetalShaderSource options:nil error:&err];
    if (!lib) {
      CFRelease(cache);
      return NULL;
    }
    PagaMetalState* s = [[PagaMetalState alloc] init];
    s->device = device;
    s->queue = queue;
    s->textureCache = cache;
    s->avc420Pipe = make_pipeline(device, lib, @"avc420_to_bgra");
    s->avc444MainPipe = make_pipeline(device, lib, @"avc444_apply_main");
    s->avc444AuxV1Pipe = make_pipeline(device, lib, @"avc444_apply_aux_v1");
    s->avc444AuxV2Pipe = make_pipeline(device, lib, @"avc444_apply_aux_v2");
    s->avc444ToBgraPipe = make_pipeline(device, lib, @"avc444_to_bgra");
    s->copyOpaquePipe = make_pipeline(device, lib, @"copy_opaque");
    s->clearCodecPipe = make_pipeline(device, lib, @"clearcodec_composite");
    s->solidFillPipe = make_pipeline(device, lib, @"solid_fill");
    s->blitScaledPipe = make_pipeline(device, lib, @"blit_scaled");
    if (!s->avc420Pipe || !s->avc444MainPipe || !s->avc444AuxV1Pipe ||
        !s->avc444AuxV2Pipe || !s->avc444ToBgraPipe || !s->copyOpaquePipe ||
        !s->clearCodecPipe || !s->solidFillPipe || !s->blitScaledPipe) {
      return NULL;
    }
    s->surfaces = [NSMutableDictionary dictionary];
    s->mapOrder = [NSMutableArray array];
    s->cache = [NSMutableDictionary dictionary];
    s->budgetUsed = 0;
    s->outputWidth = 0;
    s->outputHeight = 0;
    s->outputPool = NULL;
    s->pendingCmd = nil;
    s->dirty = NO;
    return (void*)CFBridgingRetain(s);
  }
}

void paga_metal_compositor_free(void* handle) {
  if (!handle) return;
  @autoreleasepool {
    PagaMetalState* s = (__bridge_transfer PagaMetalState*)handle;
    (void)s;
  }
}

bool paga_metal_compositor_reset(void* handle, uint32_t width, uint32_t height) {
  if (!handle || width == 0 || height == 0 || width > UINT16_MAX || height > UINT16_MAX ||
      (uint64_t)width * (uint64_t)height > kMaxOutputPixels) {
    return false;
  }
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    if (s->pendingCmd) {
      [s->pendingCmd commit];
      [s->pendingCmd waitUntilCompleted];
      s->pendingCmd = nil;
    }
    for (PagaMetalSurface* surf in [s->surfaces allValues]) {
      if (s->budgetUsed >= surf.bytes) s->budgetUsed -= surf.bytes;
    }
    [s->surfaces removeAllObjects];
    [s->mapOrder removeAllObjects];
    s->dirty = NO;
    if (s->outputWidth != (uint16_t)width || s->outputHeight != (uint16_t)height || !s->outputPool) {
      if (s->outputPool) {
        CVPixelBufferPoolRelease(s->outputPool);
        s->outputPool = NULL;
      }
      NSDictionary* attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(width),
        (id)kCVPixelBufferHeightKey : @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
      };
      if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs,
                                  &s->outputPool) != kCVReturnSuccess ||
          !s->outputPool) {
        s->outputWidth = 0;
        s->outputHeight = 0;
        return false;
      }
      s->outputWidth = (uint16_t)width;
      s->outputHeight = (uint16_t)height;
    }
    return true;
  }
}

bool paga_metal_compositor_create_surface(void* handle, uint16_t surface_id, uint16_t width, uint16_t height) {
  if (!handle || width == 0 || height == 0) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    NSNumber* key = @(surface_id);
    PagaMetalSurface* existing = s->surfaces[key];
    if (existing) {
      if (s->budgetUsed >= existing.bytes) s->budgetUsed -= existing.bytes;
      [s->surfaces removeObjectForKey:key];
      [s->mapOrder removeObject:key];
    }
    size_t bytes = (size_t)width * (size_t)height * 4u;
    if (s->budgetUsed + bytes > kMaxBudgetBytes) return false;
    MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> tex =
        make_texture(s->device, MTLPixelFormatBGRA8Unorm, width, height, usage, MTLStorageModePrivate);
    if (!tex) return false;
    if (!fill_texture_solid(s, tex, 0, 0, width, height, 0.0f, 0.0f, 0.0f)) return false;
    PagaMetalSurface* surf = [[PagaMetalSurface alloc] init];
    surf.surfaceId = surface_id;
    surf.width = width;
    surf.height = height;
    surf.color = tex;
    surf.bytes = bytes;
    surf.mapped = NO;
    surf.painted = NO;
    s->surfaces[key] = surf;
    s->budgetUsed += bytes;
    return true;
  }
}

void paga_metal_compositor_delete_surface(void* handle, uint16_t surface_id) {
  if (!handle) return;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    NSNumber* key = @(surface_id);
    PagaMetalSurface* surf = s->surfaces[key];
    if (surf) {
      if (surf.mapped && surf.painted) s->dirty = YES;
      if (s->budgetUsed >= surf.bytes) s->budgetUsed -= surf.bytes;
      [s->surfaces removeObjectForKey:key];
      [s->mapOrder removeObject:key];
    }
  }
}

bool paga_metal_compositor_map_surface(void* handle, uint16_t surface_id, uint32_t origin_x,
                                       uint32_t origin_y, uint32_t target_w, uint32_t target_h) {
  if (!handle) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    NSNumber* key = @(surface_id);
    PagaMetalSurface* surf = s->surfaces[key];
    if (!surf) return false;
    surf.mapped = YES;
    surf.originX = origin_x;
    surf.originY = origin_y;
    surf.targetW = target_w ? target_w : surf.width;
    surf.targetH = target_h ? target_h : surf.height;
    [s->mapOrder removeObject:key];
    [s->mapOrder addObject:key];
    if (surf.painted) s->dirty = YES;
    return true;
  }
}

void paga_metal_compositor_unmap_surface(void* handle, uint16_t surface_id) {
  if (!handle) return;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    NSNumber* key = @(surface_id);
    PagaMetalSurface* surf = s->surfaces[key];
    if (surf && surf.mapped) {
      surf.mapped = NO;
      [s->mapOrder removeObject:key];
      if (surf.painted) s->dirty = YES;
    }
  }
}

bool paga_metal_compositor_apply_avc420(void* handle, uint16_t surface_id, CVPixelBufferRef pb,
                                        PagaMetalRect dest, const PagaMetalRect* rects,
                                        size_t rect_count) {
  if (!handle || !pb) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    PagaMetalSurface* surf = s->surfaces[@(surface_id)];
    if (!surf) return false;
    CVMetalTextureRef yRef = NULL, uvRef = NULL;
    if (!wrap_nv12(s, pb, &yRef, &uvRef)) return false;
    id<MTLTexture> yTex = CVMetalTextureGetTexture(yRef);
    id<MTLTexture> uvTex = CVMetalTextureGetTexture(uvRef);
    id<MTLCommandBuffer> cmd = ensure_cmd(s);
    id<MTLComputeCommandEncoder> enc = cmd ? [cmd computeCommandEncoder] : nil;
    bool ok = false;
    if (yTex && uvTex && enc) {
      [enc setTexture:yTex atIndex:0];
      [enc setTexture:uvTex atIndex:1];
      [enc setTexture:surf.color atIndex:2];
      if (rect_count == 0) {
        if (dest.left < dest.right && dest.top < dest.bottom) {
          uint32_t w = dest.right - dest.left;
          uint32_t h = dest.bottom - dest.top;
          Avc420Params p = {0, 0, dest.left, dest.top, w, h};
          [enc setBytes:&p length:sizeof(p) atIndex:0];
          dispatch_2d(enc, s->avc420Pipe, w, h);
        }
      } else {
        for (size_t i = 0; i < rect_count; ++i) {
          PagaMetalRect r = rects[i];
          if (r.left >= r.right || r.top >= r.bottom) continue;
          uint32_t w = r.right - r.left;
          uint32_t h = r.bottom - r.top;
          Avc420Params p = {r.left, r.top, r.left, r.top, w, h};
          [enc setBytes:&p length:sizeof(p) atIndex:0];
          dispatch_2d(enc, s->avc420Pipe, w, h);
        }
      }
      [enc endEncoding];
      // Keep the VideoToolbox IOSurface alive until the command buffer finishes.
      CVPixelBufferRef retainedPb = CVPixelBufferRetain(pb);
      CVMetalTextureRef retainedY = (CVMetalTextureRef)CFRetain(yRef);
      CVMetalTextureRef retainedUv = (CVMetalTextureRef)CFRetain(uvRef);
      [cmd addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull _cb) {
        (void)_cb;
        CFRelease(retainedUv);
        CFRelease(retainedY);
        CVPixelBufferRelease(retainedPb);
      }];
      mark_painted(s, surf);
      ok = true;
    }
    CFRelease(uvRef);
    CFRelease(yRef);
    return ok;
  }
}

bool paga_metal_compositor_apply_avc444(void* handle, uint16_t surface_id, bool is_v2,
                                        CVPixelBufferRef main_pb, const PagaMetalRect* main_rects,
                                        size_t main_count, CVPixelBufferRef aux_pb,
                                        const PagaMetalRect* aux_rects, size_t aux_count,
                                        const PagaMetalRect* painted, size_t painted_count) {
  if (!handle) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    PagaMetalSurface* surf = s->surfaces[@(surface_id)];
    if (!surf) return false;
    if (!main_pb && (!surf.avcY || !surf.avcU || !surf.avcV)) {
      // Chroma-only update before any luma picture: ignore safely.
      return true;
    }
    if (!ensure_avc444_planes(s, surf)) return false;

    id<MTLCommandBuffer> cmd = ensure_cmd(s);
    if (!cmd) return false;

    if (main_pb && main_count > 0) {
      CVMetalTextureRef yRef = NULL, uvRef = NULL;
      if (!wrap_nv12(s, main_pb, &yRef, &uvRef)) return false;
      id<MTLTexture> yTex = CVMetalTextureGetTexture(yRef);
      id<MTLTexture> uvTex = CVMetalTextureGetTexture(uvRef);
      id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
      if (!yTex || !uvTex || !enc) {
        CFRelease(uvRef);
        CFRelease(yRef);
        return false;
      }
      [enc setTexture:yTex atIndex:0];
      [enc setTexture:uvTex atIndex:1];
      [enc setTexture:surf.avcY atIndex:2];
      [enc setTexture:surf.avcU atIndex:3];
      [enc setTexture:surf.avcV atIndex:4];
      for (size_t i = 0; i < main_count; ++i) {
        PagaMetalRect r = main_rects[i];
        uint32_t left = (uint32_t)r.left & ~1u;
        uint32_t top = (uint32_t)r.top & ~1u;
        uint32_t right = (((uint32_t)(r.right < surf.width ? r.right : surf.width) + 1u) & ~1u);
        uint32_t bottom = (((uint32_t)(r.bottom < surf.height ? r.bottom : surf.height) + 1u) & ~1u);
        if (left >= right || top >= bottom) continue;
        Avc444MainParams p = {
            left,
            top,
            right - left,
            bottom - top,
            r.left,
            r.top,
            r.right < surf.width ? r.right : surf.width,
            r.bottom < surf.height ? r.bottom : surf.height,
        };
        [enc setBytes:&p length:sizeof(p) atIndex:0];
        dispatch_2d(enc, s->avc444MainPipe, p.area_width, p.area_height);
      }
      [enc endEncoding];
      CVPixelBufferRef retainedPb = CVPixelBufferRetain(main_pb);
      CVMetalTextureRef retainedY = (CVMetalTextureRef)CFRetain(yRef);
      CVMetalTextureRef retainedUv = (CVMetalTextureRef)CFRetain(uvRef);
      [cmd addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull _cb) {
        (void)_cb;
        CFRelease(retainedUv);
        CFRelease(retainedY);
        CVPixelBufferRelease(retainedPb);
      }];
      CFRelease(uvRef);
      CFRelease(yRef);
    }

    if (aux_pb && aux_count > 0) {
      CVMetalTextureRef yRef = NULL, uvRef = NULL;
      if (!wrap_nv12(s, aux_pb, &yRef, &uvRef)) return false;
      id<MTLTexture> yTex = CVMetalTextureGetTexture(yRef);
      id<MTLTexture> uvTex = CVMetalTextureGetTexture(uvRef);
      id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
      if (!yTex || !uvTex || !enc) {
        CFRelease(uvRef);
        CFRelease(yRef);
        return false;
      }
      uint32_t padded_w = (((uint32_t)CVPixelBufferGetWidth(aux_pb) + 15u) & ~15u);
      uint32_t half_w = padded_w >> 1;
      uint32_t quarter_w = half_w >> 1;
      [enc setTexture:yTex atIndex:0];
      [enc setTexture:uvTex atIndex:1];
      [enc setTexture:surf.avcU atIndex:2];
      [enc setTexture:surf.avcV atIndex:3];
      id<MTLComputePipelineState> pipe = is_v2 ? s->avc444AuxV2Pipe : s->avc444AuxV1Pipe;
      for (size_t i = 0; i < aux_count; ++i) {
        PagaMetalRect r = aux_rects[i];
        uint32_t left = (uint32_t)r.left & ~1u;
        uint32_t top = (uint32_t)r.top & ~1u;
        uint32_t right = (((uint32_t)(r.right < surf.width ? r.right : surf.width) + 1u) & ~1u);
        uint32_t bottom = (((uint32_t)(r.bottom < surf.height ? r.bottom : surf.height) + 1u) & ~1u);
        if (left >= right || top >= bottom) continue;
        Avc444AuxParams p = {left, top, right - left, bottom - top, half_w, quarter_w};
        [enc setBytes:&p length:sizeof(p) atIndex:0];
        dispatch_2d(enc, pipe, p.area_width, p.area_height);
      }
      [enc endEncoding];
      CVPixelBufferRef retainedPb = CVPixelBufferRetain(aux_pb);
      CVMetalTextureRef retainedY = (CVMetalTextureRef)CFRetain(yRef);
      CVMetalTextureRef retainedUv = (CVMetalTextureRef)CFRetain(uvRef);
      [cmd addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull _cb) {
        (void)_cb;
        CFRelease(retainedUv);
        CFRelease(retainedY);
        CVPixelBufferRelease(retainedPb);
      }];
      CFRelease(uvRef);
      CFRelease(yRef);
    }

    if (painted_count > 0) {
      id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
      if (!enc) return false;
      [enc setTexture:surf.avcY atIndex:0];
      [enc setTexture:surf.avcU atIndex:1];
      [enc setTexture:surf.avcV atIndex:2];
      [enc setTexture:surf.color atIndex:3];
      for (size_t i = 0; i < painted_count; ++i) {
        PagaMetalRect r = painted[i];
        uint32_t right = r.right < surf.width ? r.right : surf.width;
        uint32_t bottom = r.bottom < surf.height ? r.bottom : surf.height;
        if (r.left >= right || r.top >= bottom) continue;
        RectParams p = {r.left, r.top, right - r.left, bottom - r.top};
        [enc setBytes:&p length:sizeof(p) atIndex:0];
        dispatch_2d(enc, s->avc444ToBgraPipe, p.width, p.height);
      }
      [enc endEncoding];
      mark_painted(s, surf);
    }
    return true;
  }
}

static bool upload_patch_with_pipe(PagaMetalState* s, PagaMetalSurface* surf, PagaMetalRect dest,
                                   const uint8_t* pixels, size_t pitch, uint16_t src_x,
                                   uint16_t src_y, MTLPixelFormat src_fmt,
                                   id<MTLComputePipelineState> pipe) {
  uint32_t right = dest.right < surf.width ? dest.right : surf.width;
  uint32_t bottom = dest.bottom < surf.height ? dest.bottom : surf.height;
  if (dest.left >= right || dest.top >= bottom) return true;
  uint32_t w = right - dest.left;
  uint32_t h = bottom - dest.top;
  id<MTLTexture> staging = make_texture(s->device, src_fmt, w, h, MTLTextureUsageShaderRead,
                                        MTLStorageModeShared);
  if (!staging) return false;
  const uint8_t* origin = pixels + (size_t)src_y * pitch + (size_t)src_x * 4u;
  [staging replaceRegion:MTLRegionMake2D(0, 0, w, h)
             mipmapLevel:0
               withBytes:origin
             bytesPerRow:pitch];
  id<MTLCommandBuffer> cmd = ensure_cmd(s);
  if (!cmd) return false;
  id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
  if (!enc) return false;
  RectParams p = {dest.left, dest.top, w, h};
  [enc setTexture:staging atIndex:0];
  [enc setTexture:surf.color atIndex:1];
  [enc setBytes:&p length:sizeof(p) atIndex:0];
  dispatch_2d(enc, pipe, w, h);
  [enc endEncoding];
  mark_painted(s, surf);
  return true;
}

bool paga_metal_compositor_apply_rgba(void* handle, uint16_t surface_id, PagaMetalRect dest,
                                      const uint8_t* rgba, size_t pitch, uint16_t src_x,
                                      uint16_t src_y) {
  if (!handle || !rgba) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    PagaMetalSurface* surf = s->surfaces[@(surface_id)];
    if (!surf) return false;
    return upload_patch_with_pipe(s, surf, dest, rgba, pitch, src_x, src_y,
                                  MTLPixelFormatRGBA8Unorm, s->copyOpaquePipe);
  }
}

bool paga_metal_compositor_apply_clearcodec(void* handle, uint16_t surface_id, PagaMetalRect dest,
                                            const uint8_t* bgra_coverage) {
  if (!handle || !bgra_coverage) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    PagaMetalSurface* surf = s->surfaces[@(surface_id)];
    if (!surf) return false;
    if (dest.left >= dest.right || dest.top >= dest.bottom) return true;
    size_t pitch = (size_t)(dest.right - dest.left) * 4u;
    return upload_patch_with_pipe(s, surf, dest, bgra_coverage, pitch, 0, 0,
                                  MTLPixelFormatBGRA8Unorm, s->clearCodecPipe);
  }
}

bool paga_metal_compositor_solid_fill(void* handle, uint16_t surface_id, uint8_t r, uint8_t g, uint8_t b,
                                      const PagaMetalRect* rects, size_t rect_count) {
  if (!handle) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    PagaMetalSurface* surf = s->surfaces[@(surface_id)];
    if (!surf) return false;
    float rf = (float)r / 255.0f;
    float gf = (float)g / 255.0f;
    float bf = (float)b / 255.0f;
    for (size_t i = 0; i < rect_count; ++i) {
      PagaMetalRect rect = rects[i];
      uint32_t right = rect.right < surf.width ? rect.right : surf.width;
      uint32_t bottom = rect.bottom < surf.height ? rect.bottom : surf.height;
      if (rect.left >= right || rect.top >= bottom) continue;
      if (!fill_texture_solid(s, surf.color, rect.left, rect.top, right - rect.left,
                              bottom - rect.top, rf, gf, bf)) {
        return false;
      }
      mark_painted(s, surf);
    }
    return true;
  }
}

bool paga_metal_compositor_surface_to_surface(void* handle, uint16_t src_id, uint16_t dst_id,
                                              PagaMetalRect src_rect, const PagaMetalPoint* dsts,
                                              size_t dst_count) {
  if (!handle) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    PagaMetalSurface* src = s->surfaces[@(src_id)];
    PagaMetalSurface* dst = s->surfaces[@(dst_id)];
    if (!src || !dst) return false;
    uint32_t sr = src_rect.right < src.width ? src_rect.right : src.width;
    uint32_t sb = src_rect.bottom < src.height ? src_rect.bottom : src.height;
    if (src_rect.left >= sr || src_rect.top >= sb || dst_count == 0) return true;
    uint32_t w = sr - src_rect.left;
    uint32_t h = sb - src_rect.top;
    id<MTLCommandBuffer> cmd = ensure_cmd(s);
    if (!cmd) return false;
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    if (!blit) return false;

    id<MTLTexture> copySrc = src.color;
    uint32_t copySrcX = src_rect.left;
    uint32_t copySrcY = src_rect.top;
    if (src_id == dst_id) {
      id<MTLTexture> scratch =
          make_texture(s->device, MTLPixelFormatBGRA8Unorm, w, h,
                       MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, MTLStorageModePrivate);
      if (!scratch) {
        [blit endEncoding];
        return false;
      }
      [blit copyFromTexture:src.color
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(src_rect.left, src_rect.top, 0)
                 sourceSize:MTLSizeMake(w, h, 1)
                  toTexture:scratch
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
      copySrc = scratch;
      copySrcX = 0;
      copySrcY = 0;
    }
    for (size_t i = 0; i < dst_count; ++i) {
      uint32_t dx = dsts[i].x;
      uint32_t dy = dsts[i].y;
      if (dx >= dst.width || dy >= dst.height) continue;
      uint32_t cw = w < (dst.width - dx) ? w : (dst.width - dx);
      uint32_t ch = h < (dst.height - dy) ? h : (dst.height - dy);
      if (cw == 0 || ch == 0) continue;
      [blit copyFromTexture:copySrc
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(copySrcX, copySrcY, 0)
                 sourceSize:MTLSizeMake(cw, ch, 1)
                  toTexture:dst.color
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(dx, dy, 0)];
    }
    [blit endEncoding];
    mark_painted(s, dst);
    return true;
  }
}

bool paga_metal_compositor_surface_to_cache(void* handle, uint16_t surface_id, uint16_t slot,
                                            PagaMetalRect src_rect) {
  if (!handle) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    PagaMetalSurface* src = s->surfaces[@(surface_id)];
    if (!src) return false;
    uint32_t sr = src_rect.right < src.width ? src_rect.right : src.width;
    uint32_t sb = src_rect.bottom < src.height ? src_rect.bottom : src.height;
    if (src_rect.left >= sr || src_rect.top >= sb) return false;
    uint32_t w = sr - src_rect.left;
    uint32_t h = sb - src_rect.top;
    NSNumber* key = @(slot);
    PagaMetalCacheEntry* prev = s->cache[key];
    if (prev) {
      if (s->budgetUsed >= prev.bytes) s->budgetUsed -= prev.bytes;
      [s->cache removeObjectForKey:key];
    }
    size_t bytes = (size_t)w * (size_t)h * 4u;
    if (s->budgetUsed + bytes > kMaxBudgetBytes) return false;
    id<MTLTexture> tex =
        make_texture(s->device, MTLPixelFormatBGRA8Unorm, w, h, MTLTextureUsageShaderRead,
                     MTLStorageModePrivate);
    if (!tex) return false;
    id<MTLCommandBuffer> cmd = ensure_cmd(s);
    if (!cmd) return false;
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    if (!blit) return false;
    [blit copyFromTexture:src.color
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(src_rect.left, src_rect.top, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                toTexture:tex
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    PagaMetalCacheEntry* entry = [[PagaMetalCacheEntry alloc] init];
    entry.width = (uint16_t)w;
    entry.height = (uint16_t)h;
    entry.texture = tex;
    entry.bytes = bytes;
    s->cache[key] = entry;
    s->budgetUsed += bytes;
    return true;
  }
}

bool paga_metal_compositor_cache_to_surface(void* handle, uint16_t slot, uint16_t surface_id,
                                            const PagaMetalPoint* dsts, size_t dst_count) {
  if (!handle) return false;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    PagaMetalCacheEntry* entry = s->cache[@(slot)];
    PagaMetalSurface* dst = s->surfaces[@(surface_id)];
    if (!entry || !dst) return false;
    if (dst_count == 0) return true;
    id<MTLCommandBuffer> cmd = ensure_cmd(s);
    if (!cmd) return false;
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    if (!blit) return false;
    for (size_t i = 0; i < dst_count; ++i) {
      uint32_t dx = dsts[i].x;
      uint32_t dy = dsts[i].y;
      if (dx >= dst.width || dy >= dst.height) continue;
      uint32_t cw = entry.width < (dst.width - dx) ? entry.width : (dst.width - dx);
      uint32_t ch = entry.height < (dst.height - dy) ? entry.height : (dst.height - dy);
      if (cw == 0 || ch == 0) continue;
      [blit copyFromTexture:entry.texture
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(cw, ch, 1)
                  toTexture:dst.color
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(dx, dy, 0)];
    }
    [blit endEncoding];
    mark_painted(s, dst);
    return true;
  }
}

void paga_metal_compositor_evict_cache(void* handle, uint16_t slot) {
  if (!handle) return;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    NSNumber* key = @(slot);
    PagaMetalCacheEntry* entry = s->cache[key];
    if (entry) {
      if (s->budgetUsed >= entry.bytes) s->budgetUsed -= entry.bytes;
      [s->cache removeObjectForKey:key];
    }
  }
}

CVPixelBufferRef paga_metal_compositor_end_frame(void* handle, uint16_t* out_width,
                                                 uint16_t* out_height) {
  if (!handle) return NULL;
  @autoreleasepool {
    PagaMetalState* s = (__bridge PagaMetalState*)handle;
    if (!s->dirty || !s->outputPool || s->outputWidth == 0 || s->outputHeight == 0) {
      if (s->pendingCmd) {
        [s->pendingCmd commit];
        [s->pendingCmd waitUntilCompleted];
        s->pendingCmd = nil;
      }
      return NULL;
    }
    NSDictionary* aux = @{(id)kCVPixelBufferPoolAllocationThresholdKey : @(5)};
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, s->outputPool, (__bridge CFDictionaryRef)aux, &pb) !=
            kCVReturnSuccess ||
        !pb) {
      return NULL;
    }
    CVMetalTextureRef outTexRef = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, s->textureCache, pb, NULL, MTLPixelFormatBGRA8Unorm,
            s->outputWidth, s->outputHeight, 0, &outTexRef) != kCVReturnSuccess ||
        !outTexRef) {
      CVPixelBufferRelease(pb);
      return NULL;
    }
    id<MTLTexture> outTex = CVMetalTextureGetTexture(outTexRef);
    id<MTLCommandBuffer> cmd = ensure_cmd(s);
    if (!outTex || !cmd) {
      CFRelease(outTexRef);
      CVPixelBufferRelease(pb);
      return NULL;
    }

    // Fast path: single unscaled mapped surface covering the entire output.
    BOOL fastCovered = NO;
    if (s->mapOrder.count == 1) {
      PagaMetalSurface* only = s->surfaces[s->mapOrder[0]];
      if (only && only.mapped && only.originX == 0 && only.originY == 0 &&
          only.width == s->outputWidth && only.height == s->outputHeight &&
          only.targetW == s->outputWidth && only.targetH == s->outputHeight) {
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromTexture:only.color
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(s->outputWidth, s->outputHeight, 1)
                    toTexture:outTex
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        fastCovered = YES;
      }
    }

    if (!fastCovered) {
      fill_texture_solid(s, outTex, 0, 0, s->outputWidth, s->outputHeight, 0.0f, 0.0f, 0.0f);
      for (NSNumber* key in s->mapOrder) {
        PagaMetalSurface* surf = s->surfaces[key];
        if (!surf || !surf.mapped) continue;
        if (surf.originX >= s->outputWidth || surf.originY >= s->outputHeight) continue;
        if (surf.targetW == surf.width && surf.targetH == surf.height) {
          uint32_t cw = surf.width < (s->outputWidth - surf.originX)
                            ? surf.width
                            : (s->outputWidth - surf.originX);
          uint32_t ch = surf.height < (s->outputHeight - surf.originY)
                            ? surf.height
                            : (s->outputHeight - surf.originY);
          if (cw == 0 || ch == 0) continue;
          id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
          [blit copyFromTexture:surf.color
                    sourceSlice:0
                    sourceLevel:0
                   sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(cw, ch, 1)
                      toTexture:outTex
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(surf.originX, surf.originY, 0)];
          [blit endEncoding];
        } else {
          id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
          BlitScaledParams p = {
              surf.originX, surf.originY, surf.targetW, surf.targetH, surf.width, surf.height,
          };
          [enc setTexture:surf.color atIndex:0];
          [enc setTexture:outTex atIndex:1];
          [enc setBytes:&p length:sizeof(p) atIndex:0];
          dispatch_2d(enc, s->blitScaledPipe, surf.targetW, surf.targetH);
          [enc endEncoding];
        }
      }
    }

    [cmd commit];
    [cmd waitUntilCompleted];
    BOOL failed = (cmd.status == MTLCommandBufferStatusError);
    s->pendingCmd = nil;
    CFRelease(outTexRef);
    CVMetalTextureCacheFlush(s->textureCache, 0);
    if (failed) {
      CVPixelBufferRelease(pb);
      return NULL;
    }
    s->dirty = NO;
    *out_width = s->outputWidth;
    *out_height = s->outputHeight;
    return pb;
  }
}
