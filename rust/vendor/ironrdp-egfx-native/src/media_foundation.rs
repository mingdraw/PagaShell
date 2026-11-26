//! H.264 decoding with the Media Foundation decoder transform.

use core::any::Any;
use core::time::Duration;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};

use ironrdp_egfx::decode::{DecodedFrame, DecoderError, DecoderResult, H264Decoder, Yuv420Frame};
use ironrdp_egfx::gpu::HwVideoFrame;
use ironrdp_egfx::pdu::{avc_to_annex_b_into, is_avc_format};
use tracing::{debug, warn};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
use windows::Win32::Graphics::Direct3D10::ID3D10Multithread;
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_SHADER_RESOURCE, D3D11_BOX, D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT, D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
    ID3D11VideoDevice,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_NV12, DXGI_SAMPLE_DESC};
use windows::Win32::Media::MediaFoundation::{
    CLSID_MSH264DecoderMFT, IMF2DBuffer, IMFDXGIBuffer, IMFDXGIDeviceManager, IMFMediaType, IMFSample, IMFTransform,
    MF_E_NOTACCEPTING, MF_E_TRANSFORM_NEED_MORE_INPUT, MF_E_TRANSFORM_STREAM_CHANGE, MF_LOW_LATENCY,
    MF_MT_DEFAULT_STRIDE, MF_MT_FRAME_SIZE, MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE, MF_SA_D3D11_AWARE, MF_VERSION,
    MFMediaType_Video, MFSTARTUP_NOSOCKET, MFT_MESSAGE_COMMAND_FLUSH, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING,
    MFT_MESSAGE_NOTIFY_START_OF_STREAM, MFT_MESSAGE_SET_D3D_MANAGER, MFT_OUTPUT_DATA_BUFFER,
    MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES, MFT_OUTPUT_STREAM_PROVIDES_SAMPLES, MFVideoFormat_H264, MFVideoFormat_NV12,
};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
};
use windows::core::Interface as _;

mod mfplat;
use mfplat::{
    MFCreateDXGIDeviceManager, MFCreateMediaType, MFCreateMemoryBuffer, MFCreateSample, MFShutdown, MFStartup,
};

/// Longest time a decode waits for the worker thread. Pictures normally decode in milliseconds,
/// and the caller is blocked meanwhile.
const DECODE_TIMEOUT: Duration = Duration::from_secs(1);
/// Longest time creating the decoder waits for Media Foundation to start.
///
/// Starting COM, Media Foundation and the transform cold can take seconds on a loaded machine.
/// The graphics pipeline creates its decoder once per connection and loses H.264 for the whole
/// session when this expires, so it allows for that rather than for the usual start.
const START_TIMEOUT: Duration = Duration::from_secs(2);
/// Spacing of the synthetic sample times, in 100-ns units (30 frames per second).
const SAMPLE_DURATION: i64 = 333_333;

pub use ironrdp_egfx::decode::YuvMatrix;

/// Luma scale and offset, then V-to-R, U-to-G, V-to-G and U-to-B factors, in 16.16 fixed point.
fn coefficients(matrix: YuvMatrix) -> (i32, i32, [i32; 4]) {
    match matrix {
        // 255/219, 1.596, 0.392, 0.813, 2.017
        YuvMatrix::Bt601Limited => (76_309, 16, [104_597, 25_675, 53_279, 132_201]),
        // 1, 1.5748, 0.1873, 0.4681, 1.8556
        YuvMatrix::Bt709Full => (65_536, 0, [103_206, 12_276, 30_679, 121_609]),
    }
}

/// GPU-resident D3D11 NV12 video picture produced by Media Foundation on a shared device.
pub struct D3D11Nv12Frame {
    texture: ID3D11Texture2D,
    width: u32,
    height: u32,
}

// The shared D3D11 device has ID3D10Multithread::SetMultithreadProtected(true).
unsafe impl Send for D3D11Nv12Frame {}

impl D3D11Nv12Frame {
    pub fn texture(&self) -> &ID3D11Texture2D {
        &self.texture
    }
}

impl HwVideoFrame for D3D11Nv12Frame {
    fn width(&self) -> u32 {
        self.width
    }

    fn height(&self) -> u32 {
        self.height
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

enum Command {
    Decode(Vec<u8>, mpsc::SyncSender<DecoderResult<Picture>>),
    DecodeHw(Vec<u8>, mpsc::SyncSender<DecoderResult<D3D11Nv12Frame>>),
    Reset,
}

/// A decoded NV12 picture.
struct Picture {
    pixels: Vec<u8>,
    format: OutputFormat,
}

/// H.264 decoder backed by the Microsoft H.264 decoder transform shipped with Windows.
///
/// [`H264Decoder::decode`] converts pictures with the matrix given at creation, and
/// [`H264Decoder::decode_yuv420`] returns their planes.
pub struct MediaFoundationH264Decoder {
    commands: Option<mpsc::Sender<Command>>,
    thread: Option<JoinHandle<()>>,
    matrix: YuvMatrix,
    shared_device: bool,
}

impl MediaFoundationH264Decoder {
    /// Creates a decoder converting pictures with `matrix`.
    ///
    /// Fails when Media Foundation or its H.264 decoder is unavailable.
    pub fn new(matrix: YuvMatrix) -> DecoderResult<Self> {
        Self::new_with_device(matrix, None)
    }

    /// Creates a decoder bound to `shared_device` when provided, enabling
    /// zero-readback [`H264Decoder::decode_hw`] output on that D3D11 device.
    pub fn new_with_device(matrix: YuvMatrix, shared_device: Option<ID3D11Device>) -> DecoderResult<Self> {
        let has_shared = shared_device.is_some();
        // COM interfaces are safe to move into the multithreaded worker when multithread-protected.
        let device_raw = shared_device.map(|device| device.into_raw() as usize);
        let (commands, command_receiver) = mpsc::channel();
        let (ready, ready_receiver) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("h264-decoder".to_owned())
            .spawn(move || {
                let device = device_raw.map(|raw| unsafe { ID3D11Device::from_raw(raw as *mut core::ffi::c_void) });
                worker_main(&command_receiver, &ready, device);
            })
            .map_err(|error| DecoderError::new("failed to spawn the H.264 decoder thread", error))?;
        match ready_receiver.recv_timeout(START_TIMEOUT) {
            Ok(Ok(())) => Ok(Self {
                commands: Some(commands),
                thread: Some(thread),
                matrix,
                shared_device: has_shared,
            }),
            Ok(Err(error)) => Err(DecoderError::new(
                "failed to create the Media Foundation H.264 decoder",
                error,
            )),
            Err(_) => Err(DecoderError::msg(
                "the Media Foundation H.264 decoder did not start in time",
            )),
        }
    }

    fn decode_picture(&mut self, data: &[u8]) -> DecoderResult<Picture> {
        let commands = self
            .commands
            .as_ref()
            .ok_or_else(|| DecoderError::msg("the H.264 decoder thread has stopped"))?;
        let (reply, response) = mpsc::sync_channel(1);
        commands
            .send(Command::Decode(data.to_vec(), reply))
            .map_err(|_| DecoderError::msg("the H.264 decoder thread has stopped"))?;
        match response.recv_timeout(DECODE_TIMEOUT) {
            Ok(result) => result,
            Err(_) => {
                // A hung transform would stall every later sample, and joining it would block the
                // session: later decodes fail at once and the thread is left to end on its own.
                self.commands = None;
                drop(self.thread.take());
                Err(DecoderError::msg("the H.264 decoder did not answer and was abandoned"))
            }
        }
    }

    fn decode_hw_picture(&mut self, data: &[u8]) -> DecoderResult<D3D11Nv12Frame> {
        let commands = self
            .commands
            .as_ref()
            .ok_or_else(|| DecoderError::msg("the H.264 decoder thread has stopped"))?;
        let (reply, response) = mpsc::sync_channel(1);
        commands
            .send(Command::DecodeHw(data.to_vec(), reply))
            .map_err(|_| DecoderError::msg("the H.264 decoder thread has stopped"))?;
        match response.recv_timeout(DECODE_TIMEOUT) {
            Ok(result) => result,
            Err(_) => {
                self.commands = None;
                drop(self.thread.take());
                Err(DecoderError::msg("the H.264 decoder did not answer and was abandoned"))
            }
        }
    }
}

impl H264Decoder for MediaFoundationH264Decoder {
    fn supports_hw_frame(&self) -> bool {
        self.shared_device
    }

    fn decode_hw(&mut self, data: &[u8]) -> DecoderResult<Option<Box<dyn HwVideoFrame>>> {
        if !self.shared_device {
            return Ok(None);
        }
        Ok(Some(Box::new(self.decode_hw_picture(data)?)))
    }
    fn decode(&mut self, data: &[u8]) -> DecoderResult<DecodedFrame> {
        let Picture { pixels, format } = self.decode_picture(data)?;
        let (Ok(width), Ok(height)) = (usize::try_from(format.width), usize::try_from(format.height)) else {
            return Err(DecoderError::msg("H.264 picture dimensions overflow"));
        };
        let rgba = nv12_to_rgba(&pixels, width, height, format.stride, self.matrix)
            .ok_or_else(|| DecoderError::msg("the H.264 picture is smaller than its format"))?;
        Ok(DecodedFrame::new(rgba, format.width, format.height))
    }

    fn decode_avc420(&mut self, data: &[u8], rgba: &mut Vec<u8>) -> DecoderResult<(u32, u32)> {
        let Picture {
            pixels,
            format: OutputFormat { width, height, stride },
        } = self.decode_picture(data)?;
        let stride = stride as u32;
        let luma_len = stride as usize * height as usize;
        let (y, uv) = pixels.split_at(luma_len);
        rgba.resize(width as usize * height as usize * 4, 0);
        yuv::yuv_nv12_to_rgba(
            &yuv::YuvBiPlanarImage {
                y_plane: y,
                y_stride: stride,
                uv_plane: uv,
                uv_stride: stride,
                width,
                height,
            },
            rgba,
            width * 4,
            yuv::YuvRange::Full,
            yuv::YuvStandardMatrix::Bt709,
            yuv::YuvConversionMode::Balanced,
        )
        .map_err(|error| DecoderError::new("convert D3D11 NV12", error))?;
        Ok((width, height))
    }

    fn decode_yuv420(&mut self, data: &[u8]) -> DecoderResult<Yuv420Frame> {
        let Picture { pixels, format } = self.decode_picture(data)?;
        nv12_to_yuv420(&pixels, format)
    }

    fn supports_yuv420(&self) -> bool {
        true
    }

    fn reset(&mut self) {
        if let Some(commands) = &self.commands {
            let _ = commands.send(Command::Reset);
        }
    }
}

impl Drop for MediaFoundationH264Decoder {
    fn drop(&mut self) {
        // Closing the command channel ends the worker after its current picture.
        self.commands = None;
        // A driver may stall during reset or shutdown. Never join its thread
        // from the RDP session; dropping the channel lets it finish normally.
        drop(self.thread.take());
    }
}

fn worker_main(
    commands: &mpsc::Receiver<Command>,
    ready: &mpsc::SyncSender<Result<(), windows::core::Error>>,
    shared_device: Option<ID3D11Device>,
) {
    let _media_foundation = match MediaFoundationThread::initialize() {
        Ok(media_foundation) => media_foundation,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    let mut transform = match Transform::create(shared_device) {
        Ok(transform) => transform,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    if ready.send(Ok(())).is_err() {
        return;
    }
    while let Ok(command) = commands.recv() {
        match command {
            Command::Decode(data, reply) => {
                let _ = reply.send(transform.decode(data));
            }
            Command::DecodeHw(data, reply) => {
                let _ = reply.send(transform.decode_hw(data));
            }
            Command::Reset => transform.flush(),
        }
    }
}

/// Initializes COM for the multithreaded apartment and starts Media Foundation on this thread.
struct MediaFoundationThread;

impl MediaFoundationThread {
    fn initialize() -> windows::core::Result<Self> {
        // SAFETY: balanced by `CoUninitialize` in `Drop` or below.
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.ok()?;
        // SAFETY: COM is initialized on this thread.
        if let Err(error) = unsafe { MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET) } {
            // SAFETY: balances the successful `CoInitializeEx` above.
            unsafe { CoUninitialize() };
            return Err(error);
        }
        Ok(Self)
    }
}

impl Drop for MediaFoundationThread {
    fn drop(&mut self) {
        // SAFETY: balances the successful `MFStartup` in `initialize`.
        let _ = unsafe { MFShutdown() };
        // SAFETY: balances the successful `CoInitializeEx` in `initialize`.
        unsafe { CoUninitialize() };
    }
}

/// Layout of the NV12 pictures the transform produces.
#[derive(Debug, Clone, Copy)]
struct OutputFormat {
    width: u32,
    height: u32,
    stride: usize,
}

/// The decoder transform. Lives on the worker thread only.
struct Transform {
    transform: IMFTransform,
    _device_manager: IMFDXGIDeviceManager,
    hw_device: Option<(ID3D11Device, ID3D11DeviceContext)>,
    hw_pool: [Option<(u32, u32, ID3D11Texture2D)>; 3],
    hw_pool_index: usize,
    output: Option<OutputFormat>,
    sample_time: i64,
    annex_b: Vec<u8>,
}

impl Transform {
    fn create(shared_device: Option<ID3D11Device>) -> windows::core::Result<Self> {
        // SAFETY: COM is initialized on the worker thread.
        let transform: IMFTransform = unsafe { CoCreateInstance(&CLSID_MSH264DecoderMFT, None, CLSCTX_INPROC_SERVER) }?;
        // SAFETY: valid transform.
        let attributes = unsafe { transform.GetAttributes() }?;
        if unsafe { attributes.GetUINT32(&MF_SA_D3D11_AWARE) }? == 0 {
            return Err(windows::core::Error::empty());
        }
        unsafe { attributes.SetUINT32(&MF_LOW_LATENCY, 1) }?;
        let (device_manager, hw_device) = create_device_manager(shared_device)?;
        unsafe { transform.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, device_manager.as_raw() as usize) }?;

        // SAFETY: creates an empty media type.
        let input = unsafe { MFCreateMediaType() }?;
        // SAFETY: valid media type and static keys.
        unsafe { input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video) }?;
        // SAFETY: as above.
        unsafe { input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264) }?;
        // SAFETY: valid transform and media type.
        unsafe { transform.SetInputType(0, &input, 0) }?;

        let output = select_output(&transform)?;
        // SAFETY: valid, configured transform.
        unsafe { transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0) }?;
        // SAFETY: as above.
        unsafe { transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0) }?;
        Ok(Self {
            transform,
            _device_manager: device_manager,
            hw_device,
            hw_pool: [None, None, None],
            hw_pool_index: 0,
            output,
            sample_time: 0,
            annex_b: Vec::new(),
        })
    }

    fn decode_sample(&mut self, data: Vec<u8>) -> DecoderResult<(IMFSample, OutputFormat)> {
        let converted = is_avc_format(&data);
        let data = if converted {
            avc_to_annex_b_into(&data, &mut self.annex_b);
            core::mem::take(&mut self.annex_b)
        } else {
            data
        };
        let sample = self
            .input_sample(&data)
            .map_err(|error| DecoderError::new("failed to prepare the H.264 sample", error))?;
        if converted {
            self.annex_b = data;
        }

        let timestamp = unsafe { sample.GetSampleTime() }
            .map_err(|error| DecoderError::new("failed to timestamp the H.264 sample", error))?;
        // SAFETY: valid transform and sample.
        match unsafe { self.transform.ProcessInput(0, &sample, 0) } {
            Ok(()) => {}
            Err(error) if error.code() == MF_E_NOTACCEPTING => {
                // Collect the pending pictures, then retry.
                let _ = self.drain(timestamp)?;
                // SAFETY: as above.
                unsafe { self.transform.ProcessInput(0, &sample, 0) }
                    .map_err(|error| DecoderError::new("the H.264 decoder rejected the sample", error))?;
            }
            Err(error) => return Err(DecoderError::new("the H.264 decoder rejected the sample", error)),
        }
        self.drain(timestamp)?
            .ok_or_else(|| DecoderError::msg("the H.264 decoder returned no picture"))
    }

    fn decode(&mut self, data: Vec<u8>) -> DecoderResult<Picture> {
        let (picture, format) = self.decode_sample(data)?;
        let pixels = sample_bytes(&picture, format)
            .map_err(|error| DecoderError::new("failed to read a D3D11 H.264 picture", error))?;
        Ok(Picture { pixels, format })
    }

    fn decode_hw(&mut self, data: Vec<u8>) -> DecoderResult<D3D11Nv12Frame> {
        let (picture, format) = self.decode_sample(data)?;
        let Some((device, context)) = self.hw_device.as_ref() else {
            return Err(DecoderError::msg("H.264 decoder has no shared D3D11 device"));
        };
        let buffer = unsafe { picture.GetBufferByIndex(0) }
            .map_err(|error| DecoderError::new("failed to access D3D11 H.264 output buffer", error))?;
        let surface = buffer
            .cast::<IMFDXGIBuffer>()
            .map_err(|error| DecoderError::new("H.264 output buffer is not a DXGI surface", error))?;
        let mut raw_tex = core::ptr::null_mut();
        unsafe { surface.GetResource(&ID3D11Texture2D::IID, &mut raw_tex) }
            .map_err(|error| DecoderError::new("failed to obtain D3D11 H.264 texture", error))?;
        if raw_tex.is_null() {
            return Err(DecoderError::msg("D3D11 H.264 output texture was null"));
        }
        let src_tex = unsafe { ID3D11Texture2D::from_raw(raw_tex) };
        let subresource = unsafe { surface.GetSubresourceIndex() }
            .map_err(|error| DecoderError::new("failed to read D3D11 H.264 subresource index", error))?;

        let tex_w = format.width.next_multiple_of(2);
        let tex_h = format.height.next_multiple_of(2);
        let slot_index = self.hw_pool_index;
        self.hw_pool_index = (slot_index + 1) % self.hw_pool.len();
        let slot = &mut self.hw_pool[slot_index];
        let dst_tex = match slot {
            Some((w, h, tex)) if *w == tex_w && *h == tex_h => tex.clone(),
            _ => {
                let desc = D3D11_TEXTURE2D_DESC {
                    Width: tex_w,
                    Height: tex_h,
                    MipLevels: 1,
                    ArraySize: 1,
                    Format: DXGI_FORMAT_NV12,
                    SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                    Usage: D3D11_USAGE_DEFAULT,
                    BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
                    CPUAccessFlags: 0,
                    MiscFlags: 0,
                };
                let mut created = None;
                unsafe { device.CreateTexture2D(&desc, None, Some(&mut created)) }
                    .map_err(|error| DecoderError::new("failed to allocate GPU NV12 texture", error))?;
                let tex = created.ok_or_else(|| DecoderError::msg("failed to allocate GPU NV12 texture"))?;
                *slot = Some((tex_w, tex_h, tex.clone()));
                tex
            }
        };
        let box_ = D3D11_BOX {
            left: 0,
            top: 0,
            front: 0,
            right: tex_w,
            bottom: tex_h,
            back: 1,
        };
        unsafe {
            context.CopySubresourceRegion(&dst_tex, 0, 0, 0, 0, &src_tex, subresource, Some(&box_));
        }
        Ok(D3D11Nv12Frame {
            texture: dst_tex,
            width: format.width,
            height: format.height,
        })
    }

    fn flush(&mut self) {
        // SAFETY: valid transform.
        if let Err(error) = unsafe { self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0) } {
            warn!(%error, "Failed to flush the H.264 decoder");
        }
        let _ = unsafe { self.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0) };
    }

    fn input_sample(&mut self, data: &[u8]) -> windows::core::Result<IMFSample> {
        let length = u32::try_from(data.len()).map_err(|_| windows::core::Error::empty())?;
        // SAFETY: creates a buffer of the sample's size.
        let buffer = unsafe { MFCreateMemoryBuffer(length.max(1)) }?;
        let mut pointer = core::ptr::null_mut();
        // SAFETY: valid buffer; the out pointer is a valid local.
        unsafe { buffer.Lock(&mut pointer, None, None) }?;
        if !pointer.is_null() {
            // SAFETY: the locked buffer holds at least `length` writable bytes until `Unlock`.
            unsafe { core::ptr::copy_nonoverlapping(data.as_ptr(), pointer, data.len()) };
        }
        // SAFETY: balances the successful `Lock`.
        unsafe { buffer.Unlock() }?;
        // SAFETY: the buffer now holds `length` bytes.
        unsafe { buffer.SetCurrentLength(length) }?;
        // SAFETY: creates an empty sample.
        let sample = unsafe { MFCreateSample() }?;
        // SAFETY: valid sample and buffer.
        unsafe { sample.AddBuffer(&buffer) }?;
        // SAFETY: valid sample.
        unsafe { sample.SetSampleTime(self.sample_time) }?;
        // SAFETY: valid sample.
        unsafe { sample.SetSampleDuration(SAMPLE_DURATION) }?;
        self.sample_time = self.sample_time.saturating_add(SAMPLE_DURATION);
        Ok(sample)
    }

    /// Returns the pictures the transform has ready.
    fn drain(&mut self, timestamp: i64) -> DecoderResult<Option<(IMFSample, OutputFormat)>> {
        let mut frame = None;
        for _ in 0..32 {
            // SAFETY: valid transform.
            let info = unsafe { self.transform.GetOutputStreamInfo(0) }
                .map_err(|error| DecoderError::new("failed to query the H.264 decoder output", error))?;
            let provides_samples = info.dwFlags
                & flag_bits(MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0)
                != 0;
            let output_sample = if provides_samples {
                None
            } else {
                Some(
                    output_sample(info.cbSize)
                        .map_err(|error| DecoderError::new("failed to allocate an H.264 picture", error))?,
                )
            };
            let mut output = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: core::mem::ManuallyDrop::new(output_sample),
                dwStatus: 0,
                pEvents: core::mem::ManuallyDrop::new(None),
            }];
            let mut status = 0u32;
            // SAFETY: valid transform; the array holds one initialized buffer description.
            let result = unsafe { self.transform.ProcessOutput(0, &mut output, &mut status) };
            let [output] = output;
            let picture = core::mem::ManuallyDrop::into_inner(output.pSample);
            drop(core::mem::ManuallyDrop::into_inner(output.pEvents));
            match result {
                Ok(()) => {}
                Err(error) if error.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(frame),
                Err(error) if error.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    self.output = select_output(&self.transform)
                        .map_err(|error| DecoderError::new("failed to follow an H.264 format change", error))?;
                    debug!(output = ?self.output, "H.264 decoder output format changed");
                    continue;
                }
                Err(error) => return Err(DecoderError::new("the H.264 decoder failed", error)),
            }
            let Some(picture) = picture else {
                continue;
            };
            // AVC444 uses two consecutive pictures with distinct roles.
            // Never pair the current metadata with a delayed decoded picture.
            if unsafe { picture.GetSampleTime() }.ok() != Some(timestamp) {
                continue;
            }
            let format = match self.output {
                Some(format) => format,
                None => {
                    let media_type = unsafe { self.transform.GetOutputCurrentType(0) }
                        .map_err(|error| DecoderError::new("failed to query the H.264 output type", error))?;
                    read_output_format(&media_type).ok_or_else(|| DecoderError::msg("H.264 output has no size"))?
                }
            };
            frame = Some((picture, format));
        }
        Err(DecoderError::msg("the H.264 decoder did not complete its output"))
    }
}

fn create_device_manager(
    shared_device: Option<ID3D11Device>,
) -> windows::core::Result<(IMFDXGIDeviceManager, Option<(ID3D11Device, ID3D11DeviceContext)>)> {
    let (device, hw_device) = match shared_device {
        Some(device) => {
            let context = unsafe { device.GetImmediateContext() }?;
            (device.clone(), Some((device, context)))
        }
        None => {
            let mut device = None;
            // No WARP fallback: this path is for a physical video device only.
            unsafe {
                D3D11CreateDevice(
                    None,
                    D3D_DRIVER_TYPE_HARDWARE,
                    Default::default(),
                    D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                    None,
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    None,
                    None,
                )?;
            }
            (device.ok_or_else(windows::core::Error::empty)?, None)
        }
    };
    let _video = device.cast::<ID3D11VideoDevice>()?;
    let multithread = device.cast::<ID3D10Multithread>()?;
    let _ = unsafe { multithread.SetMultithreadProtected(true) };
    let (token, manager) = MFCreateDXGIDeviceManager()?;
    unsafe { manager.ResetDevice(&device, token) }?;
    Ok((manager, hw_device))
}

/// Selects the NV12 output type and returns its layout.
fn select_output(transform: &IMFTransform) -> windows::core::Result<Option<OutputFormat>> {
    for index in 0u32.. {
        // SAFETY: valid transform; enumeration ends with an error.
        let candidate: IMFMediaType = unsafe { transform.GetOutputAvailableType(0, index) }?;
        // SAFETY: valid media type and static key.
        if unsafe { candidate.GetGUID(&MF_MT_SUBTYPE) }? != MFVideoFormat_NV12 {
            continue;
        }
        // SAFETY: valid transform and media type.
        unsafe { transform.SetOutputType(0, &candidate, 0) }?;
        // Some transforms omit dimensions until they receive the first SPS.
        return Ok(read_output_format(&candidate));
    }
    Err(windows::core::Error::empty())
}

fn read_output_format(media_type: &IMFMediaType) -> Option<OutputFormat> {
    let frame_size = unsafe { media_type.GetUINT64(&MF_MT_FRAME_SIZE) }.ok()?;
    let width = (frame_size >> 32) as u32;
    let height = frame_size as u32;
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > 16_777_216 {
        return None;
    }
    let stride = unsafe { media_type.GetUINT32(&MF_MT_DEFAULT_STRIDE) }
        .ok()
        .map(|stride| stride as usize)
        .filter(|stride| (1..=usize::from(u16::MAX)).contains(stride))
        .unwrap_or(width.div_ceil(2) as usize * 2);
    Some(OutputFormat { width, height, stride })
}

fn output_sample(size: u32) -> windows::core::Result<IMFSample> {
    // SAFETY: creates an empty sample.
    let sample = unsafe { MFCreateSample() }?;
    // SAFETY: creates a buffer of the size the transform asks for.
    let buffer = unsafe { MFCreateMemoryBuffer(size.max(1)) }?;
    // SAFETY: valid sample and buffer.
    unsafe { sample.AddBuffer(&buffer) }?;
    Ok(sample)
}

fn sample_bytes(sample: &IMFSample, format: OutputFormat) -> windows::core::Result<Vec<u8>> {
    let buffer = unsafe { sample.GetBufferByIndex(0) }?;
    // A system-memory sample is not this backend's D3D11 path.
    let _surface = buffer.cast::<IMFDXGIBuffer>()?;
    let buffer = buffer.cast::<IMF2DBuffer>()?;
    let (width, height) = (u64::from(format.width), u64::from(format.height));
    let length = unsafe { buffer.GetContiguousLength() }? as usize;
    let required = format
        .stride
        .saturating_mul(height as usize + height.div_ceil(2) as usize);
    if width == 0
        || height == 0
        || width * height > 16_777_216
        || format.stride < width.div_ceil(2) as usize * 2
        || required > length
        || length > 64 * 1024 * 1024
    {
        return Err(windows::core::Error::empty());
    }
    let mut data = vec![0; length];
    // Read back the packed NV12 planes for the EGFX surface compositor.
    unsafe { buffer.ContiguousCopyTo(&mut data) }?;
    Ok(data)
}

/// Splits an NV12 picture into the planes of a YUV 4:2:0 picture.
fn nv12_to_yuv420(nv12: &[u8], format: OutputFormat) -> DecoderResult<Yuv420Frame> {
    let OutputFormat { width, height, stride } = format;
    let (Ok(width), Ok(height)) = (u16::try_from(width), u16::try_from(height)) else {
        return Err(DecoderError::msg("H.264 picture dimensions exceed 65535"));
    };
    let chroma_width = usize::from(width.div_ceil(2));
    let chroma_rows = usize::from(height.div_ceil(2));
    let luma_size = stride * usize::from(height);
    let Some(interleaved) = nv12.get(luma_size..luma_size + stride * chroma_rows) else {
        return Err(DecoderError::msg("the H.264 picture is smaller than its format"));
    };
    let mut u = Vec::with_capacity(chroma_width * chroma_rows);
    let mut v = Vec::with_capacity(chroma_width * chroma_rows);
    for row in interleaved.chunks_exact(stride) {
        for pair in row.chunks_exact(2).take(chroma_width) {
            u.push(pair[0]);
            v.push(pair[1]);
        }
    }
    Yuv420Frame::new(width, height, nv12[..luma_size].to_vec(), stride, u, v, chroma_width)
}

/// Converts an NV12 picture with `stride`-byte rows to tightly packed RGBA.
///
/// Returns `None` when `nv12` is too small for the picture.
fn nv12_to_rgba(nv12: &[u8], width: usize, height: usize, stride: usize, matrix: YuvMatrix) -> Option<Vec<u8>> {
    let luma_size = stride.checked_mul(height)?;
    let chroma_size = stride.checked_mul(height.div_ceil(2))?;
    if stride < width || nv12.len() < luma_size.checked_add(chroma_size)? {
        return None;
    }
    let (luma, chroma) = nv12.split_at(luma_size);
    let (scale, black, [v_to_r, u_to_g, v_to_g, u_to_b]) = coefficients(matrix);
    let mut rgba = Vec::with_capacity(width.checked_mul(height)?.checked_mul(4)?);
    for y in 0..height {
        let luma_row = &luma[y * stride..][..width];
        let chroma_row = &chroma[(y / 2) * stride..][..width.next_multiple_of(2).min(stride)];
        for (x, luma) in luma_row.iter().enumerate() {
            let pair = (x / 2) * 2;
            let (Some(u), Some(v)) = (chroma_row.get(pair), chroma_row.get(pair + 1)) else {
                return None;
            };
            let luma = (i32::from(*luma) - black) * scale + (1 << 15);
            let u = i32::from(*u) - 128;
            let v = i32::from(*v) - 128;
            rgba.push(clamp_channel((luma + v_to_r * v) >> 16));
            rgba.push(clamp_channel((luma - u_to_g * u - v_to_g * v) >> 16));
            rgba.push(clamp_channel((luma + u_to_b * u) >> 16));
            rgba.push(0xFF);
        }
    }
    Some(rgba)
}

fn clamp_channel(value: i32) -> u8 {
    // The clamped value is its own low byte.
    let [low, ..] = value.clamp(0, 255).to_le_bytes();
    low
}

fn flag_bits(flag: i32) -> u32 {
    u32::from_ne_bytes(flag.to_ne_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nv12_converts_with_both_matrices() {
        // A 2x2 picture with a 4-byte stride: limited-range white, then one chroma pair.
        let nv12 = [235, 235, 0, 0, 235, 235, 0, 0, 128, 128, 0, 0];
        let rgba = nv12_to_rgba(&nv12, 2, 2, 4, YuvMatrix::Bt601Limited).unwrap();
        assert_eq!(rgba, [255, 255, 255, 255].repeat(4));

        let nv12 = [0, 0, 0, 0, 128, 128];
        let rgba = nv12_to_rgba(&nv12, 2, 2, 2, YuvMatrix::Bt709Full).unwrap();
        assert_eq!(rgba, [0, 0, 0, 255].repeat(4));

        assert!(nv12_to_rgba(&nv12[..5], 2, 2, 2, YuvMatrix::Bt709Full).is_none());
    }
}
