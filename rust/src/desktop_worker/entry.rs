use std::{sync::Arc, time::Duration};

use anyhow::{anyhow, bail, Context, Result};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{Mutex, Semaphore},
};

use super::{
    windows_handles::{accept_tunnel, FrameWriter},
    wire::{
        self, GpuSurfaceOffer, Packet, Reply, Request, MAX_FRAME_BYTES, MAX_IN_FLIGHT, VERSION,
    },
};
use crate::{desktop, vnc};

#[derive(Clone, Copy)]
enum SessionKind {
    Rdp(u32),
    Vnc(u32),
}

impl SessionKind {
    async fn disconnect(self) {
        match self {
            Self::Rdp(id) => desktop::disconnect_worker(id).await,
            Self::Vnc(id) => vnc::disconnect_worker(id).await,
        }
    }
}

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
    let session = match first.body {
        Request::Prepare {
            version,
            host,
            port,
        } if version == VERSION => {
            prepare_rdp(&mut output, first.id, desktop::prepare(host, port, None)).await?
        }
        Request::PreparePage {
            version,
            host,
            port,
            gateway,
        } if version == VERSION => {
            prepare_rdp(
                &mut output,
                first.id,
                desktop::prepare_with_page(host, port, None, Some(gateway)),
            )
            .await?
        }
        Request::PrepareTunnel {
            version,
            host,
            tunnel_handle,
        } if version == VERSION => match accept_tunnel(tunnel_handle) {
            Ok(pipe) => {
                prepare_rdp(
                    &mut output,
                    first.id,
                    desktop::prepare_transport(host, desktop::Transport::Pipe(pipe)),
                )
                .await?
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
        Request::VncConnect {
            version,
            host,
            port,
            password,
            page_gateway,
        } if version == VERSION => {
            connect_vnc(
                &mut output,
                first.id,
                vnc::connect(host, port, password, None, page_gateway),
            )
            .await?
        }
        Request::VncConnectTunnel {
            version,
            password,
            tunnel_handle,
        } if version == VERSION => match accept_tunnel(tunnel_handle) {
            Ok(pipe) => {
                connect_vnc(
                    &mut output,
                    first.id,
                    vnc::connect_transport(password, desktop::Transport::Pipe(pipe)),
                )
                .await?
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
                    body: Reply::Error("桌面会话进程协议版本不兼容".into()),
                },
            )
            .await?;
            return Ok(());
        }
    };
    let Some(session) = session else {
        return Ok(());
    };
    let output = Arc::new(Mutex::new(output));
    let framebuffer = Arc::new(Mutex::new(None));
    let limit = Arc::new(Semaphore::new(MAX_IN_FLIGHT));
    let result: Result<()> = async {
        loop {
            let packet = wire::read::<Request>(&mut input).await?;
            if matches!(packet.body, Request::Close) {
                session.disconnect().await;
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
                .context("桌面会话进程已关闭")?;
            let output = output.clone();
            let framebuffer = framebuffer.clone();
            // The frame/clipboard long polls must not hold back input or close.
            tokio::spawn(async move {
                let response = invoke(session, packet.body, &framebuffer)
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
    session.disconnect().await;
    result
}

async fn prepare_rdp<W: AsyncWrite + Unpin>(
    output: &mut W,
    packet_id: u32,
    future: impl std::future::Future<Output = Result<crate::api::desktop::DesktopHandshake>>,
) -> Result<Option<SessionKind>> {
    match future.await {
        Ok(handshake) => {
            let session_id = handshake.session_id;
            wire::write(
                output,
                Packet {
                    id: packet_id,
                    body: Reply::Handshake(handshake),
                },
            )
            .await?;
            Ok(Some(SessionKind::Rdp(session_id)))
        }
        Err(error) => {
            wire::write(
                output,
                Packet {
                    id: packet_id,
                    body: error_reply(error),
                },
            )
            .await?;
            Ok(None)
        }
    }
}

async fn connect_vnc<W: AsyncWrite + Unpin>(
    output: &mut W,
    packet_id: u32,
    future: impl std::future::Future<Output = Result<u32>>,
) -> Result<Option<SessionKind>> {
    match future.await {
        Ok(session_id) => {
            wire::write(
                output,
                Packet {
                    id: packet_id,
                    body: Reply::Done,
                },
            )
            .await?;
            Ok(Some(SessionKind::Vnc(session_id)))
        }
        Err(error) => {
            wire::write(
                output,
                Packet {
                    id: packet_id,
                    body: error_reply(error),
                },
            )
            .await?;
            Ok(None)
        }
    }
}

fn error_reply(error: anyhow::Error) -> Reply {
    // These messages are already filtered by the desktop API. Keep the error
    // stage and code so Dart can still distinguish bad credentials.
    Reply::Error(format!("{error:#}"))
}

async fn invoke(
    session: SessionKind,
    command: Request,
    target: &Mutex<Option<FrameWriter>>,
) -> Result<Reply> {
    match (session, command) {
        (
            SessionKind::Rdp(session_id),
            Request::Authenticate {
                fingerprint,
                username,
                password,
                domain,
                preferences,
                gpu_adapter_luid,
            },
        ) => {
            desktop::authenticate_with_gpu(
                session_id,
                fingerprint,
                username,
                password,
                domain,
                preferences,
                gpu_adapter_luid,
            )
            .await?;
        }
        (SessionKind::Rdp(session_id), Request::DisableGpu) => {
            desktop::disable_gpu(session_id).await;
        }
        (session, Request::Frame { after, mapping }) => {
            let mut target = target.lock().await;
            if let Some(offer) = mapping {
                *target = Some(FrameWriter::accept(offer)?);
            }
            let target = target
                .as_mut()
                .ok_or_else(|| anyhow!("桌面会话进程缺少帧缓冲"))?;
            let (mut frame, gpu) = match session {
                SessionKind::Rdp(session_id) => {
                    let Some(delivery) = desktop::frame_delivery(session_id, after).await? else {
                        return Ok(Reply::Frame(None));
                    };
                    (delivery.frame, delivery.gpu)
                }
                SessionKind::Vnc(session_id) => {
                    let Some(frame) = vnc::frame(session_id, after).await? else {
                        return Ok(Reply::Frame(None));
                    };
                    (frame, None)
                }
            };
            if let Some(gpu_frame) = gpu {
                if let Some(d3d) = gpu_frame
                    .as_any()
                    .downcast_ref::<ironrdp_egfx_native::D3D11PresentedFrame>()
                {
                    return Ok(Reply::GpuFrame {
                        frame,
                        surface: GpuSurfaceOffer {
                            handle: d3d.shared_handle(),
                            generation: d3d.generation(),
                        },
                    });
                }
            }
            if frame.rgba.len() > target.capacity() {
                if frame.rgba.len() > MAX_FRAME_BYTES {
                    bail!("桌面会话进程画面超限");
                }
                return Ok(Reply::NeedFrameSpace(frame.rgba.len() as u32));
            }
            let pixels = std::mem::take(&mut frame.rgba);
            target.publish(&pixels, frame.sequence);
            return Ok(Reply::Frame(Some(frame)));
        }
        (
            SessionKind::Rdp(session_id),
            Request::Input {
                kind,
                code,
                flags,
                x,
                y,
                text,
            },
        ) => {
            desktop::input(session_id, kind, code, flags, x, y, text).await?;
        }
        (
            SessionKind::Vnc(session_id),
            Request::VncInput {
                kind,
                code,
                flags,
                x,
                y,
                text,
            },
        ) => {
            vnc::input(session_id, kind, code, flags, x, y, text).await?;
        }
        (SessionKind::Rdp(session_id), Request::InputBatch(events)) => {
            desktop::input_batch(session_id, events).await?;
        }
        (SessionKind::Rdp(session_id), Request::Resize { width, height }) => {
            return Ok(Reply::Resize(
                desktop::resize(session_id, width, height).await?,
            ));
        }
        (SessionKind::Rdp(session_id), Request::ClipboardActive { active, directory }) => {
            desktop::clipboard_active(session_id, active, directory).await?;
        }
        (SessionKind::Rdp(session_id), Request::ClipboardUpdate { text, files }) => {
            desktop::clipboard_update(session_id, text, files).await?;
        }
        (SessionKind::Rdp(session_id), Request::ClipboardEvent { after }) => {
            return Ok(Reply::Clipboard(
                desktop::clipboard_event(session_id, after).await?,
            ));
        }
        (SessionKind::Rdp(session_id), Request::ClipboardCancel) => {
            desktop::clipboard_cancel(session_id).await?;
        }
        (SessionKind::Rdp(session_id), Request::Probe) => desktop::probe(session_id).await?,
        (SessionKind::Vnc(session_id), Request::Probe) => vnc::probe(session_id).await?,
        _ => bail!("桌面会话进程状态无效"),
    }
    Ok(Reply::Done)
}
