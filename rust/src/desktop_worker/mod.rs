//! Session processes for Windows direct RDP. The renderer and credential
//! approval remain in the app. No shared native session state crosses the pipe.
mod rpc;
mod wire;

#[cfg(windows)]
mod entry;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
mod windows_handles;

#[cfg(windows)]
pub(crate) use windows::{get, open, remove};
