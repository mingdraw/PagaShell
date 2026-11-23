use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use anyhow::{anyhow, ensure, Result};
use russh::{Channel, ChannelMsg, Sig};
use tokio::sync::Mutex;
use tokio::time::{sleep, timeout, Instant};
use tokio_util::sync::CancellationToken;

use crate::api::ssh::docker_api_channel;

static NEXT: AtomicU32 = AtomicU32::new(1);
static READERS: LazyLock<Mutex<HashMap<u32, Arc<Reader>>>> = LazyLock::new(Mutex::default);
const MAX_BATCH: usize = 64 * 1024;
const BATCH_INTERVAL: Duration = Duration::from_millis(50);

struct Reader {
    session_id: u32,
    cancellation: CancellationToken,
    streaming: AtomicBool,
    state: Mutex<ReaderState>,
}

struct ReaderState {
    channel: Channel<russh::client::Msg>,
    exit_status: Option<u32>,
    ended: bool,
}

impl Reader {
    async fn stop(&self) {
        self.cancellation.cancel();
        let state = self.state.lock().await;
        let _ = timeout(Duration::from_secs(1), async {
            if !state.ended {
                let _ = state.channel.signal(Sig::TERM).await;
            }
            state.channel.close().await
        })
        .await;
    }
}

pub(super) async fn open(session_id: u32, container_id: &str) -> Result<u32> {
    let command = crate::docker_operations::log_command(session_id, container_id).await?;
    let channel = timeout(
        Duration::from_secs(8),
        docker_api_channel(session_id, command),
    )
    .await
    .map_err(|_| anyhow!("打开容器日志超时"))?
    .map_err(|_| anyhow!("无法打开容器日志，请检查连接"))?;
    let reader = Arc::new(Reader {
        session_id,
        cancellation: CancellationToken::new(),
        streaming: AtomicBool::new(false),
        state: Mutex::new(ReaderState {
            channel,
            exit_status: None,
            ended: false,
        }),
    });
    let mut readers = READERS.lock().await;
    if readers.len() >= 64 {
        drop(readers);
        reader.stop().await;
        return Err(anyhow!("打开的容器日志过多"));
    }
    let mut id = NEXT.fetch_add(1, Ordering::Relaxed);
    while readers.contains_key(&id) {
        id = NEXT.fetch_add(1, Ordering::Relaxed);
    }
    readers.insert(id, reader);
    Ok(id)
}

pub(in crate::api) async fn stream(log_id: u32, emit: impl Fn(Vec<u8>) -> bool) -> Result<()> {
    let Some(reader) = READERS.lock().await.get(&log_id).cloned() else {
        return Ok(());
    };
    ensure!(
        !reader.streaming.swap(true, Ordering::Relaxed),
        "容器日志已在读取"
    );
    let mut state = tokio::select! {
        biased;
        _ = reader.cancellation.cancelled() => return Ok(()),
        state = reader.state.lock() => state,
    };
    let mut batch = Vec::new();
    let tick = sleep(BATCH_INTERVAL);
    tokio::pin!(tick);
    let result = 'read: loop {
        tokio::select! {
            biased;
            _ = reader.cancellation.cancelled() => break Ok(()),
            _ = &mut tick, if !batch.is_empty() => {
                if !emit(std::mem::take(&mut batch)) { break Ok(()); }
            }
            message = state.channel.wait() => match message {
                Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                    let mut remaining = &data[..];
                    while !remaining.is_empty() {
                        if batch.is_empty() { tick.as_mut().reset(Instant::now() + BATCH_INTERVAL); }
                        let size = (MAX_BATCH - batch.len()).min(remaining.len());
                        batch.extend_from_slice(&remaining[..size]);
                        remaining = &remaining[size..];
                        if batch.len() == MAX_BATCH && !emit(std::mem::take(&mut batch)) {
                            break 'read Ok(());
                        }
                    }
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => state.exit_status = Some(exit_status),
                Some(ChannelMsg::Close) | None => {
                    state.ended = true;
                    break if state.exit_status == Some(0) { Ok(()) } else { Err(anyhow!("容器日志流已断开或读取失败")) };
                }
                Some(ChannelMsg::Failure) | Some(ChannelMsg::ExitSignal { .. }) => {
                    state.ended = true;
                    break Err(anyhow!("无法读取容器日志，请检查容器和权限"));
                }
                _ => {}
            }
        }
    };
    if !batch.is_empty() && !reader.cancellation.is_cancelled() {
        let _ = emit(batch);
    }
    drop(state);
    close(log_id).await;
    result
}

pub(super) async fn close(log_id: u32) {
    let reader = READERS.lock().await.remove(&log_id);
    if let Some(reader) = reader {
        reader.stop().await;
    }
}

pub(in crate::api) async fn close_session(session_id: u32) {
    let removed = {
        let mut readers = READERS.lock().await;
        let ids: Vec<_> = readers
            .iter()
            .filter_map(|(&id, reader)| (reader.session_id == session_id).then_some(id))
            .collect();
        ids.into_iter()
            .filter_map(|id| readers.remove(&id))
            .collect::<Vec<_>>()
    };
    for reader in &removed {
        reader.cancellation.cancel();
    }
    for reader in removed {
        reader.stop().await;
    }
}
