use std::{
    ffi::c_void,
    io,
    mem::size_of,
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle, RawHandle},
    ptr::{self, NonNull},
    sync::atomic::{AtomicU32, Ordering},
};

use anyhow::{bail, ensure, Context, Result};
use windows_sys::Win32::{
    Foundation::{DuplicateHandle, DUPLICATE_SAME_ACCESS, INVALID_HANDLE_VALUE},
    System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Memory::{
            CreateFileMappingW, MapViewOfFile, UnmapViewOfFile, FILE_MAP, FILE_MAP_WRITE,
            MEMORY_MAPPED_VIEW_ADDRESS, PAGE_READWRITE,
        },
        Threading::{GetCurrentProcess, PROCESS_DUP_HANDLE},
    },
};

use super::wire::{MapOffer, MAX_FRAME_BYTES};

pub(super) struct WorkerJob {
    job: OwnedHandle,
    process: OwnedHandle,
}

impl WorkerJob {
    pub(super) fn attach(child: RawHandle) -> io::Result<Self> {
        // Neither the Job handle nor the parent's process handle is inherited.
        let job = owned(unsafe { CreateJobObjectW(ptr::null(), ptr::null()) })?;
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if unsafe {
            SetInformationJobObject(
                job.as_raw_handle(),
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let current = unsafe { GetCurrentProcess() };
        let mut process = ptr::null_mut();
        if unsafe {
            DuplicateHandle(
                current,
                child,
                current,
                &mut process,
                PROCESS_DUP_HANDLE,
                0,
                0,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let process = owned(process)?;
        if unsafe { AssignProcessToJobObject(job.as_raw_handle(), child) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { job, process })
    }

    pub(super) fn terminate(&self) {
        unsafe { TerminateJobObject(self.job.as_raw_handle(), 1) };
    }

    fn share(&self, mapping: &OwnedHandle, capacity: usize) -> io::Result<MapOffer> {
        let mut remote = ptr::null_mut();
        if unsafe {
            DuplicateHandle(
                GetCurrentProcess(),
                mapping.as_raw_handle(),
                self.process.as_raw_handle(),
                &mut remote,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        // The handle is valid only in the child. It owns and closes the copy.
        Ok(MapOffer {
            handle: remote as usize as u64,
            capacity: capacity as u32,
        })
    }
}

fn owned(handle: RawHandle) -> io::Result<OwnedHandle> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    // The caller transfers a real, newly created or duplicated Win32 handle.
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

const HEADER: usize = size_of::<AtomicU32>();

struct View {
    base: NonNull<u8>,
    capacity: usize,
}

// A view is owned by exactly one endpoint and is used under that endpoint's
// frame mutex. Raw addresses are valid across threads in the same process.
unsafe impl Send for View {}

impl View {
    fn new(mapping: RawHandle, access: FILE_MAP, capacity: usize) -> io::Result<Self> {
        let view = unsafe { MapViewOfFile(mapping, access, 0, 0, HEADER + capacity) };
        let base = NonNull::new(view.Value.cast()).ok_or_else(io::Error::last_os_error)?;
        Ok(Self { base, capacity })
    }

    fn sequence(&self) -> &AtomicU32 {
        // Windows page-aligns views. Both endpoints access this header only
        // atomically; newly allocated page-file mappings start zeroed.
        unsafe { AtomicU32::from_ptr(self.base.as_ptr().cast()) }
    }

    fn pixels(&self) -> *mut u8 {
        // Capacity and the header were checked when this mapping was made.
        unsafe { self.base.as_ptr().add(HEADER) }
    }
}

impl Drop for View {
    fn drop(&mut self) {
        unsafe {
            UnmapViewOfFile(MEMORY_MAPPED_VIEW_ADDRESS {
                Value: self.base.as_ptr().cast::<c_void>(),
            })
        };
    }
}

pub(super) struct FrameReader {
    view: View,
    mapping: OwnedHandle,
}

impl FrameReader {
    pub(super) fn new(capacity: usize) -> Result<Self> {
        ensure!(
            (1..=MAX_FRAME_BYTES).contains(&capacity),
            "RDP 会话进程帧缓冲超限"
        );
        let mapping = owned(unsafe {
            CreateFileMappingW(
                INVALID_HANDLE_VALUE,
                ptr::null(),
                PAGE_READWRITE,
                0,
                (HEADER + capacity) as u32,
                ptr::null(),
            )
        })
        .context("无法创建 RDP 会话进程帧缓冲")?;
        // AtomicU32::from_ptr requires a view valid for both reads and writes.
        // FrameReader exposes no writes.
        let view = View::new(mapping.as_raw_handle(), FILE_MAP_WRITE, capacity)
            .context("无法读取 RDP 会话进程帧缓冲")?;
        Ok(Self { view, mapping })
    }

    pub(super) fn capacity(&self) -> usize {
        self.view.capacity
    }

    pub(super) fn offer(&self, job: &WorkerJob) -> Result<MapOffer> {
        job.share(&self.mapping, self.view.capacity)
            .context("无法共享 RDP 会话进程帧缓冲")
    }

    pub(super) fn read(&self, len: usize, sequence: u32) -> Result<Vec<u8>> {
        if len > self.view.capacity || sequence == 0 {
            bail!("RDP 会话进程画面无效");
        }
        if len == 0 {
            return Ok(Vec::new());
        }
        ensure!(
            self.view.sequence().load(Ordering::Acquire) == sequence,
            "RDP 会话进程画面未就绪"
        );
        // The parent issues no new frame request while reading. It copies to
        // an owned Vec so the mapping may be reused after returning to Flutter.
        Ok(unsafe { std::slice::from_raw_parts(self.view.pixels(), len) }.to_vec())
    }
}

pub(super) struct FrameWriter(View);

impl FrameWriter {
    pub(super) fn accept(offer: MapOffer) -> Result<Self> {
        let handle = usize::try_from(offer.handle).context("RDP 帧缓冲句柄无效")? as RawHandle;
        let capacity = offer.capacity as usize;
        ensure!(
            (1..=MAX_FRAME_BYTES).contains(&capacity),
            "RDP 会话进程帧缓冲超限"
        );
        let view = View::new(handle, FILE_MAP_WRITE, capacity)?;
        // MapViewOfFile proved that this is a live mapping handle before we
        // take ownership of the duplicate received over the private pipe.
        let _mapping = owned(handle)?;
        // A view owns a mapping reference independently of the transferred handle.
        Ok(Self(view))
    }

    pub(super) fn capacity(&self) -> usize {
        self.0.capacity
    }

    pub(super) fn publish(&mut self, bytes: &[u8], sequence: u32) {
        assert!(bytes.len() <= self.0.capacity);
        if !bytes.is_empty() {
            // No other worker task writes this view. The parent waits for the
            // matching reply before accessing these bytes.
            unsafe { ptr::copy_nonoverlapping(bytes.as_ptr(), self.0.pixels(), bytes.len()) };
            self.0.sequence().store(sequence, Ordering::Release);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mapping_reads_only_the_published_frame_and_preserves_previous_readers() {
        let read = FrameReader::new(1024).unwrap();
        let mut write =
            FrameWriter(View::new(read.mapping.as_raw_handle(), FILE_MAP_WRITE, 1024).unwrap());
        assert!(read.read(4, 1).is_err());
        write.publish(&[1, 2, 3, 255], 1);
        let first = read.read(4, 1).unwrap();
        write.publish(&[4, 5, 6, 255], 2);
        assert_eq!(first, [1, 2, 3, 255]);
        assert_eq!(read.read(4, 2).unwrap(), [4, 5, 6, 255]);
        assert!(read.read(4, 1).is_err());
        assert!(read.read(1025, 2).is_err());
    }
}
