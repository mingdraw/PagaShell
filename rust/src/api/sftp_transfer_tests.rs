//! 使用真实 SFTP 编解码和内存通道核验分块、限额及写入确认。
//! 延迟测试是可重复的协议等待模拟，不代表真实 SSH/磁盘吞吐。

use super::*;
use russh_sftp::protocol::{
    Attrs, Data, ExtendedReply, FileAttributes, Handle, OpenFlags, Packet, Status, StatusCode,
    Version,
};
use std::sync::atomic::AtomicUsize;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
struct Options {
    delay: Duration,
    limited: bool,
    fail_write: bool,
    fail_close: bool,
    fail_open: bool,
    file_missing: bool,
    fail_read_after: Option<usize>,
    fail_write_after: Option<usize>,
    read_gate: Option<Arc<Notify>>,
    change_on_stat: Option<usize>,
    write_gate: Option<Arc<Notify>>,
}

#[derive(Default)]
struct FileState {
    bytes: StdMutex<Vec<u8>>,
    reads: AtomicUsize,
    writes: AtomicUsize,
    max_read: AtomicUsize,
    max_write: AtomicUsize,
    removes: AtomicUsize,
    exists: AtomicBool,
    write_offsets: StdMutex<Vec<u64>>,
    stats: AtomicUsize,
    change_on_stat: Option<usize>,
}

struct FileServer {
    state: Arc<FileState>,
    options: Options,
}

fn ok_status(id: u32) -> Status {
    Status {
        id,
        status_code: StatusCode::Ok,
        error_message: String::new(),
        language_tag: String::new(),
    }
}

impl russh_sftp::server::Handler for FileServer {
    type Error = StatusCode;

    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }

    async fn init(&mut self, _: u32, _: HashMap<String, String>) -> Result<Version, Self::Error> {
        let mut version = Version::new();
        if self.options.limited {
            version
                .extensions
                .insert("limits@openssh.com".into(), "1".into());
        }
        Ok(version)
    }

    async fn extended(
        &mut self,
        id: u32,
        request: String,
        _: Vec<u8>,
    ) -> Result<Packet, Self::Error> {
        if request != "limits@openssh.com" {
            return Err(StatusCode::OpUnsupported);
        }
        Ok(ExtendedReply {
            id,
            data: [32768_u64, 8192, 4096, 16]
                .into_iter()
                .flat_map(u64::to_be_bytes)
                .collect(),
        }
        .into())
    }

    async fn open(
        &mut self,
        id: u32,
        _: String,
        flags: OpenFlags,
        _: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        if self.options.fail_open {
            return Err(StatusCode::PermissionDenied);
        }
        if !self.state.exists.load(Ordering::Relaxed) && !flags.contains(OpenFlags::CREATE) {
            return Err(StatusCode::NoSuchFile);
        }
        if self.state.exists.load(Ordering::Relaxed)
            && flags.contains(OpenFlags::CREATE | OpenFlags::EXCLUDE)
        {
            return Err(StatusCode::Failure);
        }
        if flags.contains(OpenFlags::CREATE) {
            self.state.exists.store(true, Ordering::Relaxed);
        }
        if flags.contains(OpenFlags::TRUNCATE) {
            self.state.bytes.lock().unwrap().clear();
        }
        Ok(Handle {
            id,
            handle: "f".into(),
        })
    }

    async fn read(
        &mut self,
        id: u32,
        _: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, Self::Error> {
        self.state.reads.fetch_add(1, Ordering::Relaxed);
        if let Some(gate) = self.options.read_gate.take() {
            gate.notified().await;
        }
        if self
            .options
            .fail_read_after
            .is_some_and(|limit| offset as usize >= limit)
        {
            return Err(StatusCode::Failure);
        }
        self.state
            .max_read
            .fetch_max(len as usize, Ordering::Relaxed);
        if self.options.limited && len > 8192 {
            return Err(StatusCode::BadMessage);
        }
        tokio::time::sleep(self.options.delay).await;
        let bytes = self.state.bytes.lock().unwrap();
        let offset = offset as usize;
        if offset >= bytes.len() {
            return Err(StatusCode::Eof);
        }
        let end = (offset + len as usize).min(bytes.len());
        Ok(Data {
            id,
            data: bytes[offset..end].to_vec(),
        })
    }

    async fn write(
        &mut self,
        id: u32,
        _: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        if let Some(gate) = self.options.write_gate.take() {
            gate.notified().await;
        }
        self.state.writes.fetch_add(1, Ordering::Relaxed);
        self.state.write_offsets.lock().unwrap().push(offset);
        self.state
            .max_write
            .fetch_max(data.len(), Ordering::Relaxed);
        if self.options.fail_write
            || self
                .options
                .fail_write_after
                .is_some_and(|limit| offset as usize >= limit)
        {
            return Err(StatusCode::PermissionDenied);
        }
        if self.options.limited && data.len() > 4096 {
            return Err(StatusCode::BadMessage);
        }
        tokio::time::sleep(self.options.delay).await;
        let mut bytes = self.state.bytes.lock().unwrap();
        let offset = offset as usize;
        let size = bytes.len().max(offset + data.len());
        bytes.resize(size, 0);
        bytes[offset..offset + data.len()].copy_from_slice(&data);
        Ok(ok_status(id))
    }

    async fn stat(&mut self, id: u32, _: String) -> Result<Attrs, Self::Error> {
        if !self.state.exists.load(Ordering::Relaxed) {
            return Err(StatusCode::NoSuchFile);
        }
        let index = self.state.stats.fetch_add(1, Ordering::Relaxed);
        Ok(Attrs {
            id,
            attrs: FileAttributes {
                size: Some(self.state.bytes.lock().unwrap().len() as u64),
                mtime: Some(u32::from(
                    self.state
                        .change_on_stat
                        .is_some_and(|count| index >= count),
                )),
                ..FileAttributes::default()
            },
        })
    }

    async fn remove(&mut self, id: u32, _: String) -> Result<Status, Self::Error> {
        self.state.removes.fetch_add(1, Ordering::Relaxed);
        self.state.exists.store(false, Ordering::Relaxed);
        self.state.bytes.lock().unwrap().clear();
        Ok(ok_status(id))
    }

    async fn close(&mut self, id: u32, _: String) -> Result<Status, Self::Error> {
        if self.options.fail_close {
            return Err(StatusCode::Failure);
        }
        Ok(ok_status(id))
    }
}

async fn fixture(
    config: SftpConfig,
    options: Options,
    initial: Vec<u8>,
) -> (SftpSession, Arc<FileState>) {
    let state = Arc::new(FileState {
        bytes: StdMutex::new(initial),
        exists: AtomicBool::new(!options.file_missing),
        change_on_stat: options.change_on_stat,
        ..FileState::default()
    });
    // 足以容纳完整写入窗口，使测试测量协议等待而不是内存通道容量。
    let (client, server) = tokio::io::duplex(4 * 1024 * 1024);
    russh_sftp::server::run(
        server,
        FileServer {
            state: state.clone(),
            options,
        },
    )
    .await;
    let session = SftpSession::new_with_config(client, config).await.unwrap();
    (session, state)
}

fn payload(len: usize) -> Vec<u8> {
    (0..len).map(|index| (index % 251) as u8).collect()
}

async fn download(session: &SftpSession, chunk: usize) -> Vec<u8> {
    let mut remote = session.open("file").await.unwrap();
    let mut buffer = vec![0; chunk];
    let mut bytes = Vec::new();
    let cancel = AtomicBool::new(false);
    loop {
        let len = transfer_io(&cancel, remote.read(&mut buffer))
            .await
            .unwrap();
        if len == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..len]);
    }
    bytes
}

async fn upload(session: &SftpSession, bytes: &[u8], chunk: usize) {
    let mut remote = session.create("file").await.unwrap();
    let cancel = AtomicBool::new(false);
    for part in bytes.chunks(chunk) {
        transfer_io(&cancel, remote.write_all(part)).await.unwrap();
    }
    transfer_io(&cancel, remote.flush()).await.unwrap();
    transfer_io(&cancel, remote.shutdown()).await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn larger_chunks_reduce_delayed_sftp_requests_without_corrupting_data() {
    let bytes = payload(2 * 1024 * 1024);
    for uploading in [false, true] {
        let mut measurements = Vec::new();
        for (chunk, config) in [
            (64 * 1024, SftpConfig::default()),
            (TRANSFER_CHUNK, sftp_client_config()),
        ] {
            let (session, state) = fixture(
                config,
                Options {
                    delay: Duration::from_millis(4),
                    ..Options::default()
                },
                if uploading { Vec::new() } else { bytes.clone() },
            )
            .await;
            let started = tokio::time::Instant::now();
            if uploading {
                upload(&session, &bytes, chunk).await;
                assert_eq!(*state.bytes.lock().unwrap(), bytes);
            } else {
                assert_eq!(download(&session, chunk).await, bytes);
            }
            measurements.push((
                started.elapsed(),
                if uploading {
                    state.writes.load(Ordering::Relaxed)
                } else {
                    state.reads.load(Ordering::Relaxed)
                },
            ));
            session.close().await.unwrap();
        }
        let (before, after) = (measurements[0], measurements[1]);
        eprintln!("SFTP simulated 4ms response delay, upload={uploading}: 64KiB={before:?}, 128KiB={after:?}");
        assert!(
            after.0 < before.0,
            "fewer round trips must reduce simulated waiting"
        );
        assert!(after.1 <= before.1 / 2 + 1);
    }
}

#[tokio::test(start_paused = true)]
async fn larger_chunks_respect_advertised_server_limits_and_partial_final_blocks() {
    let bytes = payload(TRANSFER_CHUNK * 2 + 17);
    let (session, state) = fixture(
        sftp_client_config(),
        Options {
            limited: true,
            ..Options::default()
        },
        bytes.clone(),
    )
    .await;
    assert_eq!(download(&session, TRANSFER_CHUNK).await, bytes);
    upload(&session, &bytes, TRANSFER_CHUNK).await;
    assert_eq!(*state.bytes.lock().unwrap(), bytes);
    assert!(state.max_read.load(Ordering::Relaxed) <= 8192);
    assert!(state.max_write.load(Ordering::Relaxed) <= 4096);
    session.close().await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn write_pipeline_is_bounded_and_flush_waits_for_acks() {
    let gate = Arc::new(Notify::new());
    let (session, state) = fixture(
        sftp_client_config(),
        Options {
            write_gate: Some(gate.clone()),
            ..Options::default()
        },
        Vec::new(),
    )
    .await;
    let mut remote = session.create("file").await.unwrap();
    let chunk = payload(TRANSFER_CHUNK);
    for _ in 0..TRANSFER_MAX_CONCURRENT_WRITES {
        remote.write_all(&chunk).await.unwrap();
    }
    assert!(
        tokio::time::timeout(Duration::from_millis(1), remote.write_all(&chunk))
            .await
            .is_err()
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(1), remote.flush())
            .await
            .is_err()
    );
    gate.notify_one();
    transfer_io(&AtomicBool::new(false), remote.flush())
        .await
        .unwrap();
    remote.shutdown().await.unwrap();
    assert_eq!(
        state.writes.load(Ordering::Relaxed),
        TRANSFER_MAX_CONCURRENT_WRITES
    );
    assert_eq!(
        state.bytes.lock().unwrap().len(),
        TRANSFER_CHUNK * TRANSFER_MAX_CONCURRENT_WRITES
    );
    session.close().await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn buffered_write_and_close_errors_are_not_reported_as_success() {
    for fail_write in [true, false] {
        let (session, _) = fixture(
            sftp_client_config(),
            Options {
                fail_write,
                fail_close: !fail_write,
                ..Options::default()
            },
            Vec::new(),
        )
        .await;
        let mut remote = session.create("file").await.unwrap();
        remote.write_all(&payload(TRANSFER_CHUNK)).await.unwrap();
        if fail_write {
            assert!(transfer_io(&AtomicBool::new(false), remote.flush())
                .await
                .is_err());
        } else {
            remote.flush().await.unwrap();
            assert!(transfer_io(&AtomicBool::new(false), remote.shutdown())
                .await
                .is_err());
        }
        session.close().await.unwrap();
    }
}

#[tokio::test]
async fn download_retains_partial_file_after_read_failure() {
    let bytes = payload(TRANSFER_CHUNK * 2 + 17);
    let (session, _) = fixture(
        sftp_client_config(),
        Options {
            fail_read_after: Some(TRANSFER_CHUNK),
            ..Options::default()
        },
        bytes.clone(),
    )
    .await;
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("download.bin");
    let result = transfer_file(
        &session,
        &AtomicBool::new(false),
        path.to_str().unwrap(),
        "file",
        TransferMode {
            upload: false,
            resume: false,
        },
        &|event| assert!(!event.completed),
    )
    .await;
    assert!(result.is_err());
    assert_eq!(
        tokio::fs::read(path).await.unwrap(),
        bytes[..TRANSFER_CHUNK]
    );
}

#[tokio::test]
async fn upload_retains_written_file_after_write_or_close_failure() {
    for fail_write in [true, false] {
        let bytes = payload(TRANSFER_CHUNK * 2 + 17);
        let (session, state) = fixture(
            sftp_client_config(),
            Options {
                fail_write_after: fail_write.then_some(TRANSFER_CHUNK),
                fail_close: !fail_write,
                ..Options::default()
            },
            Vec::new(),
        )
        .await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("upload.bin");
        tokio::fs::write(&path, &bytes).await.unwrap();
        let result = transfer_file(
            &session,
            &AtomicBool::new(false),
            path.to_str().unwrap(),
            "file",
            TransferMode {
                upload: true,
                resume: false,
            },
            &|event| assert!(!event.completed),
        )
        .await;
        assert!(result.is_err());
        assert_eq!(state.removes.load(Ordering::Relaxed), 0);
        let expected = if fail_write {
            &bytes[..TRANSFER_CHUNK]
        } else {
            &bytes
        };
        assert_eq!(&*state.bytes.lock().unwrap(), expected);
        assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
    }
}

#[tokio::test]
async fn transfer_retains_existing_files_when_open_fails() {
    for upload in [true, false] {
        let bytes = b"original file".to_vec();
        let (session, state) = fixture(
            sftp_client_config(),
            Options {
                fail_open: true,
                ..Options::default()
            },
            bytes.clone(),
        )
        .await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("original.bin");
        tokio::fs::write(&path, &bytes).await.unwrap();
        let result = transfer_file(
            &session,
            &AtomicBool::new(false),
            path.to_str().unwrap(),
            "file",
            TransferMode {
                upload,
                resume: false,
            },
            &|_| panic!("failed open must not report progress"),
        )
        .await;
        assert!(result.is_err());
        assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
        assert_eq!(*state.bytes.lock().unwrap(), bytes);
        assert_eq!(state.removes.load(Ordering::Relaxed), 0);
    }
}

#[tokio::test]
async fn download_retains_written_file_after_cancellation() {
    let bytes = payload(PROGRESS_EMIT_EVERY as usize + TRANSFER_CHUNK);
    let (session, _) = fixture(sftp_client_config(), Options::default(), bytes.clone()).await;
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("cancelled.bin");
    let cancel = AtomicBool::new(false);
    let result = transfer_file(
        &session,
        &cancel,
        path.to_str().unwrap(),
        "file",
        TransferMode {
            upload: false,
            resume: false,
        },
        &|event| {
            assert!(!event.completed);
            cancel.store(true, Ordering::Relaxed);
        },
    )
    .await;
    assert_eq!(result.unwrap_err().to_string(), "传输已取消");
    assert_eq!(
        tokio::fs::read(path).await.unwrap(),
        bytes[..PROGRESS_EMIT_EVERY as usize]
    );
}

#[tokio::test]
async fn single_file_transfer_completes_and_reports_final_progress() {
    for upload in [true, false] {
        let bytes = payload(TRANSFER_CHUNK + 17);
        let (session, state) = fixture(
            sftp_client_config(),
            Options::default(),
            if upload { Vec::new() } else { bytes.clone() },
        )
        .await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("complete.bin");
        if upload {
            tokio::fs::write(&path, &bytes).await.unwrap();
        }
        let events = StdMutex::new(Vec::new());
        transfer_file(
            &session,
            &AtomicBool::new(false),
            path.to_str().unwrap(),
            "file",
            TransferMode {
                upload,
                resume: false,
            },
            &|event| events.lock().unwrap().push(event),
        )
        .await
        .unwrap();
        assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
        assert_eq!(*state.bytes.lock().unwrap(), bytes);
        let events = events.lock().unwrap();
        let finished = events.last().unwrap();
        assert!(finished.completed);
        assert_eq!(finished.transferred, bytes.len() as u64);
        assert_eq!(finished.total, bytes.len() as u64);
    }
}

#[tokio::test]
async fn resumed_transfers_verify_prefix_and_write_only_the_remainder() {
    let bytes = payload(TRANSFER_CHUNK * 2 + 17);
    let offset = TRANSFER_CHUNK + 19;
    for upload in [true, false] {
        let (session, state) = fixture(
            sftp_client_config(),
            Options::default(),
            if upload {
                bytes[..offset].to_vec()
            } else {
                bytes.clone()
            },
        )
        .await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("resumed.bin");
        tokio::fs::write(&path, if upload { &bytes } else { &bytes[..offset] })
            .await
            .unwrap();
        let events = StdMutex::new(Vec::new());
        transfer_file(
            &session,
            &AtomicBool::new(false),
            path.to_str().unwrap(),
            "file",
            TransferMode {
                upload,
                resume: true,
            },
            &|event| events.lock().unwrap().push(event),
        )
        .await
        .unwrap();
        assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
        assert_eq!(*state.bytes.lock().unwrap(), bytes);
        if upload {
            let offsets = state.write_offsets.lock().unwrap();
            assert!(!offsets.is_empty());
            assert!(offsets.iter().all(|&position| position >= offset as u64));
        }
        let events = events.lock().unwrap();
        assert!(events
            .iter()
            .any(|event| event.transferred == offset as u64));
        assert!(events.last().unwrap().completed);
    }
}

#[tokio::test]
async fn resumed_transfers_reject_mismatched_or_longer_targets_without_writing() {
    let bytes = payload(TRANSFER_CHUNK + 17);
    for upload in [true, false] {
        for too_long in [true, false] {
            let mut partial = if too_long {
                vec![123; bytes.len() + 1]
            } else {
                bytes[..TRANSFER_CHUNK].to_vec()
            };
            partial[0] ^= 0xff;
            let (session, state) = fixture(
                sftp_client_config(),
                Options::default(),
                if upload {
                    partial.clone()
                } else {
                    bytes.clone()
                },
            )
            .await;
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("mismatch.bin");
            tokio::fs::write(&path, if upload { &bytes } else { &partial })
                .await
                .unwrap();
            let result = transfer_file(
                &session,
                &AtomicBool::new(false),
                path.to_str().unwrap(),
                "file",
                TransferMode {
                    upload,
                    resume: true,
                },
                &|_| {},
            )
            .await;
            assert_eq!(
                result.unwrap_err().to_string(),
                resume_mismatch().to_string()
            );
            assert_eq!(
                tokio::fs::read(path).await.unwrap().as_slice(),
                if upload {
                    bytes.as_slice()
                } else {
                    partial.as_slice()
                }
            );
            assert_eq!(
                *state.bytes.lock().unwrap(),
                if upload { partial } else { bytes.clone() }
            );
            assert_eq!(state.writes.load(Ordering::Relaxed), 0);
            assert_eq!(state.removes.load(Ordering::Relaxed), 0);
        }
    }
}

#[tokio::test]
async fn resumed_transfers_create_missing_targets_without_truncating_other_files() {
    let bytes = payload(TRANSFER_CHUNK + 17);
    for upload in [true, false] {
        let (session, state) = fixture(
            sftp_client_config(),
            Options {
                file_missing: upload,
                ..Options::default()
            },
            if upload { Vec::new() } else { bytes.clone() },
        )
        .await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("new.bin");
        if upload {
            tokio::fs::write(&path, &bytes).await.unwrap();
        }
        transfer_file(
            &session,
            &AtomicBool::new(false),
            path.to_str().unwrap(),
            "file",
            TransferMode {
                upload,
                resume: true,
            },
            &|_| {},
        )
        .await
        .unwrap();
        assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
        assert_eq!(*state.bytes.lock().unwrap(), bytes);
    }
}

#[tokio::test]
async fn interrupted_transfers_resume_using_the_actual_preserved_bytes() {
    let bytes = payload(TRANSFER_CHUNK * 2 + 17);
    for upload in [true, false] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("interrupted.bin");
        if upload {
            tokio::fs::write(&path, &bytes).await.unwrap();
        }
        let (first, state) = fixture(
            sftp_client_config(),
            Options {
                fail_write_after: upload.then_some(TRANSFER_CHUNK),
                fail_read_after: (!upload).then_some(TRANSFER_CHUNK),
                ..Options::default()
            },
            if upload { Vec::new() } else { bytes.clone() },
        )
        .await;
        assert!(transfer_file(
            &first,
            &AtomicBool::new(false),
            path.to_str().unwrap(),
            "file",
            TransferMode {
                upload,
                resume: false
            },
            &|_| {},
        )
        .await
        .is_err());
        let partial = if upload {
            state.bytes.lock().unwrap().clone()
        } else {
            tokio::fs::read(&path).await.unwrap()
        };
        assert_eq!(partial, bytes[..TRANSFER_CHUNK]);
        let (second, state) = fixture(
            sftp_client_config(),
            Options::default(),
            if upload { partial } else { bytes.clone() },
        )
        .await;
        transfer_file(
            &second,
            &AtomicBool::new(false),
            path.to_str().unwrap(),
            "file",
            TransferMode {
                upload,
                resume: true,
            },
            &|_| {},
        )
        .await
        .unwrap();
        assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
        assert_eq!(*state.bytes.lock().unwrap(), bytes);
        if upload {
            assert!(state
                .write_offsets
                .lock()
                .unwrap()
                .iter()
                .all(|&offset| offset >= TRANSFER_CHUNK as u64));
        }
    }
}

#[tokio::test]
async fn resume_rejects_remote_metadata_changes_before_writing() {
    let bytes = payload(TRANSFER_CHUNK * 2);
    for upload in [true, false] {
        let partial = bytes[..TRANSFER_CHUNK].to_vec();
        let (session, state) = fixture(
            sftp_client_config(),
            Options {
                change_on_stat: Some(1),
                ..Options::default()
            },
            if upload {
                partial.clone()
            } else {
                bytes.clone()
            },
        )
        .await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("changed.bin");
        tokio::fs::write(&path, if upload { &bytes } else { &partial })
            .await
            .unwrap();
        let error = transfer_file(
            &session,
            &AtomicBool::new(false),
            path.to_str().unwrap(),
            "file",
            TransferMode {
                upload,
                resume: true,
            },
            &|_| {},
        )
        .await
        .unwrap_err();
        assert_eq!(error.to_string(), "续传期间文件已变化，请重新发起传输");
        assert_eq!(state.writes.load(Ordering::Relaxed), 0);
        assert_eq!(
            tokio::fs::read(path).await.unwrap(),
            if upload {
                bytes.as_slice()
            } else {
                partial.as_slice()
            }
        );
    }
}

#[tokio::test]
async fn resume_rejects_local_file_changes_during_prefix_verification() {
    let bytes = payload(TRANSFER_CHUNK * 2);
    for upload in [true, false] {
        let partial = bytes[..TRANSFER_CHUNK].to_vec();
        let gate = Arc::new(Notify::new());
        let (session, state) = fixture(
            sftp_client_config(),
            Options {
                read_gate: Some(gate.clone()),
                ..Options::default()
            },
            if upload {
                partial.clone()
            } else {
                bytes.clone()
            },
        )
        .await;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("changed-local.bin");
        tokio::fs::write(&path, if upload { &bytes } else { &partial })
            .await
            .unwrap();
        let task_path = path.clone();
        let transfer = tokio::spawn(async move {
            transfer_file(
                &session,
                &AtomicBool::new(false),
                task_path.to_str().unwrap(),
                "file",
                TransferMode {
                    upload,
                    resume: true,
                },
                &|_| {},
            )
            .await
        });
        tokio::time::timeout(Duration::from_secs(2), async {
            while state.reads.load(Ordering::Relaxed) == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let mut modified = if upload {
            bytes.clone()
        } else {
            partial.clone()
        };
        modified.push(42);
        tokio::fs::write(&path, &modified).await.unwrap();
        gate.notify_one();
        let error = transfer.await.unwrap().unwrap_err();
        assert_eq!(error.to_string(), "续传期间文件已变化，请重新发起传输");
        assert_eq!(tokio::fs::read(path).await.unwrap(), modified);
        assert_eq!(state.writes.load(Ordering::Relaxed), 0);
    }
}
