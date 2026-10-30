//! Explicit HTTP / HTTPS CONNECT / SOCKS5 TCP proxies. Never decrypt website TLS.
use std::collections::BTreeMap;
use std::convert::Infallible;
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, ensure, Context, Result};
use http_body_util::{combinators::BoxBody, BodyExt, Empty, Full};
use hyper::body::{Bytes, Incoming};
use hyper::header::{HeaderValue, CONNECTION, HOST};
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode, Uri};
use hyper_util::rt::{TokioIo, TokioTimer};
use ipnet::IpNet;
use serde::Deserialize;
use tokio::io::{copy_bidirectional, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{lookup_host, TcpListener, TcpStream};
use tokio::sync::{watch, OwnedSemaphorePermit, Semaphore};
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

use crate::api::page::PageGateway;

const OPEN_TIMEOUT: Duration = Duration::from_secs(15);
const HEADER_TIMEOUT: Duration = Duration::from_secs(15);
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(60);
const HTTP: u8 = 1;
const HTTPS: u8 = 2;
const SOCKS: u8 = 4;

#[derive(Clone, Copy, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
enum Mode {
    #[serde(alias = "direct")]
    Rule,
    #[default]
    Global,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
enum RuleType {
    Ip,
    DomainExact,
    DomainPrefix,
    DomainSuffix,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct RuleSpec {
    #[serde(rename = "type")]
    kind: RuleType,
    value: String,
}

#[derive(Clone, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
struct Config {
    mode: Mode,
    http_enabled: bool,
    http_port: u16,
    https_enabled: bool,
    https_port: u16,
    socks5_enabled: bool,
    socks5_port: u16,
    rules: Vec<RuleSpec>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            mode: Mode::Global,
            http_enabled: true,
            http_port: 18080,
            https_enabled: true,
            https_port: 18080,
            socks5_enabled: false,
            socks5_port: 1080,
            rules: Vec::new(),
        }
    }
}

enum Rule {
    Ip(IpNet),
    Domain(RuleType, String),
}

impl Rule {
    fn parse(spec: RuleSpec) -> Result<Self> {
        let value = spec.value.trim().to_ascii_lowercase();
        if matches!(spec.kind, RuleType::Ip) {
            let net = if value.contains('/') {
                value.parse::<IpNet>()?
            } else {
                value.parse::<IpAddr>()?.into()
            };
            return Ok(Self::Ip(net));
        }
        ensure!(
            !value.is_empty() && value.len() <= 253 && value.parse::<IpAddr>().is_err(),
            "请填写域名，不包含协议、端口或通配符"
        );
        ensure!(
            value.trim_end_matches('.').split('.').all(|label| {
                !label.is_empty()
                    && label
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            }),
            "请填写域名，不包含协议、端口或通配符"
        );
        let value = if matches!(spec.kind, RuleType::DomainPrefix) {
            value
        } else {
            value.trim_end_matches('.').to_owned()
        };
        Ok(Self::Domain(spec.kind, value))
    }

    fn domain_matches(&self, host: &str) -> bool {
        match self {
            Self::Domain(RuleType::DomainExact, value) => host == value,
            Self::Domain(RuleType::DomainPrefix, value) => host.starts_with(value),
            Self::Domain(RuleType::DomainSuffix, value) => {
                host == value || host.strip_suffix(value).is_some_and(|s| s.ends_with('.'))
            }
            _ => false,
        }
    }

    fn ip_matches(&self, ip: IpAddr) -> bool {
        matches!(self, Self::Ip(net) if net.contains(&ip))
    }
}

trait ProxyIo: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> ProxyIo for T {}
type Stream = Box<dyn ProxyIo>;

enum Gateway {
    Ssh(u32),
    Page(PageGateway),
}

struct Router {
    mode: Mode,
    rules: Vec<Rule>,
    gateway: Option<Gateway>,
}

impl Router {
    async fn use_gateway(&self, host: &str, port: u16) -> Result<bool> {
        match self.mode {
            Mode::Global => return Ok(true),
            Mode::Rule => {}
        }
        let host = host.trim_end_matches('.').to_ascii_lowercase();
        if let Ok(ip) = host.parse::<IpAddr>() {
            return Ok(self.rules.iter().any(|r| r.ip_matches(ip)));
        }
        if self.rules.iter().any(|r| r.domain_matches(&host)) {
            return Ok(true);
        }
        // Only IP rules need local DNS. Domain matches retain gateway-side DNS.
        if self.rules.iter().any(|r| matches!(r, Rule::Ip(_))) {
            let addresses = lookup_host((host.as_str(), port))
                .await
                .context("无法解析代理目标地址")?;
            return Ok(addresses
                .into_iter()
                .any(|a| self.rules.iter().any(|r| r.ip_matches(a.ip()))));
        }
        Ok(false)
    }

    async fn connect(&self, host: &str, port: u16) -> Result<Stream> {
        timeout(OPEN_TIMEOUT, async {
            if self.use_gateway(host, port).await? {
                // A selected gateway failure is never retried using direct access.
                match self.gateway.as_ref().context("所选网关不可用")? {
                    Gateway::Ssh(id) => Ok(Box::new(
                        crate::api::ssh::desktop_tunnel(*id, host.to_owned(), port).await?,
                    ) as Stream),
                    Gateway::Page(gateway) => Ok(Box::new(
                        crate::page::connect(gateway.clone(), host, port).await?,
                    ) as Stream),
                }
            } else {
                Ok(Box::new(TcpStream::connect((host, port)).await?) as Stream)
            }
        })
        .await
        .context("代理目标连接超时")?
    }
}

pub(crate) struct RunningProxy {
    cancel: CancellationToken,
    pub(crate) status: watch::Receiver<Option<String>>,
    task: JoinHandle<()>,
}

impl RunningProxy {
    pub(crate) async fn stop(self) {
        self.cancel.cancel();
        let _ = self.task.await;
    }
}

pub(crate) async fn start(
    json: &str,
    ssh_id: Option<u32>,
    page: Option<PageGateway>,
) -> Result<RunningProxy> {
    ensure!(json.len() <= 1024 * 1024, "代理配置过大");
    let config: Config = serde_json::from_str(json).context("代理配置无效")?;
    ensure!(
        config.http_port > 0 && config.https_port > 0 && config.socks5_port > 0,
        "请填写有效的端口（1-65535）"
    );
    ensure!(config.rules.len() <= 10000, "代理规则过多");
    ensure!(ssh_id.is_none() || page.is_none(), "网关配置无效");
    let gateway = ssh_id.map(Gateway::Ssh).or_else(|| page.map(Gateway::Page));
    ensure!(gateway.is_some(), "所选网关不可用");
    let router = Arc::new(Router {
        mode: config.mode,
        rules: config
            .rules
            .into_iter()
            .map(Rule::parse)
            .collect::<Result<_>>()?,
        gateway,
    });
    let mut ports = BTreeMap::<u16, u8>::new();
    for (enabled, port, kind) in [
        (config.http_enabled, config.http_port, HTTP),
        (config.https_enabled, config.https_port, HTTPS),
        (config.socks5_enabled, config.socks5_port, SOCKS),
    ] {
        if enabled {
            *ports.entry(port).or_default() |= kind;
        }
    }
    ensure!(!ports.is_empty(), "请至少启用一种代理协议");
    let mut listeners = Vec::new();
    for (port, protocols) in ports {
        // Dropping this vector rolls back every successful bind on any failure.
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, port))
            .await
            .with_context(|| format!("无法监听本地代理端口 {port}"))?;
        listeners.push((listener, protocols));
    }
    let cancel = CancellationToken::new();
    let shutdown = cancel.clone();
    let (status_tx, status) = watch::channel(None);
    let task = tokio::spawn(async move {
        let tracker = TaskTracker::new();
        let slots = Arc::new(Semaphore::new(256));
        let mut acceptors = JoinSet::new();
        for (listener, protocols) in listeners {
            let router = router.clone();
            let cancel = shutdown.clone();
            let tracker = tracker.clone();
            let slots = slots.clone();
            acceptors.spawn(async move {
                loop {
                    let (socket, _) = listener.accept().await?;
                    let Ok(permit) = slots.clone().try_acquire_owned() else {
                        continue;
                    };
                    let router = router.clone();
                    let token = cancel.clone();
                    let tasks = tracker.clone();
                    spawn(&tracker, &cancel, async move {
                        let _ =
                            serve(socket, protocols, router, token, tasks, Arc::new(permit)).await;
                    });
                }
                #[allow(unreachable_code)]
                Ok::<(), std::io::Error>(())
            });
        }
        let reason = tokio::select! {
            biased;
            _ = shutdown.cancelled() => String::new(),
            _ = acceptors.join_next() => "动态代理监听已断开".to_owned(),
        };
        shutdown.cancel();
        acceptors.abort_all();
        while acceptors.join_next().await.is_some() {}
        tracker.close();
        tracker.wait().await;
        let _ = status_tx.send(Some(reason));
    });
    Ok(RunningProxy {
        cancel,
        status,
        task,
    })
}

fn spawn(
    tracker: &TaskTracker,
    token: &CancellationToken,
    task: impl Future<Output = ()> + Send + 'static,
) {
    let token = token.clone();
    tracker.spawn(async move {
        tokio::select! { biased; _ = token.cancelled() => {}, _ = task => {} }
    });
}

async fn serve(
    socket: TcpStream,
    protocols: u8,
    router: Arc<Router>,
    token: CancellationToken,
    tracker: TaskTracker,
    lease: Arc<OwnedSemaphorePermit>,
) -> Result<()> {
    let mut first = [0];
    let count = timeout(HEADER_TIMEOUT, socket.peek(&mut first)).await??;
    if count == 0 {
        return Ok(());
    }
    if first[0] == 5 {
        if protocols & SOCKS == 0 {
            return Ok(());
        }
        return socks(socket, router).await;
    }
    if protocols & (HTTP | HTTPS) == 0 {
        return Ok(());
    }
    hyper::server::conn::http1::Builder::new()
        .half_close(true)
        .max_buf_size(32768)
        .timer(TokioTimer::new())
        .header_read_timeout(HEADER_TIMEOUT)
        .serve_connection(
            TokioIo::new(socket),
            service_fn(move |req| {
                http(
                    req,
                    protocols,
                    router.clone(),
                    token.clone(),
                    tracker.clone(),
                    lease.clone(),
                )
            }),
        )
        .with_upgrades()
        .await?;
    Ok(())
}

type Body = BoxBody<Bytes, hyper::Error>;

fn response(status: StatusCode, text: &'static str) -> Response<Body> {
    let mut response = Response::new(
        Full::new(Bytes::from_static(text.as_bytes()))
            .map_err(|never: Infallible| match never {})
            .boxed(),
    );
    *response.status_mut() = status;
    response
}

fn authority(uri: &Uri, default_port: Option<u16>) -> Result<(String, u16)> {
    let authority = uri.authority().context("missing proxy authority")?;
    let raw = authority.as_str();
    ensure!(!raw.contains('@'), "userinfo is not supported");
    let (host, port_text) = if let Some(ipv6) = raw.strip_prefix('[') {
        let (host, rest) = ipv6.split_once(']').context("invalid IPv6 destination")?;
        host.parse::<Ipv6Addr>()?;
        let port = if rest.is_empty() {
            None
        } else {
            Some(rest.strip_prefix(':').context("invalid port")?)
        };
        (host, port)
    } else {
        let (host, port) = raw
            .split_once(':')
            .map_or((raw, None), |(h, p)| (h, Some(p)));
        (host, port)
    };
    let port = if let Some(text) = port_text {
        ensure!(
            !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()),
            "invalid port"
        );
        text.parse::<u16>()?
    } else {
        default_port.context("missing port")?
    };
    ensure!(
        !host.is_empty() && port > 0 && !host.contains('%'),
        "invalid destination"
    );
    Ok((host.to_owned(), port))
}

fn strip_hop_headers(headers: &mut hyper::HeaderMap) {
    let nominated: Vec<_> = headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|s| s.split(','))
        .filter_map(|s| hyper::header::HeaderName::from_bytes(s.trim().as_bytes()).ok())
        .collect();
    for name in nominated {
        headers.remove(name);
    }
    for name in [
        "connection",
        "proxy-connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ] {
        headers.remove(name);
    }
}

async fn http(
    mut req: Request<Incoming>,
    protocols: u8,
    router: Arc<Router>,
    token: CancellationToken,
    tracker: TaskTracker,
    lease: Arc<OwnedSemaphorePermit>,
) -> Result<Response<Body>, Infallible> {
    if req.method() == Method::CONNECT {
        if protocols & HTTPS == 0 {
            return Ok(response(
                StatusCode::FORBIDDEN,
                "HTTPS CONNECT is disabled\n",
            ));
        }
        let Ok((host, port)) = authority(req.uri(), None) else {
            return Ok(response(
                StatusCode::BAD_REQUEST,
                "Invalid CONNECT destination\n",
            ));
        };
        let Ok(mut target) = router.connect(&host, port).await else {
            return Ok(response(
                StatusCode::BAD_GATEWAY,
                "Proxy target connection failed\n",
            ));
        };
        let upgrade = hyper::upgrade::on(&mut req);
        spawn(&tracker, &token, async move {
            let _lease = lease;
            if let Ok(upgraded) = upgrade.await {
                let _ = copy_bidirectional(&mut TokioIo::new(upgraded), &mut target).await;
            }
        });
        return Ok(Response::new(
            Empty::<Bytes>::new()
                .map_err(|never: Infallible| match never {})
                .boxed(),
        ));
    }
    if protocols & HTTP == 0 {
        return Ok(response(
            StatusCode::FORBIDDEN,
            "HTTP proxying is disabled\n",
        ));
    }
    if req.uri().scheme_str() != Some("http") {
        return Ok(response(
            StatusCode::BAD_REQUEST,
            "Use an absolute HTTP URI or HTTPS CONNECT\n",
        ));
    }
    let Ok((host, port)) = authority(req.uri(), Some(80)) else {
        return Ok(response(
            StatusCode::BAD_REQUEST,
            "Invalid HTTP destination\n",
        ));
    };
    let authority = req.uri().authority().unwrap().as_str().to_owned();
    let path = req
        .uri()
        .path_and_query()
        .map_or("/", |p| p.as_str())
        .to_owned();
    *req.uri_mut() = path.parse().unwrap_or_else(|_| Uri::from_static("/"));
    strip_hop_headers(req.headers_mut());
    let Ok(host_header) = HeaderValue::from_str(&authority) else {
        return Ok(response(StatusCode::BAD_REQUEST, "Invalid Host\n"));
    };
    req.headers_mut().insert(HOST, host_header);
    let result = async {
        let target = router.connect(&host, port).await?;
        let (mut sender, connection) =
            hyper::client::conn::http1::handshake(TokioIo::new(target)).await?;
        spawn(&tracker, &token, async move {
            let _ = connection.await;
        });
        let response = timeout(RESPONSE_TIMEOUT, sender.send_request(req)).await??;
        Ok::<_, anyhow::Error>(response)
    }
    .await;
    Ok(match result {
        Ok(mut res) => {
            strip_hop_headers(res.headers_mut());
            res.map(|body| body.boxed())
        }
        Err(_) => response(StatusCode::BAD_GATEWAY, "Proxy target request failed\n"),
    })
}

async fn socks(mut socket: TcpStream, router: Arc<Router>) -> Result<()> {
    let target = timeout(HEADER_TIMEOUT, async {
        ensure!(socket.read_u8().await? == 5, "invalid SOCKS version");
        let length = socket.read_u8().await?;
        let mut methods = vec![0; length as usize];
        socket.read_exact(&mut methods).await?;
        if !methods.contains(&0) {
            socket.write_all(&[5, 0xff]).await?;
            bail!("no supported SOCKS authentication");
        }
        socket.write_all(&[5, 0]).await?;
        let mut header = [0; 4];
        socket.read_exact(&mut header).await?;
        ensure!(header[0] == 5 && header[2] == 0, "invalid SOCKS request");
        if header[1] != 1 {
            socket.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            bail!("only SOCKS CONNECT is supported");
        }
        let host = match header[3] {
            1 => {
                let mut bytes = [0; 4];
                socket.read_exact(&mut bytes).await?;
                Ipv4Addr::from(bytes).to_string()
            }
            4 => {
                let mut bytes = [0; 16];
                socket.read_exact(&mut bytes).await?;
                Ipv6Addr::from(bytes).to_string()
            }
            3 => {
                let length = socket.read_u8().await?;
                ensure!(length > 0, "empty SOCKS domain");
                let mut bytes = vec![0; length as usize];
                socket.read_exact(&mut bytes).await?;
                let host = String::from_utf8(bytes)?;
                ensure!(
                    host.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b)),
                    "invalid SOCKS domain"
                );
                host
            }
            _ => {
                socket.write_all(&[5, 8, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
                bail!("unsupported SOCKS address type");
            }
        };
        let port = socket.read_u16().await?;
        ensure!(port > 0, "invalid SOCKS port");
        Ok::<_, anyhow::Error>((host, port))
    })
    .await??;
    match router.connect(&target.0, target.1).await {
        Ok(mut target) => {
            socket.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            copy_bidirectional(&mut socket, &mut target).await?;
        }
        Err(_) => {
            socket.write_all(&[5, 5, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "proxy_tests.rs"]
mod tests;
