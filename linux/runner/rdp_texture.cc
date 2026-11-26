#include "rdp_texture.h"
#include "../../rust/include/rdp_texture.h"

#include <dlfcn.h>

#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace {
// Standard OpenGL / OpenGL ES constants (identical values across GL and GLES).
constexpr uint32_t kGlTexture2d = 0x0DE1;
constexpr uint32_t kGlRgba = 0x1908;
constexpr uint32_t kGlUnsignedByte = 0x1401;
constexpr uint32_t kGlTextureMinFilter = 0x2801;
constexpr uint32_t kGlTextureMagFilter = 0x2800;
constexpr uint32_t kGlTextureWrapS = 0x2802;
constexpr uint32_t kGlTextureWrapT = 0x2803;
constexpr int32_t kGlLinear = 0x2601;
constexpr int32_t kGlClampToEdge = 0x812F;
constexpr uint32_t kGlUnpackAlignment = 0x0CF5;
constexpr size_t kMaxPendingGlPatches = 12;

struct GlProcs {
  using GenTexturesFn = void (*)(int32_t, uint32_t*);
  using DeleteTexturesFn = void (*)(int32_t, const uint32_t*);
  using BindTextureFn = void (*)(uint32_t, uint32_t);
  using TexParameteriFn = void (*)(uint32_t, uint32_t, int32_t);
  using PixelStoreiFn = void (*)(uint32_t, int32_t);
  using TexImage2DFn = void (*)(uint32_t, int32_t, int32_t, int32_t, int32_t,
                                int32_t, uint32_t, uint32_t, const void*);
  using TexSubImage2DFn = void (*)(uint32_t, int32_t, int32_t, int32_t, int32_t,
                                   int32_t, uint32_t, uint32_t, const void*);

  GenTexturesFn gen_textures = nullptr;
  DeleteTexturesFn delete_textures = nullptr;
  BindTextureFn bind_texture = nullptr;
  TexParameteriFn tex_parameteri = nullptr;
  PixelStoreiFn pixel_storei = nullptr;
  TexImage2DFn tex_image_2d = nullptr;
  TexSubImage2DFn tex_sub_image_2d = nullptr;

  bool valid() const {
    return gen_textures && delete_textures && bind_texture && tex_parameteri &&
           pixel_storei && tex_image_2d && tex_sub_image_2d;
  }
};

const GlProcs& LoadGlProcs() {
  static const GlProcs procs = [] {
    GlProcs p{};
    p.gen_textures =
        reinterpret_cast<GlProcs::GenTexturesFn>(dlsym(RTLD_DEFAULT, "glGenTextures"));
    p.delete_textures = reinterpret_cast<GlProcs::DeleteTexturesFn>(
        dlsym(RTLD_DEFAULT, "glDeleteTextures"));
    p.bind_texture =
        reinterpret_cast<GlProcs::BindTextureFn>(dlsym(RTLD_DEFAULT, "glBindTexture"));
    p.tex_parameteri = reinterpret_cast<GlProcs::TexParameteriFn>(
        dlsym(RTLD_DEFAULT, "glTexParameteri"));
    p.pixel_storei =
        reinterpret_cast<GlProcs::PixelStoreiFn>(dlsym(RTLD_DEFAULT, "glPixelStorei"));
    p.tex_image_2d =
        reinterpret_cast<GlProcs::TexImage2DFn>(dlsym(RTLD_DEFAULT, "glTexImage2D"));
    p.tex_sub_image_2d = reinterpret_cast<GlProcs::TexSubImage2DFn>(
        dlsym(RTLD_DEFAULT, "glTexSubImage2D"));
    return p;
  }();
  return procs;
}

// ============================================================================
// Incremental FlTextureGL backend (avoids full-frame CPU clones & GL uploads)
// ============================================================================

struct TilePatch {
  uint16_t x = 0;
  uint16_t y = 0;
  uint16_t width = 0;
  uint16_t height = 0;
  std::vector<uint8_t> rgba;
};

struct GlFramePatch {
  uint16_t width = 0;
  uint16_t height = 0;
  bool full = false;
  std::vector<uint8_t> full_rgba;
  std::vector<TilePatch> tiles;
};

struct GlTextureState {
  std::mutex mutex;
  std::deque<GlFramePatch> pending;
  uint16_t logical_width = 0;
  uint16_t logical_height = 0;
  uint32_t gl_texture = 0;
  uint16_t gl_width = 0;
  uint16_t gl_height = 0;
  FlTextureRegistrar* registrar = nullptr;
  bool closed = false;
  bool notification_pending = false;
};

struct PagaRdpGlTexture {
  FlTextureGL parent_instance;
  GlTextureState* state;
};
using PagaRdpGlTextureClass = FlTextureGLClass;
G_DEFINE_TYPE(PagaRdpGlTexture, paga_rdp_gl_texture, fl_texture_gl_get_type())

gboolean PopulateGl(FlTextureGL* texture, uint32_t* target, uint32_t* name,
                    uint32_t* width, uint32_t* height, GError** error) {
  auto& state = *reinterpret_cast<PagaRdpGlTexture*>(texture)->state;
  const auto& gl = LoadGlProcs();
  if (!gl.valid()) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                        "OpenGL symbols unavailable");
    return FALSE;
  }

  std::deque<GlFramePatch> batch;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.closed || (state.gl_texture == 0 && state.pending.empty())) {
      g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_CLOSED,
                          "RDP GL texture unavailable");
      return FALSE;
    }
    batch.swap(state.pending);
  }

  if (state.gl_texture == 0) {
    gl.gen_textures(1, &state.gl_texture);
    if (state.gl_texture == 0) {
      g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                          "Failed to create GL texture");
      return FALSE;
    }
    gl.bind_texture(kGlTexture2d, state.gl_texture);
    gl.tex_parameteri(kGlTexture2d, kGlTextureMinFilter, kGlLinear);
    gl.tex_parameteri(kGlTexture2d, kGlTextureMagFilter, kGlLinear);
    gl.tex_parameteri(kGlTexture2d, kGlTextureWrapS, kGlClampToEdge);
    gl.tex_parameteri(kGlTexture2d, kGlTextureWrapT, kGlClampToEdge);
  } else if (!batch.empty()) {
    gl.bind_texture(kGlTexture2d, state.gl_texture);
  }

  if (!batch.empty()) {
    gl.pixel_storei(kGlUnpackAlignment, 1);
    for (const auto& patch : batch) {
      if (patch.full) {
        if (state.gl_width != patch.width || state.gl_height != patch.height) {
          gl.tex_image_2d(kGlTexture2d, 0, kGlRgba, patch.width, patch.height,
                          0, kGlRgba, kGlUnsignedByte, patch.full_rgba.data());
          state.gl_width = patch.width;
          state.gl_height = patch.height;
        } else {
          gl.tex_sub_image_2d(kGlTexture2d, 0, 0, 0, patch.width, patch.height,
                              kGlRgba, kGlUnsignedByte, patch.full_rgba.data());
        }
      } else if (state.gl_width == patch.width && state.gl_height == patch.height) {
        for (const auto& tile : patch.tiles) {
          gl.tex_sub_image_2d(kGlTexture2d, 0, tile.x, tile.y, tile.width,
                              tile.height, kGlRgba, kGlUnsignedByte,
                              tile.rgba.data());
        }
      }
    }
  }

  if (state.gl_width == 0 || state.gl_height == 0) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_CLOSED,
                        "RDP GL texture has no content");
    return FALSE;
  }

  *target = kGlTexture2d;
  *name = state.gl_texture;
  *width = state.gl_width;
  *height = state.gl_height;
  return TRUE;
}

void paga_rdp_gl_texture_class_init(PagaRdpGlTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = PopulateGl;
  G_OBJECT_CLASS(klass)->finalize = [](GObject* object) {
    delete reinterpret_cast<PagaRdpGlTexture*>(object)->state;
    G_OBJECT_CLASS(paga_rdp_gl_texture_parent_class)->finalize(object);
  };
}

void paga_rdp_gl_texture_init(PagaRdpGlTexture* texture) {
  texture->state = new GlTextureState();
}

gboolean MarkGlFrame(gpointer data) {
  auto* texture = static_cast<PagaRdpGlTexture*>(data);
  auto& state = *texture->state;
  FlTextureRegistrar* registrar = nullptr;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
    state.notification_pending = false;
    if (!state.closed) registrar = state.registrar;
  }
  if (registrar) {
    fl_texture_registrar_mark_texture_frame_available(registrar, FL_TEXTURE(texture));
  }
  return G_SOURCE_REMOVE;
}

bool SubmitGl(void* context, const PagaRdpFrameView* frame) {
  auto* texture = static_cast<PagaRdpGlTexture*>(context);
  auto& state = *texture->state;
  std::lock_guard<std::mutex> lock(state.mutex);
  if (state.closed) return false;
  if (frame->rgba_len == 0) return state.logical_width != 0;
  if (!PagaRdpFrameHasValidPixels(frame)) return false;
  const bool full = PagaRdpFrameIsFull(frame);
  const bool resized =
      state.logical_width != frame->width || state.logical_height != frame->height;
  if (resized && !full) return false;
  if (!full && state.pending.size() >= kMaxPendingGlPatches) {
    // Request a fresh full base if the raster thread falls far behind.
    return false;
  }
  try {
    GlFramePatch patch;
    patch.width = frame->width;
    patch.height = frame->height;
    patch.full = full;
    if (full) {
      patch.full_rgba.assign(frame->rgba, frame->rgba + frame->rgba_len);
      state.pending.clear();
    } else {
      patch.tiles.reserve(frame->tile_count);
      const size_t src_stride = size_t{frame->bitmap_width} * 4;
      for (size_t i = 0; i < frame->tile_count; ++i) {
        const auto& tile = frame->tiles[i];
        TilePatch packed;
        packed.x = tile.x;
        packed.y = tile.y;
        packed.width = tile.width;
        packed.height = tile.height;
        const size_t row_bytes = size_t{tile.width} * 4;
        packed.rgba.resize(row_bytes * tile.height);
        for (size_t row = 0; row < tile.height; ++row) {
          std::memcpy(packed.rgba.data() + row * row_bytes,
                      frame->rgba + (tile.source_y + row) * src_stride +
                          tile.source_x * 4,
                      row_bytes);
        }
        patch.tiles.push_back(std::move(packed));
      }
    }
    state.logical_width = frame->width;
    state.logical_height = frame->height;
    state.pending.push_back(std::move(patch));
  } catch (const std::bad_alloc&) {
    return false;
  }
  if (!state.notification_pending) {
    state.notification_pending = true;
    g_idle_add_full(G_PRIORITY_DEFAULT, MarkGlFrame, g_object_ref(texture),
                    g_object_unref);
  }
  return true;
}

// ============================================================================
// FlPixelBufferTexture fallback (when GL symbols are not dynamically exported)
// ============================================================================

struct Pixels {
  uint16_t width = 0, height = 0;
  std::vector<uint8_t> rgba;
};

struct TextureState {
  std::mutex mutex;
  std::shared_ptr<Pixels> latest;
  std::shared_ptr<Pixels> raster;
  // Used only on the GTK thread. Owned by the registrar's registry below.
  FlTextureRegistrar* registrar = nullptr;
  bool closed = false;
  bool notification_pending = false;
};

struct PagaRdpTexture {
  FlPixelBufferTexture parent_instance;
  TextureState* state;
};
using PagaRdpTextureClass = FlPixelBufferTextureClass;
G_DEFINE_TYPE(PagaRdpTexture, paga_rdp_texture, fl_pixel_buffer_texture_get_type())

gboolean CopyPixels(FlPixelBufferTexture* texture, const uint8_t** buffer,
                    uint32_t* width, uint32_t* height, GError** error) {
  auto& state = *reinterpret_cast<PagaRdpTexture*>(texture)->state;
  std::lock_guard<std::mutex> lock(state.mutex);
  if (state.closed || !state.latest) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_CLOSED, "RDP texture unavailable");
    return FALSE;
  }
  state.raster = state.latest;
  *buffer = state.raster->rgba.data();
  *width = state.raster->width;
  *height = state.raster->height;
  return TRUE;
}

void paga_rdp_texture_class_init(PagaRdpTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = CopyPixels;
  G_OBJECT_CLASS(klass)->finalize = [](GObject* object) {
    delete reinterpret_cast<PagaRdpTexture*>(object)->state;
    G_OBJECT_CLASS(paga_rdp_texture_parent_class)->finalize(object);
  };
}

void paga_rdp_texture_init(PagaRdpTexture* texture) {
  texture->state = new TextureState();
}

gboolean MarkFrame(gpointer data) {
  auto* texture = static_cast<PagaRdpTexture*>(data);
  auto& state = *texture->state;
  FlTextureRegistrar* registrar = nullptr;
  {
    std::lock_guard<std::mutex> lock(state.mutex);
    state.notification_pending = false;
    if (!state.closed) registrar = state.registrar;
  }
  if (registrar) fl_texture_registrar_mark_texture_frame_available(registrar, FL_TEXTURE(texture));
  return G_SOURCE_REMOVE;
}

bool Submit(void* context, const PagaRdpFrameView* frame) {
  auto* texture = static_cast<PagaRdpTexture*>(context);
  auto& state = *texture->state;
  std::lock_guard<std::mutex> lock(state.mutex);
  if (state.closed) return false;
  if (frame->rgba_len == 0) return state.latest != nullptr;
  if (!PagaRdpFrameHasValidPixels(frame)) return false;
  const bool full = PagaRdpFrameIsFull(frame);
  const bool resized = !state.latest || state.latest->width != frame->width ||
                       state.latest->height != frame->height;
  if (resized && !full) return false;
  try {
    if (resized || (full && !state.latest.unique())) {
      auto pixels = std::make_shared<Pixels>();
      pixels->width = frame->width;
      pixels->height = frame->height;
      pixels->rgba.assign(frame->rgba, frame->rgba + frame->rgba_len);
      state.latest = std::move(pixels);
    } else if (full) {
      std::memcpy(state.latest->rgba.data(), frame->rgba, frame->rgba_len);
    } else {
      if (!state.latest.unique()) state.latest = std::make_shared<Pixels>(*state.latest);
      size_t dst_stride = size_t{frame->width} * 4;
      size_t src_stride = size_t{frame->bitmap_width} * 4;
      for (size_t i = 0; i < frame->tile_count; ++i) {
        const auto& tile = frame->tiles[i];
        for (size_t row = 0; row < tile.height; ++row) {
          std::memcpy(state.latest->rgba.data() + (tile.y + row) * dst_stride + tile.x * 4,
                      frame->rgba + (tile.source_y + row) * src_stride + tile.source_x * 4,
                      size_t{tile.width} * 4);
        }
      }
    }
  } catch (const std::bad_alloc&) {
    return false;
  }
  if (!state.notification_pending) {
    state.notification_pending = true;
    g_idle_add_full(G_PRIORITY_DEFAULT, MarkFrame, g_object_ref(texture), g_object_unref);
  }
  return true;
}

class Registry {
 public:
  explicit Registry(FlEngine* engine)
      : registrar_(FL_TEXTURE_REGISTRAR(g_object_ref(fl_engine_get_texture_registrar(engine)))) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    channel_ = fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                                     "pagashell/rdpTexture", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel_, Handle, this, nullptr);
  }

  ~Registry() { Close(); }

  void Close() {
    if (!channel_) return;
    fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
    while (!textures_.empty()) Detach(textures_.begin()->first);
    g_clear_object(&channel_);
    g_clear_object(&registrar_);
  }

 private:
  struct Entry {
    FlTexture* texture = nullptr;
    bool is_gl = false;
  };

  bool Attach(uint32_t session) {
    if (textures_.count(session)) return false;
    if (LoadGlProcs().valid()) {
      auto* texture = static_cast<PagaRdpGlTexture*>(
          g_object_new(paga_rdp_gl_texture_get_type(), nullptr));
      texture->state->registrar = registrar_;
      if (fl_texture_registrar_register_texture(registrar_, FL_TEXTURE(texture))) {
        int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
        if (pagashell_rdp_texture_attach(session, id, g_object_ref(texture),
                                         SubmitGl, g_object_unref)) {
          textures_.emplace(session, Entry{FL_TEXTURE(texture), true});
          return true;
        }
        g_object_unref(texture);  // Rust did not take its reference.
        fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture));
      }
      g_object_unref(texture);
    }

    auto* texture =
        static_cast<PagaRdpTexture*>(g_object_new(paga_rdp_texture_get_type(), nullptr));
    texture->state->registrar = registrar_;
    if (!fl_texture_registrar_register_texture(registrar_, FL_TEXTURE(texture))) {
      g_object_unref(texture);
      return false;
    }
    int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
    if (!pagashell_rdp_texture_attach(session, id, g_object_ref(texture), Submit, g_object_unref)) {
      g_object_unref(texture);  // Rust did not take its reference.
      fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture));
      g_object_unref(texture);
      return false;
    }
    textures_.emplace(session, Entry{FL_TEXTURE(texture), false});
    return true;
  }

  void Detach(uint32_t session) {
    auto entry = textures_.find(session);
    if (entry == textures_.end()) return;
    auto info = entry->second;
    if (info.is_gl) {
      auto* texture = reinterpret_cast<PagaRdpGlTexture*>(info.texture);
      std::lock_guard<std::mutex> lock(texture->state->mutex);
      texture->state->closed = true;
      texture->state->pending.clear();
    } else {
      auto* texture = reinterpret_cast<PagaRdpTexture*>(info.texture);
      std::lock_guard<std::mutex> lock(texture->state->mutex);
      texture->state->closed = true;
      texture->state->latest.reset();
    }
    pagashell_rdp_texture_detach(session);
    fl_texture_registrar_unregister_texture(registrar_, info.texture);
    textures_.erase(entry);
    g_object_unref(info.texture);
  }

  static void Handle(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
    auto& registry = *static_cast<Registry*>(user_data);
    FlValue* args = fl_method_call_get_args(call);
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_INT) {
      int64_t value = fl_value_get_int(args);
      if (value >= 0 && value <= UINT32_MAX) {
        const auto session = static_cast<uint32_t>(value);
        const gchar* method = fl_method_call_get_name(call);
        if (g_str_equal(method, "attach")) {
          g_autoptr(FlValue) result = fl_value_new_bool(registry.Attach(session));
          fl_method_call_respond_success(call, result, nullptr);
          return;
        }
        if (g_str_equal(method, "detach")) {
          registry.Detach(session);
          fl_method_call_respond_success(call, nullptr, nullptr);
          return;
        }
      }
    }
    fl_method_call_respond_not_implemented(call, nullptr);
  }

  FlMethodChannel* channel_ = nullptr;
  FlTextureRegistrar* registrar_;
  std::unordered_map<uint32_t, Entry> textures_;
};
}  // namespace

void RegisterRdpTextures(FlView* view) {
  auto* registry = new Registry(fl_view_get_engine(view));
  g_object_set_data_full(G_OBJECT(view), "pagashell-rdp-textures", registry,
                         [](gpointer data) { delete static_cast<Registry*>(data); });
  g_signal_connect(view, "destroy",
                   G_CALLBACK(+[](GtkWidget*, gpointer data) {
                     static_cast<Registry*>(data)->Close();
                   }), registry);
}
