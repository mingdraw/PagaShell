//! Session processes for Windows RDP (direct and gateway) and VNC. The renderer
//! and credential approval remain in the app. No shared native session state crosses the pipe.
mod rpc;
mod wire;

#[cfg(windows)]
mod entry;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
mod windows_handles;

#[cfg(windows)]
pub(crate) use windows::{get, get_vnc, open, open_vnc, remove, remove_vnc};
