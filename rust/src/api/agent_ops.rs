//! Independent SSH channels for Agent operations on an authenticated session.
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, ensure, Result};
use russh::{ChannelMsg, Sig};
use sha2::{Digest, Sha256};
use tokio::time::{timeout, timeout_at, Instant};
use tokio_util::sync::CancellationToken;

use super::ssh::{
    check_text_bytes, open_agent_channel, read_only_exec, server_status_command, ReadOnlyExecPolicy,
};
use crate::frb_generated::StreamSink;

const FILE_LIMIT: usize = 2 * 1024 * 1024;
const EXEC_LIMIT: usize = 2 * 1024 * 1024;
const EXEC_FLUSH_BYTES: usize = 16 * 1024;
const EXEC_FLUSH_INTERVAL: Duration = Duration::from_millis(32);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(1);
const PROFILE_POLICY: ReadOnlyExecPolicy = ReadOnlyExecPolicy {
    overall_timeout: Some(Duration::from_secs(8)),
    closed: "SSH 会话已关闭",
    timeout: "服务器基线采集超时",
    connection: "无法采集服务器基线",
    denied: "此连接不允许服务器基线采集",
    too_large: "服务器基线输出过大",
    incomplete: "服务器基线采集未完成",
};

pub struct SshExecEvent {
    /// started, stdout, stderr, exit
    pub kind: String,
    pub data: String,
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    pub cancelled: bool,
    pub truncated: bool,
}

impl SshExecEvent {
    fn new(kind: &str, data: String) -> Self {
        Self {
            kind: kind.into(),
            data,
            exit_code: None,
            timed_out: false,
            cancelled: false,
            truncated: false,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum OperationId {
    Exec(u32),
    File(u64),
}

static ACTIVE_OPERATIONS: LazyLock<Mutex<HashMap<OperationId, (u32, CancellationToken)>>> =
    LazyLock::new(Mutex::default);
static NEXT_FILE_OP: AtomicU64 = AtomicU64::new(1);

struct ExecRegistration(OperationId);

impl ExecRegistration {
    fn register(session_id: u32, exec_id: u32) -> Result<(Self, CancellationToken)> {
        Self::register_operation(session_id, OperationId::Exec(exec_id))
    }

    fn register_operation(session_id: u32, id: OperationId) -> Result<(Self, CancellationToken)> {
        let mut active = ACTIVE_OPERATIONS.lock().unwrap_or_else(|e| e.into_inner());
        ensure!(active.len() < 32, "SSH 后台命令过多");
        ensure!(!active.contains_key(&id), "SSH 后台任务编号重复");
        let cancellation = CancellationToken::new();
        active.insert(id, (session_id, cancellation.clone()));
        Ok((Self(id), cancellation))
    }
}

impl Drop for ExecRegistration {
    fn drop(&mut self) {
        ACTIVE_OPERATIONS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.0);
    }
}

pub(super) fn close_session(session_id: u32) {
    for (owner, cancellation) in ACTIVE_OPERATIONS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .values()
    {
        if *owner == session_id {
            cancellation.cancel();
        }
    }
}

pub async fn ssh_exec_cancel(session_id: u32, exec_id: u32) {
    if let Some((owner, cancellation)) = ACTIVE_OPERATIONS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&OperationId::Exec(exec_id))
    {
        if *owner == session_id {
            cancellation.cancel();
        }
    }
}

// Keep at most three incomplete UTF-8 bytes between SSH packets. Discard an
// incomplete character when the byte limit cuts the stream in the middle of it.
struct Utf8Chunks(Vec<u8>);

impl Utf8Chunks {
    fn push_into(&mut self, bytes: &[u8], out: &mut String) {
        if bytes.is_empty() {
            return;
        }
        // Fast path: no buffered tail and packet is valid UTF-8 (zero extra copy).
        if self.0.is_empty() {
            if let Ok(valid) = std::str::from_utf8(bytes) {
                out.push_str(valid);
                return;
            }
        }
        self.0.extend_from_slice(bytes);
        let mut consumed = 0;
        while consumed < self.0.len() {
            match std::str::from_utf8(&self.0[consumed..]) {
                Ok(valid) => {
                    out.push_str(valid);
                    consumed = self.0.len();
                }
                Err(error) => {
                    let end = consumed + error.valid_up_to();
                    out.push_str(std::str::from_utf8(&self.0[consumed..end]).unwrap_or_default());
                    consumed = end;
                    if let Some(length) = error.error_len() {
                        out.push('\u{fffd}');
                        consumed += length;
                    } else {
                        break;
                    }
                }
            }
        }
        self.0.drain(..consumed);
    }

    #[cfg(test)]
    fn push(&mut self, bytes: &[u8]) -> String {
        let mut text = String::new();
        self.push_into(bytes, &mut text);
        text
    }
}

struct ExecBatcher<'a> {
    sink: &'a StreamSink<SshExecEvent>,
    decoders: [Utf8Chunks; 2],
    pending_stderr: Option<bool>,
    pending: String,
    remaining: usize,
    truncated: bool,
    last_flush: Instant,
}

impl<'a> ExecBatcher<'a> {
    fn new(sink: &'a StreamSink<SshExecEvent>) -> Self {
        Self {
            sink,
            decoders: [Utf8Chunks(Vec::new()), Utf8Chunks(Vec::new())],
            pending_stderr: None,
            pending: String::new(),
            remaining: EXEC_LIMIT,
            truncated: false,
            last_flush: Instant::now(),
        }
    }

    fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }

    fn next_flush_at(&self) -> Instant {
        self.last_flush + EXEC_FLUSH_INTERVAL
    }

    fn flush(&mut self) -> bool {
        let Some(stderr) = self.pending_stderr.take() else {
            return true;
        };
        if self.pending.is_empty() {
            return true;
        }
        let data = std::mem::take(&mut self.pending);
        self.last_flush = Instant::now();
        self.sink
            .add(SshExecEvent::new(
                if stderr { "stderr" } else { "stdout" },
                data,
            ))
            .is_ok()
    }

    fn push(&mut self, stderr: bool, data: &[u8]) -> bool {
        if self.remaining == 0 {
            self.truncated |= !data.is_empty();
            return true;
        }
        let take = data.len().min(self.remaining);
        self.remaining -= take;
        self.truncated |= take < data.len();
        if take == 0 {
            return true;
        }
        if self.pending_stderr.is_some_and(|current| current != stderr) && !self.flush() {
            return false;
        }
        if self.pending_stderr.is_none() {
            self.pending_stderr = Some(stderr);
            self.last_flush = Instant::now();
        }
        self.decoders[usize::from(stderr)].push_into(&data[..take], &mut self.pending);
        if self.pending.len() >= EXEC_FLUSH_BYTES
            || self.last_flush.elapsed() >= EXEC_FLUSH_INTERVAL
        {
            return self.flush();
        }
        true
    }

    fn finish(&mut self) {
        let _ = self.flush();
        if !self.truncated {
            for (decoder, kind) in self.decoders.iter().zip(["stdout", "stderr"]) {
                if !decoder.0.is_empty() {
                    let _ = self.sink.add(SshExecEvent::new(
                        kind,
                        String::from_utf8_lossy(&decoder.0).into(),
                    ));
                }
            }
        }
    }
}

enum ChannelExit {
    Status(u32),
    Timeout,
    Cancelled,
    Error(anyhow::Error),
}

async fn run_channel(
    session_id: u32,
    command: String,
    input: &[u8],
    time_limit: Duration,
    cancellation: &CancellationToken,
    mut on_data: impl FnMut(bool, &[u8]) -> bool,
) -> ChannelExit {
    let deadline = Instant::now() + time_limit;
    let opened = tokio::select! {
        biased;
        _ = cancellation.cancelled() => return ChannelExit::Cancelled,
        result = timeout_at(deadline, open_agent_channel(session_id)) => result,
    };
    let mut channel = match opened {
        Ok(Ok(channel)) => channel,
        Ok(Err(error)) => return ChannelExit::Error(error),
        Err(_) => return ChannelExit::Timeout,
    };
    let result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => ChannelExit::Cancelled,
        result = timeout_at(deadline, async {
            channel.exec(true, command).await?;
            // Fixed file scripts consume stdin before emitting any file data.
            // EOF is required even for commands with no input.
            if !input.is_empty() {
                channel.data(input).await?;
            }
            channel.eof().await?;
            let mut status = None;
            while let Some(message) = channel.wait().await {
                let keep_reading = match message {
                    ChannelMsg::Data { data } => on_data(false, &data),
                    ChannelMsg::ExtendedData { data, ext: 1 } => on_data(true, &data),
                    ChannelMsg::ExitStatus { exit_status } => {
                        status = Some(exit_status);
                        true
                    }
                    ChannelMsg::Failure => bail!("远端拒绝后台执行"),
                    ChannelMsg::ExitSignal { .. } => bail!("远端进程被信号终止"),
                    ChannelMsg::Close => break,
                    _ => true,
                };
                if !keep_reading {
                    return Ok(ChannelExit::Cancelled);
                }
            }
            Ok(ChannelExit::Status(status.ok_or_else(|| anyhow!("SSH 后台命令未返回退出码"))?))
        }) => match result {
            Ok(Ok(exit)) => exit,
            Ok(Err(error)) => ChannelExit::Error(error),
            Err(_) => ChannelExit::Timeout,
        },
    };
    let _ = timeout(CLEANUP_TIMEOUT, async {
        if matches!(result, ChannelExit::Timeout | ChannelExit::Cancelled) {
            let _ = channel.signal(Sig::TERM).await;
        }
        channel.close().await
    })
    .await;
    result
}

async fn run_channel_streaming(
    session_id: u32,
    command: String,
    time_limit: Duration,
    cancellation: &CancellationToken,
    batcher: &mut ExecBatcher<'_>,
) -> ChannelExit {
    let deadline = Instant::now() + time_limit;
    let opened = tokio::select! {
        biased;
        _ = cancellation.cancelled() => return ChannelExit::Cancelled,
        result = timeout_at(deadline, open_agent_channel(session_id)) => result,
    };
    let mut channel = match opened {
        Ok(Ok(channel)) => channel,
        Ok(Err(error)) => return ChannelExit::Error(error),
        Err(_) => return ChannelExit::Timeout,
    };
    let result = tokio::select! {
        biased;
        _ = cancellation.cancelled() => ChannelExit::Cancelled,
        result = timeout_at(deadline, async {
            channel.exec(true, command).await?;
            channel.eof().await?;
            let mut status = None;
            loop {
                let message = if batcher.has_pending() {
                    tokio::select! {
                        biased;
                        message = channel.wait() => message,
                        _ = tokio::time::sleep_until(batcher.next_flush_at()) => {
                            if !batcher.flush() {
                                return Ok(ChannelExit::Cancelled);
                            }
                            continue;
                        }
                    }
                } else {
                    channel.wait().await
                };
                let Some(message) = message else {
                    break;
                };
                let keep_reading = match message {
                    ChannelMsg::Data { data } => batcher.push(false, &data),
                    ChannelMsg::ExtendedData { data, ext: 1 } => batcher.push(true, &data),
                    ChannelMsg::ExitStatus { exit_status } => {
                        status = Some(exit_status);
                        true
                    }
                    ChannelMsg::Failure => bail!("远端拒绝后台执行"),
                    ChannelMsg::ExitSignal { .. } => bail!("远端进程被信号终止"),
                    ChannelMsg::Close => break,
                    _ => true,
                };
                if !keep_reading {
                    return Ok(ChannelExit::Cancelled);
                }
            }
            Ok(ChannelExit::Status(status.ok_or_else(|| anyhow!("SSH 后台命令未返回退出码"))?))
        }) => match result {
            Ok(Ok(exit)) => exit,
            Ok(Err(error)) => ChannelExit::Error(error),
            Err(_) => ChannelExit::Timeout,
        },
    };
    let _ = timeout(CLEANUP_TIMEOUT, async {
        if matches!(result, ChannelExit::Timeout | ChannelExit::Cancelled) {
            let _ = channel.signal(Sig::TERM).await;
        }
        channel.close().await
    })
    .await;
    result
}

/// Callers must bind the command to a current session and obtain any required
/// approval before opening this user-authorized command channel.
pub async fn ssh_exec_stream(
    session_id: u32,
    exec_id: u32,
    command: String,
    timeout_secs: u32,
    sink: StreamSink<SshExecEvent>,
) {
    let mut terminal = SshExecEvent::new("exit", String::new());
    if command.trim().is_empty()
        || command.len() > 32_000
        || command
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\t' | '\r' | '\n'))
    {
        terminal.data = "SSH 后台命令无效".into();
        let _ = sink.add(terminal);
        return;
    }
    let (_registration, cancellation) = match ExecRegistration::register(session_id, exec_id) {
        Ok(pair) => pair,
        Err(error) => {
            terminal.data = error.to_string();
            let _ = sink.add(terminal);
            return;
        }
    };
    if sink
        .add(SshExecEvent::new("started", String::new()))
        .is_err()
    {
        return;
    }
    let mut batcher = ExecBatcher::new(&sink);
    let result = run_channel_streaming(
        session_id,
        command,
        Duration::from_secs(timeout_secs.clamp(1, 600).into()),
        &cancellation,
        &mut batcher,
    )
    .await;
    batcher.finish();
    terminal.truncated = batcher.truncated;
    match result {
        ChannelExit::Status(code) => terminal.exit_code = i32::try_from(code).ok(),
        ChannelExit::Timeout => terminal.timed_out = true,
        ChannelExit::Cancelled => terminal.cancelled = true,
        ChannelExit::Error(_) => terminal.data = "SSH 后台命令未完成，请检查连接".into(),
    }
    let _ = sink.add(terminal);
}

pub async fn ssh_read_server_profile(session_id: u32) -> Result<String> {
    let (bytes, code) = read_only_exec(
        session_id,
        server_status_command(include_str!("agent_profile.sh")),
        &PROFILE_POLICY,
        512 * 1024,
    )
    .await?;
    ensure!(code == 0, "无法采集服务器基线");
    Ok(String::from_utf8_lossy(&bytes).into())
}

pub struct RemoteTextFile {
    pub text: String,
    pub sha256: String,
    pub modified_unix: Option<u32>,
    pub size_bytes: u32,
    pub used_sudo: bool,
}

pub struct RemoteWriteOutcome {
    pub backup_path: Option<String>,
    pub new_sha256: String,
    pub created_new: bool,
    pub used_sudo: bool,
}

fn secret_path(path: &str) -> bool {
    path.to_ascii_lowercase().split('/').any(|part| {
        matches!(
            part,
            ".ssh"
                | ".gnupg"
                | ".aws"
                | ".kube"
                | "shadow"
                | "gshadow"
                | "master.passwd"
                | "shadow-"
                | "gshadow-"
                | ".my.cnf"
                | ".pgpass"
                | "pgpass"
                | ".netrc"
                | ".npmrc"
                | "credentials"
                | "secrets"
                | "secret"
                | "login.keychain-db"
        ) || part.starts_with("id_rsa")
            || part.starts_with("id_ed25519")
            || part.starts_with("ssh_host_")
            || part == ".env"
            || part.starts_with(".env.")
            || [".key", ".pem", ".p12", ".pfx", ".kdbx", ".jks"]
                .iter()
                .any(|suffix| part.ends_with(suffix))
    })
}

fn validate_path(path: &str) -> Result<()> {
    ensure!(
        path.starts_with('/')
            && path.len() <= 3600
            && !path.chars().any(char::is_control)
            && path[1..]
                .split('/')
                .all(|part| !matches!(part, "" | "." | "..")),
        "INVALID_TARGET"
    );
    ensure!(!secret_path(path), "SENSITIVE_FILE");
    Ok(())
}

fn contains_ascii_ignore_case(haystack: &str, needle: &str) -> bool {
    let needle = needle.as_bytes();
    if needle.is_empty() {
        return true;
    }
    haystack
        .as_bytes()
        .windows(needle.len())
        .any(|window| window.eq_ignore_ascii_case(needle))
}

fn ends_with_ascii_ignore_case(value: &str, suffix: &str) -> bool {
    let value = value.as_bytes();
    let suffix = suffix.as_bytes();
    value.len() >= suffix.len() && value[value.len() - suffix.len()..].eq_ignore_ascii_case(suffix)
}

fn is_sensitive_key(key: &str) -> bool {
    const EXACT: &[&str] = &[
        "password",
        "passwd",
        "requirepass",
        "masterauth",
        "api_key",
        "apikey",
        "secret_key",
        "access_token",
        "client_secret",
        "token",
        "authorization",
        "sslpassword",
        "primary_conninfo",
    ];
    EXACT.iter().any(|name| key.eq_ignore_ascii_case(name))
        || ends_with_ascii_ignore_case(key, "_password")
        || ends_with_ascii_ignore_case(key, "_token")
        || ends_with_ascii_ignore_case(key, "_secret")
}

fn is_sensitive_line(raw: &str) -> bool {
    let line = raw.trim();
    if line.is_empty() {
        return false;
    }
    if line.contains("-----")
        && ((contains_ascii_ignore_case(line, "-----begin ")
            && contains_ascii_ignore_case(line, "private key-----"))
            || contains_ascii_ignore_case(line, "-----begin pgp private key block-----"))
    {
        return true;
    }
    if line.starts_with(['#', ';']) {
        return false;
    }
    let (key, value) = line.split_once(['=', ':', ' ', '\t']).unwrap_or((line, ""));
    let key = key.trim_matches(['\'', '"']);
    if !is_sensitive_key(key) {
        return false;
    }
    let value =
        value.trim_matches(|c: char| c.is_whitespace() || matches!(c, '=' | ':' | '"' | '\''));
    !value.is_empty()
}

fn validate_text(bytes: &[u8]) -> Result<&str> {
    let text = check_text_bytes(bytes)?;
    ensure!(!text.lines().any(is_sensitive_line), "SENSITIVE_FILE");
    Ok(text)
}

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn validate_hash(hash: &str) -> Result<()> {
    ensure!(
        hash.len() == 64
            && hash
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()),
        "INVALID_TARGET"
    );
    Ok(())
}

fn validate_suffix(suffix: &str) -> Result<()> {
    ensure!(
        (1..=64).contains(&suffix.len())
            && suffix
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-'),
        "INVALID_TARGET"
    );
    Ok(())
}

fn shell_word(word: &str) -> String {
    format!("'{}'", word.replace('\'', "'\\''"))
}

fn file_command(script: &str, arguments: &[&str], sudo: bool) -> String {
    let script = [include_str!("agent_file_common.sh"), script]
        .join("\n")
        .replace("\r\n", "\n");
    let args = arguments
        .iter()
        .map(|s| shell_word(s))
        .collect::<Vec<_>>()
        .join(" ");
    let command = format!(
        "/bin/sh -c {} pagashell {} {args}",
        shell_word(&script),
        u8::from(sudo)
    );
    if sudo {
        format!(
            "if [ \"$(/usr/bin/id -u)\" = 0 ]; then {command}; else sudo -n -- {command}; rc=$?; [ \"$rc\" -ne 1 ] || exit 77; exit \"$rc\"; fi"
        )
    } else {
        command
    }
}

async fn run_file_command(
    session_id: u32,
    script: &str,
    arguments: &[&str],
    use_sudo: bool,
    input: &[u8],
    modifies: bool,
) -> Result<Vec<u8>> {
    let (_registration, cancellation) = ExecRegistration::register_operation(
        session_id,
        OperationId::File(NEXT_FILE_OP.fetch_add(1, Ordering::Relaxed)),
    )?;
    let mut output = Vec::new();
    let mut received = 0usize;
    let result = run_channel(
        session_id,
        file_command(script, arguments, use_sudo),
        input,
        Duration::from_secs(30),
        &cancellation,
        |stderr, bytes| {
            received = received.saturating_add(bytes.len());
            if received > FILE_LIMIT + 1024 {
                return false;
            }
            if !stderr {
                output.extend_from_slice(bytes);
            }
            true
        },
    )
    .await;
    ensure!(received <= FILE_LIMIT + 1024, "FILE_TOO_LARGE");
    match result {
        ChannelExit::Status(0) => Ok(output),
        ChannelExit::Status(66) => bail!("FILE_CONFLICT"),
        ChannelExit::Status(67) => bail!("FILE_NOT_FOUND"),
        ChannelExit::Status(68) => bail!("FILE_ALREADY_EXISTS"),
        ChannelExit::Status(75) => bail!("FILE_TOO_LARGE"),
        ChannelExit::Status(76) => bail!("SENSITIVE_FILE"),
        ChannelExit::Status(77) => bail!("SUDO_PASSWORD_REQUIRED"),
        ChannelExit::Status(78) => bail!("INVALID_TARGET"),
        ChannelExit::Status(_) => bail!("REMOTE_FILE_OPERATION_FAILED"),
        ChannelExit::Error(_) if modifies => bail!("REMOTE_FILE_OUTCOME_UNKNOWN"),
        ChannelExit::Error(error) => Err(error),
        ChannelExit::Timeout | ChannelExit::Cancelled => bail!("REMOTE_FILE_OUTCOME_UNKNOWN"),
    }
}

pub async fn ssh_read_remote_text(
    session_id: u32,
    path: String,
    use_sudo: bool,
) -> Result<RemoteTextFile> {
    validate_path(&path)?;
    let bytes = run_file_command(
        session_id,
        include_str!("agent_read_file.sh"),
        &[&path],
        use_sudo,
        &[],
        false,
    )
    .await?;
    let separator = bytes
        .iter()
        .position(|b| *b == b'\n')
        .ok_or_else(|| anyhow!("INVALID_TARGET"))?;
    let modified_unix = std::str::from_utf8(&bytes[..separator])
        .ok()
        .and_then(|s| s.parse().ok());
    let content = &bytes[separator + 1..];
    ensure!(content.len() <= FILE_LIMIT, "FILE_TOO_LARGE");
    Ok(RemoteTextFile {
        text: validate_text(content)?.into(),
        sha256: hash(content),
        modified_unix,
        size_bytes: content.len() as u32,
        used_sudo: use_sudo,
    })
}

pub struct RemoteWriteRequest {
    pub path: String,
    pub content: String,
    pub expected_sha256: Option<String>,
    pub create_if_missing: bool,
    pub create_parent_dirs: bool,
    pub backup_suffix: String,
    pub use_sudo: bool,
}

pub async fn ssh_write_remote_text(
    session_id: u32,
    request: RemoteWriteRequest,
) -> Result<RemoteWriteOutcome> {
    validate_path(&request.path)?;
    validate_text(request.content.as_bytes())?;
    validate_suffix(&request.backup_suffix)?;
    if let Some(expected) = &request.expected_sha256 {
        validate_hash(expected)?;
    }
    let new_sha256 = hash(request.content.as_bytes());
    run_file_command(
        session_id,
        include_str!("agent_write_file.sh"),
        &[
            &request.path,
            request.expected_sha256.as_deref().unwrap_or(""),
            if request.create_if_missing { "1" } else { "0" },
            if request.create_parent_dirs { "1" } else { "0" },
            &request.backup_suffix,
            &new_sha256,
        ],
        request.use_sudo,
        request.content.as_bytes(),
        true,
    )
    .await?;
    let created_new = request.expected_sha256.is_none();
    Ok(RemoteWriteOutcome {
        backup_path: (!created_new)
            .then(|| format!("{}.pagashell.bak.{}", request.path, request.backup_suffix)),
        new_sha256,
        created_new,
        used_sudo: request.use_sudo,
    })
}

pub async fn ssh_restore_remote_backup(
    session_id: u32,
    path: String,
    backup_path: Option<String>,
    expected_current_sha256: String,
    expected_backup_sha256: Option<String>,
    use_sudo: bool,
) -> Result<()> {
    validate_path(&path)?;
    validate_hash(&expected_current_sha256)?;
    let (suffix, original) = match (backup_path, expected_backup_sha256) {
        (Some(backup), Some(original)) => {
            let suffix = backup
                .strip_prefix(&format!("{path}.pagashell.bak."))
                .ok_or_else(|| anyhow!("INVALID_TARGET"))?;
            validate_suffix(suffix)?;
            validate_hash(&original)?;
            (suffix.to_owned(), original)
        }
        (None, None) => (String::new(), String::new()),
        _ => bail!("INVALID_TARGET"),
    };
    run_file_command(
        session_id,
        include_str!("agent_restore_file.sh"),
        &[&path, &expected_current_sha256, &suffix, &original],
        use_sudo,
        &[],
        true,
    )
    .await?;
    Ok(())
}

#[cfg(all(test, unix))]
#[path = "agent_ops_tests.rs"]
mod tests;
