use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

async fn initialize(stream: &mut TcpStream, minor: u8, password: bool) {
    let version = format!("RFB 003.00{minor}\n");
    stream.write_all(version.as_bytes()).await.unwrap();
    let mut response = [0; 12];
    stream.read_exact(&mut response).await.unwrap();
    assert_eq!(&response, version.as_bytes());
    let security = if password { 2 } else { 1 };
    if minor == 3 {
        stream.write_u32(security).await.unwrap();
    } else {
        stream.write_all(&[1, security as u8]).await.unwrap();
        assert_eq!(stream.read_u8().await.unwrap(), security as u8);
    }
    if password {
        stream
            .write_all(&(0u8..16).collect::<Vec<_>>())
            .await
            .unwrap();
        let mut response = [0; 16];
        stream.read_exact(&mut response).await.unwrap();
        // DES response calculated independently with OpenSSL; secret is a test fixture.
        assert_eq!(
            response,
            [
                0xee, 0x22, 0x53, 0x9f, 0x33, 0xa5, 0x98, 0x3e, 0xc1, 0x2f, 0x9c, 0x2e, 0xdb, 0xc9,
                0x95, 0xdd
            ]
        );
    }
    if password || minor == 8 {
        stream.write_u32(0).await.unwrap();
    }
    assert_eq!(stream.read_u8().await.unwrap(), 1); // Shared desktop.
    stream.write_u16(2).await.unwrap();
    stream.write_u16(1).await.unwrap();
    stream
        .write_all(&[32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        .await
        .unwrap();
    stream.write_u32(4).await.unwrap();
    stream.write_all(b"test").await.unwrap();
    let mut format = [0; 20];
    stream.read_exact(&mut format).await.unwrap();
    assert_eq!(format[0], 0);
    assert_eq!(&format[14..17], &[0, 8, 16]); // Requested RGBA byte order.
    assert_eq!(stream.read_u8().await.unwrap(), 2);
    assert_eq!(stream.read_u8().await.unwrap(), 0);
    let encodings = stream.read_u16().await.unwrap();
    let mut bytes = vec![0; usize::from(encodings) * 4];
    stream.read_exact(&mut bytes).await.unwrap();
}

fn raw_frame(x: u16, width: u16, pixels: &[u8]) -> Vec<u8> {
    let mut bytes = vec![0, 0, 0, 1]; // FramebufferUpdate, one rectangle.
    bytes.extend_from_slice(&x.to_be_bytes());
    bytes.extend_from_slice(&0u16.to_be_bytes());
    bytes.extend_from_slice(&width.to_be_bytes());
    bytes.extend_from_slice(&1u16.to_be_bytes());
    bytes.extend_from_slice(&0i32.to_be_bytes());
    bytes.extend_from_slice(pixels);
    bytes
}

async fn server(
    minor: u8,
    password: bool,
) -> (
    u16,
    mpsc::UnboundedSender<Vec<u8>>,
    mpsc::UnboundedReceiver<Vec<u8>>,
    tokio::task::JoinHandle<()>,
) {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (commands, mut command_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let (events, event_rx) = mpsc::unbounded_channel();
    let worker = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        initialize(&mut stream, minor, password).await;
        loop {
            tokio::select! {
                message = command_rx.recv() => {
                    let Some(message) = message else { break; };
                    if stream.write_all(&message).await.is_err() { break; }
                }
                kind = stream.read_u8() => {
                    let Ok(kind) = kind else { break; };
                    let size = match kind { 3 => 9, 4 => 7, 5 => 5, _ => panic!("unexpected input type {kind}") };
                    let mut body = vec![0; size];
                    if stream.read_exact(&mut body).await.is_err() { break; }
                    if kind != 3 {
                        let mut bytes = vec![kind];
                        bytes.extend_from_slice(&body);
                        let _ = events.send(bytes);
                    }
                }
            }
        }
    });
    (port, commands, event_rx, worker)
}

async fn next_frame(id: u32, after: u32, expected: &[u8]) -> DesktopFrame {
    tokio::time::timeout(Duration::from_secs(3), async {
        let mut sequence = after;
        loop {
            if let Some(frame) = frame(id, sequence).await.unwrap() {
                sequence = frame.sequence;
                if frame.rgba.starts_with(expected) {
                    return frame;
                }
            }
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn rfb_versions_password_frame_pointer_keyboard_and_disconnect() {
    for (minor, password) in [
        (3, false),
        (7, false),
        (8, false),
        (3, true),
        (7, true),
        (8, true),
    ] {
        let (port, commands, mut events, worker) = server(minor, password).await;
        let id = connect("127.0.0.1".into(), port, "secret".into(), None, None)
            .await
            .unwrap();
        commands
            .send(raw_frame(0, 2, &[255, 0, 0, 0, 0, 255, 0, 0]))
            .unwrap();
        let first = next_frame(id, 0, &[255, 0, 0, 255, 0, 255, 0, 255]).await;
        assert_eq!((first.width, first.height), (2, 1));
        commands.send(raw_frame(1, 1, &[0, 0, 255, 0])).unwrap();
        let patch = next_frame(id, first.sequence, &[0, 0, 255, 255]).await;
        assert_eq!(patch.bitmap_width, 1);
        assert_eq!(patch.tiles[0].x, 1);
        input(id, 0, 0xff51, 0, 0, 0, String::new()).await.unwrap();
        input(id, 0, 0xff51, 1, 0, 0, String::new()).await.unwrap();
        input(id, 1, 0, 0x9000, 1, 0, String::new()).await.unwrap();
        input(id, 1, 120, 0x0300, 1, 0, String::new())
            .await
            .unwrap();
        let mut received = Vec::new();
        for _ in 0..5 {
            received.push(
                tokio::time::timeout(Duration::from_secs(1), events.recv())
                    .await
                    .unwrap()
                    .unwrap(),
            );
        }
        assert_eq!(received[0], [4, 1, 0, 0, 0, 0, 0xff, 0x51]);
        assert_eq!(received[1], [4, 0, 0, 0, 0, 0, 0xff, 0x51]);
        assert_eq!(received[2], [5, 1, 0, 1, 0, 0]);
        assert_eq!(received[3][1], 17); // Scroll down while left button remains held.
        assert_eq!(received[4][1], 1);
        disconnect(id).await;
        disconnect(id).await; // Idempotent.
        assert!(!SESSIONS.lock().await.contains_key(&id));
        drop(commands);
        tokio::time::timeout(Duration::from_secs(2), worker)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn unsupported_authentication_and_untrusted_server_strings_are_sanitized() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let worker = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(b"RFB 003.008\n").await.unwrap();
        let mut version = [0; 12];
        stream.read_exact(&mut version).await.unwrap();
        stream.write_all(&[1, 19]).await.unwrap(); // VeNCrypt isn't implemented.
    });
    let error = connect(
        "127.0.0.1".into(),
        port,
        "private-password".into(),
        None,
        None,
    )
    .await
    .unwrap_err();
    assert!(!error.to_string().contains("private-password"));
    assert!(error.to_string().contains("认证"));
    worker.await.unwrap();
}

#[test]
fn framebuffer_handles_overlapping_copy_resync_and_rejects_invalid_rectangles() {
    let mut image = Framebuffer::default();
    image.resize(3, 1).unwrap();
    image
        .blit(
            Rect {
                x: 0,
                y: 0,
                width: 3,
                height: 1,
            },
            &[1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0],
        )
        .unwrap();
    let first = image.frame(0).unwrap();
    image
        .apply(VncEvent::Copy(
            Rect {
                x: 1,
                y: 0,
                width: 2,
                height: 1,
            },
            Rect {
                x: 0,
                y: 0,
                width: 2,
                height: 1,
            },
        ))
        .unwrap();
    assert_eq!(
        image.frame(first.sequence).unwrap().rgba,
        [1, 0, 0, 255, 2, 0, 0, 255]
    );
    let full = image.frame(0).unwrap();
    assert_eq!(full.rgba, [1, 0, 0, 255, 1, 0, 0, 255, 2, 0, 0, 255]);
    assert!(image
        .blit(
            Rect {
                x: 3,
                y: 0,
                width: 1,
                height: 1
            },
            &[0; 4]
        )
        .is_err());
    assert!(image.resize(8192, 8192).is_err());
}
