//! Resolve Media Foundation lazily, so Windows installations without the
//! Media Feature Pack still load the PagaShell DLL and use OpenH264.
#![allow(non_snake_case)]

use core::ffi::c_void;
use std::sync::OnceLock;

use windows::Win32::Media::MediaFoundation::{IMFDXGIDeviceManager, IMFMediaBuffer, IMFMediaType, IMFSample};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW};
use windows::core::{Error, HRESULT, Interface, Result, s, w};

struct MfPlat {
    startup: unsafe extern "system" fn(u32, u32) -> HRESULT,
    shutdown: unsafe extern "system" fn() -> HRESULT,
    manager: unsafe extern "system" fn(*mut u32, *mut *mut c_void) -> HRESULT,
    media_type: unsafe extern "system" fn(*mut *mut c_void) -> HRESULT,
    memory_buffer: unsafe extern "system" fn(u32, *mut *mut c_void) -> HRESULT,
    sample: unsafe extern "system" fn(*mut *mut c_void) -> HRESULT,
}

fn load() -> Result<&'static MfPlat> {
    static LIBRARY: OnceLock<Option<MfPlat>> = OnceLock::new();
    LIBRARY
        .get_or_init(|| {
            let module = unsafe { LoadLibraryExW(w!("mfplat.dll"), None, LOAD_LIBRARY_SEARCH_SYSTEM32) }.ok()?;
            macro_rules! load {
                ($symbol:literal, $type:ty) => {{
                    let address = unsafe { GetProcAddress(module, s!($symbol)) }?;
                    // The export is from the system DLL and has the signature
                    // in the matching Windows SDK declaration.
                    unsafe { core::mem::transmute::<_, $type>(address) }
                }};
            }
            Some(MfPlat {
                startup: load!("MFStartup", unsafe extern "system" fn(u32, u32) -> HRESULT),
                shutdown: load!("MFShutdown", unsafe extern "system" fn() -> HRESULT),
                manager: load!(
                    "MFCreateDXGIDeviceManager",
                    unsafe extern "system" fn(*mut u32, *mut *mut c_void) -> HRESULT
                ),
                media_type: load!(
                    "MFCreateMediaType",
                    unsafe extern "system" fn(*mut *mut c_void) -> HRESULT
                ),
                memory_buffer: load!(
                    "MFCreateMemoryBuffer",
                    unsafe extern "system" fn(u32, *mut *mut c_void) -> HRESULT
                ),
                sample: load!("MFCreateSample", unsafe extern "system" fn(*mut *mut c_void) -> HRESULT),
            })
        })
        .as_ref()
        .ok_or_else(Error::empty)
}

fn make_interface<T: Interface>(call: impl FnOnce(*mut *mut c_void) -> HRESULT) -> Result<T> {
    let mut pointer = core::ptr::null_mut();
    call(&mut pointer).ok()?;
    if pointer.is_null() {
        Err(Error::empty())
    } else {
        // A successful constructor returns one owning interface reference.
        Ok(unsafe { T::from_raw(pointer) })
    }
}

pub(super) unsafe fn MFStartup(version: u32, flags: u32) -> Result<()> {
    unsafe { (load()?.startup)(version, flags) }.ok()
}

pub(super) unsafe fn MFShutdown() -> Result<()> {
    unsafe { (load()?.shutdown)() }.ok()
}

pub(super) fn MFCreateDXGIDeviceManager() -> Result<(u32, IMFDXGIDeviceManager)> {
    let mut token = 0;
    let api = load()?;
    let manager = make_interface(|output| unsafe { (api.manager)(&mut token, output) })?;
    Ok((token, manager))
}

pub(super) unsafe fn MFCreateMediaType() -> Result<IMFMediaType> {
    let api = load()?;
    make_interface(|output| unsafe { (api.media_type)(output) })
}

pub(super) unsafe fn MFCreateMemoryBuffer(size: u32) -> Result<IMFMediaBuffer> {
    let api = load()?;
    make_interface(|output| unsafe { (api.memory_buffer)(size, output) })
}

pub(super) unsafe fn MFCreateSample() -> Result<IMFSample> {
    let api = load()?;
    make_interface(|output| unsafe { (api.sample)(output) })
}
