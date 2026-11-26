#![cfg_attr(doc, doc = include_str!("../README.md"))]
#![doc(html_logo_url = "https://cdnweb.devolutions.net/images/projects/devolutions/logos/devolutions-icon-shadow.svg")]

#[cfg(windows)]
mod d3d11_compositor;
#[cfg(windows)]
mod media_foundation;

#[cfg(windows)]
pub use d3d11_compositor::{D3D11DecoderOpener, D3D11GpuCompositor, D3D11PresentedFrame};
#[cfg(windows)]
pub use media_foundation::{D3D11Nv12Frame, MediaFoundationH264Decoder, YuvMatrix};

#[cfg(target_os = "macos")]
mod video_toolbox;
#[cfg(target_os = "macos")]
pub use video_toolbox::{MetalGpuCompositor, MetalPresentedFrame, VideoToolboxH264Decoder, VtHwFrame};

#[cfg(all(target_os = "linux", paga_vaapi))]
mod vaapi;

#[cfg(target_os = "linux")]
pub fn open_vaapi() -> ironrdp_egfx::decode::DecoderResult<Box<dyn ironrdp_egfx::decode::H264Decoder>> {
    #[cfg(paga_vaapi)]
    {
        Ok(Box::new(vaapi::VaapiDecoder::new()?))
    }
    #[cfg(not(paga_vaapi))]
    Err(ironrdp_egfx::decode::DecoderError::msg("VA-API decoder was not built"))
}
