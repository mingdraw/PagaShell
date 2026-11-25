//! PagaGateway Page v1: optional pinned TLS and a bounded opening frame, then TCP.
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context as TaskContext, Poll};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{lookup_host, TcpStream};
use tokio::time::{timeout_at, Instant};
use tokio_rustls::{client::TlsStream, rustls, TlsConnector};

use crate::api::page::PageGateway;

const MAX_FRAME: usize = 8192;
const SERVER_DNS_TTL: Duration = Duration::from_secs(30);

pub(crate) enum PageStream {
    Tcp(TcpStream),
    Tls(Box<TlsStream<TcpStream>>),
}

impl AsyncRead for PageStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Tcp(stream) => Pin::new(stream).poll_read(cx, buf),
            Self::Tls(stream) => Pin::new(stream).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for PageStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        match self.get_mut() {
            Self::Tcp(stream) => Pin::new(stream).poll_write(cx, buf),
            Self::Tls(stream) => Pin::new(stream).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Tcp(stream) => Pin::new(stream).poll_flush(cx),
            Self::Tls(stream) => Pin::new(stream).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Self::Tcp(stream) => Pin::new(stream).poll_shutdown(cx),
            Self::Tls(stream) => Pin::new(stream).poll_shutdown(cx),
        }
    }
}

#[derive(Serialize)]
struct Open<'a> {
    version: u8,
    kind: &'static str,
    client_id: &'a str,
    token: &'a str,
    host: &'a str,
    port: u16,
    timeout_ms: u32,
}

#[derive(Deserialize)]
struct Reply {
    version: u8,
    kind: String,
    #[serde(default)]
    error: String,
}

#[derive(Debug)]
struct PinVerifier {
    fingerprint: Vec<u8>,
    provider: Arc<rustls::crypto::CryptoProvider>,
}

impl rustls::client::danger::ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        cert: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        if Sha256::digest(cert.as_ref()).as_slice() != self.fingerprint {
            return Err(rustls::Error::General("Page Server 证书指纹不匹配".into()));
        }
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn parse_pin(value: &str) -> Result<Vec<u8>> {
    let normalized = value
        .trim()
        .strip_prefix("SHA256:")
        .unwrap_or(value.trim())
        .replace(':', "");
    if normalized.len() != 64 || !normalized.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("Page Server 证书指纹无效");
    }
    (0..64)
        .step_by(2)
        .map(|i| u8::from_str_radix(&normalized[i..i + 2], 16).context("Page Server 证书指纹无效"))
        .collect()
}

fn gateway_pin(gateway: &PageGateway) -> Result<Option<Vec<u8>>> {
    if gateway.server_host.trim().is_empty()
        || gateway.server_port == 0
        || gateway.token.is_empty()
        || gateway.client_id.is_empty()
        || gateway.client_id.len() > 64
        || !gateway
            .client_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        bail!("Page 网关配置无效，请检查 Client ID 与访问令牌");
    }
    if gateway.server_fingerprint.trim().is_empty() {
        Ok(None)
    } else {
        parse_pin(&gateway.server_fingerprint).map(Some)
    }
}

enum ServerEndpoint {
    Fixed(SocketAddr),
    CachedDns(Mutex<Option<(Arc<[SocketAddr]>, Instant)>>),
}

pub(crate) struct PageConnector {
    gateway: PageGateway,
    tls: Option<(TlsConnector, rustls::pki_types::ServerName<'static>)>,
    endpoint: ServerEndpoint,
}

impl PageConnector {
    pub fn new(gateway: PageGateway) -> Result<Self> {
        let tls = if let Some(fingerprint) = gateway_pin(&gateway)? {
            let provider = Arc::new(rustls::crypto::ring::default_provider());
            // Reuse the verifier and config; require the pinned certificate on
            // each connection so rotation cannot be hidden by a cached ticket.
            let mut config = rustls::ClientConfig::builder_with_provider(provider.clone())
                .with_protocol_versions(&[&rustls::version::TLS13])?
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(PinVerifier {
                    fingerprint,
                    provider,
                }))
                .with_no_client_auth();
            config.resumption = rustls::client::Resumption::disabled();
            let name = rustls::pki_types::ServerName::try_from(gateway.server_host.clone())
                .context("Page Server 地址无效")?;
            Some((TlsConnector::from(Arc::new(config)), name))
        } else {
            None
        };
        let endpoint = match gateway.server_host.trim().parse::<IpAddr>() {
            Ok(ip) => ServerEndpoint::Fixed(SocketAddr::new(ip, gateway.server_port)),
            Err(_) => ServerEndpoint::CachedDns(Mutex::new(None)),
        };
        Ok(Self {
            gateway,
            tls,
            endpoint,
        })
    }

    async fn dial_server(&self, deadline: Instant) -> Result<TcpStream> {
        let gateway = &self.gateway;
        match &self.endpoint {
            ServerEndpoint::Fixed(addr) => timeout_at(deadline, TcpStream::connect(*addr))
                .await
                .context("连接 Page Server 超时")?
                .context("无法连接 Page Server"),
            ServerEndpoint::CachedDns(cache) => {
                let cached = cache
                    .lock()
                    .unwrap()
                    .as_ref()
                    .filter(|(_, expires)| *expires > Instant::now())
                    .map(|(addrs, _)| addrs.clone());
                let (addresses, from_cache) = if let Some(addrs) = cached {
                    (addrs, true)
                } else {
                    let addrs: Arc<[SocketAddr]> = timeout_at(
                        deadline,
                        lookup_host((gateway.server_host.as_str(), gateway.server_port)),
                    )
                    .await
                    .context("连接 Page Server 超时")?
                    .context("无法连接 Page Server")?
                    .collect();
                    if addrs.is_empty() {
                        bail!("无法连接 Page Server");
                    }
                    *cache.lock().unwrap() = Some((addrs.clone(), Instant::now() + SERVER_DNS_TTL));
                    (addrs, false)
                };
                match timeout_at(deadline, crate::proxy::connect_happy_eyeballs(&addresses)).await {
                    Ok(Ok(stream)) => Ok(stream),
                    Ok(Err(err)) => {
                        if from_cache {
                            *cache.lock().unwrap() = None;
                        }
                        Err(err).context("无法连接 Page Server")
                    }
                    Err(err) => {
                        if from_cache {
                            *cache.lock().unwrap() = None;
                        }
                        Err(err).context("连接 Page Server 超时")
                    }
                }
            }
        }
    }

    pub async fn connect(&self, host: &str, port: u16, deadline: Instant) -> Result<PageStream> {
        let gateway = &self.gateway;
        let tcp = self.dial_server(deadline).await?;
        tcp.set_nodelay(true)?;
        let stream = if let Some((connector, name)) = &self.tls {
            let tls = timeout_at(deadline, connector.connect(name.clone(), tcp))
                .await
                .context("Page Server TLS 握手超时")?
                .context("Page Server TLS 握手失败，请核对证书指纹")?;
            PageStream::Tls(Box::new(tls))
        } else {
            PageStream::Tcp(tcp)
        };
        timeout_at(deadline, open_target(gateway, host, port, stream, deadline))
            .await
            .context("Page 隧道建立超时")?
    }
}

pub(crate) async fn connect(
    gateway: PageGateway,
    host: &str,
    port: u16,
    deadline: Instant,
) -> Result<PageStream> {
    PageConnector::new(gateway)?
        .connect(host, port, deadline)
        .await
}

async fn open_target(
    gateway: &PageGateway,
    host: &str,
    port: u16,
    mut stream: PageStream,
    deadline: Instant,
) -> Result<PageStream> {
    let remaining = deadline
        .saturating_duration_since(Instant::now())
        .as_millis();
    // Leave time for the Server's outcome to reach the caller.
    let timeout_ms = remaining.saturating_sub(50).clamp(1, u32::MAX.into()) as u32;
    let mut frame = Vec::with_capacity(256);
    frame.extend_from_slice(&[0; 4]);
    serde_json::to_writer(
        &mut frame,
        &Open {
            version: 1,
            kind: "open",
            client_id: &gateway.client_id,
            token: &gateway.token,
            host,
            port,
            timeout_ms,
        },
    )?;
    let size = frame.len() - 4;
    if size > MAX_FRAME {
        bail!("Page 请求超限");
    }
    frame[..4].copy_from_slice(&(size as u32).to_be_bytes());
    stream.write_all(&frame).await?;
    stream.flush().await?;
    let size = stream.read_u32().await? as usize;
    if size == 0 || size > MAX_FRAME {
        bail!("Page Server 返回的帧超限");
    }
    let mut frame = vec![0; size];
    stream.read_exact(&mut frame).await?;
    let reply: Reply = serde_json::from_slice(&frame).context("Page Server 协议无效")?;
    if reply.version != 1 {
        bail!("Page Server 协议版本不支持");
    }
    if reply.kind != "ready" {
        bail!(match reply.error.as_str() {
            "unauthorized" => "Page 访问令牌或 Client ID 无效",
            "clientOffline" => "Page Client 未连接中转 Server",
            "gatewayBusy" => "Page Server 连接额度已满，请稍后重试",
            "clientBusy" => "Page Client 隧道额度已满，请稍后重试",
            "workUnavailable" => "Page Client 无法建立到 Server 的工作连接",
            "targetDenied" => "Page Client 未允许此目标地址和端口",
            "targetUnavailable" => "Page Client 无法连接目标服务",
            "targetTimeout" => "Page 目标连接超时",
            _ => "Page Server 拒绝连接",
        });
    }
    Ok(stream)
}

/// Optional cross-repository fixture. Starts the actual Go executables and uses
/// only ephemeral loopback listeners and generated, non-production credentials.
#[cfg(test)]
pub(crate) struct GoRelay {
    pub gateway: PageGateway,
    server: std::process::Child,
    client: std::process::Child,
    directory: std::path::PathBuf,
}

#[cfg(test)]
impl Drop for GoRelay {
    fn drop(&mut self) {
        let _ = self.client.kill();
        let _ = self.server.kill();
        let _ = self.client.wait();
        let _ = self.server.wait();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[cfg(test)]
impl GoRelay {
    pub async fn start(target_ports: &[u16], use_tls: bool) -> Self {
        use std::process::{Command, Stdio};
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::time::{Duration, SystemTime, UNIX_EPOCH};
        static NEXT_DIR: AtomicU64 = AtomicU64::new(1);
        let binary = std::env::var("PAGAGATEWAY_BIN")
            .expect("set PAGAGATEWAY_BIN to a built pagagateway binary");
        let client_binary =
            std::env::var("PAGAGATEWAY_CLIENT_BIN").unwrap_or_else(|_| binary.clone());
        let directory = std::env::temp_dir().join(format!(
            "pagashell-page-{}-{}-{}",
            std::process::id(),
            NEXT_DIR.fetch_add(1, Ordering::Relaxed),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&directory).unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let mut server_config = serde_json::json!({
            "listen":address.to_string(),
            "routes":[{"id":"test", "client_token":"client", "access_token":"access"}]
        });
        let fingerprint = if use_tls {
            let key = rcgen::KeyPair::generate().unwrap();
            let cert = rcgen::CertificateParams::new(vec!["127.0.0.1".into()])
                .unwrap()
                .self_signed(&key)
                .unwrap();
            std::fs::write(directory.join("server.crt"), cert.pem()).unwrap();
            std::fs::write(directory.join("server.key"), key.serialize_pem()).unwrap();
            server_config["cert_file"] = serde_json::json!(directory.join("server.crt"));
            server_config["key_file"] = serde_json::json!(directory.join("server.key"));
            Sha256::digest(cert.der())
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        } else {
            String::new()
        };
        let client_config = serde_json::json!({"server":address.to_string(), "server_fingerprint":fingerprint, "id":"test", "token":"client", "allowed_targets":target_ports.iter().map(|p| format!("127.0.0.1:{p}")).collect::<Vec<_>>()});
        std::fs::write(directory.join("server.json"), server_config.to_string()).unwrap();
        std::fs::write(directory.join("client.json"), client_config.to_string()).unwrap();
        let spawn = |binary: &str, kind: &str| {
            Command::new(binary)
                .args([kind, "run", "-config"])
                .arg(directory.join(format!("{kind}.json")))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        };
        let server = spawn(&binary, "server");
        let client = spawn(&client_binary, "client");
        let relay = Self {
            gateway: PageGateway {
                server_host: "127.0.0.1".into(),
                server_port: address.port(),
                client_id: "test".into(),
                token: "access".into(),
                server_fingerprint: fingerprint,
            },
            server,
            client,
            directory,
        };
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let deadline = Instant::now() + Duration::from_secs(2);
                let result = connect(relay.gateway.clone(), "127.0.0.1", 1, deadline).await;
                if matches!(result, Err(ref e) if e.to_string().contains("未允许此目标")) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("Go relay did not become ready");
        relay
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pin_requires_exact_sha256_digest() {
        assert!(parse_pin("").is_err());
        assert!(parse_pin(&"z".repeat(64)).is_err());
        assert_eq!(
            parse_pin(&format!("SHA256:{}", "ab:".repeat(32))).unwrap(),
            vec![171; 32]
        );
    }

    #[tokio::test]
    async fn empty_pin_uses_plain_tcp_and_preserves_tunnel_bytes() {
        use std::time::Duration;
        tokio::time::timeout(Duration::from_secs(5), async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let peer = tokio::spawn(async move {
                let (mut tcp, _) = listener.accept().await.unwrap();
                let size = tcp.read_u32().await.unwrap() as usize;
                assert!(size <= MAX_FRAME);
                let mut frame = vec![0; size];
                tcp.read_exact(&mut frame).await.unwrap();
                let request: serde_json::Value = serde_json::from_slice(&frame).unwrap();
                assert_eq!(request["kind"], "open");
                assert_eq!(request["token"], "test-access");
                assert_eq!(request["host"], "internal.test");
                assert!(matches!(request["timeout_ms"].as_u64(), Some(1..=5_000)));
                let reply = br#"{"version":1,"kind":"ready"}"#;
                let mut data = (reply.len() as u32).to_be_bytes().to_vec();
                data.extend_from_slice(reply);
                data.extend_from_slice(b"SSH-banner");
                tcp.write_all(&data).await.unwrap();
                let mut payload = Vec::new();
                tcp.read_to_end(&mut payload).await.unwrap();
                tcp.write_all(&payload).await.unwrap();
            });
            let gateway = PageGateway {
                server_host: "127.0.0.1".into(),
                server_port: port,
                client_id: "test".into(),
                token: "test-access".into(),
                server_fingerprint: " \t".into(),
            };
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut stream = connect(gateway, "internal.test", 22, deadline)
                .await
                .unwrap();
            let mut banner = [0; 10];
            stream.read_exact(&mut banner).await.unwrap();
            assert_eq!(&banner, b"SSH-banner");
            let payload = [0, 255, 1, 128, 13, 10];
            stream.write_all(&payload).await.unwrap();
            stream.shutdown().await.unwrap();
            let mut echoed = Vec::new();
            stream.read_to_end(&mut echoed).await.unwrap();
            assert_eq!(echoed, payload);
            peer.await.unwrap();
        })
        .await
        .unwrap();
    }
}
