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
    let router = Router {
        mode: Mode::Rule,
        gateway: None,
        rules: vec![
            rule(RuleType::Ip, "10.0.0.0/16"),
            rule(RuleType::Ip, "2001:db8::/32"),
            rule(RuleType::Ip, "192.0.2.4"),
            rule(RuleType::Ip, "::1/128"),
            rule(RuleType::DomainExact, "EXACT.internal."),
            rule(RuleType::DomainPrefix, "api."),
            rule(RuleType::DomainSuffix, "example.com"),
        ],
    };
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
        assert!(router.use_gateway(host, 443).await.unwrap(), "{host}");
    }
    for host in ["10.1.0.1", "2001:db9::1", "192.0.2.5", "::2"] {
        assert!(!router.use_gateway(host, 443).await.unwrap(), "{host}");
    }
    let suffix = rule(RuleType::DomainSuffix, "example.com");
    assert!(!suffix.domain_matches("evilexample.com"));
    assert!(!suffix.domain_matches("example.com.evil"));
    assert!(!rule(RuleType::DomainPrefix, "api.").domain_matches("api-evil.test"));
    assert!(!rule(RuleType::DomainExact, "exact.test").domain_matches("sub.exact.test"));
    for value in ["10.0.0.0/33", "::/129", "256.0.0.1", "10.1/8", "::1%lo0"] {
        assert!(Rule::parse(RuleSpec {
            kind: RuleType::Ip,
            value: value.into()
        })
        .is_err());
    }
    let router = Router {
        mode: Mode::Rule,
        gateway: None,
        rules: vec![rule(RuleType::Ip, "127.0.0.0/8"), rule(RuleType::Ip, "::1")],
    };
    assert!(router.use_gateway("localhost", 80).await.unwrap());
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
    let proxy = start(&config(port, "rule", json!([])), Some(u32::MAX), None)
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
    proxy.stop().await;
}

#[tokio::test]
async fn proxy_connect_preserves_early_tls_bytes_and_half_close() {
    let (echo, _) = echo(false).await;
    let port = port().await;
    let proxy = start(&config(port, "rule", json!([])), Some(u32::MAX), None)
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
    proxy.stop().await;
}

#[tokio::test]
async fn proxy_socks_accepts_domain_ipv4_ipv6_and_rejects_unsupported_commands() {
    let (v4, _) = echo(false).await;
    let (v6, _) = echo(true).await;
    let port = port().await;
    let proxy = start(&config(port, "rule", json!([])), Some(u32::MAX), None)
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
    let port = port().await;
    for (mode, rules) in [
        ("global", json!([])),
        ("rule", json!([{"type":"ip", "value":"127.0.0.0/8"}])),
    ] {
        let proxy = start(&config(port, mode, rules), Some(u32::MAX), None)
            .await
            .unwrap();
        assert!(http_request(port, &echo.address.to_string())
            .await
            .starts_with("HTTP/1.1 502"));
        assert!(connections.try_recv().is_err());
        proxy.stop().await;
    }
    for (mode, rules) in [
        ("rule", json!([])),
        ("rule", json!([{"type":"ip", "value":"10.0.0.0/8"}])),
    ] {
        let proxy = start(&config(port, mode, rules), Some(u32::MAX), None)
            .await
            .unwrap();
        let mut socket = tunnel(port, &echo.address.to_string()).await;
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
    assert!(start(&settings.to_string(), Some(u32::MAX), None)
        .await
        .is_err());
    drop(
        TcpListener::bind((Ipv4Addr::LOCALHOST, free_port))
            .await
            .unwrap(),
    );
    drop(busy);

    let (echo, _) = echo(false).await;
    let proxy = start(&config(free_port, "rule", json!([])), Some(u32::MAX), None)
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
    let proxy = start(&settings.to_string(), Some(u32::MAX), None)
        .await
        .unwrap();
    assert!(http_request(port, "127.0.0.1:1")
        .await
        .starts_with("HTTP/1.1 403"));
    proxy.stop().await;
    let settings = json!({"mode":"rule", "httpPort":port, "httpsEnabled":false});
    let proxy = start(&settings.to_string(), Some(u32::MAX), None)
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
    let id = crate::api::proxy::proxy_start(config(port, "rule", json!([])), Some(u32::MAX), None)
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
