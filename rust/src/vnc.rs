use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use ::vnc::{
    PixelFormat, Rect, VncClient, VncConnector, VncEncoding, VncError, VncEvent, X11Event,
};
use anyhow::{anyhow, bail, Context, Result};
use tokio::net::TcpStream;
use tokio::sync::{watch, Mutex, Notify};

use crate::api::desktop::{DesktopCursor, DesktopFrame, DesktopTile};
use crate::desktop::Transport;

#[cfg(test)]
#[path = "vnc_tests.rs"]
mod tests;

const TIMEOUT: Duration = Duration::from_secs(30);
const INPUT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_PIXELS: usize = 8_294_400;
static NEXT_ID: AtomicU32 = AtomicU32::new(1);
static SESSIONS: LazyLock<Mutex<HashMap<u32, Arc<Session>>>> = LazyLock::new(Default::default);

struct Session {
    client: VncClient,
    image: Mutex<Framebuffer>,
    held: Mutex<HeldInputs>,
    updated: Notify,
    cancel: watch::Sender<bool>,
    finished: watch::Sender<bool>,
}

#[derive(Default)]
struct HeldInputs {
    keys: HashSet<u32>,
    buttons: u8,
    x: u16,
    y: u16,
}

#[derive(Default)]
struct Framebuffer {
    width: u16,
    height: u16,
    pixels: Vec<u8>,
    damage: Option<Rect>,
    cursor: Option<DesktopCursor>,
    cursor_changed: bool,
    sequence: u32,
}

impl Framebuffer {
    fn resize(&mut self, width: u16, height: u16) -> Result<()> {
        let count = usize::from(width) * usize::from(height);
        if width == 0 || height == 0 || width > 8192 || height > 8192 || count > MAX_PIXELS {
            bail!("VNC 画面尺寸无效或过大");
        }
        if self.width == width && self.height == height {
            return Ok(());
        }
        self.width = width;
        self.height = height;
        self.pixels = vec![0; count * 4];
        for pixel in self.pixels.as_chunks_mut::<4>().0 {
            pixel[3] = 255;
        }
        self.damage = Some(Rect {
            x: 0,
            y: 0,
            width,
            height,
        });
        Ok(())
    }

    fn valid(&self, r: Rect) -> bool {
        r.width > 0
            && r.height > 0
            && u32::from(r.x) + u32::from(r.width) <= u32::from(self.width)
            && u32::from(r.y) + u32::from(r.height) <= u32::from(self.height)
    }

    fn damage(&mut self, r: Rect) {
        self.damage = Some(match self.damage {
            None => r,
            Some(old) => {
                let x = old.x.min(r.x);
                let y = old.y.min(r.y);
                Rect {
                    x,
                    y,
                    width: (old.x + old.width).max(r.x + r.width) - x,
                    height: (old.y + old.height).max(r.y + r.height) - y,
                }
            }
        });
    }

    fn region(&self, r: Rect) -> Vec<u8> {
        let mut pixels = Vec::with_capacity(usize::from(r.width) * usize::from(r.height) * 4);
        for y in r.y..r.y + r.height {
            let offset = (usize::from(y) * usize::from(self.width) + usize::from(r.x)) * 4;
            pixels.extend_from_slice(&self.pixels[offset..offset + usize::from(r.width) * 4]);
        }
        pixels
    }

    fn blit(&mut self, r: Rect, pixels: &[u8]) -> Result<()> {
        if !self.valid(r) || pixels.len() != usize::from(r.width) * usize::from(r.height) * 4 {
            bail!("VNC 画面数据无效");
        }
        let stride = usize::from(r.width) * 4;
        for row in 0..usize::from(r.height) {
            let offset =
                ((usize::from(r.y) + row) * usize::from(self.width) + usize::from(r.x)) * 4;
            self.pixels[offset..offset + stride]
                .copy_from_slice(&pixels[row * stride..(row + 1) * stride]);
            // RFB carries RGB padding, not alpha.
            for pixel in self.pixels[offset..offset + stride].as_chunks_mut::<4>().0 {
                pixel[3] = 255;
            }
        }
        self.damage(r);
        Ok(())
    }

    fn apply(&mut self, event: VncEvent) -> Result<()> {
        match event {
            VncEvent::SetResolution(s) => self.resize(s.width, s.height)?,
            VncEvent::DesktopUpdate(update) => {
                if let Some(layout) = update.layout {
                    self.resize(layout.width, layout.height)?;
                }
            }
            VncEvent::RawImage(r, pixels) => self.blit(r, &pixels)?,
            VncEvent::Copy(dst, src) => {
                if !self.valid(src) || dst.width != src.width || dst.height != src.height {
                    bail!("VNC 画面数据无效");
                }
                self.blit(dst, &self.region(src))?;
            }
            VncEvent::SetCursor(r, rgba) => {
                if rgba.len() != usize::from(r.width) * usize::from(r.height) * 4 {
                    bail!("VNC 光标无效");
                }
                self.cursor = Some(DesktopCursor {
                    kind: if r.width == 0 || r.height == 0 { 1 } else { 2 },
                    width: r.width,
                    height: r.height,
                    hotspot_x: r.x,
                    hotspot_y: r.y,
                    rgba,
                });
                self.cursor_changed = true;
            }
            VncEvent::Error(_) => bail!("VNC 连接已断开，请重新连接"),
            // Tight/JPEG and server clipboard synchronization are not negotiated.
            VncEvent::JpegImage(_, _) => bail!("VNC 画面编码不受支持"),
            _ => {}
        }
        Ok(())
    }

    fn frame(&mut self, after: u32) -> Option<DesktopFrame> {
        if self.width == 0 {
            return None;
        }
        let resync = after != self.sequence || after == 0;
        if !resync && self.damage.is_none() && !self.cursor_changed {
            return None;
        }
        let r = if resync {
            Some(Rect {
                x: 0,
                y: 0,
                width: self.width,
                height: self.height,
            })
        } else {
            self.damage
        };
        let rgba = r.map(|rect| self.region(rect)).unwrap_or_default();
        let cursor = if resync || self.cursor_changed {
            self.cursor.clone()
        } else {
            None
        };
        self.sequence = self.sequence.wrapping_add(1).max(1);
        self.damage = None;
        self.cursor_changed = false;
        Some(DesktopFrame {
            sequence: self.sequence,
            width: self.width,
            height: self.height,
            bitmap_width: r.map_or(0, |rect| rect.width),
            bitmap_height: r.map_or(0, |rect| rect.height),
            rgba,
            tiles: r
                .map(|rect| {
                    vec![DesktopTile {
                        x: rect.x,
                        y: rect.y,
                        width: rect.width,
                        height: rect.height,
                        source_x: 0,
                        source_y: 0,
                    }]
                })
                .unwrap_or_default(),
            cursor,
        })
    }
}

pub(crate) async fn connect(
    host: String,
    port: u16,
    password: String,
    ssh_gateway: Option<u32>,
    page_gateway: Option<crate::api::page::PageGateway>,
) -> Result<u32> {
    let client = tokio::time::timeout(TIMEOUT, async move {
        let stream = if let Some(gateway) = page_gateway {
            Transport::Page(Box::new(crate::page::connect(gateway, &host, port).await?))
        } else if let Some(id) = ssh_gateway {
            Transport::Ssh(crate::api::ssh::desktop_tunnel(id, host, port).await?)
        } else {
            let stream = TcpStream::connect((host.as_str(), port))
                .await
                .context("VNC TCP 连接失败")?;
            stream.set_nodelay(true)?;
            Transport::Direct(stream)
        };
        let state = VncConnector::new(stream)
            .set_auth_method(async move { Ok(password) })
            .set_pixel_format(PixelFormat::rgba())
            .allow_shared(true)
            .add_encoding(VncEncoding::Zrle)
            .add_encoding(VncEncoding::CopyRect)
            .add_encoding(VncEncoding::Raw)
            .add_encoding(VncEncoding::CursorPseudo)
            .add_encoding(VncEncoding::DesktopSizePseudo)
            .add_encoding(VncEncoding::LastRectPseudo)
            .build()
            .map_err(connect_error)?;
        state
            .try_start()
            .await
            .map_err(connect_error)?
            .finish()
            .map_err(connect_error)
    })
    .await
    .context("VNC 连接超时")??;
    let (cancel, cancel_rx) = watch::channel(false);
    let (finished, _) = watch::channel(false);
    let session = Arc::new(Session {
        client,
        image: Mutex::new(Framebuffer::default()),
        held: Mutex::new(HeldInputs::default()),
        updated: Notify::new(),
        cancel,
        finished,
    });
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    SESSIONS.lock().await.insert(id, Arc::clone(&session));
    tokio::spawn(run(session, cancel_rx));
    Ok(id)
}

fn connect_error(error: VncError) -> anyhow::Error {
    match error {
        VncError::WrongPassword | VncError::NoPassword => anyhow!("VNC_AUTH_FAILED"),
        VncError::InvalidSecurityTyep(_) => {
            anyhow!("VNC 服务器认证方式不受支持，请启用标准 VNC 密码认证")
        }
        // 3.8 authentication failures are returned as an opaque server string by vnc-rs.
        // Do not expose or classify arbitrary server messages as a password rejection.
        VncError::General(_) => anyhow!("VNC 认证或协议协商失败，请检查密码及服务器认证方式"),
        _ => anyhow!("VNC 连接失败，请检查地址、端口及服务器设置"),
    }
}

async fn run(session: Arc<Session>, mut cancel: watch::Receiver<bool>) {
    let mut poll = tokio::time::interval(Duration::from_millis(8));
    let mut refresh = tokio::time::interval(Duration::from_millis(33));
    let result: Result<()> = async {
        loop {
            tokio::select! {
                _ = cancel.changed() => return Ok(()),
                _ = refresh.tick() => {
                    tokio::time::timeout(INPUT_TIMEOUT, session.client.input(X11Event::Refresh)).await??;
                }
                _ = poll.tick() => {
                    for _ in 0..256 {
                        let Some(event) = session.client.poll_event().await? else { break; };
                        session.image.lock().await.apply(event)?;
                        session.updated.notify_waiters();
                    }
                }
            }
        }
    }.await;
    let _ = result; // Protocol details and server strings never enter logs/UI.
    session.finished.send_replace(true);
    session.updated.notify_waiters();
    let _ = session.client.close().await;
}

async fn get(id: u32) -> Result<Arc<Session>> {
    SESSIONS
        .lock()
        .await
        .get(&id)
        .cloned()
        .context("VNC 会话已关闭")
}

pub(crate) async fn frame(id: u32, after: u32) -> Result<Option<DesktopFrame>> {
    let session = get(id).await?;
    let wait = async {
        loop {
            let notified = session.updated.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if *session.finished.borrow() {
                bail!("VNC 连接已断开，请重新连接");
            }
            if let Some(frame) = session.image.lock().await.frame(after) {
                return Ok(Some(frame));
            }
            notified.await;
        }
    };
    tokio::time::timeout(Duration::from_millis(500), wait)
        .await
        .unwrap_or(Ok(None))
}

async fn send(client: &VncClient, event: X11Event) -> Result<()> {
    tokio::time::timeout(INPUT_TIMEOUT, client.input(event))
        .await
        .context("VNC 输入超时")?
        .map_err(|_| anyhow!("VNC 输入失败，连接已断开"))
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn input(
    id: u32,
    kind: u8,
    code: u32,
    flags: u16,
    x: u16,
    y: u16,
    text: String,
) -> Result<()> {
    let session = get(id).await?;
    let mut held = session.held.lock().await;
    match kind {
        0 => {
            let down = flags & 1 == 0;
            send(&session.client, X11Event::KeyEvent((code, down).into())).await?;
            if down {
                held.keys.insert(code);
            } else {
                held.keys.remove(&code);
            }
        }
        1 => {
            held.x = x;
            held.y = y;
            for (flag, bit) in [(0x1000, 1), (0x2000, 4), (0x4000, 2)] {
                if flags & flag != 0 {
                    if flags & 0x8000 != 0 {
                        held.buttons |= bit;
                    } else {
                        held.buttons &= !bit;
                    }
                }
            }
            let wheel = if flags & 0x0200 != 0 {
                if flags & 0x0100 != 0 {
                    16
                } else {
                    8
                }
            } else if flags & 0x0400 != 0 {
                if flags & 0x0100 != 0 {
                    64
                } else {
                    32
                }
            } else {
                0
            };
            if wheel != 0 {
                for _ in 0..code.div_ceil(120).clamp(1, 8) {
                    send(
                        &session.client,
                        X11Event::PointerEvent((x, y, held.buttons | wheel).into()),
                    )
                    .await?;
                    send(
                        &session.client,
                        X11Event::PointerEvent((x, y, held.buttons).into()),
                    )
                    .await?;
                }
            } else {
                send(
                    &session.client,
                    X11Event::PointerEvent((x, y, held.buttons).into()),
                )
                .await?;
            }
        }
        2 => {
            if text.len() > 65536 {
                bail!("VNC 输入文本过长");
            }
            for c in text.chars() {
                let code = if c == '\n' || c == '\r' {
                    0xff0d
                } else if c == '\t' {
                    0xff09
                } else if u32::from(c) <= 255 {
                    u32::from(c)
                } else {
                    0x01000000 | u32::from(c)
                };
                send(&session.client, X11Event::KeyEvent((code, true).into())).await?;
                send(&session.client, X11Event::KeyEvent((code, false).into())).await?;
            }
        }
        _ => bail!("VNC 输入类型无效"),
    }
    Ok(())
}

pub(crate) async fn disconnect(id: u32) {
    let Some(session) = SESSIONS.lock().await.remove(&id) else {
        return;
    };
    // Release held input before closing the shared connection.
    let _ = tokio::time::timeout(Duration::from_secs(1), async {
        let mut held = session.held.lock().await;
        for code in held.keys.drain() {
            let _ = session
                .client
                .input(X11Event::KeyEvent((code, false).into()))
                .await;
        }
        let _ = session
            .client
            .input(X11Event::PointerEvent((held.x, held.y, 0).into()))
            .await;
    })
    .await;
    session.cancel.send_replace(true);
    session.finished.send_replace(true);
    session.updated.notify_waiters();
    let _ = session.client.close().await;
}
