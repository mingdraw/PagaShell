//! Host bridge for optional native textures. On Windows the RDP worker
//! still owns the protocol; this removes the Dart pixel transfer.
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use crate::api::desktop::{DesktopFrame, DesktopTile};

#[repr(C)]
struct FrameView {
    width: u16,
    height: u16,
    bitmap_width: u16,
    bitmap_height: u16,
    rgba: *const u8,
    rgba_len: usize,
    tiles: *const DesktopTile,
    tile_count: usize,
}

#[repr(C)]
struct GpuSurfaceView {
    kind: u32,
    width: u16,
    height: u16,
    handle: u64,
    generation: u64,
}

#[cfg(target_os = "macos")]
pub(crate) const GPU_SURFACE_CV_PIXEL_BUFFER: u32 = 1;
#[cfg(any(windows, test))]
pub(crate) const GPU_SURFACE_DXGI_SHARED_HANDLE: u32 = 2;

type Submit = unsafe extern "C" fn(*mut c_void, *const FrameView) -> bool;
type SubmitGpu = unsafe extern "C" fn(*mut c_void, *const GpuSurfaceView) -> bool;
type Release = unsafe extern "C" fn(*mut c_void);

struct Consumer {
    texture_id: i64,
    context: usize,
    submit: Submit,
    submit_gpu: Mutex<Option<(SubmitGpu, u64)>>,
    release: Release,
}

impl Drop for Consumer {
    fn drop(&mut self) {
        // The runner transfers one owning reference on successful attach.
        unsafe { (self.release)(self.context as *mut c_void) };
    }
}

static CONSUMERS: LazyLock<Mutex<HashMap<u32, Arc<Consumer>>>> = LazyLock::new(Default::default);

pub(crate) struct Presenter(Arc<Consumer>);

impl Presenter {
    pub fn for_session(session: u32) -> Option<Self> {
        CONSUMERS.lock().ok()?.get(&session).cloned().map(Self)
    }

    pub fn supports_gpu(&self) -> bool {
        self.0
            .submit_gpu
            .lock()
            .ok()
            .is_some_and(|gpu| gpu.is_some())
    }

    #[cfg(any(windows, test))]
    pub fn adapter_luid(&self) -> Option<u64> {
        self.0.submit_gpu.lock().ok()?.map(|(_, luid)| luid)
    }

    /// Submit a GPU-resident surface handle synchronously without CPU readback.
    pub fn submit_gpu(
        &self,
        frame: &mut DesktopFrame,
        kind: u32,
        handle: u64,
        generation: u64,
    ) -> Result<(), ()> {
        let submit_gpu = self
            .0
            .submit_gpu
            .lock()
            .ok()
            .and_then(|gpu| gpu.map(|(f, _)| f))
            .ok_or(())?;
        let view = GpuSurfaceView {
            kind,
            width: frame.width,
            height: frame.height,
            handle,
            generation,
        };
        if !unsafe { (submit_gpu)(self.0.context as *mut c_void, &view) } {
            return Err(());
        }
        frame.texture_id = Some(self.0.texture_id);
        frame.rgba = Vec::new();
        frame.tiles = Vec::new();
        frame.bitmap_width = 0;
        frame.bitmap_height = 0;
        Ok(())
    }

    /// Submit the borrowed pixel view synchronously. The runner must finish
    /// reading it before returning; it owns any separate raster storage.
    pub fn submit(&self, frame: &mut DesktopFrame, pixels: &[u8]) -> Result<(), ()> {
        let consumer = &self.0;
        let view = FrameView {
            width: frame.width,
            height: frame.height,
            bitmap_width: frame.bitmap_width,
            bitmap_height: frame.bitmap_height,
            rgba: pixels.as_ptr(),
            rgba_len: pixels.len(),
            tiles: frame.tiles.as_ptr(),
            tile_count: frame.tiles.len(),
        };
        if !unsafe { (consumer.submit)(consumer.context as *mut c_void, &view) } {
            return Err(());
        }
        frame.texture_id = Some(consumer.texture_id);
        frame.tiles = Vec::new();
        frame.bitmap_width = 0;
        frame.bitmap_height = 0;
        Ok(())
    }
}

// Callbacks must be safe on any thread; FrameView and its buffers are borrowed
// solely for the duration of the synchronous submit call.
#[no_mangle]
extern "C" fn pagashell_rdp_texture_attach(
    session: u32,
    texture_id: i64,
    context: *mut c_void,
    submit: Option<Submit>,
    release: Option<Release>,
) -> bool {
    let (Some(submit), Some(release)) = (submit, release) else {
        return false;
    };
    if texture_id == -1 || context.is_null() {
        return false;
    }
    let Ok(mut consumers) = CONSUMERS.lock() else {
        return false;
    };
    let std::collections::hash_map::Entry::Vacant(entry) = consumers.entry(session) else {
        return false;
    };
    entry.insert(Arc::new(Consumer {
        texture_id,
        context: context as usize,
        submit,
        submit_gpu: Mutex::new(None),
        release,
    }));
    true
}

#[no_mangle]
extern "C" fn pagashell_rdp_texture_attach_gpu(
    session: u32,
    submit_gpu: Option<SubmitGpu>,
    adapter_luid: u64,
) -> bool {
    let Some(submit_gpu) = submit_gpu else {
        return false;
    };
    let Ok(consumers) = CONSUMERS.lock() else {
        return false;
    };
    let Some(consumer) = consumers.get(&session) else {
        return false;
    };
    let Ok(mut slot) = consumer.submit_gpu.lock() else {
        return false;
    };
    *slot = Some((submit_gpu, adapter_luid));
    true
}

#[no_mangle]
pub(crate) extern "C" fn pagashell_rdp_texture_detach(session: u32) {
    let detached = CONSUMERS
        .lock()
        .ok()
        .and_then(|mut consumers| consumers.remove(&session));
    drop(detached);
}

/// On a failed upload the caller must request a full CPU frame, since Dart no
/// longer has the base for the incremental patches it previously skipped.
pub(crate) async fn present(session: u32, frame: DesktopFrame) -> Result<DesktopFrame, ()> {
    let Some(presenter) = Presenter::for_session(session) else {
        return Ok(frame);
    };
    run_upload(session, move || {
        let mut frame = frame;
        let pixels = std::mem::take(&mut frame.rgba);
        presenter.submit(&mut frame, &pixels)?;
        Ok(frame)
    })
    .await
}

#[cfg(any(target_os = "macos", windows))]
pub(crate) async fn present_gpu(
    session: u32,
    frame: DesktopFrame,
    gpu: Box<dyn ironrdp_egfx::gpu::GpuPresentedFrame>,
) -> Result<DesktopFrame, ()> {
    let Some(presenter) = Presenter::for_session(session) else {
        return Err(());
    };
    #[cfg(target_os = "macos")]
    let info = gpu
        .as_any()
        .downcast_ref::<ironrdp_egfx_native::MetalPresentedFrame>()
        .map(|metal| (GPU_SURFACE_CV_PIXEL_BUFFER, metal.raw_pixel_buffer(), 0u64));
    #[cfg(windows)]
    let info = gpu
        .as_any()
        .downcast_ref::<ironrdp_egfx_native::D3D11PresentedFrame>()
        .map(|d3d| {
            (
                GPU_SURFACE_DXGI_SHARED_HANDLE,
                d3d.shared_handle(),
                d3d.generation(),
            )
        });
    let Some((kind, handle, generation)) = info else {
        return Err(());
    };
    run_upload(session, move || {
        let _keep_alive = gpu;
        let mut frame = frame;
        presenter.submit_gpu(&mut frame, kind, handle, generation)?;
        Ok(frame)
    })
    .await
}

pub(crate) async fn run_upload<T: Send + 'static>(
    session: u32,
    submit: impl FnOnce() -> Result<T, ()> + Send + 'static,
) -> Result<T, ()> {
    let upload = tokio::task::spawn_blocking(submit);
    match tokio::time::timeout(Duration::from_millis(500), upload).await {
        Ok(Ok(Ok(frame))) => Ok(frame),
        _ => {
            pagashell_rdp_texture_detach(session);
            Err(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Default)]
    struct Probe {
        calls: AtomicUsize,
        releases: AtomicUsize,
    }

    unsafe extern "C" fn submit(context: *mut c_void, frame: *const FrameView) -> bool {
        let probe = unsafe { &*context.cast::<Probe>() };
        probe.calls.fetch_add(1, Ordering::Relaxed);
        let frame = unsafe { &*frame };
        frame.width == 2
            && frame.tile_count == 0
            && unsafe { std::slice::from_raw_parts(frame.rgba, frame.rgba_len) }
                == [0, 0, 0, 255, 42, 0, 0, 255]
    }

    unsafe extern "C" fn release(context: *mut c_void) {
        let probe = unsafe { Arc::from_raw(context.cast::<Probe>()) };
        probe.releases.fetch_add(1, Ordering::Relaxed);
    }

    #[tokio::test]
    async fn native_consumer_receives_pixels_then_dart_gets_metadata_or_cpu_fallback() {
        let session = u32::MAX;
        let probe = Arc::new(Probe::default());
        let context = Arc::into_raw(Arc::clone(&probe))
            .cast_mut()
            .cast::<c_void>();
        assert!(pagashell_rdp_texture_attach(
            session,
            123,
            context,
            Some(submit),
            Some(release)
        ));
        let frame = |width| DesktopFrame {
            sequence: 3,
            width,
            height: 1,
            bitmap_width: width,
            bitmap_height: 1,
            rgba: vec![0, 0, 0, 255, 42, 0, 0, 255],
            tiles: vec![],
            cursor: None,
            texture_id: None,
        };
        let metadata = present(session, frame(2)).await.unwrap();
        assert_eq!(metadata.texture_id, Some(123));
        assert!(metadata.rgba.is_empty());
        assert_eq!((metadata.width, metadata.height), (2, 1));
        assert_eq!((metadata.bitmap_width, metadata.bitmap_height), (0, 0));
        assert!(present(session, frame(3)).await.is_err());
        assert_eq!(probe.calls.load(Ordering::Relaxed), 2);
        assert_eq!(probe.releases.load(Ordering::Relaxed), 1);
        let fallback = present(session, frame(2)).await.unwrap();
        assert!(fallback.texture_id.is_none());
        assert_eq!(fallback.rgba, [0, 0, 0, 255, 42, 0, 0, 255]);
    }

    unsafe extern "C" fn submit_gpu_ok(
        _context: *mut c_void,
        surface: *const GpuSurfaceView,
    ) -> bool {
        let surface = unsafe { &*surface };
        surface.kind == GPU_SURFACE_DXGI_SHARED_HANDLE
            && surface.handle == 0x1234
            && surface.generation == 9
            && surface.width == 1280
            && surface.height == 720
    }

    #[test]
    fn gpu_surface_registration_exposes_adapter_luid_and_submits_metadata() {
        let session = u32::MAX - 1;
        let probe = Arc::new(Probe::default());
        let context = Arc::into_raw(Arc::clone(&probe))
            .cast_mut()
            .cast::<c_void>();
        assert!(pagashell_rdp_texture_attach(
            session,
            456,
            context,
            Some(submit),
            Some(release)
        ));
        let presenter = Presenter::for_session(session).unwrap();
        assert!(!presenter.supports_gpu());
        assert!(pagashell_rdp_texture_attach_gpu(
            session,
            Some(submit_gpu_ok),
            0xAABB_CCDD
        ));
        assert!(presenter.supports_gpu());
        assert_eq!(presenter.adapter_luid(), Some(0xAABB_CCDD));
        let mut frame = DesktopFrame {
            sequence: 1,
            width: 1280,
            height: 720,
            bitmap_width: 0,
            bitmap_height: 0,
            rgba: Vec::new(),
            tiles: Vec::new(),
            cursor: None,
            texture_id: None,
        };
        assert!(presenter
            .submit_gpu(&mut frame, GPU_SURFACE_DXGI_SHARED_HANDLE, 0x1234, 9)
            .is_ok());
        assert_eq!(frame.texture_id, Some(456));
        assert!(presenter
            .submit_gpu(&mut frame, GPU_SURFACE_DXGI_SHARED_HANDLE, 0x9999, 9)
            .is_err());
        pagashell_rdp_texture_detach(session);
        drop(presenter);
        assert_eq!(probe.releases.load(Ordering::Relaxed), 1);
    }
}
