#include "rdp_texture.h"
#include "../../rust/include/rdp_texture.h"

#include <d3d11.h>
#include <d3d11_4.h>
#include <dxgi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <wrl/client.h>

#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <unordered_map>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;

using FrameView = PagaRdpFrameView;
using GpuSurfaceView = PagaRdpGpuSurfaceView;
using Attach = PagaRdpTextureAttach;
using AttachGpu = PagaRdpTextureAttachGpu;
using Detach = PagaRdpTextureDetach;

constexpr size_t kCpuPoolSize = 3;
constexpr size_t kMaxGpuCacheEntries = 8;

template <typename Function>
Function LoadFunction(HMODULE module, const char* name) {
  const FARPROC address = GetProcAddress(module, name);
  static_assert(sizeof(Function) == sizeof(address));
  Function function = nullptr;
  std::memcpy(&function, &address, sizeof(function));
  return function;
}

struct Snapshot {
  ComPtr<ID3D11Texture2D> texture;
  HANDLE handle = nullptr;
  UINT width = 0;
  UINT height = 0;
};

class TextureState {
 public:
  TextureState(HWND window, ComPtr<IDXGIAdapter> adapter)
      : window_(window), adapter_(std::move(adapter)) {}
  ~TextureState() {
    if (upload_done_) CloseHandle(upload_done_);
  }

  int64_t id = -1;
  std::atomic_bool closed{false};
  std::atomic_bool notification_pending{false};

  bool UpdateGpu(const GpuSurfaceView& surface) {
    if (closed.load()) return false;
    std::lock_guard<std::mutex> lock(upload_mutex_);
    if (closed.load()) return false;
    if (surface.kind != PAGA_RDP_GPU_SURFACE_DXGI_SHARED_HANDLE ||
        surface.handle == 0 || surface.width == 0 || surface.height == 0 ||
        static_cast<size_t>(surface.width) * surface.height > 16777216) {
      return false;
    }
    if (!InitializeDevice()) return false;
    if (FAILED(device_->GetDeviceRemovedReason())) return false;

    if (surface.generation != gpu_generation_) {
      gpu_cache_.clear();
      gpu_generation_ = surface.generation;
    }

    auto cached = gpu_cache_.find(surface.handle);
    std::shared_ptr<Snapshot> next;
    if (cached != gpu_cache_.end() &&
        cached->second->width == surface.width &&
        cached->second->height == surface.height) {
      next = cached->second;
    } else {
      auto opened = std::make_shared<Snapshot>();
      HANDLE shared_handle =
          reinterpret_cast<HANDLE>(static_cast<uintptr_t>(surface.handle));
      if (FAILED(device_->OpenSharedResource(
              shared_handle, IID_PPV_ARGS(opened->texture.GetAddressOf()))) ||
          !opened->texture) {
        return false;
      }
      D3D11_TEXTURE2D_DESC desc{};
      opened->texture->GetDesc(&desc);
      if (desc.Width != surface.width || desc.Height != surface.height ||
          desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM) {
        return false;
      }
      opened->handle = shared_handle;
      opened->width = desc.Width;
      opened->height = desc.Height;
      if (gpu_cache_.size() >= kMaxGpuCacheEntries) {
        gpu_cache_.clear();
      }
      gpu_cache_.emplace(surface.handle, opened);
      next = std::move(opened);
    }

    std::atomic_store(&latest_, std::move(next));
    return notification_pending.exchange(true) ||
           PostMessageW(window_, RdpTextureRegistry::kFrameMessage,
                        static_cast<WPARAM>(id), 0) != 0;
  }

  bool Update(const FrameView& frame) {
    if (closed.load()) return false;
    std::lock_guard<std::mutex> lock(upload_mutex_);
    if (closed.load()) return false;
    if (frame.rgba_len == 0) return std::atomic_load(&latest_) != nullptr;
    if (!PagaRdpFrameHasValidPixels(&frame)) return false;
    const bool full = PagaRdpFrameIsFull(&frame);
    auto previous = std::atomic_load(&latest_);
    const bool resized =
        !previous || previous->width != frame.width || previous->height != frame.height;
    if (resized && !full) return false;
    if (!InitializeDevice()) return false;

    auto next = AcquireCpuSlot(frame.width, frame.height, previous.get());
    if (!next) return false;

    const UINT pitch = static_cast<UINT>(frame.bitmap_width) * 4;
    if (full) {
      context_->UpdateSubresource(next->texture.Get(), 0, nullptr, frame.rgba, pitch,
                                  0);
    } else {
      // Raster may still be sampling the previous snapshot. Both devices
      // only read from it, and only the new texture receives the patch.
      context_->CopyResource(next->texture.Get(), previous->texture.Get());
      for (size_t i = 0; i < frame.tile_count; ++i) {
        const auto& tile = frame.tiles[i];
        const D3D11_BOX box{tile.x,
                            tile.y,
                            0,
                            static_cast<UINT>(tile.x) + tile.width,
                            static_cast<UINT>(tile.y) + tile.height,
                            1};
        const auto* pixels = frame.rgba +
                             static_cast<size_t>(tile.source_y) * pitch +
                             tile.source_x * 4u;
        context_->UpdateSubresource(next->texture.Get(), 0, &box, pixels, pitch, 0);
      }
    }

    ++fence_value_;
    if (FAILED(fenced_context_->Signal(fence_.Get(), fence_value_)) ||
        FAILED(fence_->SetEventOnCompletion(fence_value_, upload_done_))) {
      return false;
    }
    context_->Flush();
    if (WaitForSingleObject(upload_done_, 64) != WAIT_OBJECT_0 ||
        closed.load() || FAILED(device_->GetDeviceRemovedReason())) {
      return false;
    }
    std::atomic_store(&latest_, std::move(next));
    return notification_pending.exchange(true) ||
           PostMessageW(window_, RdpTextureRegistry::kFrameMessage,
                        static_cast<WPARAM>(id), 0) != 0;
  }

  std::shared_ptr<Snapshot> SnapshotForRaster() const {
    return std::atomic_load(&latest_);
  }

 private:
  std::shared_ptr<Snapshot> CreateSharedTexture(UINT width, UINT height) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width;
    desc.Height = height;
    desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    auto snap = std::make_shared<Snapshot>();
    if (FAILED(device_->CreateTexture2D(&desc, nullptr, snap->texture.GetAddressOf())))
      return nullptr;
    ComPtr<IDXGIResource> resource;
    if (FAILED(snap->texture.As(&resource)) ||
        FAILED(resource->GetSharedHandle(&snap->handle)) || !snap->handle)
      return nullptr;
    snap->width = width;
    snap->height = height;
    return snap;
  }

  std::shared_ptr<Snapshot> AcquireCpuSlot(UINT width, UINT height,
                                           const Snapshot* previous) {
    if (pool_width_ != width || pool_height_ != height) {
      for (auto& slot : cpu_pool_) slot.reset();
      pool_width_ = width;
      pool_height_ = height;
      cpu_pool_index_ = 0;
    }
    // Reuse a pooled texture that neither `latest_` nor Flutter's raster thread holds.
    for (size_t attempt = 0; attempt < kCpuPoolSize; ++attempt) {
      size_t index = (cpu_pool_index_ + attempt) % kCpuPoolSize;
      auto& slot = cpu_pool_[index];
      if (!slot) {
        slot = CreateSharedTexture(width, height);
        if (!slot) return nullptr;
      }
      if (slot.get() != previous && slot.use_count() == 1) {
        cpu_pool_index_ = (index + 1) % kCpuPoolSize;
        return slot;
      }
    }
    return CreateSharedTexture(width, height);
  }

  bool InitializeDevice() {
    if (device_) return fence_ != nullptr && upload_done_ != nullptr;
    if (FAILED(D3D11CreateDevice(
            adapter_.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
            device_.GetAddressOf(), nullptr, context_.GetAddressOf())))
      return false;
    ComPtr<ID3D11Device5> fence_device;
    if (FAILED(device_.As(&fence_device)) ||
        FAILED(context_.As(&fenced_context_)) ||
        FAILED(fence_device->CreateFence(
            0, D3D11_FENCE_FLAG_NONE, IID_PPV_ARGS(fence_.GetAddressOf())))) {
      return false;
    }
    upload_done_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    return upload_done_ != nullptr;
  }

  HWND window_;
  ComPtr<IDXGIAdapter> adapter_;
  ComPtr<ID3D11Device> device_;
  ComPtr<ID3D11DeviceContext> context_;
  ComPtr<ID3D11DeviceContext4> fenced_context_;
  ComPtr<ID3D11Fence> fence_;
  HANDLE upload_done_ = nullptr;
  UINT64 fence_value_ = 0;
  std::mutex upload_mutex_;
  std::array<std::shared_ptr<Snapshot>, kCpuPoolSize> cpu_pool_;
  UINT pool_width_ = 0;
  UINT pool_height_ = 0;
  size_t cpu_pool_index_ = 0;
  std::unordered_map<uint64_t, std::shared_ptr<Snapshot>> gpu_cache_;
  uint64_t gpu_generation_ = 0;
  std::shared_ptr<Snapshot> latest_;
};

using TextureRef = std::shared_ptr<TextureState>;

bool Submit(void* context, const FrameView* frame) noexcept {
  try {
    return frame && (*static_cast<TextureRef*>(context))->Update(*frame);
  } catch (...) {
    return false;
  }
}

bool SubmitGpu(void* context, const GpuSurfaceView* surface) noexcept {
  try {
    return surface && (*static_cast<TextureRef*>(context))->UpdateGpu(*surface);
  } catch (...) {
    return false;
  }
}

void ReleaseTexture(void* context) { delete static_cast<TextureRef*>(context); }

const FlutterDesktopGpuSurfaceDescriptor* Acquire(size_t, size_t,
                                                  void* context) {
  auto current = (*static_cast<TextureRef*>(context))->SnapshotForRaster();
  if (!current) return nullptr;
  using SnapshotRef = std::shared_ptr<Snapshot>;
  auto* retained = new (std::nothrow) SnapshotRef(current);
  if (!retained) return nullptr;
  thread_local FlutterDesktopGpuSurfaceDescriptor descriptor;
  descriptor = {sizeof(descriptor),
                current->handle,
                current->width,
                current->height,
                current->width,
                current->height,
                kFlutterDesktopPixelFormatRGBA8888,
                [](void* value) { delete static_cast<SnapshotRef*>(value); },
                retained};
  return &descriptor;
}
}  // namespace

class RdpTextureRegistry::Impl {
 public:
  Impl(flutter::FlutterEngine* engine, HWND window)
      : engine_(engine),
        window_(window),
        registrar_(FlutterDesktopRegistrarGetTextureRegistrar(
            engine->GetRegistrarForPlugin("PagaShellRdpTexture"))),
        channel_(engine->messenger(), "pagashell/rdpTexture",
                 &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
                                         std::unique_ptr<Result> result) {
      int64_t raw = -1;
      if (const Value* value = call.arguments()) {
        if (const auto* small = std::get_if<int32_t>(value)) raw = *small;
        if (const auto* big = std::get_if<int64_t>(value)) raw = *big;
      }
      if (raw <= 0 || raw > std::numeric_limits<uint32_t>::max()) {
        result->Error("rdp_texture", "Invalid RDP session ID");
        return;
      }
      const auto session = static_cast<uint32_t>(raw);
      if (call.method_name() == "attach") {
        result->Success(Value(Open(session)));
      } else if (call.method_name() == "detach") {
        Close(session);
        result->Success();
      } else {
        result->NotImplemented();
      }
    });
  }

  ~Impl() {
    channel_.SetMethodCallHandler(nullptr);
    while (!entries_.empty()) Close(entries_.begin()->first);
  }

  void MarkFrame(WPARAM id) {
    for (const auto& entry : entries_) {
      if (static_cast<WPARAM>(entry.second.state->id) == id) {
        entry.second.state->notification_pending.store(false);
        FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
            registrar_, entry.second.state->id);
        return;
      }
    }
  }

 private:
  struct Entry {
    TextureRef state;
    TextureRef* raster_ref;
  };

  bool Open(uint32_t session) {
    if (entries_.find(session) != entries_.end()) return true;
    const HMODULE rust = GetModuleHandleW(L"rust_lib_pagashell.dll");
    if (!rust || !registrar_) return false;
    const auto attach =
        LoadFunction<Attach>(rust, "pagashell_rdp_texture_attach");
    if (!attach) return false;
    detach_ = LoadFunction<Detach>(rust, "pagashell_rdp_texture_detach");
    if (!detach_) return false;
    const auto attach_gpu =
        LoadFunction<AttachGpu>(rust, "pagashell_rdp_texture_attach_gpu");
    ComPtr<IDXGIAdapter> adapter;
    if (!engine_->GetGraphicsAdapter(adapter.GetAddressOf()) || !adapter)
      return false;
    uint64_t adapter_luid = 0;
    DXGI_ADAPTER_DESC adapter_desc{};
    if (SUCCEEDED(adapter->GetDesc(&adapter_desc))) {
      adapter_luid =
          (static_cast<uint64_t>(
               static_cast<uint32_t>(adapter_desc.AdapterLuid.HighPart))
           << 32) |
          static_cast<uint64_t>(adapter_desc.AdapterLuid.LowPart);
    }
    auto state = std::make_shared<TextureState>(window_, std::move(adapter));
    auto raster_ref = std::make_unique<TextureRef>(state);
    auto rust_ref = std::make_unique<TextureRef>(state);
    FlutterDesktopTextureInfo info{};
    info.type = kFlutterDesktopGpuSurfaceTexture;
    info.gpu_surface_config = {sizeof(FlutterDesktopGpuSurfaceTextureConfig),
                               kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
                               Acquire, raster_ref.get()};
    state->id = FlutterDesktopTextureRegistrarRegisterExternalTexture(
        registrar_, &info);
    if (state->id < 0) return false;
    auto* registered_ref = raster_ref.release();
    if (!attach(session, state->id, rust_ref.get(), Submit, ReleaseTexture)) {
      FlutterDesktopTextureRegistrarUnregisterExternalTexture(
          registrar_, state->id, ReleaseTexture, registered_ref);
      return false;
    }
    rust_ref.release();
    if (attach_gpu) {
      attach_gpu(session, SubmitGpu, adapter_luid);
    }
    entries_.emplace(session, Entry{std::move(state), registered_ref});
    return true;
  }

  void Close(uint32_t session) {
    auto item = entries_.find(session);
    if (item == entries_.end()) return;
    auto& entry = item->second;
    entry.state->closed.store(true);
    detach_(session);
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(
        registrar_, entry.state->id, ReleaseTexture, entry.raster_ref);
    entries_.erase(item);
  }

  flutter::FlutterEngine* engine_;
  HWND window_;
  FlutterDesktopTextureRegistrarRef registrar_;
  flutter::MethodChannel<Value> channel_;
  std::unordered_map<uint32_t, Entry> entries_;
  Detach detach_ = nullptr;
};

RdpTextureRegistry::RdpTextureRegistry(flutter::FlutterEngine* engine,
                                       HWND window)
    : impl_(std::make_unique<Impl>(engine, window)) {}
RdpTextureRegistry::~RdpTextureRegistry() = default;
void RdpTextureRegistry::MarkFrame(WPARAM texture_id) {
  impl_->MarkFrame(texture_id);
}
