use super::*;
use serde_json::{json, Value};
use tokio::sync::mpsc;

struct Service {
    address: std::net::SocketAddr,
    task: JoinHandle<()>,
}
impl Drop for Service {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn echo(ipv6: bool) -> (Service, mpsc::UnboundedReceiver<()>) {
    let listener = TcpListener::bind(if ipv6 { "[::1]:0" } else { "127.0.0.1:0" })
        .await
        .unwrap();
    let address = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::unbounded_channel();
    let task = tokio::spawn(async move {
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                socket = listener.accept() => {
                    let (mut socket, _) = socket.unwrap();
                    let _ = tx.send(());
                    connections.spawn(async move {
                        let (mut reader, mut writer) = socket.split();
                        let _ = tokio::io::copy(&mut reader, &mut writer).await;
                    });
                }
                _ = connections.join_next(), if !connections.is_empty() => {},
            }
        }
    });
    (Service { address, task }, rx)
}

type HttpRequest = (String, String, String, bool, bool);
async fn origin() -> (Service, mpsc::UnboundedReceiver<HttpRequest>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::unbounded_channel();
    let task = tokio::spawn(async move {
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                socket = listener.accept() => {
                    let (socket, _) = socket.unwrap();
                    let tx = tx.clone();
                    connections.spawn(async move {
                        let _ = hyper::server::conn::http1::Builder::new()
                            .serve_connection(TokioIo::new(socket), service_fn(move |req: Request<Incoming>| {
                                let tx = tx.clone();
                                async move {
                                    let path = req.uri().to_string();
                                    let host = req.headers()[HOST].to_str().unwrap().to_owned();
                                    let auth = req.headers().contains_key("proxy-authorization");
                                    let hop = req.headers().contains_key("x-private");
                                    let body = req.into_body().collect().await.unwrap().to_bytes();
                                    tx.send((path, host, String::from_utf8(body.to_vec()).unwrap(), auth, hop)).unwrap();
                                    Ok::<_, Infallible>(Response::builder()
                                        .header("connection", "x-private")
                                        .header("x-private", "secret")
                                        .body(Full::new(Bytes::from_static(b"origin response"))).unwrap())
                                }
                            })).await;
                    });
                }
                _ = connections.join_next(), if !connections.is_empty() => {},
            }
        }
    });
    (Service { address, task }, rx)
}

async fn port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn unavailable_page(server_port: u16) -> PageGateway {
    PageGateway {
        server_host: "127.0.0.1".into(),
        server_port,
        client_id: "test".into(),
        token: "test-only".into(),
        server_fingerprint: String::new(),
    }
}

fn config(port: u16, mode: &str, rules: Value) -> String {
    json!({"mode":mode, "httpEnabled":true, "httpPort":port,
        "httpsEnabled":true, "httpsPort":port, "socks5Enabled":true,
        "socks5Port":port, "rules":rules})
    .to_string()
}

async fn header(socket: &mut TcpStream) -> String {
    timeout(Duration::from_secs(3), async {
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            bytes.push(socket.read_u8().await.unwrap());
            assert!(bytes.len() < 32768);
        }
        String::from_utf8(bytes).unwrap()
    })
    .await
    .unwrap()
}

async fn http_request(port: u16, target: &str) -> String {
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    socket
        .write_all(
            format!("GET http://{target}/ HTTP/1.1\r\nHost: {target}\r\nConnection: close\r\n\r\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    header(&mut socket).await
}

async fn tunnel(port: u16, target: &str) -> TcpStream {
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    socket
        .write_all(format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").as_bytes())
        .await
        .unwrap();
    assert!(header(&mut socket).await.starts_with("HTTP/1.1 200"));
    socket
}

async fn socks_connect(port: u16, host: &str, target_port: u16) -> TcpStream {
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    socket.write_all(&[5, 2, 2, 0]).await.unwrap();
    let mut method = [0; 2];
    socket.read_exact(&mut method).await.unwrap();
    assert_eq!(method, [5, 0]);
    let mut request = vec![5, 1, 0];
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            request.push(1);
            request.extend(ip.octets());
        }
        Ok(IpAddr::V6(ip)) => {
            request.push(4);
            request.extend(ip.octets());
        }
        Err(_) => {
            request.extend([3, host.len() as u8]);
            request.extend(host.as_bytes());
        }
    }
    request.extend(target_port.to_be_bytes());
    socket.write_all(&request).await.unwrap();
    let mut reply = [0; 10];
    socket.read_exact(&mut reply).await.unwrap();
    assert_eq!(&reply[..2], &[5, 0]);
    socket
}

async fn echo_bytes(socket: &mut TcpStream) {
    let bytes = [0x16, 3, 1, 0, 5, 0xff, 0x00, 0x80];
    socket.write_all(&bytes).await.unwrap();
    let mut returned = [0; 8];
    timeout(Duration::from_secs(3), socket.read_exact(&mut returned))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(returned, bytes);
}

fn rule(kind: RuleType, value: &str) -> Rule {
    Rule::parse(RuleSpec {
        kind,
        value: value.into(),
    })
    .unwrap()
}

#[tokio::test]
async fn proxy_rules_cover_ipv4_ipv6_cidr_and_domain_boundaries() {
    let router = Router::new(
        Mode::Rule,
        [
            rule(RuleType::Ip, "10.0.7.4/16"),
            rule(RuleType::Ip, "2001:db8::/32"),
            rule(RuleType::Ip, "192.0.2.4"),
            rule(RuleType::Ip, "::1/128"),
            rule(RuleType::DomainExact, "EXACT.internal."),
            rule(RuleType::DomainPrefix, "api."),
            rule(RuleType::DomainSuffix, "example.com"),
        ],
        None,
    );
    for host in [
        "10.0.255.255",
        "2001:db8:abcd::1",
        "192.0.2.4",
        "::1",
        "EXACT.INTERNAL.",
        "api.private",
        "example.com",
        "sub.EXAMPLE.COM.",
    ] {
        assert!(
            matches!(router.route(host, 443).await.unwrap(), Route::Gateway),
            "{host}"
        );
    }
    for host in ["10.1.0.1", "2001:db9::1", "192.0.2.5", "::2"] {
        assert!(
            matches!(router.route(host, 443).await.unwrap(), Route::Direct),
            "{host}"
        );
    }
    for host in [
        "evilexample.com",
        "example.com.evil",
        "api-evil.test",
        "sub.exact.internal",
    ] {
        assert!(!router.current_routing().rules.domain_matches(host));
    }
    for value in ["10.0.0.0/33", "::/129", "256.0.0.1", "10.1/8", "::1%lo0"] {
        assert!(Rule::parse(RuleSpec {
            kind: RuleType::Ip,
            value: value.into()
        })
        .is_err());
    }
    let router = Router::new(
        Mode::Rule,
        [rule(RuleType::Ip, "127.0.0.0/8"), rule(RuleType::Ip, "::1")],
        None,
    );
    assert!(matches!(
        router.route("localhost", 80).await.unwrap(),
        Route::Gateway
    ));
}

#[tokio::test]
async fn direct_proxy_dials_the_same_addresses_it_used_for_ip_rules() {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let address = listener.local_addr().unwrap();
    let router = Router::new(
        Mode::Rule,
        [
            rule(RuleType::Ip, "192.0.2.0/24"),
            rule(RuleType::DomainSuffix, "gateway.invalid"),
        ],
        None,
    );
    router.dns.put(
        "direct.invalid".into(),
        Arc::new([address.ip()]),
        Instant::now() + DNS_TTL,
    );
    // Only the cached addresses can reach this server. Resolving the original
    // host again would fail rather than connecting to the listener.
    let mut stream = router
        .connect("direct.invalid", address.port(), TrafficKind::Https)
        .await
        .unwrap();
    stream.write_all(b"OK").await.unwrap();
    let (mut peer, _) = listener.accept().await.unwrap();
    let mut bytes = [0; 2];
    peer.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"OK");
    // Cache is keyed by hostname only, so querying another port reuses the same IP.
    let other_port = address.port().wrapping_add(1).max(1);
    let reused = router.resolve("DIRECT.INVALID.", other_port).await.unwrap();
    assert_eq!(
        reused.as_ref(),
        &[SocketAddr::new(address.ip(), other_port)]
    );
    assert!(matches!(
        router
            .route("device.gateway.invalid", address.port())
            .await
            .unwrap(),
        Route::Gateway
    ));
}

#[tokio::test]
async fn proxy_modes_require_a_gateway_and_legacy_direct_uses_rules() {
    let port = port().await;
    for mode in ["global", "rule", "direct"] {
        let settings = config(port, mode, json!([]));
        let parsed: Config = serde_json::from_str(&settings).unwrap();
        if mode == "direct" {
            assert!(matches!(parsed.mode, Mode::Rule));
        }
        let error = start(&settings, None, None).await.err().unwrap();
        assert!(error.to_string().contains("所选网关不可用"));
    }
}

#[tokio::test]
async fn proxy_http_streams_chunked_uploads_preserves_host_and_keepalive() {
    let (origin, mut requests) = origin().await;
    let port = port().await;
    let proxy = start(
        &config(port, "rule", json!([])),
        None,
        Some(unavailable_page(1)),
    )
    .await
    .unwrap();
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    for path in ["/upload?q=1", "/again"] {
        socket.write_all(format!("POST http://{}{path} HTTP/1.1\r\nHost: wrong.test\r\nTransfer-Encoding: chunked\r\nProxy-Authorization: secret\r\nConnection: x-private\r\nX-Private: secret\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n", origin.address).as_bytes()).await.unwrap();
        let headers = header(&mut socket).await.to_ascii_lowercase();
        assert!(headers.starts_with("http/1.1 200"));
        assert!(!headers.contains("x-private"));
        let mut body = [0; 15];
        socket.read_exact(&mut body).await.unwrap();
        assert_eq!(&body, b"origin response");
        let (seen_path, host, body, auth, hop) = requests.recv().await.unwrap();
        assert_eq!(seen_path, path);
        assert_eq!(host, origin.address.to_string());
        assert_eq!(body, "abcde");
        assert!(!auth);
        assert!(!hop);
    }
    let (sent, received) = proxy.traffic();
    assert!(sent > 2 * b"abcde".len() as u64);
    assert!(received > 2 * b"origin response".len() as u64);
    proxy.stop().await;
}

#[tokio::test]
async fn proxy_connect_preserves_early_tls_bytes_and_half_close() {
    let (echo, _) = echo(false).await;
    let port = port().await;
    let proxy = start(
        &config(port, "rule", json!([])),
        None,
        Some(unavailable_page(1)),
    )
    .await
    .unwrap();
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    let mut request = format!(
        "CONNECT {} HTTP/1.1\r\nHost: {}\r\n\r\n",
        echo.address, echo.address
    )
    .into_bytes();
    request.extend([0x16, 3, 1, 0, 5, 0xff]);
    socket.write_all(&request).await.unwrap();
    assert!(header(&mut socket).await.starts_with("HTTP/1.1 200"));
    socket.shutdown().await.unwrap();
    let mut echoed = Vec::new();
    timeout(Duration::from_secs(3), socket.read_to_end(&mut echoed))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(echoed, [0x16, 3, 1, 0, 5, 0xff]);
    assert_eq!(proxy.traffic(), (6, 6));
    proxy.stop().await;
}

#[tokio::test]
async fn proxy_socks_accepts_domain_ipv4_ipv6_and_rejects_unsupported_commands() {
    let (v4, _) = echo(false).await;
    let (v6, _) = echo(true).await;
    let port = port().await;
    let proxy = start(
        &config(port, "rule", json!([])),
        None,
        Some(unavailable_page(1)),
    )
    .await
    .unwrap();
    for (host, target) in [
        ("127.0.0.1", v4.address.port()),
        ("localhost", v4.address.port()),
        ("::1", v6.address.port()),
    ] {
        let mut socket = socks_connect(port, host, target).await;
        echo_bytes(&mut socket).await;
    }
    assert_eq!(proxy.traffic(), (24, 24));
    for (command, address_type, expected) in [(2, 1, 7), (3, 1, 7), (1, 7, 8)] {
        let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap();
        socket
            .write_all(&[5, 1, 0, 5, command, 0, address_type])
            .await
            .unwrap();
        let mut reply = [0; 12];
        socket.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply[..4], &[5, 0, 5, expected]);
    }
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    socket.write_all(&[5, 1, 2]).await.unwrap();
    let mut reply = [0; 2];
    socket.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply, [5, 255]);
    proxy.stop().await;
}

#[tokio::test]
async fn proxy_global_and_matching_rules_never_fallback_to_direct() {
    let (echo, mut connections) = echo(false).await;
    let proxy_port = port().await;
    let closed_relay_port = port().await;
    for (mode, rules) in [
        ("global", json!([])),
        ("rule", json!([{"type":"ip", "value":"127.0.0.0/8"}])),
    ] {
        let proxy = start(
            &config(proxy_port, mode, rules),
            None,
            Some(unavailable_page(closed_relay_port)),
        )
        .await
        .unwrap();
        assert!(http_request(proxy_port, &echo.address.to_string())
            .await
            .starts_with("HTTP/1.1 502"));
        assert!(connections.try_recv().is_err());
        proxy.stop().await;
    }
    for (mode, rules) in [
        ("rule", json!([])),
        ("rule", json!([{"type":"ip", "value":"10.0.0.0/8"}])),
    ] {
        let proxy = start(
            &config(proxy_port, mode, rules),
            None,
            Some(unavailable_page(closed_relay_port)),
        )
        .await
        .unwrap();
        let mut socket = tunnel(proxy_port, &echo.address.to_string()).await;
        echo_bytes(&mut socket).await;
        assert!(connections.recv().await.is_some());
        proxy.stop().await;
    }
}

#[tokio::test]
async fn proxy_bind_failure_rolls_back_and_stop_cancels_active_and_pending_connections() {
    let first = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let second = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (free, busy) = if first.local_addr().unwrap().port() < second.local_addr().unwrap().port() {
        (first, second)
    } else {
        (second, first)
    };
    let free_port = free.local_addr().unwrap().port();
    let busy_port = busy.local_addr().unwrap().port();
    drop(free);
    let settings = json!({"mode":"rule", "httpPort":free_port, "httpsPort":busy_port});
    assert!(
        start(&settings.to_string(), None, Some(unavailable_page(1)))
            .await
            .is_err()
    );
    drop(
        TcpListener::bind((Ipv4Addr::LOCALHOST, free_port))
            .await
            .unwrap(),
    );
    drop(busy);

    let (echo, _) = echo(false).await;
    let proxy = start(
        &config(free_port, "rule", json!([])),
        None,
        Some(unavailable_page(1)),
    )
    .await
    .unwrap();
    let mut active = tunnel(free_port, &echo.address.to_string()).await;
    let mut pending = TcpStream::connect((Ipv4Addr::LOCALHOST, free_port))
        .await
        .unwrap();
    pending.write_all(b"GET ").await.unwrap();
    timeout(Duration::from_secs(1), proxy.stop()).await.unwrap();
    assert_eq!(active.read(&mut [0]).await.unwrap(), 0);
    match pending.read(&mut [0]).await {
        Ok(n) => assert_eq!(n, 0),
        Err(e) => assert_eq!(e.kind(), std::io::ErrorKind::ConnectionReset),
    }
    drop(
        TcpListener::bind((Ipv4Addr::LOCALHOST, free_port))
            .await
            .unwrap(),
    );

    let relay = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let gateway = PageGateway {
        server_host: "127.0.0.1".into(),
        server_port: relay.local_addr().unwrap().port(),
        client_id: "test".into(),
        token: "test-only".into(),
        server_fingerprint: String::new(),
    };
    let proxy = start(&config(free_port, "global", json!([])), None, Some(gateway))
        .await
        .unwrap();
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, free_port))
        .await
        .unwrap();
    socket
        .write_all(b"CONNECT internal.test:443 HTTP/1.1\r\nHost: internal.test:443\r\n\r\n")
        .await
        .unwrap();
    let (_stalled, _) = timeout(Duration::from_secs(1), relay.accept())
        .await
        .unwrap()
        .unwrap();
    timeout(Duration::from_secs(1), proxy.stop()).await.unwrap();
    assert_eq!(socket.read(&mut [0]).await.unwrap(), 0);
    drop(
        TcpListener::bind((Ipv4Addr::LOCALHOST, free_port))
            .await
            .unwrap(),
    );
}

#[tokio::test]
async fn proxy_protocol_toggles_and_destination_validation_are_enforced() {
    let port = port().await;
    let settings =
        json!({"mode":"rule", "httpEnabled":false, "httpsEnabled":true, "httpsPort":port});
    let proxy = start(&settings.to_string(), None, Some(unavailable_page(1)))
        .await
        .unwrap();
    assert!(http_request(port, "127.0.0.1:1")
        .await
        .starts_with("HTTP/1.1 403"));
    proxy.stop().await;
    let settings = json!({"mode":"rule", "httpPort":port, "httpsEnabled":false});
    let proxy = start(&settings.to_string(), None, Some(unavailable_page(1)))
        .await
        .unwrap();
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    socket
        .write_all(b"CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: local\r\n\r\n")
        .await
        .unwrap();
    assert!(header(&mut socket).await.starts_with("HTTP/1.1 403"));
    proxy.stop().await;
    assert!(authority(&"http://host:bad/".parse().unwrap(), Some(80)).is_err());
    assert!(authority(&"host:0".parse().unwrap(), None).is_err());
    assert!(authority(&"http://user@host/".parse().unwrap(), Some(80)).is_err());
    assert_eq!(
        authority(&"[::1]:443".parse().unwrap(), None).unwrap(),
        ("::1".into(), 443)
    );
}

#[tokio::test]
async fn proxy_api_wait_and_stop_release_registry_and_ports() {
    let port = port().await;
    let id = crate::api::proxy::proxy_start(
        config(port, "rule", json!([])),
        None,
        Some(unavailable_page(1)),
    )
    .await
    .unwrap();
    let waiting = tokio::spawn(crate::api::proxy::proxy_wait(id));
    crate::api::proxy::proxy_stop(id).await.unwrap();
    assert!(waiting.await.unwrap().unwrap().is_none());
    crate::api::proxy::proxy_stop(id).await.unwrap();
    drop(
        TcpListener::bind((Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap(),
    );
}

#[tokio::test]
async fn proxy_traffic_is_isolated_and_restarts_at_zero() {
    use crate::api::proxy::{proxy_start, proxy_stop, proxy_traffic};

    let (echo, _) = echo(false).await;
    let first_port = port().await;
    let settings = config(first_port, "rule", json!([]));
    let first = proxy_start(settings.clone(), None, Some(unavailable_page(1)))
        .await
        .unwrap();
    let other_port = port().await;
    let other = proxy_start(
        config(other_port, "rule", json!([])),
        None,
        Some(unavailable_page(1)),
    )
    .await
    .unwrap();

    let mut socket = tunnel(first_port, &echo.address.to_string()).await;
    echo_bytes(&mut socket).await;
    let active = proxy_traffic(first).await.unwrap();
    assert_eq!((active.sent, active.received), (8, 8));
    let idle = proxy_traffic(other).await.unwrap();
    assert_eq!((idle.sent, idle.received), (0, 0));

    proxy_stop(first).await.unwrap();
    assert!(proxy_traffic(first).await.is_none());
    let restarted = proxy_start(settings, None, Some(unavailable_page(1)))
        .await
        .unwrap();
    let fresh = proxy_traffic(restarted).await.unwrap();
    assert_eq!((fresh.sent, fresh.received), (0, 0));
    proxy_stop(restarted).await.unwrap();
    proxy_stop(other).await.unwrap();
}

#[tokio::test]
async fn proxy_rejects_missing_ssh_gateway_and_classifies_transient_accept_errors() {
    let port = port().await;
    let err = start(&config(port, "rule", json!([])), Some(u32::MAX), None)
        .await
        .err()
        .unwrap();
    assert!(err.to_string().contains("网关连接不存在或已关闭"));
    for kind in [
        std::io::ErrorKind::ConnectionAborted,
        std::io::ErrorKind::ConnectionReset,
        std::io::ErrorKind::Interrupted,
        std::io::ErrorKind::WouldBlock,
        std::io::ErrorKind::TimedOut,
    ] {
        assert!(is_transient_accept_error(&std::io::Error::from(kind)));
    }
    assert!(!is_transient_accept_error(&std::io::Error::from(
        std::io::ErrorKind::PermissionDenied,
    )));
    assert!(!is_transient_accept_error(&std::io::Error::from(
        std::io::ErrorKind::InvalidInput,
    )));
}

#[tokio::test]
async fn dns_cache_is_port_agnostic_evicts_lru_and_deduplicates_in_flight() {
    let cache = DnsCache::default();
    let expires = Instant::now() + DNS_TTL;
    for i in 0..DNS_CACHE_LIMIT {
        cache.put(
            format!("host-{i}.invalid"),
            Arc::new([IpAddr::V4(Ipv4Addr::new(192, 0, 2, (i % 250) as u8))]),
            expires,
        );
    }
    // Touch host-0 so host-1 becomes the least recently used entry.
    let touched = cache.resolve("HOST-0.INVALID.", 8080).await.unwrap();
    assert_eq!(
        touched.as_ref(),
        &[SocketAddr::new(
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 0)),
            8080
        )]
    );
    let other_port = cache.resolve("host-0.invalid", 9090).await.unwrap();
    assert_eq!(
        other_port.as_ref(),
        &[SocketAddr::new(
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 0)),
            9090
        )]
    );

    cache.put(
        "newest.invalid".into(),
        Arc::new([IpAddr::V4(Ipv4Addr::new(198, 51, 100, 1))]),
        expires,
    );
    {
        let state = cache.state.lock().unwrap();
        assert_eq!(state.entries.len(), DNS_CACHE_LIMIT);
        assert!(state.entries.contains_key("host-0.invalid"));
        assert!(!state.entries.contains_key("host-1.invalid"));
        assert!(state.entries.contains_key("newest.invalid"));
    }

    let (first, second) = tokio::join!(
        cache.resolve("localhost", 80),
        cache.resolve("LOCALHOST.", 443),
    );
    let first = first.unwrap();
    let second = second.unwrap();
    assert!(!first.is_empty());
    assert_eq!(first.len(), second.len());
    assert!(first.iter().all(|addr| addr.port() == 80));
    assert!(second.iter().all(|addr| addr.port() == 443));
    assert_eq!(
        first.iter().map(SocketAddr::ip).collect::<Vec<_>>(),
        second.iter().map(SocketAddr::ip).collect::<Vec<_>>(),
    );
}

#[tokio::test]
async fn happy_eyeballs_interleaves_families_and_falls_back_to_reachable_address() {
    let v6_a: SocketAddr = "[2001:db8::1]:443".parse().unwrap();
    let v6_b: SocketAddr = "[2001:db8::2]:443".parse().unwrap();
    let v4_a: SocketAddr = "192.0.2.1:443".parse().unwrap();
    let v4_b: SocketAddr = "192.0.2.2:443".parse().unwrap();
    assert_eq!(
        interleave_addresses(&[v6_a, v6_b, v4_a, v4_b]),
        vec![v6_a, v4_a, v6_b, v4_b]
    );
    assert_eq!(
        interleave_addresses(&[v4_a, v4_b, v6_a]),
        vec![v4_a, v6_a, v4_b]
    );

    let closed_port = port().await;
    let dead = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), closed_port);
    let (echo, _) = echo(false).await;
    let mut stream = connect_happy_eyeballs(&[dead, echo.address]).await.unwrap();
    echo_bytes(&mut stream).await;
}

async fn http_get_status_and_body(port: u16, target: &str, path: &str) -> (String, String) {
    let mut socket = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    socket
        .write_all(
            format!(
                "GET http://{target}{path} HTTP/1.1\r\nHost: {target}\r\nConnection: close\r\n\r\n"
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let headers = header(&mut socket).await;
    let mut body = Vec::new();
    timeout(Duration::from_secs(3), socket.read_to_end(&mut body))
        .await
        .unwrap()
        .unwrap();
    (headers, String::from_utf8(body).unwrap())
}

#[tokio::test]
async fn proxy_hot_reload_updates_mode_and_rules_without_dropping_active_tunnels() {
    use crate::api::proxy::{proxy_start, proxy_stop, proxy_update_rules};

    let (echo, _) = echo(false).await;
    let (origin, _requests) = origin().await;
    let proxy_port = port().await;
    let closed_relay_port = port().await;

    let id = proxy_start(
        config(proxy_port, "rule", json!([])),
        None,
        Some(unavailable_page(closed_relay_port)),
    )
    .await
    .unwrap();

    // Establish an active CONNECT tunnel before hot-reloading.
    let mut active_tunnel = tunnel(proxy_port, &echo.address.to_string()).await;
    echo_bytes(&mut active_tunnel).await;

    // Direct HTTP succeeds and populates the upstream HTTP pool.
    let (status, body) =
        http_get_status_and_body(proxy_port, &origin.address.to_string(), "/before").await;
    assert!(status.starts_with("HTTP/1.1 200"));
    assert_eq!(body, "origin response");

    // Hot-reload rule matching loopback -> new requests must go via unavailable gateway (502)
    // and must NOT reuse the old direct pooled HTTP connection.
    proxy_update_rules(
        id,
        config(
            proxy_port,
            "rule",
            json!([{"type":"ip", "value":"127.0.0.0/8"}]),
        ),
    )
    .await
    .unwrap();
    echo_bytes(&mut active_tunnel).await;
    assert!(http_request(proxy_port, &origin.address.to_string())
        .await
        .starts_with("HTTP/1.1 502"));

    // Invalid rule update fails without breaking active routing.
    assert!(proxy_update_rules(
        id,
        config(
            proxy_port,
            "rule",
            json!([{"type":"ip", "value":"999.0.0.1"}])
        ),
    )
    .await
    .is_err());
    assert!(http_request(proxy_port, &origin.address.to_string())
        .await
        .starts_with("HTTP/1.1 502"));

    // Switch to global mode -> still routes to gateway.
    proxy_update_rules(id, config(proxy_port, "global", json!([])))
        .await
        .unwrap();
    assert!(http_request(proxy_port, &origin.address.to_string())
        .await
        .starts_with("HTTP/1.1 502"));

    // Switch back to empty rule mode -> direct HTTP succeeds again, active tunnel still alive.
    proxy_update_rules(id, config(proxy_port, "rule", json!([])))
        .await
        .unwrap();
    echo_bytes(&mut active_tunnel).await;
    let (status, body) =
        http_get_status_and_body(proxy_port, &origin.address.to_string(), "/after").await;
    assert!(status.starts_with("HTTP/1.1 200"));
    assert_eq!(body, "origin response");

    proxy_stop(id).await.unwrap();
    assert!(
        proxy_update_rules(id, config(proxy_port, "global", json!([])))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn proxy_http_pool_reuses_keepalive_upstream_and_respects_connection_close() {
    use std::sync::atomic::AtomicUsize;

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin_addr = listener.local_addr().unwrap();
    let accepts = Arc::new(AtomicUsize::new(0));
    let accepts_counter = accepts.clone();
    let server = tokio::spawn(async move {
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (socket, _) = accepted.unwrap();
                    accepts_counter.fetch_add(1, Ordering::SeqCst);
                    connections.spawn(async move {
                        let _ = hyper::server::conn::http1::Builder::new()
                            .keep_alive(true)
                            .serve_connection(
                                TokioIo::new(socket),
                                service_fn(|req: Request<Incoming>| async move {
                                    let close = req.uri().path() == "/close";
                                    let mut builder = Response::builder();
                                    if close {
                                        builder = builder.header("connection", "close");
                                    }
                                    Ok::<_, Infallible>(
                                        builder
                                            .body(Full::new(Bytes::from_static(b"pooled ok")))
                                            .unwrap(),
                                    )
                                }),
                            )
                            .await;
                    });
                }
                _ = connections.join_next(), if !connections.is_empty() => {}
            }
        }
    });

    let proxy_port = port().await;
    let proxy = start(
        &config(proxy_port, "rule", json!([])),
        None,
        Some(unavailable_page(1)),
    )
    .await
    .unwrap();

    // Three sequential client requests reuse a single keep-alive upstream TCP connection.
    for path in ["/one", "/two", "/three"] {
        let (headers, body) =
            http_get_status_and_body(proxy_port, &origin_addr.to_string(), path).await;
        assert!(headers.starts_with("HTTP/1.1 200"));
        assert_eq!(body, "pooled ok");
    }
    assert_eq!(accepts.load(Ordering::SeqCst), 1);

    // An upstream response with Connection: close is not recycled.
    let (headers, body) =
        http_get_status_and_body(proxy_port, &origin_addr.to_string(), "/close").await;
    assert!(headers.starts_with("HTTP/1.1 200"));
    assert_eq!(body, "pooled ok");
    assert_eq!(accepts.load(Ordering::SeqCst), 1);

    let (headers, body) =
        http_get_status_and_body(proxy_port, &origin_addr.to_string(), "/fresh").await;
    assert!(headers.starts_with("HTTP/1.1 200"));
    assert_eq!(body, "pooled ok");
    assert_eq!(accepts.load(Ordering::SeqCst), 2);

    // Routing hot-reload clears idle pooled connections.
    proxy
        .update_routing(&config(proxy_port, "rule", json!([])))
        .unwrap();
    let (headers, body) =
        http_get_status_and_body(proxy_port, &origin_addr.to_string(), "/after-reload").await;
    assert!(headers.starts_with("HTTP/1.1 200"));
    assert_eq!(body, "pooled ok");
    assert_eq!(accepts.load(Ordering::SeqCst), 3);

    proxy.stop().await;
    server.abort();
}

#[tokio::test]
async fn proxy_chains_http_connect_and_socks_to_http_upstream_with_bypass_and_loop_guard() {
    // Mock HTTP upstream proxy (like Clash/v2rayN) handling both absolute-URI HTTP
    // forwarding and CONNECT tunnels (with early pipelined target bytes).
    let upstream_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let upstream_port = upstream_listener.local_addr().unwrap().port();
    let upstream_requests = Arc::new(StdMutex::new(Vec::<String>::new()));
    let captured = upstream_requests.clone();
    let upstream_server = tokio::spawn(async move {
        while let Ok((mut stream, _)) = upstream_listener.accept().await {
            let captured = captured.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 1024];
                let header_end = loop {
                    let Ok(n) = stream.read(&mut chunk).await else {
                        return;
                    };
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        break pos + 4;
                    }
                };
                let head = String::from_utf8_lossy(&buf[..header_end]);
                let first_line = head.lines().next().unwrap_or("").to_owned();
                captured.lock().unwrap().push(first_line.clone());
                if first_line.starts_with("CONNECT ") {
                    // Send 200 OK + early target greeting in the same write to test PrefixedStream.
                    let _ = stream
                        .write_all(
                            b"HTTP/1.1 200 Connection Established\r\n\r\nHELLO-FROM-UPSTREAM:",
                        )
                        .await;
                    let mut req = [0u8; 4];
                    if stream.read_exact(&mut req).await.is_ok() {
                        let _ = stream.write_all(&req).await;
                    }
                    let _ = stream.shutdown().await;
                } else {
                    let body = format!("upstream:{first_line}");
                    let reply = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = stream.write_all(reply.as_bytes()).await;
                    let _ = stream.shutdown().await;
                }
            });
        }
    });

    let proxy_port = port().await;
    // Reject self-loop when upstream points at PagaShell's own listening port.
    let loop_cfg = json!({
        "mode": "rule",
        "httpEnabled": true,
        "httpPort": proxy_port,
        "httpsEnabled": true,
        "httpsPort": proxy_port,
        "socks5Enabled": true,
        "socks5Port": proxy_port,
        "rules": [],
        "upstream": {
            "http": {"protocol": "http", "host": "127.0.0.1", "port": proxy_port},
            "https": {"protocol": "http", "host": "localhost", "port": proxy_port},
            "bypass": []
        }
    })
    .to_string();
    assert!(start(&loop_cfg, None, Some(unavailable_page(1)))
        .await
        .is_err());

    let cfg = json!({
        "mode": "rule",
        "httpEnabled": true,
        "httpPort": proxy_port,
        "httpsEnabled": true,
        "httpsPort": proxy_port,
        "socks5Enabled": true,
        "socks5Port": proxy_port,
        "rules": [
            {"type": "ip", "value": "10.110.167.11"},
            {"type": "domainSuffix", "value": "sslip.io"}
        ],
        "upstream": {
            "http": {"protocol": "http", "host": "127.0.0.1", "port": upstream_port},
            "https": {"protocol": "http", "host": "127.0.0.1", "port": upstream_port},
            "bypass": ["localhost", "127.*", "10.*", "169.254/16", "*.local", "<local>"],
            "excludeSimpleHostnames": true
        }
    })
    .to_string();
    let proxy = start(&cfg, None, Some(unavailable_page(1))).await.unwrap();

    // 1. Plain HTTP unmatched external domain (even with IP gateway rules and no local DNS!)
    //    routes to HTTP upstream using absolute-form URI without failing DNS.
    let (headers, body) =
        http_get_status_and_body(proxy_port, "external.unresolvable.invalid", "/hello").await;
    assert!(headers.starts_with("HTTP/1.1 200"), "{headers}");
    assert_eq!(
        body,
        "upstream:GET http://external.unresolvable.invalid/hello HTTP/1.1"
    );

    // 2. HTTPS CONNECT unmatched domain tunnels through HTTP upstream and preserves early bytes.
    let mut tun = tunnel(proxy_port, "api.unresolvable.invalid:443").await;
    let mut greeting = [0u8; 20];
    tun.read_exact(&mut greeting).await.unwrap();
    assert_eq!(&greeting, b"HELLO-FROM-UPSTREAM:");
    tun.write_all(b"PING").await.unwrap();
    let mut echoed = [0u8; 4];
    tun.read_exact(&mut echoed).await.unwrap();
    assert_eq!(&echoed, b"PING");

    // 3. SOCKS5 unmatched domain falls back to HTTP CONNECT upstream when only HTTP upstream exists.
    let mut socks = socks_connect(proxy_port, "socks.unresolvable.invalid", 8443).await;
    let mut socks_greeting = [0u8; 20];
    socks.read_exact(&mut socks_greeting).await.unwrap();
    assert_eq!(&socks_greeting, b"HELLO-FROM-UPSTREAM:");
    socks.write_all(b"PONG").await.unwrap();
    let mut socks_echoed = [0u8; 4];
    socks.read_exact(&mut socks_echoed).await.unwrap();
    assert_eq!(&socks_echoed, b"PONG");

    // 4. Matched gateway rules MUST go to Gateway (here unavailable -> 502), NOT upstream.
    let before_count = upstream_requests.lock().unwrap().len();
    assert!(http_request(proxy_port, "10.110.167.11:31288")
        .await
        .starts_with("HTTP/1.1 502"));
    assert!(http_request(proxy_port, "app.sslip.io:80")
        .await
        .starts_with("HTTP/1.1 502"));
    assert_eq!(upstream_requests.lock().unwrap().len(), before_count);

    // 5. Bypass rules (loopback, 10.*, macOS 169.254/16, *.local, simple hostname)
    //    go Direct instead of upstream.
    let (local_origin, mut local_rx) = origin().await;
    assert!(http_request(proxy_port, &local_origin.address.to_string())
        .await
        .starts_with("HTTP/1.1 200"));
    assert!(local_rx.recv().await.is_some());
    assert_eq!(upstream_requests.lock().unwrap().len(), before_count);

    let routing = proxy.router.current_routing();
    assert!(matches!(
        proxy
            .router
            .route_with(&routing, "10.1.2.3", 80, TrafficKind::Http)
            .await
            .unwrap(),
        Route::Direct
    ));
    assert!(matches!(
        proxy
            .router
            .route_with(&routing, "169.254.12.34", 80, TrafficKind::Http)
            .await
            .unwrap(),
        Route::Direct
    ));
    proxy.router.dns.put(
        "printer.local".into(),
        Arc::new([IpAddr::V4(Ipv4Addr::new(192, 168, 1, 50))]),
        Instant::now() + DNS_TTL,
    );
    proxy.router.dns.put(
        "intranet".into(),
        Arc::new([IpAddr::V4(Ipv4Addr::new(192, 168, 1, 51))]),
        Instant::now() + DNS_TTL,
    );
    assert!(matches!(
        proxy
            .router
            .route_with(&routing, "printer.local", 80, TrafficKind::Http)
            .await
            .unwrap(),
        Route::Resolved(_)
    ));
    assert!(matches!(
        proxy
            .router
            .route_with(&routing, "intranet", 80, TrafficKind::Http)
            .await
            .unwrap(),
        Route::Resolved(_)
    ));
    assert!(matches!(
        proxy
            .router
            .route_with(&routing, "10.110.167.11", 31288, TrafficKind::Http)
            .await
            .unwrap(),
        Route::Gateway
    ));
    assert!(matches!(
        proxy
            .router
            .route_with(&routing, "example.com", 443, TrafficKind::Https)
            .await
            .unwrap(),
        Route::Upstream(_)
    ));

    // 6. Hot-reload rejects self-loop upstream without clobbering active routing.
    assert!(proxy.update_routing(&loop_cfg).is_err());

    proxy.stop().await;
    upstream_server.abort();
}

#[tokio::test]
async fn proxy_chains_to_socks5_upstream() {
    // Minimal RFC 1928 SOCKS5 mock server echoing the requested domain and port.
    let upstream_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let upstream_port = upstream_listener.local_addr().unwrap().port();
    let upstream_server = tokio::spawn(async move {
        while let Ok((mut stream, _)) = upstream_listener.accept().await {
            tokio::spawn(async move {
                let mut greeting = [0u8; 3];
                if stream.read_exact(&mut greeting).await.is_err() || greeting != [5, 1, 0] {
                    return;
                }
                let _ = stream.write_all(&[5, 0]).await;
                let mut header = [0u8; 4];
                if stream.read_exact(&mut header).await.is_err() || header[0] != 5 || header[1] != 1
                {
                    return;
                }
                let host = match header[3] {
                    3 => {
                        let Ok(len) = stream.read_u8().await else {
                            return;
                        };
                        let mut bytes = vec![0u8; len as usize];
                        if stream.read_exact(&mut bytes).await.is_err() {
                            return;
                        }
                        String::from_utf8_lossy(&bytes).into_owned()
                    }
                    _ => return,
                };
                let Ok(port) = stream.read_u16().await else {
                    return;
                };
                let _ = stream.write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]).await;
                let payload = format!("socks5:{host}:{port}");
                let _ = stream.write_all(payload.as_bytes()).await;
                let _ = stream.shutdown().await;
            });
        }
    });

    let proxy_port = port().await;
    let cfg = json!({
        "mode": "rule",
        "httpEnabled": true,
        "httpPort": proxy_port,
        "httpsEnabled": true,
        "httpsPort": proxy_port,
        "socks5Enabled": true,
        "socks5Port": proxy_port,
        "rules": [],
        "upstream": {
            "socks5": {"protocol": "socks5", "host": "127.0.0.1", "port": upstream_port},
            "bypass": ["localhost"]
        }
    })
    .to_string();
    let proxy = start(&cfg, None, Some(unavailable_page(1))).await.unwrap();

    // HTTPS CONNECT through SOCKS5 upstream receives remote hostname via ATYP=3.
    let mut tun = tunnel(proxy_port, "remote.example.invalid:443").await;
    let mut out = String::new();
    tun.read_to_string(&mut out).await.unwrap();
    assert_eq!(out, "socks5:remote.example.invalid:443");

    // SOCKS5 client through SOCKS5 upstream also forwards remote hostname.
    let mut socks = socks_connect(proxy_port, "socks.example.invalid", 9000).await;
    let mut socks_out = String::new();
    socks.read_to_string(&mut socks_out).await.unwrap();
    assert_eq!(socks_out, "socks5:socks.example.invalid:9000");

    proxy.stop().await;
    upstream_server.abort();
}

#[tokio::test]
#[ignore = "requires PAGAGATEWAY_BIN pointing to the Go relay binary"]
async fn proxy_page_relay_http_connect_and_socks_work_over_tls_and_plain_tcp() {
    for tls in [true, false] {
        let (echo, _) = echo(false).await;
        let (origin, mut requests) = origin().await;
        let relay =
            crate::page::GoRelay::start(&[echo.address.port(), origin.address.port()], tls).await;
        let port = port().await;
        let proxy = start(
            &config(port, "global", json!([])),
            None,
            Some(relay.gateway.clone()),
        )
        .await
        .unwrap();
        assert!(http_request(port, &origin.address.to_string())
            .await
            .starts_with("HTTP/1.1 200"));
        assert_eq!(requests.recv().await.unwrap().1, origin.address.to_string());
        let mut connect = tunnel(port, &echo.address.to_string()).await;
        echo_bytes(&mut connect).await;
        let mut socks = socks_connect(port, "127.0.0.1", echo.address.port()).await;
        echo_bytes(&mut socks).await;
        assert!(http_request(port, "127.0.0.1:1")
            .await
            .starts_with("HTTP/1.1 502"));
        let mut again = tunnel(port, &echo.address.to_string()).await;
        echo_bytes(&mut again).await;
        proxy.stop().await;
    }
}
