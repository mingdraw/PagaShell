use std::{collections::HashMap, time::Duration};

use anyhow::{anyhow, Result};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{mpsc, oneshot, watch},
    time,
};

use super::wire::{self, Packet, Reply, Request, MAX_IN_FLIGHT};

pub(super) const EXITED: &str = "RDP 会话进程已退出，请重新连接";
pub(super) const STALLED: &str = "RDP 会话进程无响应，请重新连接";
pub(super) const INVALID_REPLY: &str = "RDP 会话进程通信失败，请重新连接";
pub(super) const CLOSED: &str = "RDP 会话已关闭";

#[cfg(windows)]
#[derive(Clone, Copy)]
pub(super) struct Messages {
    pub exited: &'static str,
    pub stalled: &'static str,
    pub invalid_reply: &'static str,
    pub closed: &'static str,
}

#[cfg(windows)]
pub(super) const RDP_MESSAGES: Messages = Messages {
    exited: EXITED,
    stalled: STALLED,
    invalid_reply: INVALID_REPLY,
    closed: CLOSED,
};

#[cfg(windows)]
pub(super) const VNC_MESSAGES: Messages = Messages {
    exited: "VNC 会话进程已退出，请重新连接",
    stalled: "VNC 会话进程无响应，请重新连接",
    invalid_reply: "VNC 会话进程通信失败，请重新连接",
    closed: "VNC 会话已关闭",
};

#[derive(Clone)]
pub(super) struct Client {
    tx: mpsc::Sender<Call>,
    terminal: watch::Sender<Option<&'static str>>,
    exited: &'static str,
    stalled: &'static str,
}

struct Call {
    request: Request,
    reply: oneshot::Sender<Reply>,
}

impl Client {
    #[cfg(test)]
    pub(super) fn start(
        reader: impl AsyncRead + Unpin + Send + 'static,
        writer: impl AsyncWrite + Unpin + Send + 'static,
    ) -> Self {
        Self::start_inner(reader, writer, EXITED, STALLED, INVALID_REPLY, CLOSED)
    }

    #[cfg(windows)]
    pub(super) fn start_with_messages(
        reader: impl AsyncRead + Unpin + Send + 'static,
        writer: impl AsyncWrite + Unpin + Send + 'static,
        messages: Messages,
    ) -> Self {
        Self::start_inner(
            reader,
            writer,
            messages.exited,
            messages.stalled,
            messages.invalid_reply,
            messages.closed,
        )
    }

    fn start_inner(
        mut reader: impl AsyncRead + Unpin + Send + 'static,
        writer: impl AsyncWrite + Unpin + Send + 'static,
        exited: &'static str,
        stalled: &'static str,
        invalid_reply: &'static str,
        closed: &'static str,
    ) -> Self {
        let (tx, calls) = mpsc::channel(MAX_IN_FLIGHT);
        let (replies, responses) = mpsc::channel(MAX_IN_FLIGHT);
        let (terminal, _) = watch::channel(None);
        let reader_terminal = terminal.clone();
        tokio::spawn(async move {
            // A cancelled read may already have consumed a prefix. Cancel
            // only when stopping this whole connection, never per call.
            tokio::select! {
                _ = wait_stopped(&reader_terminal) => {}
                _ = async {
                    loop {
                        let response = wire::read(&mut reader).await;
                        let finished = response.is_err();
                        if replies.send(response).await.is_err() || finished {
                            break;
                        }
                    }
                } => {}
            }
        });
        tokio::spawn(drive(
            writer,
            calls,
            responses,
            terminal.clone(),
            exited,
            invalid_reply,
            closed,
        ));
        Self {
            tx,
            terminal,
            exited,
            stalled,
        }
    }

    pub(super) async fn call(&self, request: Request, timeout: Duration) -> Result<Reply> {
        if let Some(reason) = *self.terminal.borrow() {
            return Err(anyhow!(reason));
        }
        let (reply, response) = oneshot::channel();
        match time::timeout(timeout, async {
            self.tx
                .send(Call { request, reply })
                .await
                .map_err(|_| ())?;
            response.await.map_err(|_| ())
        })
        .await
        {
            Ok(Ok(Reply::Error(error))) => Err(anyhow!(error)),
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(())) => Err(anyhow!(self.terminal.borrow().unwrap_or(self.exited))),
            Err(_) => {
                self.stop(self.stalled);
                Err(anyhow!(self.terminal.borrow().unwrap_or(self.stalled)))
            }
        }
    }

    pub(super) fn stop(&self, reason: &'static str) {
        stop(&self.terminal, reason);
    }

    pub(super) async fn stopped(&self) {
        wait_stopped(&self.terminal).await;
    }
}

fn stop(terminal: &watch::Sender<Option<&'static str>>, reason: &'static str) {
    terminal.send_if_modified(|status| {
        if status.is_some() {
            false
        } else {
            *status = Some(reason);
            true
        }
    });
}

async fn wait_stopped(terminal: &watch::Sender<Option<&'static str>>) {
    let _ = terminal.subscribe().wait_for(Option::is_some).await;
}

async fn drive(
    mut writer: impl AsyncWrite + Unpin,
    mut calls: mpsc::Receiver<Call>,
    mut responses: mpsc::Receiver<std::io::Result<Packet<Reply>>>,
    terminal: watch::Sender<Option<&'static str>>,
    exited: &'static str,
    invalid_reply: &'static str,
    closed: &'static str,
) {
    let mut pending = HashMap::<u32, oneshot::Sender<Reply>>::new();
    let mut next_id = 1u32;
    let reason = loop {
        tokio::select! {
            _ = wait_stopped(&terminal) => break closed,
            response = responses.recv() => {
                let response = match response {
                    Some(Ok(response)) => response,
                    Some(Err(error)) if error.kind() == std::io::ErrorKind::InvalidData => {
                        break invalid_reply;
                    }
                    _ => break exited,
                };
                let Some(reply) = pending.remove(&response.id) else { break invalid_reply };
                let _ = reply.send(response.body);
            }
            call = calls.recv(), if pending.len() < MAX_IN_FLIGHT => {
                let Some(call) = call else { break closed };
                if call.reply.is_closed() {
                    continue;
                }
                let id = next_id;
                next_id = next_id.wrapping_add(1);
                pending.insert(id, call.reply);
                let result = tokio::select! {
                    _ = wait_stopped(&terminal) => break closed,
                    result = wire::write(&mut writer, Packet { id, body: call.request }) => result,
                };
                if result.is_err() {
                    break invalid_reply;
                }
            }
        }
    };
    // Publish the reason before dropping in-flight reply senders.
    stop(&terminal, reason);
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{duplex, split};

    #[tokio::test]
    async fn input_can_complete_while_the_same_workers_frame_poll_is_pending() {
        let (app, mut child) = duplex(4096);
        let (read, write) = split(app);
        let client = Client::start(read, write);
        let frames = client.clone();
        let pending = tokio::spawn(async move {
            frames
                .call(
                    Request::Frame {
                        after: 0,
                        mapping: None,
                    },
                    Duration::from_secs(2),
                )
                .await
        });
        let frame = wire::read::<Request>(&mut child).await.unwrap();
        assert!(matches!(frame.body, Request::Frame { .. }));

        let inputs = client.clone();
        let input = tokio::spawn(async move {
            inputs
                .call(Request::InputBatch(vec![]), Duration::from_secs(2))
                .await
        });
        let request = wire::read::<Request>(&mut child).await.unwrap();
        assert!(matches!(request.body, Request::InputBatch(_)));
        wire::write(
            &mut child,
            Packet {
                id: request.id,
                body: Reply::Done,
            },
        )
        .await
        .unwrap();
        assert!(matches!(input.await.unwrap().unwrap(), Reply::Done));
        assert!(!pending.is_finished());
        wire::write(
            &mut child,
            Packet {
                id: frame.id,
                body: Reply::Frame(None),
            },
        )
        .await
        .unwrap();
        assert!(matches!(
            pending.await.unwrap().unwrap(),
            Reply::Frame(None)
        ));
        client.stop(CLOSED);
        client.stopped().await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_stalled_worker_times_out_without_stopping_another_session() {
        let (app, mut stalled) = duplex(4096);
        let (read, write) = split(app);
        let broken = Client::start(read, write);
        let command = broken.clone();
        let error =
            tokio::spawn(async move { command.call(Request::Probe, Duration::from_secs(1)).await });
        let request = wire::read::<Request>(&mut stalled).await.unwrap();
        assert!(matches!(request.body, Request::Probe));

        let (app, mut live) = duplex(4096);
        let (read, write) = split(app);
        let healthy = Client::start(read, write);
        let worker = tokio::spawn(async move {
            let request = wire::read::<Request>(&mut live).await.unwrap();
            wire::write(
                &mut live,
                Packet {
                    id: request.id,
                    body: Reply::Done,
                },
            )
            .await
            .unwrap();
        });
        assert!(matches!(
            healthy
                .call(Request::Probe, Duration::from_secs(1))
                .await
                .unwrap(),
            Reply::Done
        ));
        assert!(matches!(error.await.unwrap(), Err(error) if error.to_string() == STALLED));
        broken.stopped().await;
        worker.await.unwrap();
    }

    #[tokio::test]
    async fn a_worker_exit_wakes_the_inflight_call() {
        let (app, mut child) = duplex(4096);
        let (read, write) = split(app);
        let client = Client::start(read, write);
        let probe = client.clone();
        let waiting =
            tokio::spawn(async move { probe.call(Request::Probe, Duration::from_secs(2)).await });
        let _ = wire::read::<Request>(&mut child).await.unwrap();
        drop(child);
        assert!(matches!(waiting.await.unwrap(), Err(error) if error.to_string() == EXITED));
        client.stopped().await;
    }
}
