//! SSH/SFTP 引擎：基于 russh 的纯 Rust 实现，经 flutter_rust_bridge 暴露给 Dart。
//!
//! 会话以 u32 句柄标识，注册在进程级会话表中；终端通道由单一 owner task
//! 持有，读写/resize/关闭通过 mpsc 指令传递，避免跨任务共享可变通道。

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use russh::client::{self, Handle};
use russh::keys::{decode_secret_key, HashAlg, PrivateKey, PrivateKeyWithHashAlg, PublicKey};
use russh::{ChannelMsg, Disconnect};
use russh_sftp::client::SftpSession;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch, Mutex, Notify};
use tokio::task::{JoinHandle, JoinSet};

use crate::frb_generated::StreamSink;

/// SFTP 目录条目（跨 FFI 的普通数据结构）。
pub struct SftpEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified_unix: u64,
}

/// 传输进度事件（跨 FFI）。total 为 0 表示大小未知。
pub struct TransferProgress {
    pub transferred: u64,
    pub total: u64,
    /// 仅在文件完整写入且远端关闭确认成功后置为 true。
    pub completed: bool,
}

/// 传输块大小与进度上报节流阈值。
const TRANSFER_CHUNK: usize = 64 * 1024;
const PROGRESS_EMIT_EVERY: u64 = 512 * 1024;
const PROGRESS_EMIT_INTERVAL: Duration = Duration::from_millis(200);
const TRANSFER_IO_TIMEOUT: Duration = Duration::from_secs(10);
const TRANSFER_CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);
const TRANSFER_RESPONSE_ATTEMPTS: usize = 3;

#[derive(Debug)]
struct TransferTimeout;

impl std::fmt::Display for TransferTimeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "传输失败：远程服务无响应，已达到重试上限（2 次，30 秒）")
    }
}

impl std::error::Error for TransferTimeout {}

// 包括写入确认、flush 和 shutdown；库自身的 request timeout 不覆盖写入确认。
async fn transfer_io<T, E: Into<anyhow::Error>>(
    cancel: &AtomicBool,
    operation: impl Future<Output = std::result::Result<T, E>>,
) -> Result<T> {
    let cancelled = async {
        loop {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    };
    tokio::pin!(operation);
    tokio::pin!(cancelled);
    for _ in 0..TRANSFER_RESPONSE_ATTEMPTS {
        tokio::select! {
            biased;
            _ = &mut cancelled => return Err(anyhow!("传输已取消")),
            result = tokio::time::timeout(TRANSFER_IO_TIMEOUT, &mut operation) => {
                match result {
                    Ok(result) => return result.map_err(Into::into),
                    // 保留同一请求继续等确认，不能重发可能已写入的块或重建同名文件。
                    Err(_) => continue,
                }
            }
        }
    }
    Err(anyhow::Error::new(TransferTimeout))
}

async fn transfer_cleanup<T>(operation: impl Future<Output = T>) {
    // 断线后的删除半成品/关闭通道也必须有上限，不能挡住失败事件。
    let _ = tokio::time::timeout(TRANSFER_CLEANUP_TIMEOUT, operation).await;
}

enum ShellCmd {
    Data(Vec<u8>),
    Resize(u32, u32),
    Close,
}

struct SessionEntry {
    handle: Arc<Mutex<Handle<PinningHandler>>>,
    gateway_id: Option<u32>,
    shell_tx: Option<mpsc::Sender<ShellCmd>>,
    pending_terminal_size: Option<(u32, u32)>,
    forwards: Option<(watch::Sender<bool>, JoinHandle<()>)>,
}

static SESSIONS: LazyLock<Mutex<HashMap<u32, SessionEntry>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_ID: AtomicU32 = AtomicU32::new(1);

/// 进行中传输的取消标志表，键为 Dart 侧分配的 transfer_id。
static TRANSFER_CANCELS: LazyLock<Mutex<HashMap<u32, Arc<AtomicBool>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 未认证的握手结果。确认指纹后只能在这条连接上认证，避免二次连接竞态。
pub struct SshHandshake {
    pub session_id: u32,
    pub key_type: String,
    pub fingerprint: String,
}

struct PendingSession {
    handle: Arc<Mutex<Handle<PinningHandler>>>,
    gateway_id: Option<u32>,
    fingerprint: String,
    authenticating: bool,
    cancelled: Arc<Notify>,
}

static PENDING_SESSIONS: LazyLock<Mutex<HashMap<u32, PendingSession>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

struct PinningHandler {
    key: Arc<Mutex<Option<PublicKey>>>,
}

impl client::Handler for PinningHandler {
    type Error = russh::Error;

    // 初次握手仅记录密钥，不发送凭据、不开放会话通道。
    // 认证由 ssh_authenticate 的指纹门禁控制；重协商不得替换密钥。
    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        let mut key = self.key.lock().await;
        match key.as_ref() {
            Some(pinned) => Ok(pinned.key_data() == server_public_key.key_data()),
            None => {
                *key = Some(server_public_key.clone());
                Ok(true)
            }
        }
    }
}

/// 只进行 SSH 握手并返回服务器指纹。此阶段不接收或发送密码。
pub async fn ssh_handshake(host: String, port: u16) -> Result<SshHandshake> {
    handshake(host, port, None, None).await
}

/// 通过已校验并认证的网关建立 direct-tcpip 通道，目标仍需独立校验指纹。
/// gateway_id 必须为专用连接；失败或目标关闭时一并关闭该网关。
pub async fn ssh_handshake_via_gateway(
    host: String,
    port: u16,
    gateway_id: u32,
) -> Result<SshHandshake> {
    let result = handshake(host, port, Some(gateway_id), None).await;
    if result.is_err() {
        ssh_disconnect(gateway_id).await?;
    }
    result
}

/// A Page stream owns its TLS connection; closing the target closes the relay.
pub async fn ssh_handshake_via_page(
    host: String,
    port: u16,
    gateway: crate::api::page::PageGateway,
) -> Result<SshHandshake> {
    handshake(host, port, None, Some(gateway)).await
}

/// Only authenticated registry entries can open a desktop tunnel.
pub(crate) async fn desktop_tunnel(
    gateway_id: u32,
    host: String,
    port: u16,
) -> Result<russh::ChannelStream<client::Msg>> {
    let handle = SESSIONS
        .lock()
        .await
        .get(&gateway_id)
        .context("网关连接不存在或已关闭")?
        .handle
        .clone();
    let channel = tokio::time::timeout(Duration::from_secs(15), async {
        handle
            .lock()
            .await
            .channel_open_direct_tcpip(host, u32::from(port), "127.0.0.1", 0)
            .await
    })
    .await
    .context("网关隧道连接超时")??;
    Ok(channel.into_stream())
}

async fn handshake(
    host: String,
    port: u16,
    gateway_id: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<SshHandshake> {
    let using_page = page_gateway.is_some();
    let config = Arc::new(client::Config {
        keepalive_interval: Some(Duration::from_secs(30)),
        ..Default::default()
    });

    let key = Arc::new(Mutex::new(None));
    let handle = tokio::time::timeout(Duration::from_secs(15), async {
        let handler = PinningHandler { key: key.clone() };
        if let Some(gateway) = page_gateway {
            let stream = crate::page::connect(gateway, &host, port).await?;
            client::connect_stream(config, stream, handler)
                .await
                .map_err(anyhow::Error::from)
        } else if let Some(id) = gateway_id {
            let handle = SESSIONS
                .lock()
                .await
                .get(&id)
                .ok_or_else(|| anyhow!("网关连接不存在或已关闭"))?
                .handle
                .clone();
            let channel = handle
                .lock()
                .await
                .channel_open_direct_tcpip(host.clone(), u32::from(port), "127.0.0.1", 0)
                .await
                .context("无法通过网关建立隧道，请检查网关转发权限和目标地址")?;
            client::connect_stream(config, channel.into_stream(), handler)
                .await
                .map_err(anyhow::Error::from)
        } else {
            client::connect(config, (host.as_str(), port), handler)
                .await
                .map_err(anyhow::Error::from)
        }
    })
    .await
    .map_err(|_| anyhow!("连接超时: {host}:{port}"))?
    .map_err(|error| {
        if using_page {
            error
        } else {
            error.context(format!("无法连接 {host}:{port}"))
        }
    })?;

    let key = key.lock().await;
    let key = key
        .as_ref()
        .ok_or_else(|| anyhow!("服务器未提供主机密钥"))?;
    let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
    let result = SshHandshake {
        session_id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
        key_type: key.algorithm().to_string(),
        fingerprint: fingerprint.clone(),
    };
    PENDING_SESSIONS.lock().await.insert(
        result.session_id,
        PendingSession {
            handle: Arc::new(Mutex::new(handle)),
            gateway_id,
            fingerprint,
            authenticating: false,
            cancelled: Arc::new(Notify::new()),
        },
    );
    let id = result.session_id;
    // 即使 Dart 侧退出确认页面或异常，也不无限保留未认证连接。
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(180)).await;
        let pending = PENDING_SESSIONS.lock().await.remove(&id);
        if let Some(pending) = pending {
            pending.cancelled.notify_one();
            let _ = pending
                .handle
                .lock()
                .await
                .disconnect(Disconnect::ByApplication, "", "en")
                .await;
            if let Some(gateway_id) = pending.gateway_id {
                let _ = ssh_disconnect(gateway_id).await;
            }
        }
    });
    Ok(result)
}

enum Credentials {
    Password(String),
    PrivateKey {
        encoded: String,
        passphrase: Option<String>,
    },
}

/// 校验导入的私钥及口令，不连接服务器、不返回敏感的解析错误原文。
pub async fn ssh_validate_private_key(
    private_key: String,
    passphrase: Option<String>,
) -> Result<()> {
    load_private_key(private_key, passphrase).await.map(|_| ())
}

async fn load_private_key(encoded: String, passphrase: Option<String>) -> Result<PrivateKey> {
    if encoded.len() > 1024 * 1024 {
        return Err(anyhow!("私钥文件不能超过 1 MiB"));
    }
    // 加密私钥的 KDF 可能耗时，放到阻塞线程池，避免阻塞协议运行时。
    tokio::task::spawn_blocking(move || {
        decode_secret_key(
            encoded.trim(),
            passphrase.as_deref().filter(|p| !p.is_empty()),
        )
        .map_err(|_| anyhow!("私钥格式无效或口令错误，请检查 OpenSSH、PEM 或 PPK 私钥与口令"))
    })
    .await
    .map_err(|_| anyhow!("私钥解析失败"))?
}

/// 在已确认指纹的同一条连接上进行密码认证。
pub async fn ssh_authenticate(
    session_id: u32,
    expected_fingerprint: String,
    username: String,
    password: String,
) -> Result<u32> {
    authenticate(
        session_id,
        expected_fingerprint,
        username,
        Credentials::Password(password),
    )
    .await
}

/// 在已确认指纹的同一条连接上进行私钥认证，私钥只在本机用于签名。
pub async fn ssh_authenticate_private_key(
    session_id: u32,
    expected_fingerprint: String,
    username: String,
    private_key: String,
    passphrase: Option<String>,
) -> Result<u32> {
    authenticate(
        session_id,
        expected_fingerprint,
        username,
        Credentials::PrivateKey {
            encoded: private_key,
            passphrase,
        },
    )
    .await
}

async fn authenticate_inner(
    handle: &mut Handle<PinningHandler>,
    username: String,
    credentials: Credentials,
) -> Result<client::AuthResult> {
    match credentials {
        Credentials::Password(password) => handle
            .authenticate_password(username, password)
            .await
            .map_err(|_| anyhow!("密码认证过程出错")),
        Credentials::PrivateKey {
            encoded,
            passphrase,
        } => {
            let key = load_private_key(encoded, passphrase).await?;
            let hash = if key.algorithm().is_rsa() {
                match handle
                    .best_supported_rsa_hash()
                    .await
                    .map_err(|_| anyhow!("无法协商 RSA 签名算法"))?
                {
                    Some(Some(hash)) => Some(hash),
                    None => Some(HashAlg::Sha256),
                    Some(None) => {
                        return Err(anyhow!(
                            "服务器不支持 RSA SHA-2 签名，请使用 Ed25519 或 ECDSA 私钥"
                        ))
                    }
                }
            } else {
                None
            };
            handle
                .authenticate_publickey(username, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
                .await
                .map_err(|_| anyhow!("私钥认证过程出错"))
        }
    }
}

async fn authenticate(
    session_id: u32,
    expected_fingerprint: String,
    username: String,
    credentials: Credentials,
) -> Result<u32> {
    let is_private_key = matches!(credentials, Credentials::PrivateKey { .. });
    let (handle, cancelled, matches) = {
        let mut pending = PENDING_SESSIONS.lock().await;
        let entry = pending
            .get_mut(&session_id)
            .ok_or_else(|| anyhow!("待确认连接不存在或已超时"))?;
        if entry.authenticating {
            return Err(anyhow!("连接正在认证中"));
        }
        entry.authenticating = true;
        (
            entry.handle.clone(),
            entry.cancelled.clone(),
            entry.fingerprint == expected_fingerprint,
        )
    };
    if !matches {
        ssh_disconnect(session_id).await?;
        return Err(anyhow!("主机指纹不匹配，已拒绝认证"));
    }
    let auth = {
        let mut guard = handle.lock().await;
        tokio::select! {
            biased;
            _ = cancelled.notified() => None,
            result = tokio::time::timeout(Duration::from_secs(15), authenticate_inner(&mut guard, username, credentials)) => Some(result),
        }
    };
    let auth = match auth {
        Some(Ok(Ok(auth))) => auth,
        Some(Ok(Err(error))) => {
            ssh_disconnect(session_id).await?;
            return Err(error);
        }
        _ => {
            ssh_disconnect(session_id).await?;
            return Err(anyhow!("连接已取消、认证出错或超时"));
        }
    };
    if !auth.success() {
        ssh_disconnect(session_id).await?;
        return Err(anyhow!(if is_private_key {
            "私钥认证失败，请检查用户名及服务器 authorized_keys 配置"
        } else {
            "认证失败：用户名或密码错误"
        }));
    }

    // 与断开操作使用相同锁顺序，避免待认证记录移除与就绪记录插入之间的空隙。
    let mut pending = PENDING_SESSIONS.lock().await;
    let entry = pending
        .remove(&session_id)
        .ok_or_else(|| anyhow!("连接已取消"))?;
    SESSIONS.lock().await.insert(
        session_id,
        SessionEntry {
            handle,
            gateway_id: entry.gateway_id,
            shell_tx: None,
            pending_terminal_size: None,
            forwards: None,
        },
    );
    Ok(session_id)
}

/// 打开带 PTY 的 shell 通道，输出通过 [output] 流回 Dart。
pub async fn ssh_start_shell(
    session_id: u32,
    cols: u32,
    rows: u32,
    output: StreamSink<Vec<u8>>,
) -> Result<()> {
    start_shell(session_id, cols, rows, move |data| output.add(data).is_ok()).await
}

async fn start_shell(
    session_id: u32,
    cols: u32,
    rows: u32,
    emit: impl Fn(Vec<u8>) -> bool + Send + 'static,
) -> Result<()> {
    let (handle, (cols, rows)) = {
        let sessions = SESSIONS.lock().await;
        let entry = sessions
            .get(&session_id)
            .ok_or_else(|| anyhow!("会话不存在: {session_id}"))?;
        (
            entry.handle.clone(),
            entry.pending_terminal_size.unwrap_or((cols, rows)),
        )
    };

    let mut channel = {
        let guard = handle.lock().await;
        guard.channel_open_session().await?
    };
    channel
        .request_pty(false, "xterm-256color", cols, rows, 0, 0, &[])
        .await?;
    channel.request_shell(false).await?;

    let (tx, mut rx) = mpsc::channel::<ShellCmd>(64);
    {
        let mut sessions = SESSIONS.lock().await;
        let entry = sessions
            .get_mut(&session_id)
            .ok_or_else(|| anyhow!("会话不存在: {session_id}"))?;
        // 布局通知可能早于 PTY 就绪。先补发启动期间的最新尺寸，再发布
        // 命令队列，使后续 resize 不会被旧尺寸覆盖。
        if let Some((c, r)) = entry.pending_terminal_size.take() {
            if (c, r) != (cols, rows) {
                tx.try_send(ShellCmd::Resize(c, r))
                    .map_err(|_| anyhow!("终端已关闭"))?;
            }
        }
        entry.shell_tx = Some(tx);
    }

    tokio::spawn(async move {
        loop {
            tokio::select! {
                msg = channel.wait() => match msg {
                    Some(ChannelMsg::Data { data }) => {
                        if !emit(data.to_vec()) {
                            break;
                        }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        if !emit(data.to_vec()) {
                            break;
                        }
                    }
                    Some(ChannelMsg::Close) | None => break,
                    Some(_) => {}
                },
                cmd = rx.recv() => match cmd {
                    Some(ShellCmd::Data(data)) => {
                        if channel.data(&data[..]).await.is_err() {
                            break;
                        }
                    }
                    Some(ShellCmd::Resize(c, r)) => {
                        let _ = channel.window_change(c, r, 0, 0).await;
                    }
                    Some(ShellCmd::Close) | None => {
                        let _ = channel.eof().await;
                        let _ = channel.close().await;
                        break;
                    }
                },
            }
        }
    });
    Ok(())
}

/// 向终端写入用户输入。
pub async fn ssh_write(session_id: u32, data: Vec<u8>) -> Result<()> {
    shell_tx(session_id)
        .await?
        .send(ShellCmd::Data(data))
        .await
        .map_err(|_| anyhow!("终端已关闭"))
}

/// 通知远端终端尺寸变化；shell 尚未就绪时保留最新尺寸，启动后补发。
pub async fn ssh_resize(session_id: u32, cols: u32, rows: u32) -> Result<()> {
    let tx = {
        let mut sessions = SESSIONS.lock().await;
        let entry = sessions
            .get_mut(&session_id)
            .ok_or_else(|| anyhow!("会话不存在: {session_id}"))?;
        match entry.shell_tx.clone() {
            Some(tx) => tx,
            None => {
                entry.pending_terminal_size = Some((cols, rows));
                return Ok(());
            }
        }
    };
    tx.send(ShellCmd::Resize(cols, rows))
        .await
        .map_err(|_| anyhow!("终端已关闭"))
}

/// 用独立、无 PTY 的 exec 通道执行固定只读采集脚本，不影响交互终端。
pub async fn ssh_read_server_status(session_id: u32) -> Result<String> {
    let handle = SESSIONS
        .lock()
        .await
        .get(&session_id)
        .ok_or_else(|| anyhow!("会话不存在: {session_id}"))?
        .handle
        .clone();
    let mut channel = tokio::time::timeout(Duration::from_secs(8), async {
        handle.lock().await.channel_open_session().await
    })
    .await
    .map_err(|_| anyhow!("服务状态采集超时"))??;
    let result = tokio::time::timeout(Duration::from_secs(8), async {
        let script = include_str!("server_status.sh").replace('\'', "'\\''");
        channel.exec(true, format!("sh -c '{script}'")).await?;
        let mut output = Vec::new();
        let mut exit_status = None;
        while let Some(message) = channel.wait().await {
            match message {
                ChannelMsg::Data { data } => {
                    if output.len() + data.len() > 512 * 1024 {
                        return Err(anyhow!("服务状态数据过大"));
                    }
                    output.extend_from_slice(&data);
                }
                ChannelMsg::Failure => return Err(anyhow!("服务器不允许采集服务状态")),
                ChannelMsg::ExitStatus { exit_status: code } => exit_status = Some(code),
                ChannelMsg::Close => break,
                _ => {}
            }
        }
        if exit_status != Some(0) {
            return Err(anyhow!("无法获取服务状态，请检查远端系统及读取权限"));
        }
        String::from_utf8(output).map_err(|_| anyhow!("服务状态输出格式无效"))
    })
    .await
    .map_err(|_| anyhow!("服务状态采集超时"))
    .and_then(|value| value);
    let _ = channel.close().await;
    result
}

/// 关闭会话：结束 shell 通道并断开连接。
pub async fn ssh_disconnect(session_id: u32) -> Result<()> {
    let pending = PENDING_SESSIONS.lock().await.remove(&session_id);
    if let Some(pending) = pending {
        pending.cancelled.notify_one();
        let _ = pending
            .handle
            .lock()
            .await
            .disconnect(Disconnect::ByApplication, "", "en")
            .await;
        if let Some(id) = pending.gateway_id {
            Box::pin(ssh_disconnect(id)).await?;
        }
    }
    let entry = SESSIONS.lock().await.remove(&session_id);
    if let Some(entry) = entry {
        if let Some((cancel, mut task)) = entry.forwards {
            let _ = cancel.send(true);
            if tokio::time::timeout(Duration::from_secs(2), &mut task)
                .await
                .is_err()
            {
                task.abort();
                let _ = task.await;
            }
        }
        if let Some(tx) = entry.shell_tx {
            let _ = tx.send(ShellCmd::Close).await;
        }
        let guard = entry.handle.lock().await;
        let _ = guard.disconnect(Disconnect::ByApplication, "", "en").await;
        if let Some(id) = entry.gateway_id {
            Box::pin(ssh_disconnect(id)).await?;
        }
    }
    Ok(())
}

/// 本地监听固定绑定所有 IPv4 网卡（*）。
#[derive(Clone)]
pub struct ForwardPortSpec {
    pub local_port: u16,
    pub target_host: String,
    pub target_port: u16,
}

pub struct PortForwardEvent {
    /// ready: 所有端口已监听；connectionError: 单次目标连接失败；closed: 隧道结束。
    pub kind: String,
    pub local_port: Option<u16>,
}

/// 一条专用 SSH 会话上的多端口转发。任一 bind 失败时不保留部分监听。
pub async fn ssh_start_port_forwards(
    session_id: u32,
    ports: Vec<ForwardPortSpec>,
    output: StreamSink<PortForwardEvent>,
) -> Result<()> {
    start_port_forwards(session_id, ports, move |event| output.add(event).is_ok()).await
}

async fn start_port_forwards(
    session_id: u32,
    ports: Vec<ForwardPortSpec>,
    emit: impl Fn(PortForwardEvent) -> bool + Send + Sync + 'static,
) -> Result<()> {
    let mut seen = HashSet::new();
    if ports.is_empty() {
        return Err(anyhow!("请配置至少一组端口映射"));
    }
    let mut bound = Vec::new();
    for port in ports {
        if port.local_port == 0 || port.target_port == 0 || port.target_host.trim().is_empty() {
            return Err(anyhow!("请填写有效的目标地址和端口（1-65535）"));
        }
        if !seen.insert(port.local_port) {
            return Err(anyhow!("本地端口不能重复"));
        }
        let listener = TcpListener::bind(("0.0.0.0", port.local_port))
            .await
            .map_err(|_| anyhow!("无法监听本地端口 {}，请检查端口占用或权限", port.local_port))?;
        bound.push((listener, port));
    }
    let mut sessions = SESSIONS.lock().await;
    let entry = sessions
        .get_mut(&session_id)
        .ok_or_else(|| anyhow!("会话已关闭"))?;
    if entry.forwards.is_some() {
        return Err(anyhow!("端口转发已启动"));
    }
    let handle = entry.handle.clone();
    let (cancel, mut cancelled) = watch::channel(false);
    let stop = cancel.clone();
    let emit = Arc::new(emit);
    let task = tokio::spawn(async move {
        let mut listeners = JoinSet::new();
        for (listener, port) in bound {
            let handle = handle.clone();
            let emit = emit.clone();
            let cancelled = cancelled.clone();
            listeners.spawn(forward_listener(listener, port, handle, cancelled, emit));
        }
        if emit(PortForwardEvent {
            kind: "ready".into(),
            local_port: None,
        }) {
            let mut tick = tokio::time::interval(Duration::from_millis(250));
            loop {
                tokio::select! {
                    _ = cancelled.changed() => break,
                    _ = listeners.join_next() => break,
                    _ = tick.tick() => {
                        // 不等待某个正在打开远端通道的任务持有的锁。
                        if let Ok(guard) = handle.try_lock() {
                            if guard.is_closed() { break; }
                        }
                    }
                }
            }
        }
        let _ = stop.send(true);
        while listeners.join_next().await.is_some() {}
        emit(PortForwardEvent {
            kind: "closed".into(),
            local_port: None,
        });
    });
    entry.forwards = Some((cancel, task));
    Ok(())
}

async fn forward_listener(
    listener: TcpListener,
    port: ForwardPortSpec,
    handle: Arc<Mutex<Handle<PinningHandler>>>,
    mut cancelled: watch::Receiver<bool>,
    emit: Arc<impl Fn(PortForwardEvent) -> bool + Send + Sync + 'static>,
) {
    let mut connections = JoinSet::new();
    while !*cancelled.borrow() {
        tokio::select! {
            _ = cancelled.changed() => break,
            _ = connections.join_next(), if !connections.is_empty() => {},
            accepted = listener.accept() => {
                let Ok((mut socket, peer)) = accepted else { break; };
                let handle = handle.clone();
                let port = port.clone();
                let emit = emit.clone();
                let mut cancelled = cancelled.clone();
                connections.spawn(async move {
                    let connection = async {
                        let channel = tokio::time::timeout(Duration::from_secs(10), async {
                            handle.lock().await.channel_open_direct_tcpip(
                                port.target_host, u32::from(port.target_port),
                                peer.ip().to_string(), u32::from(peer.port()),
                            ).await
                        }).await.map_err(|_| anyhow!("目标端口连接超时"))??;
                        let mut stream = channel.into_stream();
                        tokio::io::copy_bidirectional(&mut socket, &mut stream).await?;
                        Ok::<(), anyhow::Error>(())
                    };
                    tokio::select! {
                        _ = cancelled.changed() => {},
                        result = connection => {
                            if result.is_err() {
                                emit(PortForwardEvent {
                                    kind: "connectionError".into(), local_port: Some(port.local_port),
                                });
                            }
                        }
                    }
                });
            }
        }
    }
    connections.abort_all();
    while connections.join_next().await.is_some() {}
}

/// 在指定会话的连接上按需打开一条 SFTP 子系统通道。
async fn open_sftp(session_id: u32) -> Result<SftpSession> {
    transfer_io(&AtomicBool::new(false), open_sftp_inner(session_id)).await
}

async fn open_sftp_inner(session_id: u32) -> Result<SftpSession> {
    let handle = {
        let sessions = SESSIONS.lock().await;
        sessions
            .get(&session_id)
            .ok_or_else(|| anyhow!("会话不存在: {session_id}"))?
            .handle
            .clone()
    };

    let channel = {
        let guard = handle.lock().await;
        guard.channel_open_session().await?
    };
    channel.request_subsystem(true, "sftp").await?;
    SftpSession::new(channel.into_stream())
        .await
        .context("SFTP 子系统初始化失败")
}

/// 列出远程目录（SFTP 子系统按需在同一连接上开通道）。
pub async fn sftp_list_dir(session_id: u32, path: String) -> Result<Vec<SftpEntry>> {
    let sftp = open_sftp(session_id).await?;
    let result = async {
        let mut entries = Vec::new();
        for entry in sftp.read_dir(&path).await.context("读取目录失败")? {
            let meta = entry.metadata();
            entries.push(SftpEntry {
                name: entry.file_name(),
                is_dir: meta.is_dir(),
                size: meta.size.unwrap_or(0),
                modified_unix: u64::from(meta.mtime.unwrap_or(0)),
            });
        }
        Ok(entries)
    }
    .await;
    let _ = sftp.close().await;
    result
}

/// 规范化远程路径（解析 `.`/`..`/符号链接）；用「.」可取得家目录。
pub async fn sftp_canonicalize(session_id: u32, path: String) -> Result<String> {
    let sftp = open_sftp(session_id).await?;
    let result = sftp.canonicalize(&path).await.context("解析路径失败");
    let _ = sftp.close().await;
    result
}

/// 创建远程目录。
pub async fn sftp_mkdir(session_id: u32, path: String) -> Result<()> {
    let sftp = open_sftp(session_id).await?;
    let result = sftp.create_dir(&path).await.context("创建目录失败");
    let _ = sftp.close().await;
    result.map(|_| ())
}

/// 重命名/移动远程文件或目录。
pub async fn sftp_rename(session_id: u32, from: String, to: String) -> Result<()> {
    let sftp = open_sftp(session_id).await?;
    let result = sftp.rename(&from, &to).await.context("重命名失败");
    let _ = sftp.close().await;
    result.map(|_| ())
}

/// 删除远程文件；[is_dir] 为 true 时递归删除目录。
pub async fn sftp_remove(session_id: u32, path: String, is_dir: bool) -> Result<()> {
    let sftp = open_sftp(session_id).await?;
    let result = if is_dir {
        remove_dir_recursive(&sftp, &path).await
    } else {
        sftp.remove_file(&path)
            .await
            .context("删除文件失败")
            .map(|_| ())
    };
    let _ = sftp.close().await;
    result
}

/// 递归删除目录（异步递归需要 Box::pin）。
fn remove_dir_recursive<'a>(
    sftp: &'a SftpSession,
    path: &'a str,
) -> Pin<Box<dyn Future<Output = Result<()>> + Send + 'a>> {
    Box::pin(async move {
        for entry in sftp.read_dir(path).await.context("读取目录失败")? {
            let child = format!("{}/{}", path.trim_end_matches('/'), entry.file_name());
            if entry.metadata().is_dir() {
                remove_dir_recursive(sftp, &child).await?;
            } else {
                sftp.remove_file(&child)
                    .await
                    .with_context(|| format!("删除失败: {child}"))?;
            }
        }
        sftp.remove_dir(path).await.context("删除目录失败")?;
        Ok(())
    })
}

/// 请求取消一个进行中的传输；无此传输时为无操作。
pub async fn sftp_cancel_transfer(transfer_id: u32) -> Result<()> {
    if let Some(flag) = TRANSFER_CANCELS.lock().await.get(&transfer_id) {
        flag.store(true, Ordering::Relaxed);
    }
    Ok(())
}

/// 下载远程文件到本地，进度经 [progress] 流回 Dart（约每 512KB 一次）。
///
/// 取消或失败时删除本地半成品文件并以错误结束。
pub async fn sftp_download(
    session_id: u32,
    transfer_id: u32,
    remote_path: String,
    local_path: String,
    progress: StreamSink<TransferProgress>,
) {
    let cancel = register_transfer(transfer_id).await;
    let result = async {
        let sftp = transfer_io(&cancel, open_sftp(session_id)).await?;
        let mut created = false;
        let r = download_inner(
            &sftp,
            &cancel,
            &remote_path,
            &local_path,
            &progress,
            &mut created,
        )
        .await;
        if r.is_err() && created {
            transfer_cleanup(tokio::fs::remove_file(&local_path)).await;
        }
        transfer_cleanup(sftp.close()).await;
        r
    }
    .await;
    unregister_transfer(transfer_id).await;
    // FRB 的调用 Result 与进度流是两条通道，错误必须发到进度流。
    if let Err(error) = result {
        let _ = progress.add_error(error);
    }
}

async fn download_inner(
    sftp: &SftpSession,
    cancel: &AtomicBool,
    remote_path: &str,
    local_path: &str,
    progress: &StreamSink<TransferProgress>,
    created: &mut bool,
) -> Result<()> {
    let meta = transfer_io(cancel, sftp.metadata(remote_path))
        .await
        .context("读取远程文件信息失败")?;
    let total = meta.size.unwrap_or(0);
    let mut remote = transfer_io(cancel, sftp.open(remote_path))
        .await
        .context("打开远程文件失败")?;
    let mut local = tokio::fs::File::create(local_path)
        .await
        .context("创建本地文件失败")?;
    *created = true;

    let mut buf = vec![0u8; TRANSFER_CHUNK];
    let mut transferred: u64 = 0;
    let mut last_emit: u64 = 0;
    let mut last_emit_at = tokio::time::Instant::now();
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(anyhow!("传输已取消"));
        }
        let n = transfer_io(cancel, remote.read(&mut buf))
            .await
            .context("读取远程文件失败")?;
        if n == 0 {
            break;
        }
        local
            .write_all(&buf[..n])
            .await
            .context("写入本地文件失败")?;
        transferred += n as u64;
        if transferred - last_emit >= PROGRESS_EMIT_EVERY
            || last_emit_at.elapsed() >= PROGRESS_EMIT_INTERVAL
        {
            last_emit = transferred;
            last_emit_at = tokio::time::Instant::now();
            let _ = progress.add(TransferProgress {
                transferred,
                total,
                completed: false,
            });
        }
    }
    local.flush().await.context("写入本地文件失败")?;
    if total > 0 && transferred != total {
        return Err(anyhow!("远程文件大小已变化，下载未完成"));
    }
    let _ = progress.add(TransferProgress {
        transferred,
        total,
        completed: true,
    });
    Ok(())
}

/// 上传本地文件到远程路径，进度经 [progress] 流回 Dart。
///
/// 取消或失败时删除远端半成品文件并以错误结束。
pub async fn sftp_upload(
    session_id: u32,
    transfer_id: u32,
    local_path: String,
    remote_path: String,
    progress: StreamSink<TransferProgress>,
) {
    let cancel = register_transfer(transfer_id).await;
    let result = async {
        let sftp = transfer_io(&cancel, open_sftp(session_id)).await?;
        let mut created = false;
        let r = upload_inner(
            &sftp,
            &cancel,
            &local_path,
            &remote_path,
            &progress,
            &mut created,
        )
        .await;
        if r.is_err() && created {
            transfer_cleanup(sftp.remove_file(&remote_path)).await;
        }
        transfer_cleanup(sftp.close()).await;
        r
    }
    .await;
    unregister_transfer(transfer_id).await;
    if let Err(error) = result {
        let _ = progress.add_error(error);
    }
}

async fn upload_inner(
    sftp: &SftpSession,
    cancel: &AtomicBool,
    local_path: &str,
    remote_path: &str,
    progress: &StreamSink<TransferProgress>,
    created: &mut bool,
) -> Result<()> {
    let total = tokio::fs::metadata(local_path)
        .await
        .context("读取本地文件信息失败")?
        .len();
    let mut local = tokio::fs::File::open(local_path)
        .await
        .context("打开本地文件失败")?;
    let mut remote = transfer_io(cancel, sftp.create(remote_path))
        .await
        .context("创建远程文件失败")?;
    *created = true;

    let mut buf = vec![0u8; TRANSFER_CHUNK];
    let mut transferred: u64 = 0;
    let mut last_emit: u64 = 0;
    let mut last_emit_at = tokio::time::Instant::now();
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(anyhow!("传输已取消"));
        }
        let n = local.read(&mut buf).await.context("读取本地文件失败")?;
        if n == 0 {
            break;
        }
        transfer_io(cancel, remote.write_all(&buf[..n]))
            .await
            .context("写入远程文件失败")?;
        transferred += n as u64;
        if transferred - last_emit >= PROGRESS_EMIT_EVERY
            || last_emit_at.elapsed() >= PROGRESS_EMIT_INTERVAL
        {
            last_emit = transferred;
            last_emit_at = tokio::time::Instant::now();
            let _ = progress.add(TransferProgress {
                transferred,
                total,
                completed: false,
            });
        }
    }
    transfer_io(cancel, remote.flush())
        .await
        .context("写入远程文件失败")?;
    transfer_io(cancel, remote.shutdown())
        .await
        .context("关闭远程文件失败")?;
    if transferred != total {
        return Err(anyhow!("本地文件大小已变化，上传未完成"));
    }
    let _ = progress.add(TransferProgress {
        transferred,
        total,
        completed: true,
    });
    Ok(())
}

async fn register_transfer(transfer_id: u32) -> Arc<AtomicBool> {
    let flag = Arc::new(AtomicBool::new(false));
    TRANSFER_CANCELS
        .lock()
        .await
        .insert(transfer_id, flag.clone());
    flag
}

async fn unregister_transfer(transfer_id: u32) {
    TRANSFER_CANCELS.lock().await.remove(&transfer_id);
}

async fn shell_tx(session_id: u32) -> Result<mpsc::Sender<ShellCmd>> {
    SESSIONS
        .lock()
        .await
        .get(&session_id)
        .and_then(|e| e.shell_tx.clone())
        .ok_or_else(|| anyhow!("终端未启动或会话不存在: {session_id}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh::client::Handler as _;
    use russh::keys::ssh_key::private::{Ed25519Keypair, KeypairData};
    use russh::keys::ssh_key::{Algorithm, Cipher, Kdf, LineEnding};
    use russh::keys::{encode_pkcs8_pem, encode_pkcs8_pem_encrypted};
    use russh::server;

    #[tokio::test(start_paused = true)]
    async fn transfer_stalled_upload_fails_after_bounded_response_waits_and_cleanup() {
        // 对端保留连接但不读数据，模拟上传断网后写入/确认永久阻塞。
        let (mut remote, _peer) = tokio::io::duplex(1);
        let cancel = AtomicBool::new(false);
        let started = tokio::time::Instant::now();
        let error = transfer_io(&cancel, remote.write_all(&[1, 2]))
            .await
            .unwrap_err();
        assert!(error.downcast_ref::<TransferTimeout>().is_some());
        assert_eq!(started.elapsed(), Duration::from_secs(30));
        assert!(error.to_string().contains("重试上限"));
        transfer_cleanup(std::future::pending::<()>()).await;
        assert_eq!(started.elapsed(), Duration::from_secs(32));
    }

    #[tokio::test(start_paused = true)]
    async fn transfer_stalled_download_fails_after_bounded_response_waits() {
        let (mut remote, _peer) = tokio::io::duplex(1);
        let mut buf = [0];
        let started = tokio::time::Instant::now();
        let error = transfer_io(&AtomicBool::new(false), remote.read(&mut buf))
            .await
            .unwrap_err();
        assert!(error.downcast_ref::<TransferTimeout>().is_some());
        assert_eq!(started.elapsed(), Duration::from_secs(30));
    }

    #[tokio::test(start_paused = true)]
    async fn transfer_response_retry_keeps_the_same_request_without_duplicate_writes() {
        let (mut remote, mut peer) = tokio::io::duplex(1);
        let reader = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(15)).await;
            let mut bytes = [0; 2];
            peer.read_exact(&mut bytes).await.unwrap();
            bytes
        });
        transfer_io(&AtomicBool::new(false), remote.write_all(&[1, 2]))
            .await
            .unwrap();
        assert_eq!(reader.await.unwrap(), [1, 2]);
    }

    #[tokio::test(start_paused = true)]
    async fn transfer_cancellation_interrupts_pending_io_without_waiting_for_timeout() {
        let cancel = AtomicBool::new(false);
        let stop = async {
            tokio::time::sleep(Duration::from_millis(250)).await;
            cancel.store(true, Ordering::Relaxed);
        };
        let started = tokio::time::Instant::now();
        let (result, ()) = tokio::join!(
            transfer_io(&cancel, std::future::pending::<Result<()>>()),
            stop,
        );
        assert_eq!(result.unwrap_err().to_string(), "传输已取消");
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test(start_paused = true)]
    async fn transfer_does_not_retry_permanent_errors_or_cancelled_requests() {
        let cancel = AtomicBool::new(false);
        let started = tokio::time::Instant::now();
        let error = transfer_io(&cancel, async { Err::<(), _>(anyhow!("权限不足")) })
            .await
            .unwrap_err();
        assert_eq!(error.to_string(), "权限不足");
        assert_eq!(started.elapsed(), Duration::ZERO);
        cancel.store(true, Ordering::Relaxed);
        let invoked = AtomicBool::new(false);
        let error = transfer_io(&cancel, async {
            invoked.store(true, Ordering::Relaxed);
            Ok::<_, anyhow::Error>(())
        })
        .await
        .unwrap_err();
        assert_eq!(error.to_string(), "传输已取消");
        assert!(!invoked.load(Ordering::Relaxed));
    }

    #[tokio::test(start_paused = true)]
    async fn transfer_deadline_is_per_operation_not_the_whole_file() {
        let cancel = AtomicBool::new(false);
        let started = tokio::time::Instant::now();
        for _ in 0..4 {
            transfer_io(&cancel, async {
                tokio::time::sleep(Duration::from_secs(9)).await;
                Ok::<_, anyhow::Error>(())
            })
            .await
            .unwrap();
        }
        assert_eq!(started.elapsed(), Duration::from_secs(36));
    }

    fn test_key(seed: u8) -> PrivateKey {
        PrivateKey::new(
            KeypairData::Ed25519(Ed25519Keypair::from_seed(&[seed; 32])),
            "test-only",
        )
        .unwrap()
    }

    fn openssh(key: &PrivateKey) -> String {
        key.to_openssh(LineEnding::LF).unwrap().to_string()
    }

    fn encrypted_openssh(key: &PrivateKey) -> String {
        openssh(
            &key.encrypt_with(
                Cipher::Aes256Ctr,
                Kdf::Bcrypt {
                    salt: vec![19; 16],
                    rounds: 4,
                },
                12345,
                "test-passphrase",
            )
            .unwrap(),
        )
    }

    // Public test fixtures from ssh-key's tests/examples; never use these keys on a server.
    const PPK: &str = "PuTTY-User-Key-File-3: ssh-ed25519\n\
Encryption: none\n\
Comment: user@example.com\n\
Public-Lines: 2\n\
AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XF\n\
Sqti\n\
Private-Lines: 1\n\
AAAAILYGwiLRDBba4WxwpNRRc0cuxhfgXGVpINJuVsCPtZHt\n\
Private-MAC: 94140d0344fad6aa1bf7b71e9c93db11ccac8a232f8a51e11c024869d608c82d\n";

    const ENCRYPTED_PPK: &str = "PuTTY-User-Key-File-3: ssh-ed25519\n\
Encryption: aes256-cbc\n\
Comment: user@example.com\n\
Public-Lines: 2\n\
AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XF\n\
Sqti\n\
Key-Derivation: Argon2id\n\
Argon2-Memory: 8192\n\
Argon2-Passes: 34\n\
Argon2-Parallelism: 1\n\
Argon2-Salt: 63d1d43f7bf7700720496646a2f5ec17\n\
Private-Lines: 1\n\
DyWtExZ3dxFutnb12tIwXBC6kWdozrvP+r6faHKBGDb4+qEar9XBiC0BmGySMHUi\n\
Private-MAC: 52fd00d4ef47ebc506e4e709486c0c6bc0606e24fe2c6cb1b3d168f4da238a66\n";

    #[tokio::test]
    async fn private_key_import_accepts_openssh_and_pkcs8_with_or_without_encryption() {
        let key = test_key(7);
        let mut pem = Vec::new();
        encode_pkcs8_pem(&key, &mut pem).unwrap();
        let mut encrypted_pem = Vec::new();
        encode_pkcs8_pem_encrypted(&key, b"test-passphrase", 100, &mut encrypted_pem).unwrap();
        for (encoded, phrase) in [
            (openssh(&key), None),
            (encrypted_openssh(&key), Some("test-passphrase".into())),
            (String::from_utf8(pem).unwrap(), None),
            (
                String::from_utf8(encrypted_pem).unwrap(),
                Some("test-passphrase".into()),
            ),
        ] {
            let decoded = load_private_key(encoded, phrase).await.unwrap();
            assert_eq!(decoded.public_key().key_data(), key.public_key().key_data());
        }
    }

    #[tokio::test]
    async fn private_key_import_accepts_plain_and_encrypted_ppk() {
        let plain = load_private_key(PPK.into(), None).await.unwrap();
        let encrypted = load_private_key(ENCRYPTED_PPK.into(), Some("123".into()))
            .await
            .unwrap();
        assert_eq!(
            plain.public_key().key_data(),
            encrypted.public_key().key_data()
        );
    }

    #[tokio::test]
    async fn private_key_import_rejects_invalid_or_locked_keys_without_echoing_secrets() {
        let encoded = encrypted_openssh(&test_key(7));
        for phrase in [
            None,
            Some("".into()),
            Some("wrong-private-passphrase".into()),
        ] {
            let error = ssh_validate_private_key(encoded.clone(), phrase)
                .await
                .unwrap_err();
            assert_eq!(
                error.to_string(),
                "私钥格式无效或口令错误，请检查 OpenSSH、PEM 或 PPK 私钥与口令"
            );
        }
        let error = ssh_validate_private_key("invalid-sensitive-key".into(), None)
            .await
            .unwrap_err();
        assert!(!error.to_string().contains("invalid-sensitive-key"));
        let error = ssh_validate_private_key("x".repeat(1024 * 1024 + 1), None)
            .await
            .unwrap_err();
        assert_eq!(error.to_string(), "私钥文件不能超过 1 MiB");
    }

    struct ForwardTestServer {
        requests: mpsc::UnboundedSender<(String, u32)>,
        allow: bool,
    }

    impl server::Handler for ForwardTestServer {
        type Error = russh::Error;
        async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
            Ok(server::Auth::Accept)
        }
        async fn channel_open_direct_tcpip(
            &mut self,
            channel: russh::Channel<server::Msg>,
            host: &str,
            port: u32,
            _: &str,
            _: u32,
            reply: server::ChannelOpenHandle,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            let _ = self.requests.send((host.into(), port));
            if self.allow {
                let mut target = tokio::net::TcpStream::connect(("127.0.0.1", port as u16)).await?;
                reply.accept().await;
                tokio::spawn(async move {
                    let _ = tokio::io::copy_bidirectional(&mut channel.into_stream(), &mut target)
                        .await;
                });
            }
            Ok(())
        }
    }

    async fn forwarding_service(
        allow: bool,
    ) -> (
        u16,
        mpsc::UnboundedReceiver<(String, u32)>,
        tokio::sync::oneshot::Sender<()>,
    ) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (requests, rx) = mpsc::unbounded_channel();
        let (shutdown, stopped) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let config = Arc::new(server::Config {
                keys: vec![test_key(41)],
                ..Default::default()
            });
            let session = server::run_stream(config, socket, ForwardTestServer { requests, allow })
                .await
                .unwrap();
            let handle = session.handle();
            tokio::select! {
                _ = session => {},
                _ = stopped => { let _ = handle.disconnect(Disconnect::ByApplication, String::new(), "en".into()).await; }
            }
        });
        (port, rx, shutdown)
    }

    async fn free_forward_port() -> u16 {
        let listener = TcpListener::bind(("0.0.0.0", 0)).await.unwrap();
        listener.local_addr().unwrap().port()
    }

    #[tokio::test]
    async fn multiple_local_ports_forward_through_gateway_and_stop_releases_everything() {
        let echo = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let target_port = echo.local_addr().unwrap().port();
        let echo_task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = echo.accept().await.unwrap();
                tokio::spawn(async move {
                    let (mut read, mut write) = socket.split();
                    let _ = tokio::io::copy(&mut read, &mut write).await;
                });
            }
        });
        let (service_port, mut requests, _shutdown) = forwarding_service(true).await;
        let (gateway_port, mut hops, gateway_task) = gateway_server(service_port, true).await;
        let gateway_id = authenticated_gateway(gateway_port).await;
        let target = ssh_handshake_via_gateway("internal-service.test".into(), 2222, gateway_id)
            .await
            .unwrap();
        let session_id = ssh_authenticate(
            target.session_id,
            target.fingerprint,
            "service-user".into(),
            "test-only".into(),
        )
        .await
        .unwrap();
        assert_eq!(
            hops.recv().await.unwrap(),
            ("internal-service.test".into(), 2222)
        );
        // 先占住两个临时端口，确保生成的端口号互异。
        let first = TcpListener::bind(("0.0.0.0", 0)).await.unwrap();
        let second = TcpListener::bind(("0.0.0.0", 0)).await.unwrap();
        let ports = [
            first.local_addr().unwrap().port(),
            second.local_addr().unwrap().port(),
        ];
        drop((first, second));
        let (events, mut received) = mpsc::unbounded_channel();
        start_port_forwards(
            session_id,
            ports
                .iter()
                .map(|port| ForwardPortSpec {
                    local_port: *port,
                    target_host: "database.internal.test".into(),
                    target_port,
                })
                .collect(),
            move |event| events.send(event).is_ok(),
        )
        .await
        .unwrap();
        assert_eq!(received.recv().await.unwrap().kind, "ready");
        // UDP connect 仅查询本机路由，不发送数据。可联网环境验证非回环网卡，
        // 离线环境仍验证回环访问；两者都使用同一组通配监听端口。
        let probe = std::net::UdpSocket::bind(("0.0.0.0", 0)).unwrap();
        let interface_ip = probe
            .connect(("192.0.2.1", 9))
            .and_then(|()| probe.local_addr())
            .map(|address| address.ip())
            .unwrap_or(std::net::Ipv4Addr::LOCALHOST.into());
        if !interface_ip.is_loopback() {
            eprintln!("forwarding test covers a non-loopback IPv4 interface");
        }
        let mut sockets = Vec::new();
        for (index, port) in ports.iter().enumerate() {
            let client_ip = if index == 0 {
                std::net::Ipv4Addr::LOCALHOST.into()
            } else {
                interface_ip
            };
            let mut socket = tokio::net::TcpStream::connect((client_ip, *port))
                .await
                .unwrap();
            let data = format!("database request {index}");
            socket.write_all(data.as_bytes()).await.unwrap();
            let mut reply = vec![0; data.len()];
            tokio::time::timeout(Duration::from_secs(3), socket.read_exact(&mut reply))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(reply, data.as_bytes());
            assert_eq!(
                requests.recv().await.unwrap(),
                ("database.internal.test".into(), u32::from(target_port))
            );
            sockets.push(socket);
        }
        ssh_disconnect(session_id).await.unwrap();
        assert!(!SESSIONS.lock().await.contains_key(&gateway_id));
        assert!(!SESSIONS.lock().await.contains_key(&session_id));
        for port in ports {
            assert!(TcpListener::bind(("0.0.0.0", port)).await.is_ok());
        }
        for mut socket in sockets {
            let mut byte = [0];
            let ended = tokio::time::timeout(Duration::from_secs(2), socket.read(&mut byte))
                .await
                .unwrap();
            assert!(ended.is_err() || ended.unwrap() == 0);
        }
        gateway_task.abort();
        echo_task.abort();
    }

    #[tokio::test]
    async fn port_bind_failure_rolls_back_and_unverified_sessions_cannot_listen() {
        let (port, _, _shutdown) = forwarding_service(true).await;
        let pending = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let local_port = free_forward_port().await;
        let mapping = ForwardPortSpec {
            local_port,
            target_host: "127.0.0.1".into(),
            target_port: 3306,
        };
        assert!(
            start_port_forwards(pending.session_id, vec![mapping.clone()], |_| true)
                .await
                .is_err()
        );
        let session_id = ssh_authenticate(
            pending.session_id,
            pending.fingerprint,
            "user".into(),
            "test-only".into(),
        )
        .await
        .unwrap();
        let occupied = TcpListener::bind(("0.0.0.0", 0)).await.unwrap();
        let blocked = occupied.local_addr().unwrap().port();
        let result = start_port_forwards(
            session_id,
            vec![
                mapping.clone(),
                ForwardPortSpec {
                    local_port: blocked,
                    ..mapping.clone()
                },
            ],
            |_| true,
        )
        .await;
        assert!(result
            .unwrap_err()
            .to_string()
            .contains(&blocked.to_string()));
        assert!(TcpListener::bind(("0.0.0.0", local_port)).await.is_ok());
        assert!(SESSIONS
            .lock()
            .await
            .get(&session_id)
            .unwrap()
            .forwards
            .is_none());
        assert!(
            start_port_forwards(session_id, vec![mapping.clone(), mapping], |_| true)
                .await
                .is_err()
        );
        ssh_disconnect(session_id).await.unwrap();
    }

    #[tokio::test]
    async fn denied_target_emits_error_and_remote_disconnect_releases_listener() {
        let (port, mut requests, shutdown) = forwarding_service(false).await;
        let key = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let id = ssh_authenticate(
            key.session_id,
            key.fingerprint,
            "user".into(),
            "test-only".into(),
        )
        .await
        .unwrap();
        let local_port = free_forward_port().await;
        let (events, mut received) = mpsc::unbounded_channel();
        start_port_forwards(
            id,
            vec![ForwardPortSpec {
                local_port,
                target_host: "db.internal".into(),
                target_port: 3306,
            }],
            move |event| events.send(event).is_ok(),
        )
        .await
        .unwrap();
        assert_eq!(received.recv().await.unwrap().kind, "ready");
        let _client = tokio::net::TcpStream::connect(("127.0.0.1", local_port))
            .await
            .unwrap();
        assert_eq!(requests.recv().await.unwrap(), ("db.internal".into(), 3306));
        let event = tokio::time::timeout(Duration::from_secs(3), received.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(event.kind, "connectionError");
        assert_eq!(event.local_port, Some(local_port));
        shutdown.send(()).unwrap();
        let closed = tokio::time::timeout(Duration::from_secs(3), received.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(closed.kind, "closed");
        assert!(TcpListener::bind(("127.0.0.1", local_port)).await.is_ok());
        ssh_disconnect(id).await.unwrap();
    }

    struct TestServer {
        authentications: Arc<AtomicU32>,
        stall_auth: bool,
        authorized_key: PublicKey,
        channels: HashMap<russh::ChannelId, russh::Channel<server::Msg>>,
    }

    struct GatewayServer {
        requests: mpsc::UnboundedSender<(String, u32)>,
        target_port: u16,
        allow_forward: bool,
    }

    impl server::Handler for GatewayServer {
        type Error = russh::Error;

        async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
            Ok(server::Auth::Accept)
        }

        async fn channel_open_direct_tcpip(
            &mut self,
            channel: russh::Channel<server::Msg>,
            host: &str,
            port: u32,
            _: &str,
            _: u32,
            reply: server::ChannelOpenHandle,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            self.requests.send((host.into(), port)).unwrap();
            assert_eq!(host, "internal-service.test");
            assert_eq!(port, 2222);
            if self.allow_forward {
                let mut socket =
                    tokio::net::TcpStream::connect(("127.0.0.1", self.target_port)).await?;
                reply.accept().await;
                tokio::spawn(async move {
                    let _ = tokio::io::copy_bidirectional(&mut channel.into_stream(), &mut socket)
                        .await;
                });
            }
            Ok(())
        }
    }

    async fn gateway_server(
        target_port: u16,
        allow_forward: bool,
    ) -> (
        u16,
        mpsc::UnboundedReceiver<(String, u32)>,
        tokio::task::JoinHandle<()>,
    ) {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let (requests, rx) = mpsc::unbounded_channel();
        let config = Arc::new(server::Config {
            keys: vec![test_key(43)],
            ..Default::default()
        });
        let task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            if let Ok(session) = server::run_stream(
                config,
                socket,
                GatewayServer {
                    requests,
                    target_port,
                    allow_forward,
                },
            )
            .await
            {
                let _ = session.await;
            }
        });
        (port, rx, task)
    }

    async fn authenticated_gateway(port: u16) -> u32 {
        let key = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        assert_eq!(
            key.fingerprint,
            test_key(43)
                .public_key()
                .fingerprint(HashAlg::Sha256)
                .to_string()
        );
        ssh_authenticate(
            key.session_id,
            key.fingerprint,
            "gateway-user".into(),
            "test-only".into(),
        )
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn gateway_tunnel_verifies_target_and_closes_both_connections() {
        for outcome in ["success", "changed-key", "cancelled"] {
            let (target_port, fingerprint, auths, target_task) = local_server().await;
            let (port, mut requests, gateway_task) = gateway_server(target_port, true).await;
            let gateway_id = authenticated_gateway(port).await;
            let target =
                ssh_handshake_via_gateway("internal-service.test".into(), 2222, gateway_id)
                    .await
                    .unwrap();
            assert_eq!(
                requests.recv().await.unwrap(),
                ("internal-service.test".into(), 2222)
            );
            assert_eq!(target.fingerprint, fingerprint);
            assert_eq!(auths.load(Ordering::SeqCst), 0);
            if outcome == "cancelled" {
                ssh_disconnect(target.session_id).await.unwrap();
            } else {
                let result = ssh_authenticate_private_key(
                    target.session_id,
                    if outcome == "changed-key" {
                        "SHA256:wrong".into()
                    } else {
                        fingerprint
                    },
                    "test".into(),
                    openssh(&test_key(7)),
                    None,
                )
                .await;
                if outcome == "success" {
                    assert_eq!(result.unwrap(), target.session_id);
                    assert!(auths.load(Ordering::SeqCst) > 0);
                    assert_eq!(
                        sftp_canonicalize(target.session_id, ".".into())
                            .await
                            .unwrap(),
                        "/gateway-test"
                    );
                    ssh_disconnect(target.session_id).await.unwrap();
                } else {
                    assert!(result.is_err());
                    assert_eq!(auths.load(Ordering::SeqCst), 0);
                }
            }
            assert!(!PENDING_SESSIONS
                .lock()
                .await
                .contains_key(&target.session_id));
            assert!(!SESSIONS.lock().await.contains_key(&target.session_id));
            assert!(!SESSIONS.lock().await.contains_key(&gateway_id));
            tokio::time::timeout(Duration::from_secs(2), gateway_task)
                .await
                .unwrap()
                .unwrap();
            tokio::time::timeout(Duration::from_secs(2), target_task)
                .await
                .unwrap()
                .unwrap();
        }
    }

    #[tokio::test]
    #[ignore = "requires PAGAGATEWAY_BIN; uses real Go relay on loopback"]
    async fn page_go_relay_preserves_target_identity_authentication_and_sftp() {
        for (use_tls, outcome) in [
            (true, "success"),
            (true, "changed-key"),
            (true, "cancelled"),
            (false, "success"),
            (false, "changed-key"),
            (false, "cancelled"),
        ] {
            let (port, fingerprint, auths, task) = local_server().await;
            let relay = crate::page::GoRelay::start(&[port], use_tls).await;
            let mut wrong_pin = relay.gateway.clone();
            wrong_pin.server_fingerprint = "00".repeat(32);
            assert!(ssh_handshake_via_page("127.0.0.1".into(), port, wrong_pin)
                .await
                .is_err());
            let mut wrong_token = relay.gateway.clone();
            wrong_token.token = "x".repeat(32);
            let denied = ssh_handshake_via_page("127.0.0.1".into(), port, wrong_token)
                .await
                .err()
                .unwrap();
            assert!(denied.to_string().contains("访问令牌或 Client ID 无效"));
            let key = ssh_handshake_via_page("127.0.0.1".into(), port, relay.gateway.clone())
                .await
                .unwrap();
            assert_eq!(key.fingerprint, fingerprint);
            assert_eq!(auths.load(Ordering::SeqCst), 0);
            if outcome == "cancelled" {
                ssh_disconnect(key.session_id).await.unwrap();
            } else {
                let result = ssh_authenticate_private_key(
                    key.session_id,
                    if outcome == "changed-key" {
                        "wrong".into()
                    } else {
                        fingerprint
                    },
                    "test".into(),
                    openssh(&test_key(7)),
                    None,
                )
                .await;
                if outcome == "success" {
                    let id = result.unwrap();
                    assert_eq!(
                        sftp_canonicalize(id, ".".into()).await.unwrap(),
                        "/gateway-test"
                    );
                    ssh_disconnect(id).await.unwrap();
                } else {
                    assert!(result.is_err());
                    assert_eq!(auths.load(Ordering::SeqCst), 0);
                }
            }
            assert!(!PENDING_SESSIONS.lock().await.contains_key(&key.session_id));
            assert!(!SESSIONS.lock().await.contains_key(&key.session_id));
            tokio::time::timeout(Duration::from_secs(3), task)
                .await
                .unwrap()
                .unwrap();
        }
    }

    #[tokio::test]
    async fn denied_gateway_forwarding_closes_gateway_without_direct_fallback() {
        let (port, mut requests, task) = gateway_server(1, false).await;
        let gateway_id = authenticated_gateway(port).await;
        let result =
            ssh_handshake_via_gateway("internal-service.test".into(), 2222, gateway_id).await;
        assert!(result.is_err());
        assert_eq!(
            requests.recv().await.unwrap(),
            ("internal-service.test".into(), 2222)
        );
        assert!(!SESSIONS.lock().await.contains_key(&gateway_id));
        tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn gateway_target_authentication_can_be_cancelled_without_leaking_gateway() {
        let (target_port, fingerprint, auths, target_task) =
            local_server_with_stalled_auth(true).await;
        let (port, _requests, gateway_task) = gateway_server(target_port, true).await;
        let gateway_id = authenticated_gateway(port).await;
        let target = ssh_handshake_via_gateway("internal-service.test".into(), 2222, gateway_id)
            .await
            .unwrap();
        let id = target.session_id;
        let authentication = tokio::spawn(ssh_authenticate_private_key(
            id,
            fingerprint,
            "test".into(),
            openssh(&test_key(7)),
            None,
        ));
        tokio::time::timeout(Duration::from_secs(2), async {
            while auths.load(Ordering::SeqCst) == 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        tokio::time::timeout(Duration::from_secs(1), ssh_disconnect(id))
            .await
            .unwrap()
            .unwrap();
        assert!(tokio::time::timeout(Duration::from_secs(1), authentication)
            .await
            .unwrap()
            .unwrap()
            .is_err());
        assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
        assert!(!SESSIONS.lock().await.contains_key(&id));
        assert!(!SESSIONS.lock().await.contains_key(&gateway_id));
        tokio::time::timeout(Duration::from_secs(2), gateway_task)
            .await
            .unwrap()
            .unwrap();
        target_task.abort();
    }

    impl server::Handler for TestServer {
        type Error = russh::Error;

        async fn channel_open_session(
            &mut self,
            channel: russh::Channel<server::Msg>,
            reply: server::ChannelOpenHandle,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            self.channels.insert(channel.id(), channel);
            reply.accept().await;
            Ok(())
        }

        async fn subsystem_request(
            &mut self,
            id: russh::ChannelId,
            name: &str,
            session: &mut server::Session,
        ) -> Result<(), Self::Error> {
            assert_eq!(name, "sftp");
            let channel = self.channels.remove(&id).unwrap();
            session.channel_success(id)?;
            tokio::spawn(russh_sftp::server::run(channel.into_stream(), TestSftp));
            Ok(())
        }

        async fn channel_eof(
            &mut self,
            id: russh::ChannelId,
            session: &mut server::Session,
        ) -> Result<(), Self::Error> {
            session.close(id)?;
            Ok(())
        }

        async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
            self.authentications.fetch_add(1, Ordering::SeqCst);
            if self.stall_auth {
                tokio::time::sleep(Duration::from_secs(60)).await;
            }
            Ok(server::Auth::Accept)
        }

        async fn auth_publickey_offered(
            &mut self,
            _: &str,
            _: &PublicKey,
        ) -> Result<server::Auth, Self::Error> {
            self.authentications.fetch_add(1, Ordering::SeqCst);
            Ok(server::Auth::Accept)
        }

        async fn auth_publickey(
            &mut self,
            user: &str,
            key: &PublicKey,
        ) -> Result<server::Auth, Self::Error> {
            self.authentications.fetch_add(1, Ordering::SeqCst);
            if self.stall_auth {
                tokio::time::sleep(Duration::from_secs(60)).await;
            }
            Ok(
                if user == "test" && key.key_data() == self.authorized_key.key_data() {
                    server::Auth::Accept
                } else {
                    server::Auth::Reject {
                        proceed_with_methods: None,
                        partial_success: false,
                    }
                },
            )
        }
    }

    struct TestSftp;
    impl russh_sftp::server::Handler for TestSftp {
        type Error = russh_sftp::protocol::StatusCode;
        fn unimplemented(&self) -> Self::Error {
            russh_sftp::protocol::StatusCode::OpUnsupported
        }
        async fn realpath(
            &mut self,
            id: u32,
            path: String,
        ) -> Result<russh_sftp::protocol::Name, Self::Error> {
            assert_eq!(path, ".");
            Ok(russh_sftp::protocol::Name {
                id,
                files: vec![russh_sftp::protocol::File::dummy("/gateway-test")],
            })
        }
    }

    async fn local_server() -> (u16, String, Arc<AtomicU32>, tokio::task::JoinHandle<()>) {
        local_server_with_stalled_auth(false).await
    }

    async fn local_server_with_stalled_auth(
        stall_auth: bool,
    ) -> (u16, String, Arc<AtomicU32>, tokio::task::JoinHandle<()>) {
        local_server_with_options(stall_auth, test_key(7).public_key().clone(), true).await
    }

    async fn local_server_with_options(
        stall_auth: bool,
        authorized_key: PublicKey,
        rsa_sha2: bool,
    ) -> (u16, String, Arc<AtomicU32>, tokio::task::JoinHandle<()>) {
        let key = test_key(42);
        let fingerprint = key.public_key().fingerprint(HashAlg::Sha256).to_string();
        let mut config = server::Config {
            keys: vec![key],
            auth_rejection_time: Duration::ZERO,
            auth_rejection_time_initial: Some(Duration::ZERO),
            ..Default::default()
        };
        if !rsa_sha2 {
            config.preferred.key =
                std::borrow::Cow::Owned(vec![Algorithm::Ed25519, Algorithm::Rsa { hash: None }]);
        }
        let config = Arc::new(config);
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let authentications = Arc::new(AtomicU32::new(0));
        let handler = TestServer {
            authentications: authentications.clone(),
            stall_auth,
            authorized_key,
            channels: HashMap::new(),
        };
        let task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            if let Ok(session) = server::run_stream(config, socket, handler).await {
                let _ = session.await;
            }
        });
        (port, fingerprint, authentications, task)
    }

    #[derive(Debug, PartialEq)]
    enum TerminalEvent {
        Opening,
        Pty(u32, u32),
        Shell,
        Resize(u32, u32),
    }

    struct TerminalServer {
        events: mpsc::UnboundedSender<TerminalEvent>,
        allow_open: Arc<Notify>,
    }

    impl server::Handler for TerminalServer {
        type Error = russh::Error;

        async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
            Ok(server::Auth::Accept)
        }

        async fn channel_open_session(
            &mut self,
            _: russh::Channel<server::Msg>,
            reply: server::ChannelOpenHandle,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            self.events.send(TerminalEvent::Opening).unwrap();
            self.allow_open.notified().await;
            reply.accept().await;
            Ok(())
        }

        async fn pty_request(
            &mut self,
            _: russh::ChannelId,
            _: &str,
            cols: u32,
            rows: u32,
            _: u32,
            _: u32,
            _: &[(russh::Pty, u32)],
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            self.events.send(TerminalEvent::Pty(cols, rows)).unwrap();
            Ok(())
        }

        async fn shell_request(
            &mut self,
            _: russh::ChannelId,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            self.events.send(TerminalEvent::Shell).unwrap();
            Ok(())
        }

        async fn window_change_request(
            &mut self,
            _: russh::ChannelId,
            cols: u32,
            rows: u32,
            _: u32,
            _: u32,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            self.events.send(TerminalEvent::Resize(cols, rows)).unwrap();
            Ok(())
        }
    }

    async fn next_terminal_event(
        events: &mut mpsc::UnboundedReceiver<TerminalEvent>,
    ) -> TerminalEvent {
        tokio::time::timeout(Duration::from_secs(2), events.recv())
            .await
            .expect("SSH server did not receive terminal dimensions")
            .unwrap()
    }

    struct StatusServer {
        output: Vec<u8>,
        exit_code: u32,
    }

    impl server::Handler for StatusServer {
        type Error = russh::Error;

        async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
            Ok(server::Auth::Accept)
        }

        async fn channel_open_session(
            &mut self,
            _: russh::Channel<server::Msg>,
            reply: server::ChannelOpenHandle,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            reply.accept().await;
            Ok(())
        }

        async fn exec_request(
            &mut self,
            channel: russh::ChannelId,
            command: &[u8],
            session: &mut server::Session,
        ) -> Result<(), Self::Error> {
            let script = include_str!("server_status.sh").replace('\'', "'\\''");
            assert_eq!(command, format!("sh -c '{script}'").as_bytes());
            session.channel_success(channel)?;
            session.data(channel, self.output.clone())?;
            session.exit_status_request(channel, self.exit_code)?;
            session.eof(channel)?;
            session.close(channel)?;
            Ok(())
        }

        async fn pty_request(
            &mut self,
            _: russh::ChannelId,
            _: &str,
            _: u32,
            _: u32,
            _: u32,
            _: u32,
            _: &[(russh::Pty, u32)],
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            panic!("status collection must not request an interactive PTY");
        }
    }

    #[tokio::test]
    async fn status_collection_uses_a_separate_exec_channel_and_checks_exit_and_output_limit() {
        for (output, exit_code, expected_error) in [
            (b"PAGASHELL_STATUS_OS\nLinux\n".to_vec(), 0, None),
            (
                b"sensitive stderr must not be surfaced".to_vec(),
                1,
                Some("无法获取服务状态，请检查远端系统及读取权限"),
            ),
            (vec![b'x'; 512 * 1024 + 1], 0, Some("服务状态数据过大")),
        ] {
            let config = Arc::new(server::Config {
                keys: vec![test_key(42)],
                ..Default::default()
            });
            let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
                .await
                .unwrap();
            let port = listener.local_addr().unwrap().port();
            let expected = output.clone();
            let task = tokio::spawn(async move {
                let (socket, _) = listener.accept().await.unwrap();
                let session =
                    server::run_stream(config, socket, StatusServer { output, exit_code })
                        .await
                        .unwrap();
                let _ = session.await;
            });
            let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
            let id = ssh_authenticate(
                handshake.session_id,
                handshake.fingerprint,
                "test".into(),
                "test-only".into(),
            )
            .await
            .unwrap();
            // 注册的交互 shell 队列不会被状态采集使用或关闭。
            let (tx, mut rx) = mpsc::channel(4);
            SESSIONS.lock().await.get_mut(&id).unwrap().shell_tx = Some(tx);
            let result = ssh_read_server_status(id).await;
            if let Some(message) = expected_error {
                assert_eq!(result.unwrap_err().to_string(), message);
            } else {
                assert_eq!(result.unwrap().as_bytes(), expected);
                // 再次采样创建新通道，关闭上一条采集通道不影响认证连接。
                assert_eq!(
                    ssh_read_server_status(id).await.unwrap().as_bytes(),
                    expected
                );
            }
            assert!(rx.try_recv().is_err());
            ssh_write(id, b"vim\n".to_vec()).await.unwrap();
            assert!(matches!(rx.recv().await, Some(ShellCmd::Data(data)) if data == b"vim\n"));
            ssh_disconnect(id).await.unwrap();
            task.abort();
        }
    }

    #[tokio::test]
    async fn terminal_resize_before_and_during_shell_start_reaches_remote_pty() {
        let config = Arc::new(server::Config {
            keys: vec![test_key(42)],
            ..Default::default()
        });
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let (events_tx, mut events) = mpsc::unbounded_channel();
        let allow_open = Arc::new(Notify::new());
        let handler = TerminalServer {
            events: events_tx,
            allow_open: allow_open.clone(),
        };
        let server_task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let session = server::run_stream(config, socket, handler).await.unwrap();
            let _ = session.await;
        });
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let id = ssh_authenticate(
            handshake.session_id,
            handshake.fingerprint,
            "test".into(),
            "test-only".into(),
        )
        .await
        .unwrap();

        // Flutter 布局与 FRB 的异步调度可能先于 shell 启动调用。
        ssh_resize(id, 100, 30).await.unwrap();
        ssh_resize(id, 120, 40).await.unwrap();
        let starting = tokio::spawn(start_shell(id, 80, 24, |_| true));
        assert_eq!(
            next_terminal_event(&mut events).await,
            TerminalEvent::Opening
        );
        // 模拟慢速 SSH 通道建立期间的多次窗口变化。
        ssh_resize(id, 140, 45).await.unwrap();
        ssh_resize(id, 160, 50).await.unwrap();
        allow_open.notify_one();
        tokio::time::timeout(Duration::from_secs(2), starting)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(
            next_terminal_event(&mut events).await,
            TerminalEvent::Pty(120, 40)
        );
        assert_eq!(next_terminal_event(&mut events).await, TerminalEvent::Shell);
        assert_eq!(
            next_terminal_event(&mut events).await,
            TerminalEvent::Resize(160, 50)
        );

        ssh_resize(id, 180, 60).await.unwrap();
        assert_eq!(
            next_terminal_event(&mut events).await,
            TerminalEvent::Resize(180, 60)
        );
        ssh_disconnect(id).await.unwrap();
        assert!(ssh_resize(id, 200, 70).await.is_err());
        server_task.abort();
    }

    #[tokio::test]
    async fn encrypted_private_key_authenticates_with_a_signature_on_the_verified_connection() {
        let (port, fingerprint, authentications, task) = local_server().await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        assert_eq!(authentications.load(Ordering::SeqCst), 0);
        let id = ssh_authenticate_private_key(
            handshake.session_id,
            fingerprint,
            "test".into(),
            encrypted_openssh(&test_key(7)),
            Some("test-passphrase".into()),
        )
        .await
        .unwrap();
        assert_eq!(id, handshake.session_id);
        assert_eq!(authentications.load(Ordering::SeqCst), 2);
        assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
        assert!(SESSIONS.lock().await.contains_key(&id));
        ssh_disconnect(id).await.unwrap();
        task.abort();
    }

    #[tokio::test]
    async fn rejected_private_key_removes_the_connection_and_returns_a_safe_error() {
        let (port, fingerprint, authentications, task) = local_server().await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let id = handshake.session_id;
        let error = ssh_authenticate_private_key(
            id,
            fingerprint,
            "test".into(),
            openssh(&test_key(8)),
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(
            error.to_string(),
            "私钥认证失败，请检查用户名及服务器 authorized_keys 配置"
        );
        assert_eq!(authentications.load(Ordering::SeqCst), 2);
        assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
        assert!(!SESSIONS.lock().await.contains_key(&id));
        task.abort();
    }

    #[tokio::test]
    async fn wrong_fingerprint_rejects_private_key_auth_before_decoding_or_sending_any_key() {
        let (port, _, authentications, task) = local_server().await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let id = handshake.session_id;
        let error = ssh_authenticate_private_key(
            id,
            "SHA256:wrong".into(),
            "test".into(),
            "invalid-sensitive-key".into(),
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(error.to_string(), "主机指纹不匹配，已拒绝认证");
        assert_eq!(authentications.load(Ordering::SeqCst), 0);
        assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
        assert!(!SESSIONS.lock().await.contains_key(&id));
        task.abort();
    }

    #[tokio::test]
    async fn invalid_private_key_never_authenticates_and_removes_pending_connection() {
        let (port, fingerprint, authentications, task) = local_server().await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let id = handshake.session_id;
        assert!(ssh_authenticate_private_key(
            id,
            fingerprint,
            "test".into(),
            "invalid-sensitive-key".into(),
            None
        )
        .await
        .is_err());
        assert_eq!(authentications.load(Ordering::SeqCst), 0);
        assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
        assert!(!SESSIONS.lock().await.contains_key(&id));
        task.abort();
    }

    #[tokio::test]
    async fn rsa_authentication_uses_sha2_and_refuses_legacy_sha1_only_servers() {
        let key =
            decode_secret_key(include_str!("../../tests/fixtures/rsa_test_key"), None).unwrap();
        for rsa_sha2 in [true, false] {
            let (port, fingerprint, authentications, task) =
                local_server_with_options(false, key.public_key().clone(), rsa_sha2).await;
            let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
            let id = handshake.session_id;
            let result =
                ssh_authenticate_private_key(id, fingerprint, "test".into(), openssh(&key), None)
                    .await;
            if rsa_sha2 {
                assert_eq!(result.unwrap(), id);
                assert_eq!(authentications.load(Ordering::SeqCst), 2);
                ssh_disconnect(id).await.unwrap();
            } else {
                assert_eq!(
                    result.unwrap_err().to_string(),
                    "服务器不支持 RSA SHA-2 签名，请使用 Ed25519 或 ECDSA 私钥"
                );
                assert_eq!(authentications.load(Ordering::SeqCst), 0);
            }
            assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
            assert!(!SESSIONS.lock().await.contains_key(&id));
            task.abort();
        }
    }

    #[tokio::test]
    async fn disconnect_cancels_signed_private_key_authentication_promptly() {
        let (port, fingerprint, authentications, task) = local_server_with_stalled_auth(true).await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let id = handshake.session_id;
        let authentication = tokio::spawn(ssh_authenticate_private_key(
            id,
            fingerprint,
            "test".into(),
            openssh(&test_key(7)),
            None,
        ));
        tokio::time::timeout(Duration::from_secs(2), async {
            while authentications.load(Ordering::SeqCst) < 2 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        tokio::time::timeout(Duration::from_secs(1), ssh_disconnect(id))
            .await
            .unwrap()
            .unwrap();
        assert!(tokio::time::timeout(Duration::from_secs(1), authentication)
            .await
            .unwrap()
            .unwrap()
            .is_err());
        assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
        assert!(!SESSIONS.lock().await.contains_key(&id));
        task.abort();
    }

    #[tokio::test]
    async fn handshake_cannot_authenticate_or_open_channels_until_verified() {
        let (port, fingerprint, authentications, task) = local_server().await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        assert_eq!(handshake.fingerprint, fingerprint);
        assert_eq!(handshake.key_type, "ssh-ed25519");
        assert_eq!(authentications.load(Ordering::SeqCst), 0);
        assert!(open_sftp(handshake.session_id).await.is_err());

        let id = ssh_authenticate(
            handshake.session_id,
            fingerprint,
            "test".into(),
            "secret".into(),
        )
        .await
        .unwrap();
        assert_eq!(id, handshake.session_id);
        assert_eq!(authentications.load(Ordering::SeqCst), 1);
        assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
        assert!(SESSIONS.lock().await.contains_key(&id));
        ssh_disconnect(id).await.unwrap();
        task.abort();
    }

    #[tokio::test]
    async fn wrong_fingerprint_never_sends_password_and_removes_pending_connection() {
        let (port, _, authentications, task) = local_server().await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        assert!(ssh_authenticate(
            handshake.session_id,
            "SHA256:wrong".into(),
            "test".into(),
            "secret".into()
        )
        .await
        .is_err());
        assert_eq!(authentications.load(Ordering::SeqCst), 0);
        assert!(!PENDING_SESSIONS
            .lock()
            .await
            .contains_key(&handshake.session_id));
        assert!(!SESSIONS.lock().await.contains_key(&handshake.session_id));
        task.abort();
    }

    #[tokio::test]
    async fn cancelled_handshake_cannot_be_authenticated() {
        let (port, fingerprint, authentications, task) = local_server().await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        ssh_disconnect(handshake.session_id).await.unwrap();
        assert!(ssh_authenticate(
            handshake.session_id,
            fingerprint,
            "test".into(),
            "secret".into()
        )
        .await
        .is_err());
        assert_eq!(authentications.load(Ordering::SeqCst), 0);
        task.abort();
    }

    #[tokio::test]
    async fn disconnect_cancels_in_flight_authentication_promptly() {
        let (port, fingerprint, authentications, task) = local_server_with_stalled_auth(true).await;
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let id = handshake.session_id;
        let authentication = tokio::spawn(ssh_authenticate(
            id,
            fingerprint,
            "test".into(),
            "secret".into(),
        ));
        tokio::time::timeout(Duration::from_secs(2), async {
            while authentications.load(Ordering::SeqCst) == 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        tokio::time::timeout(Duration::from_secs(1), ssh_disconnect(id))
            .await
            .unwrap()
            .unwrap();
        assert!(tokio::time::timeout(Duration::from_secs(1), authentication)
            .await
            .unwrap()
            .unwrap()
            .is_err());
        assert!(!PENDING_SESSIONS.lock().await.contains_key(&id));
        assert!(!SESSIONS.lock().await.contains_key(&id));
        task.abort();
    }

    #[tokio::test]
    async fn rekey_cannot_replace_the_initial_server_key() {
        let initial = test_key(1);
        let replacement = test_key(2);
        let mut handler = PinningHandler {
            key: Arc::new(Mutex::new(None)),
        };
        assert!(handler
            .check_server_key(initial.public_key())
            .await
            .unwrap());
        assert!(handler
            .check_server_key(initial.public_key())
            .await
            .unwrap());
        assert!(!handler
            .check_server_key(replacement.public_key())
            .await
            .unwrap());
    }
}
