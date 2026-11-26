#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct {
  VTDecompressionSessionRef session;
  CMVideoFormatDescriptionRef format;
  CVPixelBufferRef image;
  int64_t serial;
  OSType pixel_format;
} PagaVideoToolbox;

typedef struct {
  CVPixelBufferRef image;
  const uint8_t* y;
  const uint8_t* uv;
  size_t y_stride, uv_stride, width, height;
} PagaVtPlanes;

static void receive_picture(void* context, void* token, OSStatus status,
                            VTDecodeInfoFlags info, CVImageBufferRef image,
                            CMTime timestamp, CMTime duration) {
  PagaVideoToolbox* decoder = context;
  (void)token;
  (void)info;
  (void)duration;
  // The two consecutive AVC444 views must never be paired with old output.
  if (status == noErr && image && !decoder->image &&
      CMTimeCompare(timestamp, CMTimeMake(decoder->serial, 1000)) == 0) {
    decoder->image = CVPixelBufferRetain(image);
  }
}

bool paga_rdp_vt_supported(void) {
  return VTIsHardwareDecodeSupported(kCMVideoCodecType_H264);
}

void paga_rdp_vt_close(PagaVideoToolbox* decoder) {
  if (!decoder) return;
  if (decoder->session) {
    VTDecompressionSessionInvalidate(decoder->session);
    CFRelease(decoder->session);
  }
  if (decoder->image) CVPixelBufferRelease(decoder->image);
  if (decoder->format) CFRelease(decoder->format);
  free(decoder);
}

PagaVideoToolbox* paga_rdp_vt_open(const uint8_t* sps, size_t sps_size,
                                  const uint8_t* pps, size_t pps_size) {
  const uint8_t* parameters[] = {sps, pps};
  size_t lengths[] = {sps_size, pps_size};
  CMVideoFormatDescriptionRef format = NULL;
  if (CMVideoFormatDescriptionCreateFromH264ParameterSets(
          NULL, 2, parameters, lengths, 4, &format) != noErr) return NULL;
  PagaVideoToolbox* decoder = NULL;
  CFDictionaryRef spec = NULL, output = NULL, iosurface = NULL;
  CFNumberRef pixel_format = NULL;
  CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format);
  if (size.width <= 0 || size.height <= 0 || (int64_t)size.width * size.height > 16777216)
    goto cleanup;
  const void* spec_key = kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder;
  const void* spec_value = kCFBooleanTrue;
  spec = CFDictionaryCreate(NULL, &spec_key, &spec_value, 1, &kCFTypeDictionaryKeyCallBacks,
                            &kCFTypeDictionaryValueCallBacks);
  // EGFX interprets the encoded samples as full range even when the SPS
  // omits its VUI range flag. Ask VideoToolbox for the bitstream's range
  // so it does not rescale the values before the EGFX YUV conversion.
  CFTypeRef range = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_FullRangeVideo);
  const bool full_range = range && CFEqual(range, kCFBooleanTrue);
  const OSType image_format = full_range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  int32_t format_number = (int32_t)image_format;
  pixel_format = CFNumberCreate(NULL, kCFNumberSInt32Type, &format_number);
  iosurface = CFDictionaryCreate(NULL, NULL, NULL, 0, NULL, NULL);
  if (!spec || !pixel_format || !iosurface) goto cleanup;
  const void* keys[] = {
      kCVPixelBufferPixelFormatTypeKey,
      kCVPixelBufferIOSurfacePropertiesKey,
      kCVPixelBufferMetalCompatibilityKey,
  };
  const void* values[] = {pixel_format, iosurface, kCFBooleanTrue};
  output = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
  if (!output) goto cleanup;
  decoder = calloc(1, sizeof(*decoder));
  if (!decoder) goto cleanup;
  VTDecompressionOutputCallbackRecord callback = {receive_picture, decoder};
  if (VTDecompressionSessionCreate(NULL, format, spec, output, &callback, &decoder->session)
      != noErr) {
    paga_rdp_vt_close(decoder);
    decoder = NULL;
  } else {
    decoder->pixel_format = image_format;
    decoder->format = (CMVideoFormatDescriptionRef)CFRetain(format);
    VTSessionSetProperty(decoder->session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
  }
cleanup:
  if (output) CFRelease(output);
  if (iosurface) CFRelease(iosurface);
  if (pixel_format) CFRelease(pixel_format);
  if (spec) CFRelease(spec);
  CFRelease(format);
  return decoder;
}

static CVPixelBufferRef decode_raw_image(PagaVideoToolbox* decoder, const uint8_t* data,
                                         size_t length) {
  CMBlockBufferRef block = NULL;
  CMSampleBufferRef sample = NULL;
  CVPixelBufferRef result = NULL;
  if (decoder->image || length == 0) return NULL;
  if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, length, kCFAllocatorDefault,
                                        NULL, 0, length, kCMBlockBufferAssureMemoryNowFlag, &block) != noErr ||
      CMBlockBufferReplaceDataBytes(data, block, 0, length) != noErr)
    goto cleanup;
  // Request the picture for this sample without temporal reordering.
  decoder->serial++;
  CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(decoder->serial, 1000), kCMTimeInvalid};
  if (CMSampleBufferCreateReady(NULL, block, decoder->format, 1, 1, &timing,
                                1, &length, &sample) != noErr)
    goto cleanup;
  VTDecodeInfoFlags info = 0;
  OSStatus status = VTDecompressionSessionDecodeFrame(decoder->session, sample, 0, NULL, &info);
  OSStatus waited = VTDecompressionSessionWaitForAsynchronousFrames(decoder->session);
  if (status != noErr || waited != noErr) goto cleanup;
  CVPixelBufferRef image = decoder->image;
  if (!image || CVPixelBufferGetPixelFormatType(image) != decoder->pixel_format ||
      CVPixelBufferGetPlaneCount(image) != 2)
    goto cleanup;
  size_t width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image);
  if (!width || !height || width > UINT16_MAX || height > UINT16_MAX ||
      width * height > 16777216)
    goto cleanup;
  result = image;
  decoder->image = NULL;
cleanup:
  if (decoder->image) {
    CVPixelBufferRelease(decoder->image);
    decoder->image = NULL;
  }
  if (sample) CFRelease(sample);
  if (block) CFRelease(block);
  return result;
}

CVPixelBufferRef paga_rdp_vt_decode_pixel_buffer(PagaVideoToolbox* decoder, const uint8_t* data,
                                                 size_t length, size_t* out_width,
                                                 size_t* out_height) {
  CVPixelBufferRef image = decode_raw_image(decoder, data, length);
  if (!image) return NULL;
  *out_width = CVPixelBufferGetWidth(image);
  *out_height = CVPixelBufferGetHeight(image);
  return image;
}

void paga_rdp_vt_release_pixel_buffer(CVPixelBufferRef image) {
  if (image) CVPixelBufferRelease(image);
}

bool paga_rdp_vt_decode(PagaVideoToolbox* decoder, const uint8_t* data, size_t length,
                        PagaVtPlanes* result) {
  CVPixelBufferRef image = decode_raw_image(decoder, data, length);
  if (!image) return false;
  size_t width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image);
  size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0);
  size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(image, 1);
  if (y_stride < width || uv_stride < ((width + 1) / 2) * 2 ||
      y_stride > UINT16_MAX || uv_stride > UINT16_MAX ||
      CVPixelBufferGetHeightOfPlane(image, 0) < height ||
      CVPixelBufferGetHeightOfPlane(image, 1) < (height + 1) / 2 ||
      CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
    CVPixelBufferRelease(image);
    return false;
  }
  const void* y = CVPixelBufferGetBaseAddressOfPlane(image, 0);
  const void* uv = CVPixelBufferGetBaseAddressOfPlane(image, 1);
  if (!y || !uv) {
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(image);
    return false;
  }
  *result = (PagaVtPlanes){image, y, uv, y_stride, uv_stride, width, height};
  return true;
}

void paga_rdp_vt_release_frame(CVPixelBufferRef image) {
  if (!image) return;
  CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(image);
}
