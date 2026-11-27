use super::*;
use std::time::Duration;
use tokio::io::duplex;

fn rect_header(rect: Rect, encoding: u32) -> Vec<u8> {
    let mut bytes = vec![0, 0, 0, 1];
    for value in [rect.x, rect.y, rect.width, rect.height] {
        bytes.extend(value.to_be_bytes());
    }
    bytes.extend(encoding.to_be_bytes());
    bytes
}

#[tokio::test]
async fn oversized_initialization_is_rejected_before_payload_reads() {
    for (width, height, length) in [
        (u16::MAX, 1, 0),
        (8192, 8192, 0),
        (0, 1, 0),
        (10, 10, u32::MAX),
    ] {
        let (mut client, mut server) = duplex(256);
        server.write_u16(width).await.unwrap();
        server.write_u16(height).await.unwrap();
        server
            .write_all(&Vec::<u8>::from(PixelFormat::rgba()))
            .await
            .unwrap();
        server.write_u32(length).await.unwrap();
        let result = tokio::time::timeout(
            Duration::from_secs(1),
            read_server_init(&mut client, &mut Some(PixelFormat::rgba()), &|_| async {
                Ok(())
            }),
        )
        .await
        .unwrap();
        assert!(result.is_err());
    }
}

#[tokio::test]
async fn invalid_rectangles_and_lengths_are_rejected_before_payload_reads() {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 1,
        height: 1,
    };
    let mut copy = rect_header(rect, VncEncoding::CopyRect.into());
    copy.extend([0, 64, 0, 0]);
    let mut zrle = rect_header(rect, VncEncoding::Zrle.into());
    zrle.extend(u32::MAX.to_be_bytes());
    let mut clipboard = vec![3, 0, 0, 0];
    clipboard.extend(u32::MAX.to_be_bytes());
    for payload in [
        rect_header(rect, 12345),
        rect_header(rect, VncEncoding::Tight.into()), // not negotiated
        rect_header(Rect { x: 64, ..rect }, 0),
        rect_header(
            Rect {
                x: u16::MAX,
                ..rect
            },
            0,
        ),
        rect_header(
            Rect {
                width: u16::MAX,
                ..rect
            },
            VncEncoding::DesktopSizePseudo.into(),
        ),
        copy,
        zrle,
        clipboard,
        vec![255],
    ] {
        let (mut client, mut server) = duplex(256);
        server.write_all(&payload).await.unwrap();
        let (_stop, mut stopped) = oneshot::channel();
        let result = tokio::time::timeout(
            Duration::from_secs(1),
            asycn_vnc_read_loop(
                &mut client,
                &PixelFormat::rgba(),
                &|_| async { Ok(()) },
                &mut stopped,
                &[
                    VncEncoding::Raw,
                    VncEncoding::CopyRect,
                    VncEncoding::Zrle,
                    VncEncoding::DesktopSizePseudo,
                ],
                &AtomicU32::new(pack_screen((64, 64))),
                &DesktopState::default(),
            ),
        )
        .await
        .unwrap();
        assert!(result.is_err());
    }
}

#[tokio::test]
async fn raw_is_implicit_and_resize_changes_decoder_bounds() {
    let mut bytes = rect_header(
        Rect {
            x: 0,
            y: 0,
            width: 128,
            height: 96,
        },
        VncEncoding::DesktopSizePseudo.into(),
    );
    bytes.extend(rect_header(
        Rect {
            x: 127,
            y: 95,
            width: 1,
            height: 1,
        },
        0,
    ));
    bytes.extend([1, 2, 3, 255]);
    let output = std::sync::Mutex::new(Vec::new());
    let (_stop, mut stopped) = oneshot::channel();
    let result = asycn_vnc_read_loop(
        &mut bytes.as_slice(),
        &PixelFormat::rgba(),
        &|event| {
            output.lock().unwrap().push(event);
            async { Ok(()) }
        },
        &mut stopped,
        &[VncEncoding::DesktopSizePseudo],
        &AtomicU32::new(pack_screen((64, 64))),
        &DesktopState::default(),
    )
    .await;
    assert!(matches!(result, Err(VncError::IoError(_))));
    let output = output.into_inner().unwrap();
    assert!(
        matches!(&output[0], VncEvent::SetResolution(size) if (size.width, size.height) == (128, 96))
    );
    assert!(
        matches!(&output[1], VncEvent::RawImage(rect, bytes) if (rect.x, rect.y) == (127, 95) && bytes == &[1, 2, 3, 255])
    );
}

#[tokio::test]
async fn shutdown_interrupts_a_full_event_queue() {
    let (events, mut received) = channel(OUTPUT_CHANNEL_SIZE);
    for _ in 0..OUTPUT_CHANNEL_SIZE {
        events.try_send(VncEvent::Bell).unwrap();
    }
    let calls = std::cell::Cell::new(0);
    let output = |event| {
        calls.set(calls.get() + 1);
        events.send(event)
    };
    let (stop, mut stopped) = oneshot::channel();
    let mut input = &[2_u8][..];
    let format = PixelFormat::rgba();
    let deliver = |event| {
        let send = output(event);
        async {
            send.await?;
            Ok(())
        }
    };
    let screen = AtomicU32::new(pack_screen((1, 1)));
    let desktop = DesktopState::default();
    let task = asycn_vnc_read_loop(
        &mut input,
        &format,
        &deliver,
        &mut stopped,
        &[],
        &screen,
        &desktop,
    );
    tokio::pin!(task);
    assert!(futures::poll!(task.as_mut()).is_pending());
    assert_eq!(calls.get(), 1);
    assert_eq!(events.capacity(), 0);
    stop.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .unwrap()
        .unwrap();
    for _ in 0..OUTPUT_CHANNEL_SIZE {
        assert!(matches!(received.try_recv(), Ok(VncEvent::Bell)));
    }
    assert!(received.try_recv().is_err());
}

#[tokio::test]
async fn full_bridge_resumes_without_unrelated_input_and_cancels_promptly() {
    for cancel in [false, true] {
        let (client, mut server) = duplex(1);
        let (_input, input) = channel(INPUT_CHANNEL_SIZE);
        let (bridge, mut packets) = channel(2);
        for _ in 0..2 {
            bridge.try_send(Ok(vec![0])).unwrap();
        }
        let (stop, stopped) = oneshot::channel();
        server.write_all(&[7]).await.unwrap();
        let task = async_connection_process_loop(client, input, bridge, stopped);
        tokio::pin!(task);
        assert!(futures::poll!(task.as_mut()).is_pending());
        // The network byte was consumed while every bridge slot remains occupied.
        assert_eq!(packets.len(), 2);
        assert!(futures::poll!(Box::pin(server.write_all(&[8]))).is_ready());
        if !cancel {
            assert_eq!(packets.recv().await.unwrap().unwrap(), [0]);
            assert!(futures::poll!(task.as_mut()).is_pending());
            assert_eq!(packets.recv().await.unwrap().unwrap(), [0]);
            assert_eq!(packets.recv().await.unwrap().unwrap(), [7]);
        }
        stop.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        let mut byte = [0];
        assert_eq!(server.read(&mut byte).await.unwrap(), 0);
    }
}

#[tokio::test]
async fn shutdown_interrupts_a_blocked_socket_write() {
    let (client, mut server) = duplex(1);
    let (input, input_rx) = channel(INPUT_CHANNEL_SIZE);
    let (bridge, _packets) = channel(NETWORK_CHANNEL_SIZE);
    let (stop, stopped) = oneshot::channel();
    input
        .send(ClientMsg::ClientCutText("test".into()))
        .await
        .unwrap();
    let task = async_connection_process_loop(client, input_rx, bridge, stopped);
    tokio::pin!(task);
    assert!(futures::poll!(task.as_mut()).is_pending());
    assert_eq!(input.capacity(), INPUT_CHANNEL_SIZE);
    assert_eq!(server.read_u8().await.unwrap(), 6); // first byte of ClientCutText
    stop.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
}

#[tokio::test]
async fn decoder_exit_releases_an_idle_socket() {
    let (client, mut server) = duplex(1);
    let (_input, input) = channel(INPUT_CHANNEL_SIZE);
    let (bridge, packets) = channel(NETWORK_CHANNEL_SIZE);
    let (_stop, stopped) = oneshot::channel();
    let task = async_connection_process_loop(client, input, bridge, stopped);
    tokio::pin!(task);
    assert!(futures::poll!(task.as_mut()).is_pending());
    drop(packets);
    tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
}

#[tokio::test]
async fn full_input_queue_does_not_hold_the_client_lock_during_close() {
    let (input_ch, mut input) = channel(INPUT_CHANNEL_SIZE);
    for _ in 0..INPUT_CHANNEL_SIZE {
        input_ch
            .try_send(ClientMsg::ClientCutText(String::new()))
            .unwrap();
    }
    let (_events, output_ch) = channel(OUTPUT_CHANNEL_SIZE);
    let (network_stop, network_stopped) = oneshot::channel();
    let (decoder_stop, decoder_stopped) = oneshot::channel();
    let desktop = Arc::new(DesktopState::default());
    let screen = Arc::new(AtomicU32::new(pack_screen((1, 1))));
    let pixel_format = Arc::new(std::sync::Mutex::new(PixelFormat::rgba()));
    let closed = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(std::sync::Mutex::new(StopHandles {
        decoding_stop: Some(decoder_stop),
        net_conn_stop: Some(network_stop),
    }));
    let client = VncClient {
        screen: Arc::clone(&screen),
        pixel_format: Arc::clone(&pixel_format),
        closed: Arc::clone(&closed),
        stop: Arc::clone(&stop),
        desktop: Arc::clone(&desktop),
        input_ch: input_ch.clone(),
        inner: Arc::new(Mutex::new(VncInner {
            name: String::new(),
            screen,
            pixel_format,
            desktop,
            input_ch,
            output_ch,
            stop,
            closed,
        })),
        is_apple_server: false,
    };
    let pending = client.input(X11Event::Refresh);
    tokio::pin!(pending);
    assert!(futures::poll!(pending.as_mut()).is_pending());
    tokio::time::timeout(Duration::from_secs(1), client.close())
        .await
        .unwrap()
        .unwrap();
    network_stopped.await.unwrap();
    decoder_stopped.await.unwrap();
    // Even if capacity becomes available during close, no stale input is queued.
    input.recv().await.unwrap();
    assert!(matches!(pending.await, Err(VncError::ClientNotRunning)));
    assert_eq!(input.len(), INPUT_CHANNEL_SIZE - 1);
}

#[tokio::test]
async fn emits_frame_complete_and_coalesces_batch_inputs_without_client_lock() {
    let (stream, mut server) = duplex(4096);
    server.write_u16(2).await.unwrap();
    server.write_u16(1).await.unwrap();
    server
        .write_all(&Vec::<u8>::from(PixelFormat::rgba()))
        .await
        .unwrap();
    server.write_u32(0).await.unwrap();

    let client = VncClient::new_with_options(
        stream,
        true,
        Some(PixelFormat::rgba()),
        vec![VncEncoding::Raw],
        true,
        false,
        true,
        Some(32),
    )
    .await
    .unwrap();
    // ClientInit (1) + SetEncodings (8) + initial FramebufferUpdateRequest (10).
    let mut init = [0u8; 19];
    server.read_exact(&mut init).await.unwrap();

    // Send a 1-rect FramebufferUpdate followed by a 0-rect FramebufferUpdate.
    let mut frame = rect_header(
        Rect {
            x: 0,
            y: 0,
            width: 1,
            height: 1,
        },
        0,
    );
    frame.extend_from_slice(&[10, 20, 30, 255]);
    frame.extend_from_slice(&[0, 0, 0, 0]);
    server.write_all(&frame).await.unwrap();

    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::SetResolution(_)
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::SetPixelFormat(_)
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::RawImage(_, _)
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::FrameComplete
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::FrameComplete
    ));

    // Queue input_batch while another future is actively waiting on recv_event()
    // (which holds self.inner.lock()).
    let recv_client = client.clone();
    let waiter = tokio::spawn(async move { recv_client.recv_event().await });
    tokio::task::yield_now().await;

    client
        .input_batch([
            X11Event::PointerEvent((1, 0, 0).into()),
            X11Event::KeyEvent((0x0061, true).into()),
            X11Event::KeyEvent((0x0061, false).into()),
        ])
        .await
        .unwrap();
    let mut received = [0u8; 6 + 8 + 8];
    tokio::time::timeout(Duration::from_secs(1), server.read_exact(&mut received))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&received[..6], &[5, 0, 0, 1, 0, 0]);
    assert_eq!(&received[6..14], &[4, 1, 0, 0, 0, 0, 0, 0x61]);
    assert_eq!(&received[14..22], &[4, 0, 0, 0, 0, 0, 0, 0x61]);

    client.close().await.unwrap();
    assert!(matches!(
        waiter.await.unwrap(),
        Err(VncError::ClientNotRunning)
    ));
}

#[tokio::test]
async fn set_pixel_format_switches_between_32bit_and_rgb565_cleanly() {
    let (stream, mut server) = duplex(4096);
    server.write_u16(2).await.unwrap();
    server.write_u16(1).await.unwrap();
    server
        .write_all(&Vec::<u8>::from(PixelFormat::rgba()))
        .await
        .unwrap();
    server.write_u32(0).await.unwrap();

    let client = VncClient::new_with_options(
        stream,
        true,
        Some(PixelFormat::rgba()),
        vec![VncEncoding::Raw, VncEncoding::CursorPseudo],
        true,
        false,
        true,
        Some(32),
    )
    .await
    .unwrap();
    // ClientInit (1) + SetEncodings (12) + initial FramebufferUpdateRequest (10).
    let mut init = [0u8; 23];
    server.read_exact(&mut init).await.unwrap();

    // First frame in 32-bit RGBA.
    let mut frame32 = rect_header(
        Rect {
            x: 0,
            y: 0,
            width: 2,
            height: 1,
        },
        0,
    );
    frame32.extend_from_slice(&[255, 0, 0, 255, 0, 255, 0, 255]);
    server.write_all(&frame32).await.unwrap();

    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::SetResolution(_)
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::SetPixelFormat(pf) if pf.bits_per_pixel == 32
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::RawImage(_, bytes) if bytes.len() == 8
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::FrameComplete
    ));

    // Switch to 16-bit RGB565 and request a full refresh.
    client
        .set_pixel_format(PixelFormat::rgb565())
        .await
        .unwrap();
    client.input(X11Event::FullRefresh).await.unwrap();
    let mut req = [0u8; 20 + 10];
    server.read_exact(&mut req).await.unwrap();
    assert_eq!(req[0], 0); // SetPixelFormat
    assert_eq!(req[4], 16); // bits_per_pixel = 16
    assert_eq!(&req[20..22], &[3, 0]); // FullRefresh

    // Server sends 16-bit RGB565 raw rect (red = 0xF800, blue = 0x001F) + 1x1 16-bit cursor.
    let mut frame16 = vec![0, 0, 0, 2]; // 2 rects
    for value in [0u16, 0, 2, 1] {
        frame16.extend_from_slice(&value.to_be_bytes());
    }
    frame16.extend_from_slice(&0u32.to_be_bytes()); // Raw
    frame16.extend_from_slice(&0xF800u16.to_le_bytes());
    frame16.extend_from_slice(&0x001Fu16.to_le_bytes());
    for value in [0u16, 0, 1, 1] {
        frame16.extend_from_slice(&value.to_be_bytes());
    }
    frame16.extend_from_slice(&u32::from(VncEncoding::CursorPseudo).to_be_bytes());
    frame16.extend_from_slice(&0x07E0u16.to_le_bytes()); // pure green in RGB565
    frame16.push(0x80); // opaque mask bit
    server.write_all(&frame16).await.unwrap();

    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::SetPixelFormat(pf) if pf == PixelFormat::rgb565()
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::RawImage(_, bytes) if bytes == [0x00, 0xF8, 0x1F, 0x00]
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::SetCursor(_, bytes) if bytes == [0, 255, 0, 255]
    ));
    assert!(matches!(
        client.recv_event().await.unwrap(),
        VncEvent::FrameComplete
    ));
    client.close().await.unwrap();
}
