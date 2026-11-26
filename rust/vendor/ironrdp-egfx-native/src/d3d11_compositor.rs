//! D3D11 GPU-resident EGFX surface compositor for Windows.
//!
//! Shares a single multithreaded `ID3D11Device` with Media Foundation so
//! hardware-decoded NV12 surfaces flow through HLSL compute shaders into
//! persistent RGBA8 surfaces and a triple-buffered DXGI shared output ring
//! with zero CPU readback.

use core::any::Any;
use core::ffi::c_void;
use std::collections::BTreeMap;
use std::sync::OnceLock;

use ironrdp_egfx::avc444::Avc444Layout;
use ironrdp_egfx::decode::{DecoderResult, H264Decoder, YuvMatrix};
use ironrdp_egfx::gpu::{ExclusiveRectangle, GpuCompositor, GpuPresentedFrame, HwVideoFrame};
use ironrdp_egfx::pdu::{Color, Point};
use tracing::warn;
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_UNKNOWN, D3D_SRV_DIMENSION_TEXTURE2D, ID3DBlob,
};
use windows::Win32::Graphics::Direct3D10::ID3D10Multithread;
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_CONSTANT_BUFFER, D3D11_BIND_RENDER_TARGET, D3D11_BIND_SHADER_RESOURCE, D3D11_BIND_UNORDERED_ACCESS,
    D3D11_BOX, D3D11_BUFFER_DESC, D3D11_COMPARISON_NEVER, D3D11_CPU_ACCESS_WRITE, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
    D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_FENCE_FLAG_NONE, D3D11_FILTER_MIN_MAG_MIP_LINEAR, D3D11_MAP_WRITE_DISCARD,
    D3D11_MAPPED_SUBRESOURCE, D3D11_RESOURCE_MISC_SHARED, D3D11_SAMPLER_DESC, D3D11_SDK_VERSION,
    D3D11_SHADER_RESOURCE_VIEW_DESC, D3D11_TEX2D_SRV, D3D11_TEX2D_UAV, D3D11_TEXTURE_ADDRESS_CLAMP,
    D3D11_TEXTURE2D_DESC, D3D11_UAV_DIMENSION_TEXTURE2D, D3D11_UNORDERED_ACCESS_VIEW_DESC, D3D11_USAGE_DEFAULT,
    D3D11_USAGE_DYNAMIC, D3D11CreateDevice, ID3D11Buffer, ID3D11ComputeShader, ID3D11Device, ID3D11Device5,
    ID3D11DeviceContext, ID3D11DeviceContext4, ID3D11Fence, ID3D11SamplerState, ID3D11ShaderResourceView,
    ID3D11Texture2D, ID3D11UnorderedAccessView, ID3D11VideoDevice,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_R8_UNORM, DXGI_FORMAT_R8G8_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM,
    DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter, IDXGIFactory1, IDXGIResource};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW};
use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};
use windows::core::{Error, HRESULT, Interface, PCSTR, Result, s, w};

use crate::media_foundation::D3D11Nv12Frame;

const MAX_BUDGET_BYTES: usize = 256 * 1024 * 1024;
const MAX_OUTPUT_PIXELS: u64 = 16_777_216;
const RING_SLOTS: usize = 3;

const HLSL_SOURCE: &str = r#"
cbuffer Params : register(b0) {
    uint4 p0;
    uint4 p1;
    float4 f0;
};

Texture2D<float> y_tex : register(t0);
Texture2D<float2> uv_tex : register(t1);
Texture2D<float> u_tex : register(t1);
Texture2D<float> v_tex : register(t2);
Texture2D<float4> src_rgba : register(t0);
SamplerState linear_sampler : register(s0);

RWTexture2D<unorm float4> dst_rgba : register(u0);
RWTexture2D<unorm float> out_y : register(u0);
RWTexture2D<unorm float> out_u : register(u1);
RWTexture2D<unorm float> out_v : register(u2);

float4 egfx_yuv_to_rgba(int y, int u, int v) {
    int luma = 256 * y;
    int uu = u - 128;
    int vv = v - 128;
    int r = clamp((luma + 403 * vv) >> 8, 0, 255);
    int g = clamp((luma - 48 * uu - 120 * vv) >> 8, 0, 255);
    int b = clamp((luma + 475 * uu) >> 8, 0, 255);
    return float4(float(r) / 255.0, float(g) / 255.0, float(b) / 255.0, 1.0);
}

int reverse_filter(int avg, int right, int below, int diag) {
    int rev = clamp(4 * avg - right - below - diag, 0, 255);
    return abs(rev - avg) < 30 ? avg : rev;
}

[numthreads(16, 16, 1)]
void avc420_to_rgba(uint3 gid : SV_DispatchThreadID) {
    // p0 = (src_x, src_y, dst_x, dst_y), p1 = (width, height, 0, 0)
    if (gid.x >= p1.x || gid.y >= p1.y) return;
    uint yw, yh, uvw, uvh, dw, dh;
    y_tex.GetDimensions(yw, yh);
    uv_tex.GetDimensions(uvw, uvh);
    dst_rgba.GetDimensions(dw, dh);
    uint sx = p0.x + gid.x;
    uint sy = p0.y + gid.y;
    uint dx = p0.z + gid.x;
    uint dy = p0.w + gid.y;
    if (sx >= yw || sy >= yh || dx >= dw || dy >= dh) return;
    uint cx = min(sx >> 1, uvw - 1);
    uint cy = min(sy >> 1, uvh - 1);
    int y = int(round(y_tex.Load(int3(sx, sy, 0)) * 255.0));
    float2 uv = uv_tex.Load(int3(cx, cy, 0));
    int u = int(round(uv.x * 255.0));
    int v = int(round(uv.y * 255.0));
    dst_rgba[uint2(dx, dy)] = egfx_yuv_to_rgba(y, u, v);
}

[numthreads(16, 16, 1)]
void avc444_apply_main(uint3 gid : SV_DispatchThreadID) {
    // p0 = (area_left, area_top, area_width, area_height)
    // p1 = (rect_left, rect_top, rect_right, rect_bottom)
    if (gid.x >= p0.z || gid.y >= p0.w) return;
    uint yw, yh, uvw, uvh, ow, oh;
    y_tex.GetDimensions(yw, yh);
    uv_tex.GetDimensions(uvw, uvh);
    out_y.GetDimensions(ow, oh);
    uint col = p0.x + gid.x;
    uint row = p0.y + gid.y;
    if (col >= yw || row >= yh || col >= ow || row >= oh) return;
    if (col >= p1.x && col < p1.z && row >= p1.y && row < p1.w) {
        out_y[uint2(col, row)] = y_tex.Load(int3(col, row, 0));
    }
    uint cx = min(col >> 1, uvw - 1);
    uint cy = min(row >> 1, uvh - 1);
    float2 uv = uv_tex.Load(int3(cx, cy, 0));
    out_u[uint2(col, row)] = uv.x;
    out_v[uint2(col, row)] = uv.y;
}

[numthreads(16, 16, 1)]
void avc444_apply_aux_v1(uint3 gid : SV_DispatchThreadID) {
    // p0 = (area_left, area_top, area_width, area_height)
    // out_u at u1, out_v at u2
    if (gid.x >= p0.z || gid.y >= p0.w) return;
    uint yw, yh, uvw, uvh, ow, oh;
    y_tex.GetDimensions(yw, yh);
    uv_tex.GetDimensions(uvw, uvh);
    out_u.GetDimensions(ow, oh);
    uint col = p0.x + gid.x;
    uint row = p0.y + gid.y;
    if (col >= ow || row >= oh) return;
    if ((row & 1u) == 1u) {
        uint u_row = (row - (row & 15u)) + ((row & 15u) >> 1);
        uint v_row = u_row + 8u;
        if (col < yw && v_row < yh) {
            out_u[uint2(col, row)] = y_tex.Load(int3(col, u_row, 0));
            out_v[uint2(col, row)] = y_tex.Load(int3(col, v_row, 0));
        }
    } else if ((col & 1u) == 1u) {
        uint cx = col >> 1;
        uint cy = row >> 1;
        if (cx < uvw && cy < uvh) {
            float2 uv = uv_tex.Load(int3(cx, cy, 0));
            out_u[uint2(col, row)] = uv.x;
            out_v[uint2(col, row)] = uv.y;
        }
    }
}

[numthreads(16, 16, 1)]
void avc444_apply_aux_v2(uint3 gid : SV_DispatchThreadID) {
    // p0 = (area_left, area_top, area_width, area_height), p1 = (half_w, quarter_w, 0, 0)
    if (gid.x >= p0.z || gid.y >= p0.w) return;
    uint yw, yh, uvw, uvh, ow, oh;
    y_tex.GetDimensions(yw, yh);
    uv_tex.GetDimensions(uvw, uvh);
    out_u.GetDimensions(ow, oh);
    uint col = p0.x + gid.x;
    uint row = p0.y + gid.y;
    if (col >= ow || row >= oh) return;
    if ((col & 1u) == 1u) {
        uint ux = col >> 1;
        uint vx = p1.x + ux;
        if (vx < yw && row < yh) {
            out_u[uint2(col, row)] = y_tex.Load(int3(ux, row, 0));
            out_v[uint2(col, row)] = y_tex.Load(int3(vx, row, 0));
        }
    } else if ((row & 1u) == 1u) {
        uint ux = col >> 2;
        uint vx = p1.y + ux;
        uint cy = row >> 1;
        if (vx < uvw && cy < uvh) {
            float u_val, v_val;
            if ((col & 3u) == 0u) {
                u_val = uv_tex.Load(int3(ux, cy, 0)).x;
                v_val = uv_tex.Load(int3(vx, cy, 0)).x;
            } else {
                u_val = uv_tex.Load(int3(ux, cy, 0)).y;
                v_val = uv_tex.Load(int3(vx, cy, 0)).y;
            }
            out_u[uint2(col, row)] = u_val;
            out_v[uint2(col, row)] = v_val;
        }
    }
}

[numthreads(16, 16, 1)]
void avc444_to_rgba(uint3 gid : SV_DispatchThreadID) {
    // p0 = (x, y, width, height)
    if (gid.x >= p0.z || gid.y >= p0.w) return;
    uint yw, yh, dw, dh;
    y_tex.GetDimensions(yw, yh);
    dst_rgba.GetDimensions(dw, dh);
    uint col = p0.x + gid.x;
    uint row = p0.y + gid.y;
    if (col >= dw || row >= dh || col >= yw || row >= yh) return;
    int y = int(round(y_tex.Load(int3(col, row, 0)) * 255.0));
    int u = int(round(u_tex.Load(int3(col, row, 0)) * 255.0));
    int v = int(round(v_tex.Load(int3(col, row, 0)) * 255.0));
    if (((row & 1u) == 0u) && ((col & 1u) == 0u) && (col + 1u) < yw && (row + 1u) < yh) {
        int ur = int(round(u_tex.Load(int3(col + 1u, row, 0)) * 255.0));
        int ub = int(round(u_tex.Load(int3(col, row + 1u, 0)) * 255.0));
        int ud = int(round(u_tex.Load(int3(col + 1u, row + 1u, 0)) * 255.0));
        u = reverse_filter(u, ur, ub, ud);
        int vr = int(round(v_tex.Load(int3(col + 1u, row, 0)) * 255.0));
        int vb = int(round(v_tex.Load(int3(col, row + 1u, 0)) * 255.0));
        int vd = int(round(v_tex.Load(int3(col + 1u, row + 1u, 0)) * 255.0));
        v = reverse_filter(v, vr, vb, vd);
    }
    dst_rgba[uint2(col, row)] = egfx_yuv_to_rgba(y, u, v);
}

[numthreads(16, 16, 1)]
void copy_opaque(uint3 gid : SV_DispatchThreadID) {
    // p0 = (dst_x, dst_y, width, height)
    if (gid.x >= p0.z || gid.y >= p0.w) return;
    uint dw, dh;
    dst_rgba.GetDimensions(dw, dh);
    uint dx = p0.x + gid.x;
    uint dy = p0.y + gid.y;
    if (dx >= dw || dy >= dh) return;
    float4 c = src_rgba.Load(int3(gid.x, gid.y, 0));
    dst_rgba[uint2(dx, dy)] = float4(c.rgb, 1.0);
}

[numthreads(16, 16, 1)]
void clearcodec_composite(uint3 gid : SV_DispatchThreadID) {
    // p0 = (dst_x, dst_y, width, height)
    if (gid.x >= p0.z || gid.y >= p0.w) return;
    uint dw, dh;
    dst_rgba.GetDimensions(dw, dh);
    uint dx = p0.x + gid.x;
    uint dy = p0.y + gid.y;
    if (dx >= dw || dy >= dh) return;
    float4 c = src_rgba.Load(int3(gid.x, gid.y, 0));
    if (c.a > 0.0) {
        dst_rgba[uint2(dx, dy)] = float4(c.rgb, 1.0);
    }
}

[numthreads(16, 16, 1)]
void solid_fill(uint3 gid : SV_DispatchThreadID) {
    // p0 = (x, y, width, height), f0 = (r, g, b, 1)
    if (gid.x >= p0.z || gid.y >= p0.w) return;
    uint dw, dh;
    dst_rgba.GetDimensions(dw, dh);
    uint dx = p0.x + gid.x;
    uint dy = p0.y + gid.y;
    if (dx >= dw || dy >= dh) return;
    dst_rgba[uint2(dx, dy)] = float4(f0.rgb, 1.0);
}

[numthreads(16, 16, 1)]
void blit_scaled(uint3 gid : SV_DispatchThreadID) {
    // p0 = (dst_x, dst_y, dst_w, dst_h)
    if (gid.x >= p0.z || gid.y >= p0.w) return;
    uint dw, dh;
    dst_rgba.GetDimensions(dw, dh);
    uint dx = p0.x + gid.x;
    uint dy = p0.y + gid.y;
    if (dx >= dw || dy >= dh) return;
    float2 uv = float2((float(gid.x) + 0.5) / float(p0.z), (float(gid.y) + 0.5) / float(p0.w));
    float4 c = src_rgba.SampleLevel(linear_sampler, uv, 0.0);
    dst_rgba[uint2(dx, dy)] = float4(c.rgb, 1.0);
}
"#;

#[repr(C)]
#[derive(Clone, Copy)]
struct ShaderParams {
    p0: [u32; 4],
    p1: [u32; 4],
    f0: [f32; 4],
}

type D3DCompileFn = unsafe extern "system" fn(
    *const c_void,
    usize,
    PCSTR,
    *const c_void,
    *const c_void,
    PCSTR,
    PCSTR,
    u32,
    u32,
    *mut *mut c_void,
    *mut *mut c_void,
) -> HRESULT;

fn load_d3d_compile() -> Result<D3DCompileFn> {
    static COMPILER: OnceLock<Option<D3DCompileFn>> = OnceLock::new();
    (*COMPILER.get_or_init(|| {
        let module = unsafe { LoadLibraryExW(w!("d3dcompiler_47.dll"), None, LOAD_LIBRARY_SEARCH_SYSTEM32) }.ok()?;
        let proc = unsafe { GetProcAddress(module, s!("D3DCompile")) }?;
        Some(unsafe { core::mem::transmute::<_, D3DCompileFn>(proc) })
    }))
    .ok_or_else(Error::empty)
}

fn compile_cs(device: &ID3D11Device, entry: PCSTR) -> Result<ID3D11ComputeShader> {
    let compile = load_d3d_compile()?;
    let mut code_ptr: *mut c_void = core::ptr::null_mut();
    let mut err_ptr: *mut c_void = core::ptr::null_mut();
    let hr = unsafe {
        compile(
            HLSL_SOURCE.as_ptr().cast(),
            HLSL_SOURCE.len(),
            PCSTR::null(),
            core::ptr::null(),
            core::ptr::null(),
            entry,
            s!("cs_5_0"),
            0,
            0,
            &mut code_ptr,
            &mut err_ptr,
        )
    };
    let _err_blob = if !err_ptr.is_null() {
        Some(unsafe { ID3DBlob::from_raw(err_ptr) })
    } else {
        None
    };
    hr.ok()?;
    if code_ptr.is_null() {
        return Err(Error::empty());
    }
    let blob = unsafe { ID3DBlob::from_raw(code_ptr) };
    let bytes = unsafe { core::slice::from_raw_parts(blob.GetBufferPointer().cast::<u8>(), blob.GetBufferSize()) };
    let mut shader = None;
    unsafe { device.CreateComputeShader(bytes, None, Some(&mut shader)) }?;
    shader.ok_or_else(Error::empty)
}

fn find_adapter(adapter_luid: Option<u64>) -> Result<Option<IDXGIAdapter>> {
    let Some(target) = adapter_luid.filter(|&luid| luid != 0) else {
        return Ok(None);
    };
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1() }?;
    for index in 0u32.. {
        let Ok(adapter) = (unsafe { factory.EnumAdapters1(index) }) else {
            break;
        };
        if let Ok(desc) = unsafe { adapter.GetDesc1() } {
            let luid = ((desc.AdapterLuid.HighPart as u32 as u64) << 32) | u64::from(desc.AdapterLuid.LowPart);
            if luid == target {
                return Ok(Some(adapter.cast::<IDXGIAdapter>()?));
            }
        }
    }
    Err(Error::empty())
}

fn create_tex_2d(
    device: &ID3D11Device,
    width: u32,
    height: u32,
    format: DXGI_FORMAT,
    bind_flags: u32,
    misc_flags: u32,
) -> Result<ID3D11Texture2D> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 1,
        Format: format,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: bind_flags,
        CPUAccessFlags: 0,
        MiscFlags: misc_flags,
    };
    let mut tex = None;
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut tex)) }?;
    tex.ok_or_else(Error::empty)
}

fn create_srv(device: &ID3D11Device, tex: &ID3D11Texture2D, format: DXGI_FORMAT) -> Result<ID3D11ShaderResourceView> {
    let mut desc = D3D11_SHADER_RESOURCE_VIEW_DESC {
        Format: format,
        ViewDimension: D3D_SRV_DIMENSION_TEXTURE2D,
        ..Default::default()
    };
    desc.Anonymous.Texture2D = D3D11_TEX2D_SRV {
        MostDetailedMip: 0,
        MipLevels: 1,
    };
    let mut view = None;
    unsafe { device.CreateShaderResourceView(tex, Some(&desc), Some(&mut view)) }?;
    view.ok_or_else(Error::empty)
}

fn create_uav(device: &ID3D11Device, tex: &ID3D11Texture2D, format: DXGI_FORMAT) -> Result<ID3D11UnorderedAccessView> {
    let mut desc = D3D11_UNORDERED_ACCESS_VIEW_DESC {
        Format: format,
        ViewDimension: D3D11_UAV_DIMENSION_TEXTURE2D,
        ..Default::default()
    };
    desc.Anonymous.Texture2D = D3D11_TEX2D_UAV { MipSlice: 0 };
    let mut view = None;
    unsafe { device.CreateUnorderedAccessView(tex, Some(&desc), Some(&mut view)) }?;
    view.ok_or_else(Error::empty)
}

struct Avc444Planes {
    y_srv: ID3D11ShaderResourceView,
    y_uav: ID3D11UnorderedAccessView,
    u_srv: ID3D11ShaderResourceView,
    u_uav: ID3D11UnorderedAccessView,
    v_srv: ID3D11ShaderResourceView,
    v_uav: ID3D11UnorderedAccessView,
    _y: ID3D11Texture2D,
    _u: ID3D11Texture2D,
    _v: ID3D11Texture2D,
}

struct SurfaceState {
    width: u16,
    height: u16,
    color: ID3D11Texture2D,
    color_srv: ID3D11ShaderResourceView,
    color_uav: ID3D11UnorderedAccessView,
    avc444: Option<Avc444Planes>,
    bytes: usize,
    mapped: bool,
    origin_x: u32,
    origin_y: u32,
    target_w: u32,
    target_h: u32,
    painted: bool,
}

struct CacheEntry {
    width: u16,
    height: u16,
    texture: ID3D11Texture2D,
    bytes: usize,
}

struct OutputSlot {
    texture: ID3D11Texture2D,
    uav: ID3D11UnorderedAccessView,
    shared_handle: u64,
    generation: u64,
}

/// Thread-safe handle to a compositor's `ID3D11Device` for opening shared-device
/// [`crate::MediaFoundationH264Decoder`] instances.
#[derive(Clone)]
pub struct D3D11DecoderOpener {
    device: ID3D11Device,
}

// The underlying ID3D11Device has ID3D10Multithread::SetMultithreadProtected(true).
unsafe impl Send for D3D11DecoderOpener {}
unsafe impl Sync for D3D11DecoderOpener {}

impl D3D11DecoderOpener {
    pub fn open(&self, matrix: YuvMatrix) -> DecoderResult<Box<dyn H264Decoder>> {
        Ok(Box::new(crate::MediaFoundationH264Decoder::new_with_device(
            matrix,
            Some(self.device.clone()),
        )?))
    }
}

/// D3D11 GPU-composited frame ready for cross-process DXGI shared handle presentation.
pub struct D3D11PresentedFrame {
    width: u16,
    height: u16,
    handle: u64,
    generation: u64,
}

impl D3D11PresentedFrame {
    pub fn shared_handle(&self) -> u64 {
        self.handle
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }
}

impl GpuPresentedFrame for D3D11PresentedFrame {
    fn width(&self) -> u16 {
        self.width
    }

    fn height(&self) -> u16 {
        self.height
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn into_any(self: Box<Self>) -> Box<dyn Any + Send> {
        self
    }
}

struct Pipelines {
    avc420: ID3D11ComputeShader,
    avc444_main: ID3D11ComputeShader,
    avc444_aux_v1: ID3D11ComputeShader,
    avc444_aux_v2: ID3D11ComputeShader,
    avc444_to_rgba: ID3D11ComputeShader,
    copy_opaque: ID3D11ComputeShader,
    clearcodec: ID3D11ComputeShader,
    solid_fill: ID3D11ComputeShader,
    blit_scaled: ID3D11ComputeShader,
}

/// Windows D3D11 GPU-resident EGFX surface compositor.
pub struct D3D11GpuCompositor {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    fenced_context: ID3D11DeviceContext4,
    fence: ID3D11Fence,
    fence_event: HANDLE,
    fence_value: u64,
    cbuffer: ID3D11Buffer,
    sampler: ID3D11SamplerState,
    pipes: Pipelines,
    surfaces: BTreeMap<u16, SurfaceState>,
    map_order: Vec<u16>,
    cache: BTreeMap<u16, CacheEntry>,
    budget_used: usize,
    output_width: u16,
    output_height: u16,
    output_ring: Vec<OutputSlot>,
    ring_index: usize,
    pool_generation: u64,
    dirty: bool,
}

// D3D11 device has SetMultithreadProtected(true) and compositor methods require &mut self.
unsafe impl Send for D3D11GpuCompositor {}

impl Drop for D3D11GpuCompositor {
    fn drop(&mut self) {
        if !self.fence_event.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.fence_event);
            }
        }
    }
}

impl D3D11GpuCompositor {
    /// Creates a GPU compositor on the adapter matching `adapter_luid` (or default HW adapter if `None`/`Some(0)`).
    pub fn new(adapter_luid: Option<u64>) -> Result<Self> {
        let adapter = find_adapter(adapter_luid)?;
        let driver_type = if adapter.is_some() {
            D3D_DRIVER_TYPE_UNKNOWN
        } else {
            D3D_DRIVER_TYPE_HARDWARE
        };
        let mut device = None;
        let mut context = None;
        unsafe {
            D3D11CreateDevice(
                adapter.as_ref(),
                driver_type,
                Default::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?;
        }
        let device = device.ok_or_else(Error::empty)?;
        let context = context.ok_or_else(Error::empty)?;
        // Verify hardware video support on this shared device.
        let _video = device.cast::<ID3D11VideoDevice>()?;
        let multithread = device.cast::<ID3D10Multithread>()?;
        let _ = unsafe { multithread.SetMultithreadProtected(true) };

        let fence_device = device.cast::<ID3D11Device5>()?;
        let fenced_context = context.cast::<ID3D11DeviceContext4>()?;
        let mut fence: Option<ID3D11Fence> = None;
        unsafe { fence_device.CreateFence(0, D3D11_FENCE_FLAG_NONE, &mut fence) }?;
        let fence = fence.ok_or_else(Error::empty)?;
        let fence_event = unsafe { CreateEventW(None, false, false, None) }?;

        let cb_desc = D3D11_BUFFER_DESC {
            ByteWidth: core::mem::size_of::<ShaderParams>() as u32,
            Usage: D3D11_USAGE_DYNAMIC,
            BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
            CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
            MiscFlags: 0,
            StructureByteStride: 0,
        };
        let mut cbuffer = None;
        unsafe { device.CreateBuffer(&cb_desc, None, Some(&mut cbuffer)) }?;
        let cbuffer = cbuffer.ok_or_else(Error::empty)?;

        let sampler_desc = D3D11_SAMPLER_DESC {
            Filter: D3D11_FILTER_MIN_MAG_MIP_LINEAR,
            AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
            AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
            AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
            MipLODBias: 0.0,
            MaxAnisotropy: 1,
            ComparisonFunc: D3D11_COMPARISON_NEVER,
            BorderColor: [0.0; 4],
            MinLOD: 0.0,
            MaxLOD: f32::MAX,
        };
        let mut sampler = None;
        unsafe { device.CreateSamplerState(&sampler_desc, Some(&mut sampler)) }?;
        let sampler = sampler.ok_or_else(Error::empty)?;

        let pipes = Pipelines {
            avc420: compile_cs(&device, s!("avc420_to_rgba"))?,
            avc444_main: compile_cs(&device, s!("avc444_apply_main"))?,
            avc444_aux_v1: compile_cs(&device, s!("avc444_apply_aux_v1"))?,
            avc444_aux_v2: compile_cs(&device, s!("avc444_apply_aux_v2"))?,
            avc444_to_rgba: compile_cs(&device, s!("avc444_to_rgba"))?,
            copy_opaque: compile_cs(&device, s!("copy_opaque"))?,
            clearcodec: compile_cs(&device, s!("clearcodec_composite"))?,
            solid_fill: compile_cs(&device, s!("solid_fill"))?,
            blit_scaled: compile_cs(&device, s!("blit_scaled"))?,
        };

        Ok(Self {
            device,
            context,
            fenced_context,
            fence,
            fence_event,
            fence_value: 0,
            cbuffer,
            sampler,
            pipes,
            surfaces: BTreeMap::new(),
            map_order: Vec::new(),
            cache: BTreeMap::new(),
            budget_used: 0,
            output_width: 0,
            output_height: 0,
            output_ring: Vec::new(),
            ring_index: 0,
            pool_generation: 0,
            dirty: false,
        })
    }

    /// Clones a COM reference to the shared D3D11 device for Media Foundation.
    pub fn device(&self) -> ID3D11Device {
        self.device.clone()
    }

    /// Returns a `Send` handle that opens Media Foundation H.264 decoders
    /// bound to this compositor's D3D11 device without exposing COM types.
    pub fn decoder_opener(&self) -> D3D11DecoderOpener {
        D3D11DecoderOpener {
            device: self.device.clone(),
        }
    }

    fn write_params(&self, params: ShaderParams) -> bool {
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        if unsafe { self.context.Map(&self.cbuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped)) }.is_err() {
            return false;
        }
        unsafe {
            core::ptr::write(mapped.pData.cast::<ShaderParams>(), params);
            self.context.Unmap(&self.cbuffer, 0);
        }
        true
    }

    fn clear_cs_bindings(&self) {
        let empty_srvs: [Option<ID3D11ShaderResourceView>; 4] = [None, None, None, None];
        let empty_uavs: [Option<ID3D11UnorderedAccessView>; 3] = [None, None, None];
        unsafe {
            self.context.CSSetShaderResources(0, Some(&empty_srvs));
            self.context.CSSetUnorderedAccessViews(0, 3, Some(empty_uavs.as_ptr()), None);
        }
    }

    fn dispatch(&self, shader: &ID3D11ComputeShader, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return;
        }
        let cb = [Some(self.cbuffer.clone())];
        unsafe {
            self.context.CSSetConstantBuffers(0, Some(&cb));
            self.context.CSSetShader(shader, None);
            self.context.Dispatch(width.div_ceil(16), height.div_ceil(16), 1);
        }
    }

    fn fill_uav_solid(&self, uav: &ID3D11UnorderedAccessView, x: u32, y: u32, w: u32, h: u32, rgb: [f32; 3]) -> bool {
        if w == 0 || h == 0 {
            return true;
        }
        if !self.write_params(ShaderParams {
            p0: [x, y, w, h],
            p1: [0; 4],
            f0: [rgb[0], rgb[1], rgb[2], 1.0],
        }) {
            return false;
        }
        let uavs = [Some(uav.clone())];
        unsafe {
            self.context.CSSetUnorderedAccessViews(0, 1, Some(uavs.as_ptr()), None);
        }
        self.dispatch(&self.pipes.solid_fill, w, h);
        self.clear_cs_bindings();
        true
    }

    fn ensure_avc444(&mut self, surface_id: u16) -> bool {
        let Some(surf) = self.surfaces.get(&surface_id) else {
            return false;
        };
        if surf.avc444.is_some() {
            return true;
        }
        let pw = u32::from(surf.width).next_multiple_of(16);
        let ph = u32::from(surf.height).next_multiple_of(16);
        let extra = (pw as usize).saturating_mul(ph as usize).saturating_mul(3);
        if self.budget_used.saturating_add(extra) > MAX_BUDGET_BYTES {
            return false;
        }
        let bind = (D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS).0 as u32;
        let Ok(y) = create_tex_2d(&self.device, pw, ph, DXGI_FORMAT_R8_UNORM, bind, 0) else {
            return false;
        };
        let Ok(u) = create_tex_2d(&self.device, pw, ph, DXGI_FORMAT_R8_UNORM, bind, 0) else {
            return false;
        };
        let Ok(v) = create_tex_2d(&self.device, pw, ph, DXGI_FORMAT_R8_UNORM, bind, 0) else {
            return false;
        };
        let (Ok(y_srv), Ok(y_uav), Ok(u_srv), Ok(u_uav), Ok(v_srv), Ok(v_uav)) = (
            create_srv(&self.device, &y, DXGI_FORMAT_R8_UNORM),
            create_uav(&self.device, &y, DXGI_FORMAT_R8_UNORM),
            create_srv(&self.device, &u, DXGI_FORMAT_R8_UNORM),
            create_uav(&self.device, &u, DXGI_FORMAT_R8_UNORM),
            create_srv(&self.device, &v, DXGI_FORMAT_R8_UNORM),
            create_uav(&self.device, &v, DXGI_FORMAT_R8_UNORM),
        ) else {
            return false;
        };
        unsafe {
            self.context.ClearUnorderedAccessViewFloat(&y_uav, &[0.0, 0.0, 0.0, 0.0]);
            let mid = 128.0 / 255.0;
            self.context.ClearUnorderedAccessViewFloat(&u_uav, &[mid, 0.0, 0.0, 0.0]);
            self.context.ClearUnorderedAccessViewFloat(&v_uav, &[mid, 0.0, 0.0, 0.0]);
        }
        if let Some(surf) = self.surfaces.get_mut(&surface_id) {
            surf.avc444 = Some(Avc444Planes {
                y_srv,
                y_uav,
                u_srv,
                u_uav,
                v_srv,
                v_uav,
                _y: y,
                _u: u,
                _v: v,
            });
            surf.bytes += extra;
            self.budget_used += extra;
            true
        } else {
            false
        }
    }

    fn upload_patch(
        &mut self,
        surface_id: u16,
        dest: &ExclusiveRectangle,
        pixels: &[u8],
        pitch: usize,
        src_origin: (u16, u16),
        format: DXGI_FORMAT,
        clearcodec: bool,
    ) -> bool {
        let Some((surf_w, surf_h, dst_uav, mapped)) = self
            .surfaces
            .get(&surface_id)
            .map(|s| (s.width, s.height, s.color_uav.clone(), s.mapped))
        else {
            return false;
        };
        let right = dest.right.min(surf_w);
        let bottom = dest.bottom.min(surf_h);
        if dest.left >= right || dest.top >= bottom {
            return true;
        }
        let w = u32::from(right - dest.left);
        let h = u32::from(bottom - dest.top);
        let row_bytes = (w as usize).saturating_mul(4);
        let start = usize::from(src_origin.1)
            .saturating_mul(pitch)
            .saturating_add(usize::from(src_origin.0).saturating_mul(4));
        let needed = start
            .saturating_add((h as usize).saturating_sub(1).saturating_mul(pitch))
            .saturating_add(row_bytes);
        if pitch < row_bytes || needed > pixels.len() {
            return false;
        }
        let Ok(staging) = create_tex_2d(&self.device, w, h, format, D3D11_BIND_SHADER_RESOURCE.0 as u32, 0) else {
            return false;
        };
        let Ok(srv) = create_srv(&self.device, &staging, format) else {
            return false;
        };
        unsafe {
            self.context
                .UpdateSubresource(&staging, 0, None, pixels.as_ptr().add(start).cast(), pitch as u32, 0);
        }
        if !self.write_params(ShaderParams {
            p0: [u32::from(dest.left), u32::from(dest.top), w, h],
            p1: [0; 4],
            f0: [0.0; 4],
        }) {
            return false;
        }
        let srvs = [Some(srv)];
        let uavs = [Some(dst_uav)];
        unsafe {
            self.context.CSSetShaderResources(0, Some(&srvs));
            self.context.CSSetUnorderedAccessViews(0, 1, Some(uavs.as_ptr()), None);
        }
        let pipe = if clearcodec {
            &self.pipes.clearcodec
        } else {
            &self.pipes.copy_opaque
        };
        self.dispatch(pipe, w, h);
        self.clear_cs_bindings();
        if let Some(surf) = self.surfaces.get_mut(&surface_id) {
            surf.painted = true;
        }
        if mapped {
            self.dirty = true;
        }
        true
    }
}

impl GpuCompositor for D3D11GpuCompositor {
    fn reset(&mut self, width: u32, height: u32) -> bool {
        if width == 0
            || height == 0
            || width > u32::from(u16::MAX)
            || height > u32::from(u16::MAX)
            || u64::from(width) * u64::from(height) > MAX_OUTPUT_PIXELS
        {
            return false;
        }
        for surf in self.surfaces.values() {
            self.budget_used = self.budget_used.saturating_sub(surf.bytes);
        }
        self.surfaces.clear();
        self.map_order.clear();
        self.dirty = false;

        let (w, h) = (width as u16, height as u16);
        if self.output_width != w || self.output_height != h || self.output_ring.len() != RING_SLOTS {
            self.output_ring.clear();
            self.pool_generation = self.pool_generation.wrapping_add(1).max(1);
            let bind = (D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET | D3D11_BIND_UNORDERED_ACCESS).0 as u32;
            for _ in 0..RING_SLOTS {
                let Ok(texture) = create_tex_2d(
                    &self.device,
                    width,
                    height,
                    DXGI_FORMAT_R8G8B8A8_UNORM,
                    bind,
                    D3D11_RESOURCE_MISC_SHARED.0 as u32,
                ) else {
                    self.output_ring.clear();
                    return false;
                };
                let Ok(uav) = create_uav(&self.device, &texture, DXGI_FORMAT_R8G8B8A8_UNORM) else {
                    self.output_ring.clear();
                    return false;
                };
                let Ok(resource) = texture.cast::<IDXGIResource>() else {
                    self.output_ring.clear();
                    return false;
                };
                let Ok(handle) = (unsafe { resource.GetSharedHandle() }) else {
                    self.output_ring.clear();
                    return false;
                };
                if handle.is_invalid() {
                    self.output_ring.clear();
                    return false;
                }
                self.output_ring.push(OutputSlot {
                    texture,
                    uav,
                    shared_handle: handle.0 as usize as u64,
                    generation: self.pool_generation,
                });
            }
            self.output_width = w;
            self.output_height = h;
            self.ring_index = 0;
        }
        true
    }

    fn create_surface(&mut self, id: u16, width: u16, height: u16) -> bool {
        if width == 0 || height == 0 {
            return false;
        }
        if let Some(old) = self.surfaces.remove(&id) {
            self.budget_used = self.budget_used.saturating_sub(old.bytes);
            self.map_order.retain(|&mapped_id| mapped_id != id);
        }
        let bytes = usize::from(width).saturating_mul(usize::from(height)).saturating_mul(4);
        if self.budget_used.saturating_add(bytes) > MAX_BUDGET_BYTES {
            return false;
        }
        let bind = (D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS).0 as u32;
        let Ok(color) = create_tex_2d(
            &self.device,
            u32::from(width),
            u32::from(height),
            DXGI_FORMAT_R8G8B8A8_UNORM,
            bind,
            0,
        ) else {
            return false;
        };
        let (Ok(color_srv), Ok(color_uav)) = (
            create_srv(&self.device, &color, DXGI_FORMAT_R8G8B8A8_UNORM),
            create_uav(&self.device, &color, DXGI_FORMAT_R8G8B8A8_UNORM),
        ) else {
            return false;
        };
        unsafe {
            self.context
                .ClearUnorderedAccessViewFloat(&color_uav, &[0.0, 0.0, 0.0, 1.0]);
        }
        self.surfaces.insert(
            id,
            SurfaceState {
                width,
                height,
                color,
                color_srv,
                color_uav,
                avc444: None,
                bytes,
                mapped: false,
                origin_x: 0,
                origin_y: 0,
                target_w: u32::from(width),
                target_h: u32::from(height),
                painted: false,
            },
        );
        self.budget_used += bytes;
        true
    }

    fn delete_surface(&mut self, id: u16) {
        if let Some(surf) = self.surfaces.remove(&id) {
            if surf.mapped && surf.painted {
                self.dirty = true;
            }
            self.budget_used = self.budget_used.saturating_sub(surf.bytes);
            self.map_order.retain(|&mapped_id| mapped_id != id);
        }
    }

    fn map_surface_scaled(&mut self, id: u16, origin: (u32, u32), target: (u32, u32)) -> bool {
        let Some(surf) = self.surfaces.get_mut(&id) else {
            return false;
        };
        surf.mapped = true;
        surf.origin_x = origin.0;
        surf.origin_y = origin.1;
        surf.target_w = if target.0 == 0 { u32::from(surf.width) } else { target.0 };
        surf.target_h = if target.1 == 0 { u32::from(surf.height) } else { target.1 };
        let painted = surf.painted;
        self.map_order.retain(|&mapped_id| mapped_id != id);
        self.map_order.push(id);
        if painted {
            self.dirty = true;
        }
        true
    }

    fn unmap_surface(&mut self, id: u16) {
        if let Some(surf) = self.surfaces.get_mut(&id)
            && surf.mapped
        {
            surf.mapped = false;
            self.map_order.retain(|&mapped_id| mapped_id != id);
            if surf.painted {
                self.dirty = true;
            }
        }
    }

    fn apply_hw_avc420(
        &mut self,
        surface_id: u16,
        frame: &dyn HwVideoFrame,
        dest: &ExclusiveRectangle,
        rects: &[ExclusiveRectangle],
    ) -> bool {
        let Some(nv12) = frame.as_any().downcast_ref::<D3D11Nv12Frame>() else {
            return false;
        };
        let Some((dst_uav, mapped)) = self.surfaces.get(&surface_id).map(|s| (s.color_uav.clone(), s.mapped)) else {
            return false;
        };
        let (Ok(y_srv), Ok(uv_srv)) = (
            create_srv(&self.device, nv12.texture(), DXGI_FORMAT_R8_UNORM),
            create_srv(&self.device, nv12.texture(), DXGI_FORMAT_R8G8_UNORM),
        ) else {
            return false;
        };
        let srvs = [Some(y_srv), Some(uv_srv)];
        let uavs = [Some(dst_uav)];
        unsafe {
            self.context.CSSetShaderResources(0, Some(&srvs));
            self.context.CSSetUnorderedAccessViews(0, 1, Some(uavs.as_ptr()), None);
        }
        let mut ok = true;
        if rects.is_empty() {
            if dest.left < dest.right && dest.top < dest.bottom {
                let w = u32::from(dest.right - dest.left);
                let h = u32::from(dest.bottom - dest.top);
                ok = self.write_params(ShaderParams {
                    p0: [0, 0, u32::from(dest.left), u32::from(dest.top)],
                    p1: [w, h, 0, 0],
                    f0: [0.0; 4],
                });
                if ok {
                    self.dispatch(&self.pipes.avc420, w, h);
                }
            }
        } else {
            for r in rects {
                if r.left >= r.right || r.top >= r.bottom {
                    continue;
                }
                let w = u32::from(r.right - r.left);
                let h = u32::from(r.bottom - r.top);
                if !self.write_params(ShaderParams {
                    p0: [u32::from(r.left), u32::from(r.top), u32::from(r.left), u32::from(r.top)],
                    p1: [w, h, 0, 0],
                    f0: [0.0; 4],
                }) {
                    ok = false;
                    break;
                }
                self.dispatch(&self.pipes.avc420, w, h);
            }
        }
        self.clear_cs_bindings();
        if ok {
            if let Some(surf) = self.surfaces.get_mut(&surface_id) {
                surf.painted = true;
            }
            if mapped {
                self.dirty = true;
            }
        }
        ok
    }

    fn apply_hw_avc444(
        &mut self,
        surface_id: u16,
        layout: Avc444Layout,
        main: Option<(&dyn HwVideoFrame, &[ExclusiveRectangle])>,
        auxiliary: Option<(&dyn HwVideoFrame, &[ExclusiveRectangle])>,
        painted: &[ExclusiveRectangle],
    ) -> bool {
        let Some((surf_w, surf_h, has_planes, mapped)) = self
            .surfaces
            .get(&surface_id)
            .map(|s| (s.width, s.height, s.avc444.is_some(), s.mapped))
        else {
            return false;
        };
        if main.is_none() && !has_planes {
            return true;
        }
        if !self.ensure_avc444(surface_id) {
            return false;
        }
        let (y_srv, y_uav, u_srv, u_uav, v_srv, v_uav, color_uav) = {
            let s = &self.surfaces[&surface_id];
            let p = s.avc444.as_ref().unwrap();
            (
                p.y_srv.clone(),
                p.y_uav.clone(),
                p.u_srv.clone(),
                p.u_uav.clone(),
                p.v_srv.clone(),
                p.v_uav.clone(),
                s.color_uav.clone(),
            )
        };

        if let Some((frame, rects)) = main
            && !rects.is_empty()
        {
            let Some(nv12) = frame.as_any().downcast_ref::<D3D11Nv12Frame>() else {
                return false;
            };
            let (Ok(in_y), Ok(in_uv)) = (
                create_srv(&self.device, nv12.texture(), DXGI_FORMAT_R8_UNORM),
                create_srv(&self.device, nv12.texture(), DXGI_FORMAT_R8G8_UNORM),
            ) else {
                return false;
            };
            let srvs = [Some(in_y), Some(in_uv)];
            let uavs = [Some(y_uav.clone()), Some(u_uav.clone()), Some(v_uav.clone())];
            unsafe {
                self.context.CSSetShaderResources(0, Some(&srvs));
                self.context.CSSetUnorderedAccessViews(0, 3, Some(uavs.as_ptr()), None);
            }
            for r in rects {
                let left = u32::from(r.left) & !1;
                let top = u32::from(r.top) & !1;
                let right = u32::from(r.right.min(surf_w)).next_multiple_of(2);
                let bottom = u32::from(r.bottom.min(surf_h)).next_multiple_of(2);
                if left >= right || top >= bottom {
                    continue;
                }
                if !self.write_params(ShaderParams {
                    p0: [left, top, right - left, bottom - top],
                    p1: [
                        u32::from(r.left),
                        u32::from(r.top),
                        u32::from(r.right.min(surf_w)),
                        u32::from(r.bottom.min(surf_h)),
                    ],
                    f0: [0.0; 4],
                }) {
                    self.clear_cs_bindings();
                    return false;
                }
                self.dispatch(&self.pipes.avc444_main, right - left, bottom - top);
            }
            self.clear_cs_bindings();
        }

        if let Some((frame, rects)) = auxiliary
            && !rects.is_empty()
        {
            let Some(nv12) = frame.as_any().downcast_ref::<D3D11Nv12Frame>() else {
                return false;
            };
            let (Ok(in_y), Ok(in_uv)) = (
                create_srv(&self.device, nv12.texture(), DXGI_FORMAT_R8_UNORM),
                create_srv(&self.device, nv12.texture(), DXGI_FORMAT_R8G8_UNORM),
            ) else {
                return false;
            };
            let padded_w = frame.width().next_multiple_of(16);
            let half_w = padded_w / 2;
            let quarter_w = half_w / 2;
            let srvs = [Some(in_y), Some(in_uv)];
            let uavs = [None, Some(u_uav), Some(v_uav)];
            unsafe {
                self.context.CSSetShaderResources(0, Some(&srvs));
                self.context.CSSetUnorderedAccessViews(0, 3, Some(uavs.as_ptr()), None);
            }
            let pipe = match layout {
                Avc444Layout::V1 => &self.pipes.avc444_aux_v1,
                Avc444Layout::V2 => &self.pipes.avc444_aux_v2,
            };
            for r in rects {
                let left = u32::from(r.left) & !1;
                let top = u32::from(r.top) & !1;
                let right = u32::from(r.right.min(surf_w)).next_multiple_of(2);
                let bottom = u32::from(r.bottom.min(surf_h)).next_multiple_of(2);
                if left >= right || top >= bottom {
                    continue;
                }
                if !self.write_params(ShaderParams {
                    p0: [left, top, right - left, bottom - top],
                    p1: [half_w, quarter_w, 0, 0],
                    f0: [0.0; 4],
                }) {
                    self.clear_cs_bindings();
                    return false;
                }
                self.dispatch(pipe, right - left, bottom - top);
            }
            self.clear_cs_bindings();
        }

        if !painted.is_empty() {
            let srvs = [Some(y_srv), Some(u_srv), Some(v_srv)];
            let uavs = [Some(color_uav)];
            unsafe {
                self.context.CSSetShaderResources(0, Some(&srvs));
                self.context.CSSetUnorderedAccessViews(0, 1, Some(uavs.as_ptr()), None);
            }
            for r in painted {
                let right = r.right.min(surf_w);
                let bottom = r.bottom.min(surf_h);
                if r.left >= right || r.top >= bottom {
                    continue;
                }
                let w = u32::from(right - r.left);
                let h = u32::from(bottom - r.top);
                if !self.write_params(ShaderParams {
                    p0: [u32::from(r.left), u32::from(r.top), w, h],
                    p1: [0; 4],
                    f0: [0.0; 4],
                }) {
                    self.clear_cs_bindings();
                    return false;
                }
                self.dispatch(&self.pipes.avc444_to_rgba, w, h);
            }
            self.clear_cs_bindings();
            if let Some(surf) = self.surfaces.get_mut(&surface_id) {
                surf.painted = true;
            }
            if mapped {
                self.dirty = true;
            }
        }
        true
    }

    fn apply_rgba_region(
        &mut self,
        surface_id: u16,
        dest: &ExclusiveRectangle,
        rgba: &[u8],
        source_pitch: usize,
        source_origin: (u16, u16),
    ) -> bool {
        self.upload_patch(
            surface_id,
            dest,
            rgba,
            source_pitch,
            source_origin,
            DXGI_FORMAT_R8G8B8A8_UNORM,
            false,
        )
    }

    fn apply_clearcodec(&mut self, surface_id: u16, dest: &ExclusiveRectangle, bgra_coverage: &[u8]) -> bool {
        if dest.left >= dest.right || dest.top >= dest.bottom {
            return true;
        }
        let pitch = usize::from(dest.right - dest.left).saturating_mul(4);
        self.upload_patch(
            surface_id,
            dest,
            bgra_coverage,
            pitch,
            (0, 0),
            DXGI_FORMAT_B8G8R8A8_UNORM,
            true,
        )
    }

    fn solid_fill(&mut self, surface_id: u16, color: &Color, rects: &[ExclusiveRectangle]) -> bool {
        let Some((surf_w, surf_h, uav, mapped)) = self
            .surfaces
            .get(&surface_id)
            .map(|s| (s.width, s.height, s.color_uav.clone(), s.mapped))
        else {
            return false;
        };
        let rgb = [
            f32::from(color.r) / 255.0,
            f32::from(color.g) / 255.0,
            f32::from(color.b) / 255.0,
        ];
        for r in rects {
            let right = r.right.min(surf_w);
            let bottom = r.bottom.min(surf_h);
            if r.left >= right || r.top >= bottom {
                continue;
            }
            if !self.fill_uav_solid(
                &uav,
                u32::from(r.left),
                u32::from(r.top),
                u32::from(right - r.left),
                u32::from(bottom - r.top),
                rgb,
            ) {
                return false;
            }
            if let Some(surf) = self.surfaces.get_mut(&surface_id) {
                surf.painted = true;
            }
            if mapped {
                self.dirty = true;
            }
        }
        true
    }

    fn surface_to_surface(
        &mut self,
        src_id: u16,
        dst_id: u16,
        src_rect: &ExclusiveRectangle,
        dst_points: &[Point],
    ) -> bool {
        let Some((src_w, src_h, src_tex)) = self.surfaces.get(&src_id).map(|s| (s.width, s.height, s.color.clone()))
        else {
            return false;
        };
        let Some((dst_w, dst_h, dst_tex, mapped)) = self
            .surfaces
            .get(&dst_id)
            .map(|s| (s.width, s.height, s.color.clone(), s.mapped))
        else {
            return false;
        };
        let sr = src_rect.right.min(src_w);
        let sb = src_rect.bottom.min(src_h);
        if src_rect.left >= sr || src_rect.top >= sb || dst_points.is_empty() {
            return true;
        }
        let w = u32::from(sr - src_rect.left);
        let h = u32::from(sb - src_rect.top);
        let (copy_src, copy_left, copy_top) = if src_id == dst_id {
            let Ok(scratch) = create_tex_2d(&self.device, w, h, DXGI_FORMAT_R8G8B8A8_UNORM, 0, 0) else {
                return false;
            };
            let box_ = D3D11_BOX {
                left: u32::from(src_rect.left),
                top: u32::from(src_rect.top),
                front: 0,
                right: u32::from(sr),
                bottom: u32::from(sb),
                back: 1,
            };
            unsafe {
                self.context
                    .CopySubresourceRegion(&scratch, 0, 0, 0, 0, &src_tex, 0, Some(&box_));
            }
            (scratch, 0u32, 0u32)
        } else {
            (src_tex, u32::from(src_rect.left), u32::from(src_rect.top))
        };
        for pt in dst_points {
            let dx = u32::from(pt.x);
            let dy = u32::from(pt.y);
            if dx >= u32::from(dst_w) || dy >= u32::from(dst_h) {
                continue;
            }
            let cw = w.min(u32::from(dst_w) - dx);
            let ch = h.min(u32::from(dst_h) - dy);
            if cw == 0 || ch == 0 {
                continue;
            }
            let box_ = D3D11_BOX {
                left: copy_left,
                top: copy_top,
                front: 0,
                right: copy_left + cw,
                bottom: copy_top + ch,
                back: 1,
            };
            unsafe {
                self.context
                    .CopySubresourceRegion(&dst_tex, 0, dx, dy, 0, &copy_src, 0, Some(&box_));
            }
        }
        if let Some(surf) = self.surfaces.get_mut(&dst_id) {
            surf.painted = true;
        }
        if mapped {
            self.dirty = true;
        }
        true
    }

    fn surface_to_cache(&mut self, surface_id: u16, cache_slot: u16, src_rect: &ExclusiveRectangle) -> bool {
        let Some((src_w, src_h, src_tex)) = self
            .surfaces
            .get(&surface_id)
            .map(|s| (s.width, s.height, s.color.clone()))
        else {
            return false;
        };
        let sr = src_rect.right.min(src_w);
        let sb = src_rect.bottom.min(src_h);
        if src_rect.left >= sr || src_rect.top >= sb {
            return false;
        }
        let w = sr - src_rect.left;
        let h = sb - src_rect.top;
        if let Some(prev) = self.cache.remove(&cache_slot) {
            self.budget_used = self.budget_used.saturating_sub(prev.bytes);
        }
        let bytes = usize::from(w).saturating_mul(usize::from(h)).saturating_mul(4);
        if self.budget_used.saturating_add(bytes) > MAX_BUDGET_BYTES {
            return false;
        }
        let Ok(tex) = create_tex_2d(
            &self.device,
            u32::from(w),
            u32::from(h),
            DXGI_FORMAT_R8G8B8A8_UNORM,
            0,
            0,
        ) else {
            return false;
        };
        let box_ = D3D11_BOX {
            left: u32::from(src_rect.left),
            top: u32::from(src_rect.top),
            front: 0,
            right: u32::from(sr),
            bottom: u32::from(sb),
            back: 1,
        };
        unsafe {
            self.context
                .CopySubresourceRegion(&tex, 0, 0, 0, 0, &src_tex, 0, Some(&box_));
        }
        self.cache.insert(
            cache_slot,
            CacheEntry {
                width: w,
                height: h,
                texture: tex,
                bytes,
            },
        );
        self.budget_used += bytes;
        true
    }

    fn cache_to_surface(&mut self, cache_slot: u16, surface_id: u16, dst_points: &[Point]) -> bool {
        let Some((cw_max, ch_max, src_tex)) = self
            .cache
            .get(&cache_slot)
            .map(|e| (u32::from(e.width), u32::from(e.height), e.texture.clone()))
        else {
            return false;
        };
        let Some((dst_w, dst_h, dst_tex, mapped)) = self
            .surfaces
            .get(&surface_id)
            .map(|s| (u32::from(s.width), u32::from(s.height), s.color.clone(), s.mapped))
        else {
            return false;
        };
        for pt in dst_points {
            let dx = u32::from(pt.x);
            let dy = u32::from(pt.y);
            if dx >= dst_w || dy >= dst_h {
                continue;
            }
            let cw = cw_max.min(dst_w - dx);
            let ch = ch_max.min(dst_h - dy);
            if cw == 0 || ch == 0 {
                continue;
            }
            let box_ = D3D11_BOX {
                left: 0,
                top: 0,
                front: 0,
                right: cw,
                bottom: ch,
                back: 1,
            };
            unsafe {
                self.context
                    .CopySubresourceRegion(&dst_tex, 0, dx, dy, 0, &src_tex, 0, Some(&box_));
            }
        }
        if let Some(surf) = self.surfaces.get_mut(&surface_id) {
            surf.painted = true;
        }
        if mapped {
            self.dirty = true;
        }
        true
    }

    fn evict_cache_entry(&mut self, cache_slot: u16) {
        if let Some(entry) = self.cache.remove(&cache_slot) {
            self.budget_used = self.budget_used.saturating_sub(entry.bytes);
        }
    }

    fn end_frame(&mut self) -> Option<Box<dyn GpuPresentedFrame>> {
        if !self.dirty || self.output_ring.is_empty() || self.output_width == 0 || self.output_height == 0 {
            return None;
        }
        if unsafe { self.device.GetDeviceRemovedReason() }.is_err() {
            warn!("D3D11 GPU compositor device removed");
            return None;
        }

        let slot = &self.output_ring[self.ring_index];
        let out_tex = slot.texture.clone();
        let out_uav = slot.uav.clone();
        let out_handle = slot.shared_handle;
        let out_generation = slot.generation;
        self.ring_index = (self.ring_index + 1) % self.output_ring.len();

        let (out_w, out_h) = (u32::from(self.output_width), u32::from(self.output_height));
        let mut fast_covered = false;
        if self.map_order.len() == 1
            && let Some(only) = self.surfaces.get(&self.map_order[0])
            && only.mapped
            && only.origin_x == 0
            && only.origin_y == 0
            && u32::from(only.width) == out_w
            && u32::from(only.height) == out_h
            && only.target_w == out_w
            && only.target_h == out_h
        {
            unsafe {
                self.context.CopyResource(&out_tex, &only.color);
            }
            fast_covered = true;
        }

        if !fast_covered {
            unsafe {
                self.context
                    .ClearUnorderedAccessViewFloat(&out_uav, &[0.0, 0.0, 0.0, 1.0]);
            }
            let mapped_ids = self.map_order.clone();
            for id in mapped_ids {
                let Some(surf) = self.surfaces.get(&id) else {
                    continue;
                };
                if !surf.mapped || surf.origin_x >= out_w || surf.origin_y >= out_h {
                    continue;
                }
                if surf.target_w == u32::from(surf.width) && surf.target_h == u32::from(surf.height) {
                    let cw = u32::from(surf.width).min(out_w - surf.origin_x);
                    let ch = u32::from(surf.height).min(out_h - surf.origin_y);
                    if cw == 0 || ch == 0 {
                        continue;
                    }
                    let box_ = D3D11_BOX {
                        left: 0,
                        top: 0,
                        front: 0,
                        right: cw,
                        bottom: ch,
                        back: 1,
                    };
                    unsafe {
                        self.context.CopySubresourceRegion(
                            &out_tex,
                            0,
                            surf.origin_x,
                            surf.origin_y,
                            0,
                            &surf.color,
                            0,
                            Some(&box_),
                        );
                    }
                } else {
                    let srvs = [Some(surf.color_srv.clone())];
                    let uavs = [Some(out_uav.clone())];
                    let samplers = [Some(self.sampler.clone())];
                    if !self.write_params(ShaderParams {
                        p0: [surf.origin_x, surf.origin_y, surf.target_w, surf.target_h],
                        p1: [u32::from(surf.width), u32::from(surf.height), 0, 0],
                        f0: [0.0; 4],
                    }) {
                        return None;
                    }
                    unsafe {
                        self.context.CSSetShaderResources(0, Some(&srvs));
                        self.context.CSSetUnorderedAccessViews(0, 1, Some(uavs.as_ptr()), None);
                        self.context.CSSetSamplers(0, Some(&samplers));
                    }
                    self.dispatch(&self.pipes.blit_scaled, surf.target_w, surf.target_h);
                    self.clear_cs_bindings();
                }
            }
        }

        self.fence_value = self.fence_value.wrapping_add(1);
        if unsafe { self.fenced_context.Signal(&self.fence, self.fence_value) }.is_err()
            || unsafe { self.fence.SetEventOnCompletion(self.fence_value, self.fence_event) }.is_err()
        {
            return None;
        }
        unsafe {
            self.context.Flush();
            if WaitForSingleObject(self.fence_event, 64) != WAIT_OBJECT_0
                || self.device.GetDeviceRemovedReason().is_err()
            {
                return None;
            }
        }
        self.dirty = false;
        Some(Box::new(D3D11PresentedFrame {
            width: self.output_width,
            height: self.output_height,
            handle: out_handle,
            generation: out_generation,
        }))
    }
}
