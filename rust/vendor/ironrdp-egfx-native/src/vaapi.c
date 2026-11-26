#include <dlfcn.h>
#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixfmt.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define STRING_IMPL(value) #value
#define STRING(value) STRING_IMPL(value)

#define CODEC_FUNCTIONS(F) \
  F(avcodec_find_decoder) \
  F(avcodec_get_hw_config) \
  F(avcodec_alloc_context3) \
  F(avcodec_open2) \
  F(avcodec_free_context) \
  F(avcodec_flush_buffers) \
  F(avcodec_send_packet) \
  F(avcodec_receive_frame) \
  F(av_packet_alloc) \
  F(av_packet_free) \
  F(av_packet_unref) \
  F(av_new_packet)

#define UTIL_FUNCTIONS(F) \
  F(av_hwdevice_ctx_create) \
  F(av_hwframe_transfer_data) \
  F(av_frame_alloc) \
  F(av_frame_free) \
  F(av_frame_unref)

typedef struct {
  void* codec_library;
  void* util_library;
#define DECLARE(fn) __typeof__(&fn) fn;
  CODEC_FUNCTIONS(DECLARE)
  UTIL_FUNCTIONS(DECLARE)
#undef DECLARE
  AVCodecContext* context;
  AVPacket* packet;
  AVFrame* hardware;
  AVFrame* pixels;
  int64_t timestamp;
} PagaVaapi;

typedef struct {
  const uint8_t* planes[3];
  size_t strides[3];
  size_t width, height;
  bool interleaved_chroma;
} PagaVaapiPicture;

static enum AVPixelFormat select_vaapi(AVCodecContext* context, const enum AVPixelFormat* formats) {
  (void)context;
  for (const enum AVPixelFormat* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
    if (*format == AV_PIX_FMT_VAAPI) return *format;
  }
  return AV_PIX_FMT_NONE;
}

void paga_rdp_vaapi_close(PagaVaapi* decoder) {
  if (!decoder) return;
  if (decoder->packet) decoder->av_packet_free(&decoder->packet);
  if (decoder->hardware) decoder->av_frame_free(&decoder->hardware);
  if (decoder->pixels) decoder->av_frame_free(&decoder->pixels);
  if (decoder->context) decoder->avcodec_free_context(&decoder->context);
  if (decoder->codec_library) dlclose(decoder->codec_library);
  if (decoder->util_library) dlclose(decoder->util_library);
  free(decoder);
}

PagaVaapi* paga_rdp_vaapi_open(void) {
  PagaVaapi* decoder = calloc(1, sizeof(*decoder));
  if (!decoder) return NULL;
  decoder->util_library = dlopen("libavutil.so." STRING(LIBAVUTIL_VERSION_MAJOR), RTLD_NOW | RTLD_LOCAL);
  decoder->codec_library = dlopen("libavcodec.so." STRING(LIBAVCODEC_VERSION_MAJOR), RTLD_NOW | RTLD_LOCAL);
  if (!decoder->codec_library || !decoder->util_library) goto fail;
#define LOAD_CODEC(fn) if (!(decoder->fn = (__typeof__(&fn))dlsym(decoder->codec_library, #fn))) goto fail;
#define LOAD_UTIL(fn) if (!(decoder->fn = (__typeof__(&fn))dlsym(decoder->util_library, #fn))) goto fail;
  CODEC_FUNCTIONS(LOAD_CODEC)
  UTIL_FUNCTIONS(LOAD_UTIL)
#undef LOAD_CODEC
#undef LOAD_UTIL
  const AVCodec* codec = decoder->avcodec_find_decoder(AV_CODEC_ID_H264);
  if (!codec) goto fail;
  for (int i = 0;; ++i) {
    const AVCodecHWConfig* config = decoder->avcodec_get_hw_config(codec, i);
    if (!config) goto fail;
    if (config->device_type == AV_HWDEVICE_TYPE_VAAPI &&
        config->pix_fmt == AV_PIX_FMT_VAAPI &&
        (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) break;
  }
  decoder->context = decoder->avcodec_alloc_context3(codec);
  if (!decoder->context) goto fail;
  if (decoder->av_hwdevice_ctx_create(&decoder->context->hw_device_ctx,
                                      AV_HWDEVICE_TYPE_VAAPI, NULL, NULL, 0) < 0) goto fail;
  decoder->context->get_format = select_vaapi;
  decoder->context->flags |= AV_CODEC_FLAG_LOW_DELAY;
  decoder->context->thread_count = 1;
  decoder->context->max_pixels = 16777216;
  if (decoder->avcodec_open2(decoder->context, codec, NULL) < 0) goto fail;
  decoder->packet = decoder->av_packet_alloc();
  decoder->hardware = decoder->av_frame_alloc();
  decoder->pixels = decoder->av_frame_alloc();
  if (decoder->packet && decoder->hardware && decoder->pixels) return decoder;
fail:
  paga_rdp_vaapi_close(decoder);
  return NULL;
}

bool paga_rdp_vaapi_decode(PagaVaapi* decoder, const uint8_t* input, size_t size,
                          PagaVaapiPicture* result) {
  decoder->av_frame_unref(decoder->pixels);
  decoder->av_packet_unref(decoder->packet);
  if (!size || size > INT32_MAX || decoder->av_new_packet(decoder->packet, (int)size) < 0) return false;
  memcpy(decoder->packet->data, input, size);
  decoder->packet->pts = decoder->packet->dts = ++decoder->timestamp;
  if (decoder->avcodec_send_packet(decoder->context, decoder->packet) < 0) return false;
  decoder->av_packet_unref(decoder->packet);
  for (int i = 0; i < 16; ++i) {
    if (decoder->avcodec_receive_frame(decoder->context, decoder->hardware) < 0) return false;
    if (decoder->hardware->pts == decoder->timestamp) break;
    decoder->av_frame_unref(decoder->hardware);
    if (i == 15) return false;
  }
  const bool va_surface = decoder->hardware->format == AV_PIX_FMT_VAAPI;
  const bool copied = va_surface &&
      decoder->av_hwframe_transfer_data(decoder->pixels, decoder->hardware, 0) == 0;
  decoder->av_frame_unref(decoder->hardware);
  if (!copied) return false;
  AVFrame* frame = decoder->pixels;
  if (frame->width <= 0 || frame->height <= 0 ||
      (int64_t)frame->width * frame->height > 16777216 ||
      frame->width > UINT16_MAX || frame->height > UINT16_MAX) return false;
  const bool nv12 = frame->format == AV_PIX_FMT_NV12;
  if (!nv12 && frame->format != AV_PIX_FMT_YUV420P && frame->format != AV_PIX_FMT_YUVJ420P) return false;
  result->width = (size_t)frame->width;
  result->height = (size_t)frame->height;
  result->interleaved_chroma = nv12;
  const int chroma_width = (frame->width + 1) / 2;
  for (int plane = 0; plane < (nv12 ? 2 : 3); ++plane) {
    const int visible_bytes = plane == 0 ? frame->width : chroma_width * (nv12 ? 2 : 1);
    if (!frame->data[plane] || frame->linesize[plane] < visible_bytes ||
        frame->linesize[plane] > UINT16_MAX) return false;
    result->planes[plane] = frame->data[plane];
    result->strides[plane] = (size_t)frame->linesize[plane];
  }
  return true;
}

void paga_rdp_vaapi_reset(PagaVaapi* decoder) {
  decoder->avcodec_flush_buffers(decoder->context);
  decoder->av_frame_unref(decoder->pixels);
}
