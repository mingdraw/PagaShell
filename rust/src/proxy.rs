//! Explicit HTTP / HTTPS CONNECT / SOCKS5 TCP proxies. Never decrypt website TLS.
use std::collections::{BTreeMap, HashMap, HashSet};
use std::convert::Infallible;
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, RwLock as StdRwLock};
use std::task::{Context as TaskContext, Poll};
use std::time::Duration;

use anyhow::{bail, ensure, Context, Result};
use http_body_util::{combinators::BoxBody, BodyExt, Empty, Full};
use hyper::body::{Body as HttpBody, Bytes, Frame, Incoming, SizeHint};
use hyper::header::{HeaderValue, CONNECTION, HOST};
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode, Uri, Version};
use hyper_util::rt::{TokioIo, TokioTimer};
use ipnet::IpNet;
use serde::Deserialize;
use tokio::io::{
    copy_bidirectional_with_sizes, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf,
};
use tokio::net::{lookup_host, TcpListener, TcpStream};
use tokio::sync::{watch, OwnedSemaphorePermit, Semaphore};
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::{timeout, timeout_at, Instant};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

use crate::api::page::PageGateway;
use crate::api::ssh::{ssh_gateway_handle, SshGatewayHandle};
use crate::page::PageConnector;

const OPEN_TIMEOUT: Duration = Duration::from_secs(15);
const HEADER_TIMEOUT: Duration = Duration::from_secs(15);
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(60);
const DNS_TTL: Duration = Duration::from_secs(30);
const DNS_CACHE_LIMIT: usize = 256;
const HAPPY_EYEBALLS_DELAY: Duration = Duration::from_millis(250);
const HTTP_POOL_IDLE_TTL: Duration = Duration::from_secs(30);
const HTTP_POOL_MAX_PER_HOST: usize = 8;
const HTTP_POOL_MAX_TOTAL: usize = 64;
const TUNNEL_BUFFER: usize = 64 * 1024;
pub(crate) const ACCEPT_RETRY_DELAY: Duration = Duration::from_millis(50);
const HTTP: u8 = 1;
const HTTPS: u8 = 2;
const SOCKS: u8 = 4;

fn interleave_addresses(addresses: &[SocketAddr]) -> Vec<SocketAddr> {
    let mut v6 = addresses.iter().copied().filter(SocketAddr::is_ipv6);
    let mut v4 = addresses.iter().copied().filter(SocketAddr::is_ipv4);
    let mut ordered = Vec::with_capacity(addresses.len());
    let mut prefer_v6 = addresses.first().is_some_and(SocketAddr::is_ipv6);
    while ordered.len() < addresses.len() {
        let next = if prefer_v6 {
            v6.next().or_else(|| v4.next())
        } else {
            v4.next().or_else(|| v6.next())
        };
        if let Some(addr) = next {
            ordered.push(addr);
        }
        prefer_v6 = !prefer_v6;
    }
    ordered
}

pub(crate) async fn connect_happy_eyeballs(addresses: &[SocketAddr]) -> std::io::Result<TcpStream> {
    match addresses {
        [] => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "no target addresses",
        )),
        [single] => TcpStream::connect(*single).await,
        many => {
            let ordered = interleave_addresses(many);
            let mut next = ordered.into_iter();
            let mut attempts = JoinSet::new();
            let mut last_error = None;
            if let Some(addr) = next.next() {
                attempts.spawn(TcpStream::connect(addr));
            }
            loop {
                if let Some(addr) = next.next() {
                    let delay = tokio::time::sleep(HAPPY_EYEBALLS_DELAY);
                    tokio::pin!(delay);
                    loop {
                        tokio::select! {
                            biased;
                            joined = attempts.join_next(), if !attempts.is_empty() => {
                                match joined {
                                    Some(Ok(Ok(stream))) => return Ok(stream),
                                    Some(Ok(Err(err))) => {
                                        last_error = Some(err);
                                        if attempts.is_empty() {
                                            break;
                                        }
                                    }
                                    Some(Err(_)) => {
                                        if attempts.is_empty() {
                                            break;
                                        }
                                    }
                                    None => break,
                                }
                            }
                            _ = &mut delay => break,
                        }
                    }
                    attempts.spawn(TcpStream::connect(addr));
                } else {
                    match attempts.join_next().await {
                        Some(Ok(Ok(stream))) => return Ok(stream),
                        Some(Ok(Err(err))) => last_error = Some(err),
                        Some(Err(_)) => {}
                        None => {
                            return Err(last_error.unwrap_or_else(|| {
                                std::io::Error::new(
                                    std::io::ErrorKind::NotConnected,
                                    "all target addresses failed",
                                )
                            }));
                        }
                    }
                }
            }
        }
    }
}

pub(crate) fn is_transient_accept_error(error: &std::io::Error) -> bool {
    use std::io::ErrorKind::*;
    if matches!(
        error.kind(),
        ConnectionRefused
            | ConnectionAborted
            | ConnectionReset
            | Interrupted
            | WouldBlock
            | TimedOut
    ) {
        return true;
    }
    match error.raw_os_error() {
        #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
        Some(12 | 23 | 24 | 53 | 54 | 55) => true,
        #[cfg(target_os = "linux")]
        Some(12 | 23 | 24 | 103 | 104 | 105) => true,
        #[cfg(target_os = "windows")]
        Some(10024 | 10053 | 10054 | 10055) => true,
        _ => false,
    }
}

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
}

#[derive(Default)]
struct RuleIndex {
    exact: HashSet<String>,
    suffix: HashSet<String>,
    prefix: HashSet<String>,
    prefix_lengths: Vec<usize>,
    networks: HashSet<IpNet>,
    v4_prefixes: Vec<u8>,
    v6_prefixes: Vec<u8>,
}

impl FromIterator<Rule> for RuleIndex {
    fn from_iter<T: IntoIterator<Item = Rule>>(rules: T) -> Self {
        let mut index = Self::default();
        let mut v4 = [false; 33];
        let mut v6 = [false; 129];
        for rule in rules {
            match rule {
                Rule::Ip(net) => {
                    index.networks.insert(net.trunc());
                    match net {
                        IpNet::V4(_) => v4[usize::from(net.prefix_len())] = true,
                        IpNet::V6(_) => v6[usize::from(net.prefix_len())] = true,
                    }
                }
                Rule::Domain(RuleType::DomainExact, name) => {
                    index.exact.insert(name);
                }
                Rule::Domain(RuleType::DomainPrefix, name) => {
                    index.prefix.insert(name);
                }
                Rule::Domain(RuleType::DomainSuffix, name) => {
                    index.suffix.insert(name);
                }
                Rule::Domain(RuleType::Ip, _) => unreachable!("IP rules parse as networks"),
            }
        }
        index.prefix_lengths = index.prefix.iter().map(String::len).collect();
        index.prefix_lengths.sort_unstable();
        index.prefix_lengths.dedup();
        index.v4_prefixes = v4
            .iter()
            .enumerate()
            .filter_map(|(n, present)| present.then_some(n as u8))
            .collect();
        index.v6_prefixes = v6
            .iter()
            .enumerate()
            .filter_map(|(n, present)| present.then_some(n as u8))
            .collect();
        index
    }
}

impl RuleIndex {
    fn domain_matches(&self, host: &str) -> bool {
        self.exact.contains(host)
            || self.suffix.contains(host)
            || (!self.suffix.is_empty()
                && host
                    .match_indices('.')
                    .any(|(at, _)| self.suffix.contains(&host[at + 1..])))
            || self
                .prefix_lengths
                .iter()
                .take_while(|&&len| len <= host.len())
                .filter_map(|&len| host.get(..len))
                .any(|prefix| self.prefix.contains(prefix))
    }

    fn ip_matches(&self, ip: IpAddr) -> bool {
        let prefixes = if ip.is_ipv4() {
            &self.v4_prefixes
        } else {
            &self.v6_prefixes
        };
        prefixes.iter().any(|&len| {
            self.networks
                .contains(&IpNet::new(ip, len).expect("same address family").trunc())
        })
    }
}

trait ProxyIo: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> ProxyIo for T {}
type Stream = Box<dyn ProxyIo>;

#[derive(Default)]
struct Traffic {
    sent: AtomicU64,
    received: AtomicU64,
}

// Meter the target stream after dialing or tunnelling through the gateway.
// This includes HTTP framing, but excludes proxy negotiation and gateway overhead.
struct MeteredStream {
    io: Stream,
    traffic: Arc<Traffic>,
}

impl AsyncRead for MeteredStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let result = Pin::new(&mut self.io).poll_read(cx, buf);
        if matches!(result, Poll::Ready(Ok(()))) {
            self.traffic
                .received
                .fetch_add((buf.filled().len() - before) as u64, Ordering::Relaxed);
        }
        result
    }
}

impl AsyncWrite for MeteredStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let result = Pin::new(&mut self.io).poll_write(cx, buf);
        if let Poll::Ready(Ok(written)) = result {
            self.traffic
                .sent
                .fetch_add(written as u64, Ordering::Relaxed);
        }
        result
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.io).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.io).poll_shutdown(cx)
    }
}

enum Gateway {
    Ssh(SshGatewayHandle),
    Page(PageConnector),
}

enum Route {
    Gateway,
    Direct,
    Resolved(Arc<[SocketAddr]>),
}

struct RoutingTable {
    mode: Mode,
    rules: RuleIndex,
    version: u64,
}

struct DnsEntry {
    ips: Arc<[IpAddr]>,
    expires: Instant,
    last_used: u64,
}

type DnsWatch = watch::Receiver<Option<std::result::Result<Arc<[IpAddr]>, String>>>;

#[derive(Default)]
struct DnsCacheState {
    entries: HashMap<String, DnsEntry>,
    in_flight: HashMap<String, DnsWatch>,
    tick: u64,
}

#[derive(Default)]
struct DnsCache {
    state: StdMutex<DnsCacheState>,
}

struct DnsInFlightGuard<'a> {
    cache: &'a DnsCache,
    key: String,
}

impl Drop for DnsInFlightGuard<'_> {
    fn drop(&mut self) {
        self.cache.state.lock().unwrap().in_flight.remove(&self.key);
    }
}

fn with_port(ips: &[IpAddr], port: u16) -> Arc<[SocketAddr]> {
    ips.iter()
        .copied()
        .map(|ip| SocketAddr::new(ip, port))
        .collect()
}

impl DnsCache {
    fn put(&self, key: String, ips: Arc<[IpAddr]>, expires: Instant) {
        let mut state = self.state.lock().unwrap();
        let now = Instant::now();
        state.entries.retain(|_, entry| entry.expires > now);
        if state.entries.len() >= DNS_CACHE_LIMIT && !state.entries.contains_key(&key) {
            if let Some(oldest) = state
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.last_used)
                .map(|(k, _)| k.clone())
            {
                state.entries.remove(&oldest);
            }
        }
        state.tick += 1;
        let last_used = state.tick;
        state.entries.insert(
            key,
            DnsEntry {
                ips,
                expires,
                last_used,
            },
        );
    }

    async fn resolve(&self, host: &str, port: u16) -> Result<Arc<[SocketAddr]>> {
        let key = host.trim_end_matches('.').to_ascii_lowercase();
        loop {
            let action = {
                let mut guard = self.state.lock().unwrap();
                let state = &mut *guard;
                let now = Instant::now();
                if let Some(entry) = state.entries.get_mut(&key) {
                    if entry.expires > now {
                        state.tick += 1;
                        entry.last_used = state.tick;
                        return Ok(with_port(&entry.ips, port));
                    }
                    state.entries.remove(&key);
                }
                if let Some(existing) = state.in_flight.get(&key) {
                    Err(existing.clone())
                } else {
                    let (tx, rx) = watch::channel(None);
                    state.in_flight.insert(key.clone(), rx);
                    Ok(tx)
                }
            };
            match action {
                Err(mut rx) => loop {
                    if let Some(result) = rx.borrow_and_update().clone() {
                        return result
                            .map(|ips| with_port(&ips, port))
                            .map_err(anyhow::Error::msg);
                    }
                    if rx.changed().await.is_err() {
                        break;
                    }
                },
                Ok(tx) => {
                    let _guard = DnsInFlightGuard {
                        cache: self,
                        key: key.clone(),
                    };
                    let lookup = lookup_host((host, port))
                        .await
                        .context("无法解析代理目标地址")
                        .and_then(|iter| {
                            let mut unique = Vec::new();
                            for addr in iter {
                                if !unique.contains(&addr.ip()) {
                                    unique.push(addr.ip());
                                }
                            }
                            ensure!(!unique.is_empty(), "无法解析代理目标地址");
                            Ok(Arc::<[IpAddr]>::from(unique))
                        });
                    match lookup {
                        Ok(ips) => {
                            self.put(key, ips.clone(), Instant::now() + DNS_TTL);
                            let _ = tx.send(Some(Ok(ips.clone())));
                            return Ok(with_port(&ips, port));
                        }
                        Err(error) => {
                            let message = error.to_string();
                            let _ = tx.send(Some(Err(message)));
                            return Err(error);
                        }
                    }
                }
            }
        }
    }
}

type HttpPoolKey = (String, u16, u64);

struct PooledHttp {
    sender: hyper::client::conn::http1::SendRequest<Incoming>,
    last_used: Instant,
}

#[derive(Default)]
struct HttpPool {
    idle: StdMutex<HashMap<HttpPoolKey, Vec<PooledHttp>>>,
}

impl HttpPool {
    fn prune_locked(map: &mut HashMap<HttpPoolKey, Vec<PooledHttp>>, now: Instant) {
        map.retain(|_, entries| {
            entries.retain(|entry| {
                !entry.sender.is_closed()
                    && now.saturating_duration_since(entry.last_used) < HTTP_POOL_IDLE_TTL
            });
            !entries.is_empty()
        });
    }

    fn take(&self, key: &HttpPoolKey) -> Option<hyper::client::conn::http1::SendRequest<Incoming>> {
        let mut map = self.idle.lock().unwrap();
        let now = Instant::now();
        let entries = map.get_mut(key)?;
        while let Some(entry) = entries.pop() {
            if !entry.sender.is_closed()
                && now.saturating_duration_since(entry.last_used) < HTTP_POOL_IDLE_TTL
            {
                if entries.is_empty() {
                    map.remove(key);
                }
                return Some(entry.sender);
            }
        }
        map.remove(key);
        None
    }

    fn put(&self, key: HttpPoolKey, sender: hyper::client::conn::http1::SendRequest<Incoming>) {
        if sender.is_closed() {
            return;
        }
        let mut map = self.idle.lock().unwrap();
        let now = Instant::now();
        Self::prune_locked(&mut map, now);
        let total: usize = map.values().map(Vec::len).sum();
        if total >= HTTP_POOL_MAX_TOTAL {
            if let Some(oldest_key) = map
                .iter()
                .filter_map(|(k, entries)| {
                    entries.first().map(|entry| (k.clone(), entry.last_used))
                })
                .min_by_key(|(_, used)| *used)
                .map(|(k, _)| k)
            {
                if let Some(entries) = map.get_mut(&oldest_key) {
                    entries.remove(0);
                    if entries.is_empty() {
                        map.remove(&oldest_key);
                    }
                }
            }
        }
        let entries = map.entry(key).or_default();
        if entries.len() >= HTTP_POOL_MAX_PER_HOST {
            entries.remove(0);
        }
        entries.push(PooledHttp {
            sender,
            last_used: now,
        });
    }

    fn clear(&self) {
        self.idle.lock().unwrap().clear();
    }
}

pub(crate) struct Router {
    routing: StdRwLock<Arc<RoutingTable>>,
    gateway: Option<Gateway>,
    traffic: Arc<Traffic>,
    dns: DnsCache,
    http_pool: HttpPool,
}

impl Router {
    fn new(mode: Mode, rules: impl IntoIterator<Item = Rule>, gateway: Option<Gateway>) -> Self {
        Self {
            routing: StdRwLock::new(Arc::new(RoutingTable {
                mode,
                rules: rules.into_iter().collect(),
                version: 1,
            })),
            gateway,
            traffic: Arc::default(),
            dns: DnsCache::default(),
            http_pool: HttpPool::default(),
        }
    }

    fn current_routing(&self) -> Arc<RoutingTable> {
        self.routing.read().unwrap().clone()
    }

    fn routing_version(&self) -> u64 {
        self.routing.read().unwrap().version
    }

    fn update_routing(&self, mode: Mode, rules: impl IntoIterator<Item = Rule>) {
        let index: RuleIndex = rules.into_iter().collect();
        {
            let mut guard = self.routing.write().unwrap();
            let next_version = guard.version.wrapping_add(1).max(1);
            *guard = Arc::new(RoutingTable {
                mode,
                rules: index,
                version: next_version,
            });
        }
        self.http_pool.clear();
    }

    async fn resolve(&self, host: &str, port: u16) -> Result<Arc<[SocketAddr]>> {
        self.dns.resolve(host, port).await
    }

    #[cfg(test)]
    async fn route(&self, host: &str, port: u16) -> Result<Route> {
        let routing = self.current_routing();
        self.route_with(&routing, host, port).await
    }

    async fn route_with(&self, routing: &RoutingTable, host: &str, port: u16) -> Result<Route> {
        if routing.mode == Mode::Global {
            return Ok(Route::Gateway);
        }
        let normalized = host.trim_end_matches('.').to_ascii_lowercase();
        if let Ok(ip) = normalized.parse::<IpAddr>() {
            return Ok(if routing.rules.ip_matches(ip) {
                Route::Gateway
            } else {
                Route::Direct
            });
        }
        if routing.rules.domain_matches(&normalized) {
            return Ok(Route::Gateway);
        }
        // Only IP rules need DNS before routing. A domain match retains DNS on
        // the gateway; direct access reuses the very addresses we evaluated.
        if routing.rules.networks.is_empty() {
            return Ok(Route::Direct);
        }
        let addresses = self.resolve(host, port).await?;
        if addresses
            .iter()
            .any(|address| routing.rules.ip_matches(address.ip()))
        {
            Ok(Route::Gateway)
        } else {
            Ok(Route::Resolved(addresses))
        }
    }

    async fn connect(&self, host: &str, port: u16) -> Result<Stream> {
        self.connect_with_version(host, port)
            .await
            .map(|(stream, _)| stream)
    }

    async fn connect_with_version(&self, host: &str, port: u16) -> Result<(Stream, u64)> {
        let routing = self.current_routing();
        let version = routing.version;
        let deadline = Instant::now() + OPEN_TIMEOUT;
        let io = timeout_at(deadline, async {
            let direct = match self.route_with(&routing, host, port).await? {
                Route::Gateway => {
                    // A selected gateway failure is never retried using direct access.
                    return match self.gateway.as_ref().context("所选网关不可用")? {
                        Gateway::Ssh(gateway) => Ok(Box::new(
                            gateway.open_direct_tcpip(host.to_owned(), port).await?,
                        ) as Stream),
                        Gateway::Page(gateway) => {
                            Ok(Box::new(gateway.connect(host, port, deadline).await?) as Stream)
                        }
                    };
                }
                Route::Direct => {
                    if let Ok(ip) = host.trim_end_matches('.').parse::<IpAddr>() {
                        TcpStream::connect(SocketAddr::new(ip, port)).await?
                    } else {
                        let addresses = self.resolve(host, port).await?;
                        connect_happy_eyeballs(&addresses).await?
                    }
                }
                Route::Resolved(addresses) => connect_happy_eyeballs(&addresses).await?,
            };
            direct.set_nodelay(true)?;
            Ok::<_, anyhow::Error>(Box::new(direct) as Stream)
        })
        .await
        .context("代理目标连接超时")??;
        Ok((
            Box::new(MeteredStream {
                io,
                traffic: self.traffic.clone(),
            }),
            version,
        ))
    }
}

pub(crate) struct RunningProxy {
    cancel: CancellationToken,
    pub(crate) status: watch::Receiver<Option<String>>,
    task: JoinHandle<()>,
    traffic: Arc<Traffic>,
    pub(crate) router: Arc<Router>,
}

impl RunningProxy {
    pub(crate) fn traffic(&self) -> (u64, u64) {
        (
            self.traffic.sent.load(Ordering::Relaxed),
            self.traffic.received.load(Ordering::Relaxed),
        )
    }

    #[cfg(test)]
    pub(crate) fn update_routing(&self, json: &str) -> Result<()> {
        update_routing(&self.router, json)
    }

    pub(crate) async fn stop(self) {
        self.cancel.cancel();
        let _ = self.task.await;
    }
}

pub(crate) fn update_routing(router: &Router, json: &str) -> Result<()> {
    ensure!(json.len() <= 1024 * 1024, "代理配置过大");
    let config: Config = serde_json::from_str(json).context("代理配置无效")?;
    ensure!(config.rules.len() <= 10000, "代理规则过多");
    let rules = config
        .rules
        .into_iter()
        .map(Rule::parse)
        .collect::<Result<Vec<_>>>()?;
    router.update_routing(config.mode, rules);
    Ok(())
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
    let ssh_monitor = if let Some(id) = ssh_id {
        Some(ssh_gateway_handle(id).await?)
    } else {
        None
    };
    let gateway = ssh_monitor
        .clone()
        .map(Gateway::Ssh)
        .or(page.map(PageConnector::new).transpose()?.map(Gateway::Page));
    ensure!(gateway.is_some(), "所选网关不可用");
    let router = Arc::new(Router::new(
        config.mode,
        config
            .rules
            .into_iter()
            .map(Rule::parse)
            .collect::<Result<Vec<_>>>()?,
        gateway,
    ));
    let traffic = router.traffic.clone();
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
    let running_router = router.clone();
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
                    let (socket, _) = match listener.accept().await {
                        Ok(accepted) => accepted,
                        Err(error) if is_transient_accept_error(&error) => {
                            tokio::select! {
                                biased;
                                _ = cancel.cancelled() => return Ok(()),
                                _ = tokio::time::sleep(ACCEPT_RETRY_DELAY) => continue,
                            }
                        }
                        Err(error) => return Err(error),
                    };
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
        let monitor_ssh = async {
            if let Some(ssh) = ssh_monitor {
                let mut tick = tokio::time::interval(Duration::from_millis(250));
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                loop {
                    tick.tick().await;
                    if ssh.is_closed() {
                        break;
                    }
                }
            } else {
                std::future::pending::<()>().await;
            }
        };
        let reason = tokio::select! {
            biased;
            _ = shutdown.cancelled() => String::new(),
            _ = acceptors.join_next() => "动态代理监听已断开".to_owned(),
            _ = monitor_ssh => "SSH 网关连接已断开".to_owned(),
        };
        shutdown.cancel();
        router.http_pool.clear();
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
        traffic,
        router: running_router,
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
    socket.set_nodelay(true)?;
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

struct PoolReturn {
    router: Arc<Router>,
    key: HttpPoolKey,
    sender: hyper::client::conn::http1::SendRequest<Incoming>,
}

impl PoolReturn {
    fn recycle(self) {
        if self.router.routing_version() == self.key.2 {
            self.router.http_pool.put(self.key, self.sender);
        }
    }
}

struct PoolReturnBody {
    inner: Incoming,
    slot: Option<PoolReturn>,
}

impl HttpBody for PoolReturnBody {
    type Data = Bytes;
    type Error = hyper::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
    ) -> Poll<Option<std::result::Result<Frame<Self::Data>, Self::Error>>> {
        let result = Pin::new(&mut self.inner).poll_frame(cx);
        match &result {
            Poll::Ready(None) => {
                if let Some(entry) = self.slot.take() {
                    entry.recycle();
                }
            }
            Poll::Ready(Some(Ok(_))) if self.inner.is_end_stream() => {
                if let Some(entry) = self.slot.take() {
                    entry.recycle();
                }
            }
            Poll::Ready(Some(Err(_))) => {
                self.slot = None;
            }
            _ => {}
        }
        result
    }

    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.inner.size_hint()
    }
}

impl Drop for PoolReturnBody {
    fn drop(&mut self) {
        if self.inner.is_end_stream() {
            if let Some(entry) = self.slot.take() {
                entry.recycle();
            }
        }
    }
}

fn response_allows_keep_alive<B>(res: &Response<B>) -> bool {
    if res.version() != Version::HTTP_11 || res.status().is_informational() {
        return false;
    }
    !res.headers()
        .get_all(CONNECTION)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|s| s.split(','))
        .any(|token| token.trim().eq_ignore_ascii_case("close"))
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
                let _ = copy_bidirectional_with_sizes(
                    &mut TokioIo::new(upgraded),
                    &mut target,
                    TUNNEL_BUFFER,
                    TUNNEL_BUFFER,
                )
                .await;
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
    let req_is_http11 = req.version() == Version::HTTP_11;
    let normalized_host = host.trim_end_matches('.').to_ascii_lowercase();
    let result = async {
        let initial_version = router.routing_version();
        let initial_key = (normalized_host.clone(), port, initial_version);
        let mut reused = None;
        if req_is_http11 {
            while let Some(mut candidate) = router.http_pool.take(&initial_key) {
                if candidate.ready().await.is_ok() {
                    reused = Some(candidate);
                    break;
                }
            }
        }
        let (mut sender, pool_key) = if let Some(sender) = reused {
            (sender, initial_key)
        } else {
            let (target, used_version) = router.connect_with_version(&host, port).await?;
            let (mut sender, connection) =
                hyper::client::conn::http1::handshake(TokioIo::new(target)).await?;
            spawn(&tracker, &token, async move {
                let _ = connection.await;
            });
            sender.ready().await?;
            (sender, (normalized_host, port, used_version))
        };
        let response = timeout(RESPONSE_TIMEOUT, sender.send_request(req)).await??;
        Ok::<_, anyhow::Error>((response, sender, pool_key))
    }
    .await;
    Ok(match result {
        Ok((mut res, sender, pool_key)) => {
            let keep_alive = req_is_http11 && response_allows_keep_alive(&res);
            strip_hop_headers(res.headers_mut());
            if keep_alive {
                let slot = PoolReturn {
                    router: router.clone(),
                    key: pool_key,
                    sender,
                };
                if res.body().is_end_stream() {
                    slot.recycle();
                    res.map(|body| body.boxed())
                } else {
                    res.map(|inner| {
                        PoolReturnBody {
                            inner,
                            slot: Some(slot),
                        }
                        .boxed()
                    })
                }
            } else {
                res.map(|body| body.boxed())
            }
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
            copy_bidirectional_with_sizes(&mut socket, &mut target, TUNNEL_BUFFER, TUNNEL_BUFFER)
                .await?;
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
