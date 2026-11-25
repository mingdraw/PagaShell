use std::{sync::Arc, time::Duration};

use anyhow::{anyhow, bail, Context, Result};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{Mutex, Semaphore},
};

use super::{
    windows_handles::FrameWriter,
    wire::{self, Packet, Reply, Request, MAX_FRAME_BYTES, MAX_IN_FLIGHT, VERSION},
};
use crate::desktop;

/// Called by the Windows runner before it creates a Flutter engine.
#[no_mangle]
pub extern "system" fn pagashell_rdp_worker_main() -> isize {
    std::panic::catch_unwind(|| {
        let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
        else {
            return 1;
        };
        let result = runtime.block_on(serve(tokio::io::stdin(), tokio::io::stdout()));
        // A blocking pipe operation in a dying child must not hold up exit.
        runtime.shutdown_timeout(Duration::from_millis(100));
        isize::from(result.is_err())
    })
    .unwrap_or(1)
}

async fn serve<R, W>(mut input: R, mut output: W) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let first = wire::read::<Request>(&mut input).await?;
    let session_id = match first.body {
        Request::Prepare {
            version,
            host,
            port,
        } if version == VERSION => match desktop::prepare(host, port, None).await {
            Ok(handshake) => {
                let session_id = handshake.session_id;
                wire::write(
                    &mut output,
                    Packet {
                        id: first.id,
                        body: Reply::Handshake(handshake),
                    },
                )
                .await?;
                session_id
            }
            Err(error) => {
                wire::write(
                    &mut output,
                    Packet {
                        id: first.id,
                        body: error_reply(error),
                    },
                )
                .await?;
                return Ok(());
            }
        },
        Request::Close => {
            wire::write(
                &mut output,
                Packet {
                    id: first.id,
                    body: Reply::Done,
                },
            )
            .await?;
            return Ok(());
        }
        _ => {
            wire::write(
                &mut output,
                Packet {
                    id: first.id,
                    body: Reply::Error("RDP 会话进程协议版本不兼容".into()),
                },
            )
            .await?;
            return Ok(());
        }
    };
    let output = Arc::new(Mutex::new(output));
    let framebuffer = Arc::new(Mutex::new(None));
    let limit = Arc::new(Semaphore::new(MAX_IN_FLIGHT));
    let result: Result<()> = async {
        loop {
            let packet = wire::read::<Request>(&mut input).await?;
            if matches!(packet.body, Request::Close) {
                desktop::disconnect_worker(session_id).await;
                wire::write(
                    &mut *output.lock().await,
                    Packet {
                        id: packet.id,
                        body: Reply::Done,
                    },
                )
                .await?;
                return Ok(());
            }
            let permit = limit
                .clone()
                .acquire_owned()
                .await
                .context("RDP 会话进程已关闭")?;
            let output = output.clone();
            let framebuffer = framebuffer.clone();
            // The frame/clipboard long polls must not hold back input or close.
            tokio::spawn(async move {
                let response = invoke(session_id, packet.body, &framebuffer)
                    .await
                    .unwrap_or_else(error_reply);
                // Take the output lock only after the native call has completed.
                let _ = wire::write(
                    &mut *output.lock().await,
                    Packet {
                        id: packet.id,
                        body: response,
                    },
                )
                .await;
                drop(permit);
            });
        }
    }
    .await;
    desktop::disconnect_worker(session_id).await;
    result
}

fn error_reply(error: anyhow::Error) -> Reply {
    // These messages are already filtered by the RDP API. Keep the error
    // stage and code so Dart can still distinguish bad credentials.
    Reply::Error(format!("{error:#}"))
}

async fn invoke(
    session_id: u32,
    command: Request,
    target: &Mutex<Option<FrameWriter>>,
) -> Result<Reply> {
    match command {
        Request::Authenticate {
            fingerprint,
            username,
            password,
            domain,
        } => {
            desktop::authenticate(session_id, fingerprint, username, password, domain).await?;
        }
        Request::Frame { after, mapping } => {
            let mut target = target.lock().await;
            if let Some(offer) = mapping {
                *target = Some(FrameWriter::accept(offer)?);
            }
            let target = target
                .as_mut()
                .ok_or_else(|| anyhow!("RDP 会话进程缺少帧缓冲"))?;
            let Some(mut frame) = desktop::frame(session_id, after).await? else {
                return Ok(Reply::Frame(None));
            };
            if frame.rgba.len() > target.capacity() {
                if frame.rgba.len() > MAX_FRAME_BYTES {
                    bail!("RDP 会话进程画面超限");
                }
                return Ok(Reply::NeedFrameSpace(frame.rgba.len() as u32));
            }
            let pixels = std::mem::take(&mut frame.rgba);
            target.publish(&pixels, frame.sequence);
            return Ok(Reply::Frame(Some(frame)));
        }
        Request::Input {
            kind,
            code,
            flags,
            x,
            y,
            text,
        } => {
            desktop::input(session_id, kind, code, flags, x, y, text).await?;
        }
        Request::InputBatch(events) => desktop::input_batch(session_id, events).await?,
        Request::Resize { width, height } => {
            return Ok(Reply::Resize(
                desktop::resize(session_id, width, height).await?,
            ));
        }
        Request::ClipboardActive { active, directory } => {
            desktop::clipboard_active(session_id, active, directory).await?;
        }
        Request::ClipboardUpdate { text, files } => {
            desktop::clipboard_update(session_id, text, files).await?
        }
        Request::ClipboardEvent { after } => {
            return Ok(Reply::Clipboard(
                desktop::clipboard_event(session_id, after).await?,
            ));
        }
        Request::ClipboardCancel => desktop::clipboard_cancel(session_id).await?,
        Request::Probe => desktop::probe(session_id).await?,
        Request::Prepare { .. } | Request::Close => bail!("RDP 会话进程状态无效"),
    }
    Ok(Reply::Done)
}
