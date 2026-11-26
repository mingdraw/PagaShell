# Local IronRDP patches

The vendored IronRDP crates are based on upstream
[IronRDP 85e88c2](https://github.com/Devolutions/IronRDP/commit/85e88c2424d8c36407f81540cc1f3cf8d3436a7d).
The crate manifests pin the exact same Git revision for all non-vendored
IronRDP crates so every crate shares identical protocol types. Licenses and
third-party notices are preserved in each vendored crate directory.

## Patch series (`rust/vendor/patches/`)

Each vendored crate's diff against upstream `85e88c2` (excluding standalone
`Cargo.toml` manifest adaptation) is also exported as a clean, reviewable
unified patch under `rust/vendor/patches/` to facilitate upstream PRs and
future IronRDP rebases:

1. `0001-ironrdp-graphics-clearcodec-coverage-and-progressive-scratch.patch`
   - Explicit ClearCodec pixel coverage convention so glyph cache hits preserve
     original coverage instead of importing a previous surface's background
     (fixes black-block artifacts).
   - Reuses ClearCodec and Progressive scratch storage and preserves valid
     Progressive tiles when another tile fails to decode.
2. `0002-ironrdp-egfx-compositor-gpu-hooks-and-avc-direct.patch`
   - Retains untouched ClearCodec pixels, reports missing cache entries, and
     reports exact remaining EGFX bytes in `FrameAcknowledge`.
   - Direct AVC420 YUV→RGBA decoding from borrowed OpenH264 planes and direct
     output blitting into an opaque framebuffer with deferred ordered ACKs.
   - Adds `ironrdp_egfx::gpu` (`HwVideoFrame`, `GpuPresentedFrame`,
     `GpuCompositor`) and `H264Decoder::decode_hw` hooks so hardware-decoded
     AVC420 / AVC444 / AVC444v2 and mixed EGFX surface commands can composite
     directly on the GPU with automatic CPU fallback.
3. `0003-ironrdp-egfx-native-hw-decoders-and-gpu-compositors.patch`
   - Hardware H.264 decoders: Media Foundation + D3D11 (Windows), VideoToolbox
     (macOS), and runtime-loaded FFmpeg VA-API (Linux).
   - Zero-readback GPU EGFX compositors:
     - macOS `MetalGpuCompositor` (VideoToolbox NV12 `CVPixelBuffer` → Metal
       compute shaders → pooled IOSurface-backed BGRA `CVPixelBuffer`).
     - Windows `D3D11GpuCompositor` (shared multithreaded `ID3D11Device` with
       Media Foundation → HLSL compute shaders → triple-buffered
       `D3D11_RESOURCE_MISC_SHARED` DXGI output ring + `ID3D11Fence`).
4. `0004-ironrdp-session-direct-blit-and-gdi-caches.patch`
   - Direct opaque RGBA32 blitting from EGFX into `DecodedImage` and bypass of
     CPU draining when a `GpuCompositor` is active.
   - Classic MS-RDPEGDI drawing order decoder & renderer (`gdi.rs`) with
     memory-bounded `BitmapCache` / `BitmapCacheRev2` (32 MiB), `GlyphCache` +
     fragment cache (8 MiB), `OffscreenBitmapCache` (16 MiB), and primary /
     secondary / alternate-secondary orders (`DstBlt`, `PatBlt`, `ScrBlt`,
     `OpaqueRect`, `MultiOpaqueRect`, `MemBlt`, `FastIndex`, `FastGlyph`,
     `GlyphIndex`, `SwitchSurface`, `CreateOffscreenBitmap`, `FrameMarker`),
     reset cleanly on session reactivation.
5. `0005-ironrdp-connector-gdi-cache-capabilities.patch`
   - Adds opt-in `Config::enable_gdi_caches` (default `false`) to advertise
     classic MS-RDPEGDI `Order`, `BitmapCacheRev2`, `GlyphCache` (`Full`), and
     `OffscreenBitmapCache` capabilities for non-EGFX servers.
6. `0006-ironrdp-rdpeudp-tokio-pinned-tls-config.patch`
   - Allows supplying a complete client `rustls::ClientConfig` so PagaShell pins
     the UDP multitransport TLS handshake to the verified primary TCP leaf
     certificate.

## Testing & rebasing

Regression tests in `rust/src/desktop.rs`, `rust/src/rdp.rs`,
`rust/vendor/ironrdp-egfx`, and `rust/vendor/ironrdp-egfx-native` verify
ClearCodec coverage, EGFX H.264/AVC444/Progressive/ACKs, Metal GPU composition,
classic GDI caches/orders, and capability negotiation. When rebasing onto a
newer IronRDP commit, apply or drop merged patches from `rust/vendor/patches/`,
update all vendored `Cargo.toml` manifests to the new commit hash together, and
refresh `rust/Cargo.lock`.
