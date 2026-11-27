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
    // Native 32-bit LE BGRA; client keeps it without sending SetPixelFormat.
    stream
        .write_all(&[32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        .await
        .unwrap();
    stream.write_u32(4).await.unwrap();
    stream.write_all(b"test").await.unwrap();
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
                    let mut bytes = vec![kind];
                    bytes.extend_from_slice(&body);
                    let _ = events.send(bytes);
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
        let id = connect(
            "127.0.0.1".into(),
            port,
            String::new(),
            "secret".into(),
            None,
            None,
        )
        .await
        .unwrap();
        // Server uses native LE BGRA: red = [0, 0, 255, 0], green = [0, 255, 0, 0].
        commands
            .send(raw_frame(0, 2, &[0, 0, 255, 0, 0, 255, 0, 0]))
            .unwrap();
        let first = next_frame(id, 0, &[255, 0, 0, 255, 0, 255, 0, 255]).await;
        assert_eq!((first.width, first.height), (2, 1));
        // Blue in LE BGRA = [255, 0, 0, 0].
        commands.send(raw_frame(1, 1, &[255, 0, 0, 0])).unwrap();
        let patch = next_frame(id, first.sequence, &[255, 0, 0, 255, 0, 0, 255, 255]).await;
        assert_eq!(patch.bitmap_width, 2);
        assert!(patch.tiles.is_empty()); // The single dirty tile covers the whole desktop.
        input(id, 0, 0xff51, 0, 0, 0, String::new()).await.unwrap();
        input(id, 0, 0xff51, 1, 0, 0, String::new()).await.unwrap();
        input(id, 1, 0, 0x9000, 1, 0, String::new()).await.unwrap();
        input(id, 1, 120, 0x0300, 1, 0, String::new())
            .await
            .unwrap();
        let mut received = Vec::new();
        while received.len() < 5 {
            let event = tokio::time::timeout(Duration::from_secs(1), events.recv())
                .await
                .unwrap()
                .unwrap();
            if event[0] != 3 {
                received.push(event);
            }
        }
        assert_eq!(received[0], [4, 1, 0, 0, 0, 0, 0xff, 0x51]);
        assert_eq!(received[1], [4, 0, 0, 0, 0, 0, 0xff, 0x51]);
        assert_eq!(received[2], [5, 1, 0, 1, 0, 0]);
        assert_eq!(received[3][1], 17); // Scroll down while left button remains held.
        assert_eq!(received[4][1], 1);
        probe(id).await.unwrap();
        disconnect(id).await;
        disconnect(id).await; // Idempotent.
        assert!(probe(id).await.is_err());
        assert!(!SESSIONS.lock().await.contains_key(&id));
        drop(commands);
        tokio::time::timeout(Duration::from_secs(2), worker)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn refresh_is_requested_only_when_a_viewer_needs_an_update() {
    let (port, commands, mut events, worker) = server(8, false).await;
    let id = connect(
        "127.0.0.1".into(),
        port,
        String::new(),
        String::new(),
        None,
        None,
    )
    .await
    .unwrap();
    let request = tokio::time::timeout(Duration::from_secs(1), events.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&request[..2], &[3, 0]);
    commands
        .send(raw_frame(0, 2, &[0, 0, 255, 0, 0, 255, 0, 0]))
        .unwrap();
    let first = next_frame(id, 0, &[255, 0, 0, 255, 0, 255, 0, 255]).await;
    assert!(
        tokio::time::timeout(REFRESH_RETRY + FRAME_INTERVAL, events.recv())
            .await
            .is_err()
    );
    let next = tokio::spawn(frame(id, first.sequence));
    let request = tokio::time::timeout(Duration::from_secs(1), events.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&request[..2], &[3, 1]);
    commands.send(raw_frame(1, 1, &[255, 0, 0, 0])).unwrap();
    let update = next.await.unwrap().unwrap().unwrap();
    assert_eq!(update.rgba, [255, 0, 0, 255, 0, 0, 255, 255]);
    disconnect(id).await;
    drop(commands);
    worker.await.unwrap();
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
        String::new(),
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
        [1, 0, 0, 255, 1, 0, 0, 255, 2, 0, 0, 255]
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

#[test]
fn sparse_vnc_rectangles_pack_their_tiles_without_reuploading_the_desktop() {
    let mut image = Framebuffer::default();
    image.resize(512, 256).unwrap();
    let first = image.frame(0).unwrap();
    image
        .blit(
            Rect {
                x: 3,
                y: 2,
                width: 1,
                height: 1,
            },
            &[255, 0, 0, 0],
        )
        .unwrap();
    image
        .blit(
            Rect {
                x: 500,
                y: 200,
                width: 1,
                height: 1,
            },
            &[0, 0, 255, 0],
        )
        .unwrap();
    let atlas = image.frame(first.sequence).unwrap();
    assert_eq!(
        atlas
            .tiles
            .iter()
            .map(|tile| (tile.x, tile.y))
            .collect::<Vec<_>>(),
        [(0, 0), (384, 128)]
    );
    assert!(atlas.rgba.len() < first.rgba.len());
    for (x, y, color) in [(3, 2, [255, 0, 0, 255]), (500, 200, [0, 0, 255, 255])] {
        let tile = atlas
            .tiles
            .iter()
            .find(|tile| x >= tile.x && x < tile.x + tile.width)
            .unwrap();
        let pixel = (usize::from(y - tile.y + tile.source_y) * usize::from(atlas.bitmap_width)
            + usize::from(x - tile.x + tile.source_x))
            * 4;
        assert_eq!(atlas.rgba[pixel..pixel + 4], color);
    }
}

fn fixed_be(value: &num_bigint::BigUint, len: usize) -> Vec<u8> {
    let bytes = value.to_bytes_be();
    let mut out = vec![0u8; len];
    out[len - bytes.len()..].copy_from_slice(&bytes);
    out
}

async fn perform_ard_server_exchange(stream: &mut TcpStream) -> (String, String) {
    use aes::cipher::{Array, BlockCipherDecrypt, KeyInit};
    use aes::Aes128;
    use num_bigint::BigUint;

    let key_len = 128usize;
    let generator: u16 = 5;
    let mut prime_bytes = vec![0u8; key_len];
    prime_bytes[0] = 0xD5;
    prime_bytes[key_len - 1] = 0xFD;
    let prime = BigUint::from_bytes_be(&prime_bytes);
    let server_priv = BigUint::from(0x0123_4567_89ab_cdef_u64);
    let server_pub = BigUint::from(generator).modpow(&server_priv, &prime);
    let server_pub_bytes = fixed_be(&server_pub, key_len);

    stream.write_u16(generator).await.unwrap();
    stream.write_u16(key_len as u16).await.unwrap();
    stream.write_all(&prime_bytes).await.unwrap();
    stream.write_all(&server_pub_bytes).await.unwrap();

    let mut ciphertext = [0u8; 128];
    stream.read_exact(&mut ciphertext).await.unwrap();
    let mut client_pub_bytes = vec![0u8; key_len];
    stream.read_exact(&mut client_pub_bytes).await.unwrap();

    let client_pub = BigUint::from_bytes_be(&client_pub_bytes);
    let shared = client_pub.modpow(&server_priv, &prime);
    let shared_bytes = fixed_be(&shared, key_len);
    let aes_key = md5::compute(&shared_bytes).0;
    let cipher = Aes128::new(&Array::from(aes_key));

    let mut plain = ciphertext;
    for chunk in plain.chunks_exact_mut(16) {
        let mut block = Array::from(<[u8; 16]>::try_from(&chunk[..]).unwrap());
        cipher.decrypt_block(&mut block);
        chunk.copy_from_slice(&block);
    }

    let u_end = plain[..64].iter().position(|&b| b == 0).unwrap();
    let p_end = plain[64..128].iter().position(|&b| b == 0).unwrap();
    (
        String::from_utf8(plain[..u_end].to_vec()).unwrap(),
        String::from_utf8(plain[64..64 + p_end].to_vec()).unwrap(),
    )
}

#[tokio::test]
async fn macos_screen_sharing_rfb_3889_ard_auth_xrgb_and_option_key_remapping() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (events_tx, mut events_rx) = mpsc::unbounded_channel::<Vec<u8>>();

    let worker = tokio::spawn(async move {
        // Attempt 1: empty username against ARD-only macOS server -> client disconnects before choosing.
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(b"RFB 003.889\n").await.unwrap();
        let mut version = [0; 12];
        stream.read_exact(&mut version).await.unwrap();
        assert_eq!(&version, b"RFB 003.008\n");
        stream.write_all(&[4, 30, 33, 35, 36]).await.unwrap();
        drop(stream);

        // Attempt 2: wrong password -> macOS sends SecurityResult=1 and immediately closes (no reason string).
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(b"RFB 003.889\n").await.unwrap();
        stream.read_exact(&mut version).await.unwrap();
        assert_eq!(&version, b"RFB 003.008\n");
        stream.write_all(&[4, 30, 33, 35, 36]).await.unwrap();
        assert_eq!(stream.read_u8().await.unwrap(), 30);
        let (user, pass) = perform_ard_server_exchange(&mut stream).await;
        assert_eq!((user.as_str(), pass.as_str()), ("alice", "wrong"));
        stream.write_u32(1).await.unwrap();
        drop(stream);

        // Attempt 3: valid macOS credentials -> BE xRGB pixels + SetColorMapEntries + Option/Command keys.
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(b"RFB 003.889\n").await.unwrap();
        stream.read_exact(&mut version).await.unwrap();
        assert_eq!(&version, b"RFB 003.008\n");
        stream.write_all(&[4, 30, 33, 35, 36]).await.unwrap();
        assert_eq!(stream.read_u8().await.unwrap(), 30);
        let (user, pass) = perform_ard_server_exchange(&mut stream).await;
        assert_eq!((user.as_str(), pass.as_str()), ("alice", "mac-pass"));
        stream.write_u32(0).await.unwrap();

        assert_eq!(stream.read_u8().await.unwrap(), 1); // Shared flag.
        stream.write_u16(2).await.unwrap();
        stream.write_u16(1).await.unwrap();
        // Big-endian xRGB (big_endian=1, R=16, G=8, B=0) -> [x, R, G, B].
        stream
            .write_all(&[32, 24, 1, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
            .await
            .unwrap();
        stream.write_u32(5).await.unwrap();
        stream.write_all(b"macOS").await.unwrap();

        // Client keeps native 32-bit BE xRGB without sending SetPixelFormat, so next is SetEncodings (2).
        assert_eq!(stream.read_u8().await.unwrap(), 2);
        assert_eq!(stream.read_u8().await.unwrap(), 0);
        let encodings = stream.read_u16().await.unwrap();
        let mut enc_bytes = vec![0; usize::from(encodings) * 4];
        stream.read_exact(&mut enc_bytes).await.unwrap();

        // Send a SetColorMapEntries message (opcode 1) with 2 entries; client must skip cleanly.
        let mut colormap = vec![1u8, 0, 0, 0, 0, 2];
        colormap.extend_from_slice(&[0u8; 12]);
        stream.write_all(&colormap).await.unwrap();

        // Send BE xRGB pixels: [0, 10, 20, 30] and [0, 40, 50, 60].
        stream
            .write_all(&raw_frame(0, 2, &[0, 10, 20, 30, 0, 40, 50, 60]))
            .await
            .unwrap();

        while let Ok(kind) = stream.read_u8().await {
            let size = match kind {
                3 => 9,
                4 => 7,
                5 => 5,
                _ => panic!("unexpected client msg {kind}"),
            };
            let mut body = vec![0; size];
            if stream.read_exact(&mut body).await.is_err() {
                break;
            }
            let mut msg = vec![kind];
            msg.extend_from_slice(&body);
            let _ = events_tx.send(msg);
        }
    });

    // Attempt 1: empty username triggers VNC_ARD_USERNAME_REQUIRED.
    let err = connect(
        "127.0.0.1".into(),
        port,
        String::new(),
        "mac-pass".into(),
        None,
        None,
    )
    .await
    .unwrap_err();
    assert!(err.to_string().contains("VNC_ARD_USERNAME_REQUIRED"));

    // Attempt 2: wrong password triggers VNC_ARD_AUTH_FAILED even when server closes on SecurityResult=1.
    let err = connect(
        "127.0.0.1".into(),
        port,
        "alice".into(),
        "wrong".into(),
        None,
        None,
    )
    .await
    .unwrap_err();
    assert!(err.to_string().contains("VNC_ARD_AUTH_FAILED"));

    // Attempt 3: valid credentials succeed, BE xRGB swizzles to RGBA, and Alt remaps to Meta (Option).
    let id = connect(
        "127.0.0.1".into(),
        port,
        "alice".into(),
        "mac-pass".into(),
        None,
        None,
    )
    .await
    .unwrap();
    let first = next_frame(id, 0, &[10, 20, 30, 255, 40, 50, 60, 255]).await;
    assert_eq!((first.width, first.height), (2, 1));

    // Send Alt_L down/up (remapped to Meta_L 0xffe7) and Super_L down/up (kept as 0xffeb for Command).
    input(id, 0, 0xffe9, 0, 0, 0, String::new()).await.unwrap();
    input(id, 0, 0xffe9, 1, 0, 0, String::new()).await.unwrap();
    input(id, 0, 0xffeb, 0, 0, 0, String::new()).await.unwrap();
    input(id, 0, 0xffeb, 1, 0, 0, String::new()).await.unwrap();

    let mut keys = Vec::new();
    while keys.len() < 4 {
        let msg = tokio::time::timeout(Duration::from_secs(1), events_rx.recv())
            .await
            .unwrap()
            .unwrap();
        if msg[0] == 4 {
            keys.push(msg);
        }
    }
    assert_eq!(keys[0], [4, 1, 0, 0, 0, 0, 0xff, 0xe7]);
    assert_eq!(keys[1], [4, 0, 0, 0, 0, 0, 0xff, 0xe7]);
    assert_eq!(keys[2], [4, 1, 0, 0, 0, 0, 0xff, 0xeb]);
    assert_eq!(keys[3], [4, 0, 0, 0, 0, 0, 0xff, 0xeb]);

    disconnect(id).await;
    worker.await.unwrap();
}

#[tokio::test]
async fn macos_server_with_legacy_vnc_password_allows_password_only_login() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let worker = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(b"RFB 003.889\n").await.unwrap();
        let mut version = [0; 12];
        stream.read_exact(&mut version).await.unwrap();
        assert_eq!(&version, b"RFB 003.008\n");
        stream.write_all(&[3, 30, 2, 35]).await.unwrap();
        // Without a username, client selects legacy VNC Auth (2).
        assert_eq!(stream.read_u8().await.unwrap(), 2);
        stream
            .write_all(&(0u8..16).collect::<Vec<_>>())
            .await
            .unwrap();
        let mut response = [0; 16];
        stream.read_exact(&mut response).await.unwrap();
        stream.write_u32(0).await.unwrap();
        assert_eq!(stream.read_u8().await.unwrap(), 1);
        stream.write_u16(1).await.unwrap();
        stream.write_u16(1).await.unwrap();
        // 16-bit RGB565 server format -> client must request 32-bit RGBA via SetPixelFormat.
        stream
            .write_all(&[16, 16, 0, 1, 0, 31, 0, 63, 0, 31, 11, 5, 0, 0, 0, 0])
            .await
            .unwrap();
        stream.write_u32(5).await.unwrap();
        stream.write_all(b"mac16").await.unwrap();
        let mut format = [0; 20];
        stream.read_exact(&mut format).await.unwrap();
        assert_eq!(format[0], 0);
        assert_eq!(&format[14..17], &[0, 8, 16]);
        assert_eq!(stream.read_u8().await.unwrap(), 2);
        assert_eq!(stream.read_u8().await.unwrap(), 0);
        let encodings = stream.read_u16().await.unwrap();
        let mut enc_bytes = vec![0; usize::from(encodings) * 4];
        stream.read_exact(&mut enc_bytes).await.unwrap();
        stream
            .write_all(&raw_frame(0, 1, &[11, 22, 33, 0]))
            .await
            .unwrap();
        let mut sink = [0u8; 64];
        while stream.read(&mut sink).await.unwrap_or(0) > 0 {}
    });

    let id = connect(
        "127.0.0.1".into(),
        port,
        String::new(),
        "secret".into(),
        None,
        None,
    )
    .await
    .unwrap();
    let frame = next_frame(id, 0, &[11, 22, 33, 255]).await;
    assert_eq!((frame.width, frame.height), (1, 1));
    disconnect(id).await;
    worker.await.unwrap();
}

#[test]
fn vnc_accepts_retina_5k_and_6k_framebuffers() {
    assert!(validate_desktop_size(5120, 2880).is_ok());
    assert!(validate_desktop_size(6016, 3384).is_ok());
    assert!(validate_desktop_size(8192, 8192).is_err());
}

#[tokio::test]
async fn vnc_input_batch_and_shared_desktop_session_ids() {
    let rdp_id = crate::desktop::reserve_session_id();
    let vnc_id = crate::desktop_frame::reserve_desktop_session_id();
    assert_ne!(rdp_id, vnc_id);

    let (port, commands, mut events, worker) = server(8, false).await;
    let id = connect(
        "127.0.0.1".into(),
        port,
        String::new(),
        String::new(),
        None,
        None,
    )
    .await
    .unwrap();
    assert_ne!(id, rdp_id);
    assert_ne!(id, vnc_id);

    commands
        .send(raw_frame(0, 2, &[0, 0, 255, 0, 0, 255, 0, 0]))
        .unwrap();
    let _first = next_frame(id, 0, &[255, 0, 0, 255, 0, 255, 0, 255]).await;

    input_batch(
        id,
        vec![
            VncInputEvent {
                pointer: true,
                code: 0,
                flags: 0x0800,
                x: 1,
                y: 0,
            },
            VncInputEvent {
                pointer: false,
                code: 0x0061,
                flags: 0,
                x: 0,
                y: 0,
            },
            VncInputEvent {
                pointer: false,
                code: 0x0061,
                flags: 1,
                x: 0,
                y: 0,
            },
        ],
    )
    .await
    .unwrap();

    let mut received = Vec::new();
    while received.len() < 3 {
        let msg = tokio::time::timeout(Duration::from_secs(1), events.recv())
            .await
            .unwrap()
            .unwrap();
        if msg[0] != 3 {
            received.push(msg);
        }
    }
    assert_eq!(received[0], [5, 0, 0, 1, 0, 0]);
    assert_eq!(received[1], [4, 1, 0, 0, 0, 0, 0, 0x61]);
    assert_eq!(received[2], [4, 0, 0, 0, 0, 0, 0, 0x61]);

    disconnect(id).await;
    drop(commands);
    worker.await.unwrap();
}

#[tokio::test]
async fn vnc_network_stats_and_quality_mode_switch_rgb565_and_back() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let worker = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        initialize(&mut stream, 8, false).await;

        // Read initial FullRefresh (10 bytes).
        let mut req = [0u8; 10];
        stream.read_exact(&mut req).await.unwrap();
        assert_eq!(&req[..2], &[3, 0]);

        // Reply with 32-bit LE BGRA: red + green.
        stream
            .write_all(&raw_frame(0, 2, &[0, 0, 255, 0, 0, 255, 0, 0]))
            .await
            .unwrap();

        // Expect SetPixelFormat (20 bytes) to 16-bit RGB565, followed by FullRefresh (10 bytes).
        let mut set_pf = [0u8; 20];
        stream.read_exact(&mut set_pf).await.unwrap();
        assert_eq!(set_pf[0], 0);
        assert_eq!(set_pf[4], 16); // bits_per_pixel = 16
        stream.read_exact(&mut req).await.unwrap();
        assert_eq!(&req[..2], &[3, 0]);

        // Reply with 16-bit RGB565 pixels: blue (0x001F) + white (0xFFFF).
        let mut rgb565_pixels = Vec::new();
        rgb565_pixels.extend_from_slice(&0x001Fu16.to_le_bytes());
        rgb565_pixels.extend_from_slice(&0xFFFFu16.to_le_bytes());
        stream
            .write_all(&raw_frame(0, 2, &rgb565_pixels))
            .await
            .unwrap();

        // Expect SetPixelFormat back to native 32-bit LE BGRA + FullRefresh.
        stream.read_exact(&mut set_pf).await.unwrap();
        assert_eq!(set_pf[0], 0);
        assert_eq!(set_pf[4], 32);
        stream.read_exact(&mut req).await.unwrap();
        assert_eq!(&req[..2], &[3, 0]);

        // Reply with 32-bit LE BGRA: pure red + pure blue.
        stream
            .write_all(&raw_frame(0, 2, &[0, 0, 255, 0, 255, 0, 0, 0]))
            .await
            .unwrap();

        let mut sink = [0u8; 64];
        while stream.read(&mut sink).await.unwrap_or(0) > 0 {}
    });

    let id = connect(
        "127.0.0.1".into(),
        port,
        String::new(),
        String::new(),
        None,
        None,
    )
    .await
    .unwrap();
    let initial = network_stats(id).await.unwrap();
    assert_eq!(initial.transport_kind, TRANSPORT_TCP);
    assert!(initial.rtt_ms.is_some());
    assert_eq!(initial.quality_mode, QUALITY_MODE_AUTO);

    let first = next_frame(id, 0, &[255, 0, 0, 255, 0, 255, 0, 255]).await;
    assert_eq!((first.width, first.height), (2, 1));

    // Switch to Low quality -> 16-bit RGB565.
    set_quality_mode(id, QUALITY_MODE_LOW).await.unwrap();
    let low_frame = next_frame(id, first.sequence, &[0, 0, 255, 255, 255, 255, 255, 255]).await;
    let low_stats = network_stats(id).await.unwrap();
    assert_eq!(low_stats.quality_mode, QUALITY_MODE_LOW);
    assert_eq!(low_stats.quality_tier, QualityTier::Low.as_u8());

    // Switch back to High quality -> native 32-bit LE BGRA.
    set_quality_mode(id, crate::desktop_network::QUALITY_MODE_HIGH)
        .await
        .unwrap();
    let high_frame = next_frame(id, low_frame.sequence, &[255, 0, 0, 255, 0, 0, 255, 255]).await;
    assert_eq!(high_frame.rgba, [255, 0, 0, 255, 0, 0, 255, 255]);
    let high_stats = network_stats(id).await.unwrap();
    assert_eq!(
        high_stats.quality_mode,
        crate::desktop_network::QUALITY_MODE_HIGH
    );
    assert_eq!(high_stats.quality_tier, QualityTier::High.as_u8());

    disconnect(id).await;
    worker.await.unwrap();
}

#[tokio::test]
async fn vnc_extended_desktop_resize_and_bidirectional_clipboard() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let worker = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        initialize(&mut stream, 8, false).await;

        // Read initial FullRefresh (10 bytes).
        let mut req = [0u8; 10];
        stream.read_exact(&mut req).await.unwrap();

        // Advertise ExtendedDesktopSize (2x1 single screen id=7) in an update, then send 2x1 pixels.
        let mut eds = vec![0, 0, 0, 1];
        for v in [0u16, 0, 2, 1] {
            eds.extend_from_slice(&v.to_be_bytes());
        }
        eds.extend_from_slice(&(-308i32 as u32).to_be_bytes());
        eds.extend_from_slice(&[1, 0, 0, 0]); // 1 screen
        eds.extend_from_slice(&7u32.to_be_bytes()); // id=7
        for v in [0u16, 0, 2, 1] {
            eds.extend_from_slice(&v.to_be_bytes());
        }
        eds.extend_from_slice(&0u32.to_be_bytes());
        stream.write_all(&eds).await.unwrap();
        stream
            .write_all(&raw_frame(0, 2, &[0, 0, 255, 0, 0, 255, 0, 0]))
            .await
            .unwrap();

        // Expect SetDesktopSize (msg 251, 24 bytes for 1 screen) + 1px refresh (10 bytes),
        // and ClientCutText (msg 6) in either order after resize.
        let mut saw_resize = false;
        let mut saw_cut_text = false;
        while !saw_resize || !saw_cut_text {
            let kind = stream.read_u8().await.unwrap();
            match kind {
                3 => {
                    let mut body = [0u8; 9];
                    stream.read_exact(&mut body).await.unwrap();
                }
                251 => {
                    let mut header = [0u8; 7];
                    stream.read_exact(&mut header).await.unwrap();
                    let w = u16::from_be_bytes([header[1], header[2]]);
                    let h = u16::from_be_bytes([header[3], header[4]]);
                    assert_eq!((w, h), (4, 2));
                    let count = usize::from(header[5]);
                    assert_eq!(count, 1);
                    let mut screen_buf = vec![0u8; count * 16];
                    stream.read_exact(&mut screen_buf).await.unwrap();
                    // Confirm resize with reason=1 (ThisClient), status=0 (Success).
                    let mut ack = vec![0, 0, 0, 1];
                    for v in [1u16, 0, 4, 2] {
                        ack.extend_from_slice(&v.to_be_bytes());
                    }
                    ack.extend_from_slice(&(-308i32 as u32).to_be_bytes());
                    ack.extend_from_slice(&[1, 0, 0, 0]);
                    ack.extend_from_slice(&7u32.to_be_bytes());
                    for v in [0u16, 0, 4, 2] {
                        ack.extend_from_slice(&v.to_be_bytes());
                    }
                    ack.extend_from_slice(&0u32.to_be_bytes());
                    stream.write_all(&ack).await.unwrap();
                    // Send a 4x2 frame (all green in LE BGRA).
                    let mut frame = vec![0, 0, 0, 1];
                    for v in [0u16, 0, 4, 2] {
                        frame.extend_from_slice(&v.to_be_bytes());
                    }
                    frame.extend_from_slice(&0i32.to_be_bytes());
                    for _ in 0..8 {
                        frame.extend_from_slice(&[0, 255, 0, 0]);
                    }
                    stream.write_all(&frame).await.unwrap();
                    saw_resize = true;
                }
                6 => {
                    let mut pad = [0u8; 3];
                    stream.read_exact(&mut pad).await.unwrap();
                    let len = stream.read_u32().await.unwrap() as usize;
                    let mut bytes = vec![0u8; len];
                    stream.read_exact(&mut bytes).await.unwrap();
                    assert_eq!(String::from_utf8(bytes).unwrap(), "你好\nworld");

                    // First echo the exact same text (must be suppressed), then send new remote text.
                    let echo = "你好\nworld".as_bytes();
                    stream.write_all(&[3, 0, 0, 0]).await.unwrap();
                    stream.write_u32(echo.len() as u32).await.unwrap();
                    stream.write_all(echo).await.unwrap();

                    let remote = "远程剪贴板".as_bytes();
                    stream.write_all(&[3, 0, 0, 0]).await.unwrap();
                    stream.write_u32(remote.len() as u32).await.unwrap();
                    stream.write_all(remote).await.unwrap();
                    saw_cut_text = true;
                }
                other => panic!("unexpected client msg {other}"),
            }
        }

        let mut sink = [0u8; 64];
        while stream.read(&mut sink).await.unwrap_or(0) > 0 {}
    });

    let id = connect(
        "127.0.0.1".into(),
        port,
        String::new(),
        String::new(),
        None,
        None,
    )
    .await
    .unwrap();
    let first = next_frame(id, 0, &[255, 0, 0, 255, 0, 255, 0, 255]).await;
    assert_eq!((first.width, first.height), (2, 1));

    // Dynamic resize via ExtendedDesktopSize.
    assert!(resize(id, 4, 2).await.unwrap());
    let resized = next_frame(id, first.sequence, &[0, 255, 0, 255]).await;
    assert_eq!((resized.width, resized.height), (4, 2));

    // Bidirectional text clipboard with echo suppression.
    clipboard_active(id, true).await.unwrap();
    let ready = clipboard_event(id, 0).await.unwrap().unwrap();
    assert_eq!(ready.kind, 0);

    clipboard_update(id, Some("你好\r\nworld".into()))
        .await
        .unwrap();
    let remote = tokio::time::timeout(Duration::from_secs(2), async {
        let mut after = ready.sequence;
        loop {
            if let Some(ev) = clipboard_event(id, after).await.unwrap() {
                after = ev.sequence;
                if ev.kind == 1 {
                    return ev;
                }
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(remote.text.as_deref(), Some("远程剪贴板"));

    disconnect(id).await;
    worker.await.unwrap();
}
