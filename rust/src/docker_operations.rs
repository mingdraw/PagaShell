use std::collections::HashSet;
use std::future::Future;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, ensure, Result};
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::{Method, Request};
use hyper_util::rt::TokioIo;
use serde_json::{json, Map, Value};
use tokio::time::Instant;

use crate::api::docker::{
    shell_argument, validate_docker_id, DockerContainerAction, DockerImageAction,
    DockerResourceKind,
};
use crate::api::ssh::{
    docker_api_channel, read_only_exec, server_status_command, ReadOnlyExecPolicy,
};

#[path = "docker_compose.rs"]
pub(crate) mod compose;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const OPERATION_TIMEOUT: Duration = Duration::from_secs(12 * 60);
const RESPONSE_LIMIT: usize = 8 * 1024 * 1024;
const TIMEOUT: &str = "Docker 操作超时，请刷新列表确认容器状态";
const CONNECTION: &str = "无法连接 Docker API，请检查连接";
const PERMISSION: &str = "没有权限操作 Docker 容器";
const GONE: &str = "Docker 资源可能已移除，请刷新后重试";
const CREATE_FAILED: &str = "无法创建新容器，原容器未变更，请检查镜像及运行配置";

static ACTIVE: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

struct OperationGuard(String);
impl OperationGuard {
    fn acquire(id: &str) -> Result<Self> {
        let mut active = ACTIVE
            .lock()
            .map_err(|_| anyhow!("容器操作暂不可用，请重试"))?;
        ensure!(
            active.insert(id.to_owned()),
            "容器正在执行其他操作，请稍后再试"
        );
        Ok(Self(id.to_owned()))
    }
}
impl Drop for OperationGuard {
    fn drop(&mut self) {
        if let Ok(mut active) = ACTIVE.lock() {
            active.remove(&self.0);
        }
    }
}

const ACCESS_POLICY: ReadOnlyExecPolicy = ReadOnlyExecPolicy {
    overall_timeout: Some(Duration::from_secs(8)),
    closed: "Docker 操作连接已关闭",
    timeout: TIMEOUT,
    connection: CONNECTION,
    denied: PERMISSION,
    too_large: "Docker 操作响应过大",
    incomplete: CONNECTION,
};
const PULL_POLICY: ReadOnlyExecPolicy = ReadOnlyExecPolicy {
    overall_timeout: Some(Duration::from_secs(10 * 60)),
    ..ACCESS_POLICY
};

#[derive(Clone)]
struct Access {
    binary: String,
    endpoint: String,
    sudo: bool,
    config: String,
    api: String,
    api_minor: u32,
}
impl Access {
    async fn prepare(session: u32) -> Result<Self> {
        let (output, code) = read_only_exec(
            session,
            server_status_command(include_str!("api/docker_access.sh")),
            &ACCESS_POLICY,
            16 * 1024,
        )
        .await?;
        match code {
            0 => Self::parse(&output),
            64 => Err(anyhow!("Docker 管理仅支持 Linux 和 macOS")),
            70 => Err(anyhow!("Docker 未运行")),
            77 => Err(anyhow!(PERMISSION)),
            _ => Err(anyhow!(CONNECTION)),
        }
    }

    fn parse(output: &[u8]) -> Result<Self> {
        let text = std::str::from_utf8(output).map_err(|_| anyhow!(CONNECTION))?;
        let fields: Vec<_> = text.lines().collect();
        ensure!(
            fields.len() == 6 && fields[0] == "PAGA_DOCKER_ACCESS_V1",
            "{CONNECTION}"
        );
        ensure!(
            !fields.iter().any(|s| s.chars().any(char::is_control)),
            "{CONNECTION}"
        );
        ensure!(
            !fields[1].is_empty() && !fields[1].starts_with('-') && matches!(fields[3], "0" | "1"),
            "{CONNECTION}"
        );
        ensure!(
            fields[3] != "1" || (fields[2].starts_with("unix://") && fields[2].len() > 7),
            "{CONNECTION}"
        );
        let minor = fields[5]
            .strip_prefix("1.")
            .filter(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|v| (24..1000).contains(v))
            .ok_or_else(|| anyhow!("Docker API 版本不支持此操作"))?;
        Ok(Self {
            binary: fields[1].into(),
            endpoint: fields[2].into(),
            sudo: fields[3] == "1",
            config: fields[4].into(),
            api: fields[5].into(),
            api_minor: minor,
        })
    }

    fn cli(&self) -> String {
        if self.sudo {
            format!(
                "unset DOCKER_CONTEXT DOCKER_HOST; exec sudo -n -- {} --config {} --host {}",
                shell_argument(&self.binary),
                shell_argument(&self.config),
                shell_argument(&self.endpoint)
            )
        } else {
            shell_argument(&self.binary)
        }
    }
}

#[derive(Clone)]
struct Client {
    session: u32,
    access: Access,
    deadline: Instant,
}

struct Response {
    status: u16,
    body: Vec<u8>,
}
impl Response {
    fn expect(&self, allowed: &[u16], message: &'static str) -> Result<()> {
        ensure!(!matches!(self.status, 401 | 403), "{PERMISSION}");
        ensure!(self.status != 404, "{GONE}");
        ensure!(allowed.contains(&self.status), "{message}");
        Ok(())
    }
    fn json(&self) -> Result<Value> {
        serde_json::from_slice(&self.body).map_err(|_| anyhow!("Docker 返回的数据无效，请重试"))
    }
}

trait Engine: Sync {
    fn request(
        &self,
        method: Method,
        path: String,
        body: Option<Value>,
    ) -> impl Future<Output = Result<Response>> + Send;
    fn pull(&self, image: &str) -> impl Future<Output = Result<()>> + Send;
    fn tick(&self) -> impl Future<Output = ()> + Send;
    fn recovery(&self) -> Self;
    fn api_minor(&self) -> u32;
}

struct Driver(tokio::task::JoinHandle<()>);
impl Drop for Driver {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl Engine for Client {
    async fn request(&self, method: Method, path: String, body: Option<Value>) -> Result<Response> {
        let deadline = self.deadline.min(Instant::now() + REQUEST_TIMEOUT);
        tokio::time::timeout_at(deadline, async {
            let channel = docker_api_channel(
                self.session,
                format!("{} system dial-stdio", self.access.cli()),
            )
            .await?;
            let (mut sender, connection) =
                hyper::client::conn::http1::handshake(TokioIo::new(channel.into_stream()))
                    .await
                    .map_err(|_| anyhow!(CONNECTION))?;
            let _driver = Driver(tokio::spawn(async move {
                let _ = connection.await;
            }));
            // Env、命令和卷选项只经过 SSH 的 HTTP body；不进入 argv、日志或 Dart。
            let bytes = body
                .map(|v| serde_json::to_vec(&v))
                .transpose()
                .map_err(|_| anyhow!("容器配置无效"))?
                .unwrap_or_default();
            ensure!(
                bytes.len() <= RESPONSE_LIMIT,
                "容器配置过大，无法执行此操作"
            );
            let request = Request::builder()
                .method(method)
                .uri(format!("/v{}{}", self.access.api, path))
                .header("Host", "docker")
                .header("Connection", "close")
                .header("Content-Type", "application/json")
                .body(Full::new(Bytes::from(bytes)))
                .map_err(|_| anyhow!("Docker 请求无效"))?;
            let response = sender
                .send_request(request)
                .await
                .map_err(|_| anyhow!(CONNECTION))?;
            let status = response.status().as_u16();
            let mut body = response.into_body();
            let mut bytes = Vec::new();
            while let Some(frame) = body.frame().await {
                if let Some(data) = frame.map_err(|_| anyhow!(CONNECTION))?.data_ref() {
                    ensure!(
                        bytes.len() + data.len() <= RESPONSE_LIMIT,
                        "Docker 操作响应过大"
                    );
                    bytes.extend_from_slice(data);
                }
            }
            Ok(Response {
                status,
                body: bytes,
            })
        })
        .await
        .map_err(|_| anyhow!(TIMEOUT))?
    }

    async fn pull(&self, image: &str) -> Result<()> {
        // CLI 处理用户已有的 registry 登录与 credential helper；不读取或传出凭据。
        let command = format!(
            "{} image pull {} >/dev/null 2>/dev/null",
            self.access.cli(),
            shell_argument(image)
        );
        let (_, code) = tokio::time::timeout_at(
            self.deadline,
            read_only_exec(self.session, command, &PULL_POLICY, 16 * 1024),
        )
        .await
        .map_err(|_| anyhow!(TIMEOUT))??;
        ensure!(
            code == 0,
            "无法拉取目标镜像，请检查镜像名称、仓库权限和网络"
        );
        Ok(())
    }
    async fn tick(&self) {
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    fn recovery(&self) -> Self {
        Self {
            deadline: Instant::now() + Duration::from_secs(180),
            ..self.clone()
        }
    }
    fn api_minor(&self) -> u32 {
        self.access.api_minor
    }
}

fn component(value: &str) -> String {
    let mut result = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            result.push(byte as char);
        } else {
            use std::fmt::Write;
            let _ = write!(result, "%{byte:02X}");
        }
    }
    result
}

fn validate_image(image: &str) -> Result<()> {
    ensure!(
        !image.is_empty()
            && image.len() <= 1024
            && !image.starts_with('-')
            && image
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._:/@-[]".contains(&b)),
        "目标镜像格式无效"
    );
    Ok(())
}

async fn inspect<E: Engine>(engine: &E, id: &str) -> Result<Value> {
    let response = engine
        .request(
            Method::GET,
            format!("/containers/{}/json", component(id)),
            None,
        )
        .await?;
    response.expect(&[200], "无法读取容器配置，请刷新后重试")?;
    response.json()
}

async fn post<E: Engine>(engine: &E, id: &str, suffix: &str, message: &'static str) -> Result<()> {
    engine
        .request(
            Method::POST,
            format!("/containers/{}{suffix}", component(id)),
            None,
        )
        .await?
        .expect(&[204, 304], message)
}

async fn remove<E: Engine>(engine: &E, id: &str, force: bool) -> Result<()> {
    let response = engine
        .request(
            Method::DELETE,
            format!("/containers/{}?force={force}&v=false", component(id)),
            None,
        )
        .await?;
    if response.status == 404 {
        return Ok(());
    }
    response.expect(&[204], "无法删除容器，请刷新后检查")
}

fn running(container: &Value) -> bool {
    container
        .pointer("/State/Running")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn creation_config(original: &Value, image: &str, api_minor: u32) -> Result<Value> {
    let mut config = original
        .get("Config")
        .and_then(Value::as_object)
        .cloned()
        .ok_or_else(|| anyhow!("容器配置无效"))?;
    let mut host = original
        .get("HostConfig")
        .and_then(Value::as_object)
        .cloned()
        .ok_or_else(|| anyhow!("容器配置无效"))?;
    config.insert("Image".into(), Value::String(image.into()));
    // 保留已分配的公开端口，包括最初通过 -P 或端口 0 分配的随机端口。
    if let Some(runtime) = original
        .pointer("/NetworkSettings/Ports")
        .and_then(Value::as_object)
    {
        let mut bindings = host
            .get("PortBindings")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        for (port, values) in runtime {
            if values.as_array().is_none_or(Vec::is_empty) {
                continue;
            }
            let random = bindings
                .get(port)
                .and_then(Value::as_array)
                .is_none_or(|entries| {
                    entries.is_empty()
                        || entries.iter().any(|entry| {
                            matches!(
                                entry.get("HostPort").and_then(Value::as_str),
                                None | Some("") | Some("0")
                            )
                        })
                });
            if random {
                bindings.insert(port.clone(), values.clone());
            }
        }
        if !bindings.is_empty() {
            host.insert("PortBindings".into(), Value::Object(bindings));
        }
    }
    // 显式挂回匿名卷，不能让 Config.Volumes 在新容器中分配空卷。
    let binds: Vec<&str> = host
        .get("Binds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let mut mounts = host
        .get("Mounts")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for mount in original
        .get("Mounts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if mount.get("Type").and_then(Value::as_str) != Some("volume") {
            continue;
        }
        let target = mount
            .get("Destination")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("容器卷配置无效"))?;
        if mounts
            .iter()
            .any(|v| v.get("Target").and_then(Value::as_str) == Some(target))
            || binds
                .iter()
                .any(|v| v.ends_with(&format!(":{target}")) || v.contains(&format!(":{target}:")))
        {
            continue;
        }
        let name = mount
            .get("Name")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow!("容器卷配置无效"))?;
        mounts.push(json!({"Type":"volume", "Source":name, "Target":target, "ReadOnly":mount.get("RW").and_then(Value::as_bool) == Some(false), "VolumeOptions":{"NoCopy":true}}));
    }
    if !mounts.is_empty() {
        host.insert("Mounts".into(), Value::Array(mounts));
    }
    let mode = host
        .get("NetworkMode")
        .and_then(Value::as_str)
        .unwrap_or("default")
        .to_owned();
    config.insert("HostConfig".into(), Value::Object(host));
    if !matches!(mode.as_str(), "host" | "none") && !mode.starts_with("container:") {
        let mut endpoints = Map::new();
        for (name, endpoint) in original
            .pointer("/NetworkSettings/Networks")
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
        {
            let mut settings = Map::new();
            for key in [
                "IPAMConfig",
                "Links",
                "Aliases",
                "DriverOpts",
                "GwPriority",
                "MacAddress",
            ] {
                if (key == "MacAddress" && api_minor < 44)
                    || (key == "GwPriority" && api_minor < 48)
                    || (key == "Aliases" && matches!(name.as_str(), "bridge" | "host" | "none"))
                {
                    continue;
                }
                if let Some(value) = endpoint.get(key).filter(|v| !v.is_null()) {
                    settings.insert(key.into(), value.clone());
                }
            }
            // 自动生成的旧容器 ID 不能成为替代容器的别名。
            if let Some(aliases) = settings.get_mut("Aliases").and_then(Value::as_array_mut) {
                let id = original.get("Id").and_then(Value::as_str).unwrap_or("");
                aliases.retain(|v| {
                    v.as_str()
                        .is_none_or(|alias| alias != id && Some(alias) != id.get(..12))
                });
            }
            endpoints.insert(name.clone(), Value::Object(settings));
        }
        config.insert(
            "NetworkingConfig".into(),
            json!({"EndpointsConfig":endpoints}),
        );
    }
    Ok(Value::Object(config))
}

async fn image_id<E: Engine>(engine: &E, image: &str) -> Result<Option<String>> {
    let response = engine
        .request(
            Method::GET,
            format!("/images/{}/json", component(image)),
            None,
        )
        .await?;
    if response.status == 404 {
        return Ok(None);
    }
    response.expect(&[200], "无法检查目标镜像，请重试")?;
    Ok(Some(
        response
            .json()?
            .get("Id")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow!("镜像数据无效"))?
            .into(),
    ))
}

async fn verify_started<E: Engine>(engine: &E, id: &str) -> Result<bool> {
    for attempt in 0..90 {
        let state = inspect(engine, id).await?;
        ensure!(running(&state), "新容器启动失败");
        match state
            .pointer("/State/Health/Status")
            .and_then(Value::as_str)
        {
            Some("healthy") => return Ok(true),
            Some("unhealthy") => return Err(anyhow!("新容器健康检查失败")),
            Some("starting") => {}
            _ if attempt >= 2 => return Ok(true),
            _ => {}
        }
        engine.tick().await;
    }
    Ok(false)
}

async fn rollback<E: Engine>(
    engine: &E,
    old_id: &str,
    name: &str,
    was_running: bool,
    new_id: Option<&str>,
) -> bool {
    if let Some(id) = new_id {
        if remove(engine, id, true).await.is_err() {
            return false;
        }
    }
    let Ok(old) = inspect(engine, old_id).await else {
        return false;
    };
    if old
        .get("Name")
        .and_then(Value::as_str)
        .map(|s| s.trim_start_matches('/'))
        != Some(name)
        && post(
            engine,
            old_id,
            &format!("/rename?name={}", component(name)),
            "无法恢复容器名称",
        )
        .await
        .is_err()
    {
        return false;
    }
    !was_running
        || post(engine, old_id, "/start", "无法恢复原容器")
            .await
            .is_ok()
}

async fn upgrade<E: Engine>(
    engine: &E,
    id: &str,
    image: &str,
    force: bool,
) -> Result<Option<String>> {
    let original = inspect(engine, id).await?;
    ensure!(
        original
            .pointer("/HostConfig/AutoRemove")
            .and_then(Value::as_bool)
            != Some(true),
        "此容器启用了自动删除，无法保留原容器回退，请先调整配置"
    );
    ensure!(
        original.pointer("/State/Paused").and_then(Value::as_bool) != Some(true),
        "请先恢复或停止容器，再执行升级"
    );
    ensure!(
        original
            .pointer("/Config/Labels/com.docker.swarm.service.id")
            .is_none(),
        "请通过 Swarm 服务升级此容器"
    );
    let name = original
        .get("Name")
        .and_then(Value::as_str)
        .map(|s| s.trim_start_matches('/'))
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("容器名称无效"))?;
    let old_id = original
        .get("Id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("容器标识无效"))?;
    validate_docker_id(DockerResourceKind::Container, old_id)?;
    ensure!(old_id.starts_with(id), "Docker 资源已变化，请刷新后重试");
    let mut resolved_image = if force {
        None
    } else {
        image_id(engine, image).await?
    };
    if resolved_image.is_none() {
        engine.pull(image).await?;
        resolved_image = image_id(engine, image).await?;
    }
    let image_id = resolved_image.ok_or_else(|| anyhow!("目标镜像未就绪，原容器未变更"))?;
    let mut config = creation_config(&original, image, engine.api_minor())?;
    if let Some(labels) = config.get_mut("Labels").and_then(Value::as_object_mut) {
        if labels.contains_key("com.docker.compose.image") {
            labels.insert(
                "com.docker.compose.image".into(),
                Value::String(image_id.clone()),
            );
        }
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = format!("paga-upgrade-{}-{nonce}", &old_id[..12.min(old_id.len())]);
    let backup = format!(
        "{}-paga-backup-{nonce}",
        name.chars().take(160).collect::<String>()
    );
    let was_running = running(&original);
    let mut replacement: Option<String> = None;
    let mut touched_old = false;
    let mut create_attempted = false;
    let mut create_conflict = false;
    let result = async {
        create_attempted = true;
        let response = engine
            .request(
                Method::POST,
                format!("/containers/create?name={}", component(&temporary)),
                Some(config),
            )
            .await?;
        create_conflict = response.status == 409;
        response.expect(&[201], CREATE_FAILED)?;
        let data = response.json()?;
        let new_id = data
            .get("Id")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow!(CREATE_FAILED))?
            .to_owned();
        validate_docker_id(DockerResourceKind::Container, &new_id)
            .map_err(|_| anyhow!(CREATE_FAILED))?;
        ensure!(new_id != old_id, "{CREATE_FAILED}");
        let created = inspect(engine, &new_id).await?;
        ensure!(
            created.get("Id").and_then(Value::as_str) == Some(&new_id)
                && created
                    .get("Name")
                    .and_then(Value::as_str)
                    .map(|s| s.trim_start_matches('/'))
                    == Some(&temporary),
            "{CREATE_FAILED}"
        );
        replacement = Some(new_id.clone());
        ensure!(
            created.get("Image").and_then(Value::as_str) == Some(&image_id),
            "目标镜像已变化，原容器未变更，请刷新后重试"
        );
        let current = inspect(engine, old_id).await?;
        ensure!(
            current.get("Name") == original.get("Name")
                && current.get("Config") == original.get("Config")
                && current.get("HostConfig") == original.get("HostConfig")
                && current.pointer("/NetworkSettings/Networks")
                    == original.pointer("/NetworkSettings/Networks"),
            "容器配置已变化，请刷新后重试"
        );
        touched_old = true;
        if was_running {
            post(engine, old_id, "/stop?t=20", "无法停止原容器").await?;
        }
        post(
            engine,
            old_id,
            &format!("/rename?name={}", component(&backup)),
            "无法保留原容器备份",
        )
        .await?;
        post(
            engine,
            &new_id,
            &format!("/rename?name={}", component(name)),
            "无法设置新容器名称",
        )
        .await?;
        post(engine, &new_id, "/start", "新容器启动失败").await?;
        if !verify_started(engine, &new_id).await? {
            return Ok(Some(
                "新容器已启动，健康检查尚未完成，已保留旧容器备份".into(),
            ));
        }
        if remove(engine, old_id, false).await.is_err() {
            return Ok(Some(
                "容器已升级，但旧容器备份未能删除，请刷新后检查".into(),
            ));
        }
        Ok(None)
    }
    .await;
    if result.is_err() {
        let recovery = engine.recovery();
        if replacement.is_none() && create_attempted && !create_conflict {
            if let Ok(candidate) = inspect(&recovery, &temporary).await {
                if candidate.get("Image").and_then(Value::as_str) == Some(&image_id)
                    && candidate.pointer("/Config/Image").and_then(Value::as_str) == Some(image)
                    && candidate
                        .get("Name")
                        .and_then(Value::as_str)
                        .map(|s| s.trim_start_matches('/'))
                        == Some(&temporary)
                {
                    replacement = candidate
                        .get("Id")
                        .and_then(Value::as_str)
                        .filter(|id| {
                            *id != old_id
                                && validate_docker_id(DockerResourceKind::Container, id).is_ok()
                        })
                        .map(str::to_owned);
                }
            }
        }
        if touched_old {
            return Err(anyhow!(if rollback(
                &recovery,
                old_id,
                name,
                was_running,
                replacement.as_deref()
            )
            .await
            {
                "容器升级失败，已恢复原容器"
            } else {
                "容器升级失败，自动恢复未完成，请刷新列表检查原容器备份"
            }));
        }
        if let Some(id) = replacement {
            if remove(&recovery, &id, true).await.is_err() {
                return Err(anyhow!("原容器未变更，但临时容器未能清理，请刷新列表检查"));
            }
        }
    }
    result
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) async fn run(
    session: u32,
    id: &str,
    action: DockerContainerAction,
    image: Option<&str>,
    force: bool,
) -> Result<Option<String>> {
    validate_docker_id(DockerResourceKind::Container, id)?;
    let _guard = OperationGuard::acquire(id)?;
    if matches!(action, DockerContainerAction::Upgrade) {
        validate_image(image.ok_or_else(|| anyhow!("请输入目标镜像"))?)?;
    } else {
        ensure!(image.is_none() && !force, "Docker 操作参数无效");
    }
    let client = Client {
        session,
        access: Access::prepare(session).await?,
        deadline: Instant::now() + OPERATION_TIMEOUT,
    };
    match action {
        DockerContainerAction::Start => {
            post(
                &client,
                id,
                "/start",
                "无法启动容器，请检查容器状态和运行配置",
            )
            .await?
        }
        DockerContainerAction::Stop => {
            post(&client, id, "/stop?t=20", "无法停止容器，请刷新后检查").await?
        }
        DockerContainerAction::Delete => remove(&client, id, true).await?,
        DockerContainerAction::Upgrade => return upgrade(&client, id, image.unwrap(), force).await,
    }
    Ok(None)
}

async fn image_action<E: Engine>(
    engine: &E,
    action: DockerImageAction,
    id: Option<&str>,
) -> Result<()> {
    match action {
        DockerImageAction::Delete => {
            let id = id.ok_or_else(|| anyhow!("请选择要删除的镜像"))?;
            let Some(resolved) = image_id(engine, id).await? else {
                return Ok(());
            };
            validate_docker_id(DockerResourceKind::Image, &resolved)?;
            ensure!(
                resolved
                    .strip_prefix("sha256:")
                    .unwrap_or(&resolved)
                    .starts_with(id.strip_prefix("sha256:").unwrap_or(id)),
                "镜像已变化，请刷新后重试"
            );
            let response = engine
                .request(Method::GET, "/containers/json?all=true".into(), None)
                .await?;
            response.expect(&[200], "无法核对镜像使用状态，请刷新后重试")?;
            let data = response.json()?;
            let containers = data
                .as_array()
                .ok_or_else(|| anyhow!("无法核对镜像使用状态，请刷新后重试"))?;
            for container in containers {
                let used = container
                    .get("ImageID")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("无法核对镜像使用状态，请刷新后重试"))?;
                ensure!(used != resolved, "镜像正在被容器使用，无法删除");
            }
            let response = engine
                .request(
                    Method::DELETE,
                    format!("/images/{}?force=false", component(&resolved)),
                    None,
                )
                .await?;
            if response.status == 404 {
                return Ok(());
            }
            if response.status == 409 {
                return Err(anyhow!("镜像仍被容器或其他资源引用，无法删除"));
            }
            response.expect(&[200], "无法删除 Docker 镜像，请刷新后重试")
        }
        DockerImageAction::PruneUntagged | DockerImageAction::PruneUnused => {
            let untagged_only = matches!(action, DockerImageAction::PruneUntagged);
            let dangling = if untagged_only { "true" } else { "false" };
            let filters = component(&json!({"dangling":[dangling]}).to_string());
            let response = engine
                .request(
                    Method::POST,
                    format!("/images/prune?filters={filters}"),
                    None,
                )
                .await?;
            if response.status == 409 {
                return Err(anyhow!("Docker 正在清理镜像，请稍后再试"));
            }
            response.expect(
                &[200],
                if untagged_only {
                    "无法清理无标签镜像，请刷新后重试"
                } else {
                    "无法清理未使用镜像，请刷新后重试"
                },
            )
        }
    }
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) async fn run_image(
    session: u32,
    action: DockerImageAction,
    id: Option<&str>,
) -> Result<()> {
    match action {
        DockerImageAction::Delete => validate_docker_id(
            DockerResourceKind::Image,
            id.ok_or_else(|| anyhow!("请选择要删除的镜像"))?,
        )?,
        DockerImageAction::PruneUntagged | DockerImageAction::PruneUnused => {
            ensure!(id.is_none(), "Docker 操作参数无效");
        }
    }
    let client = Client {
        session,
        access: Access::prepare(session).await.map_err(image_action_error)?,
        deadline: Instant::now() + OPERATION_TIMEOUT,
    };
    image_action(&client, action, id)
        .await
        .map_err(image_action_error)
}

fn image_action_error(error: anyhow::Error) -> anyhow::Error {
    match error.to_string().as_str() {
        PERMISSION => anyhow!("没有权限操作 Docker 镜像"),
        TIMEOUT => anyhow!("Docker 镜像操作超时，请刷新列表确认状态"),
        _ => error,
    }
}

#[cfg(test)]
#[path = "docker_operations_tests.rs"]
mod tests;

#[cfg(all(test, unix))]
#[path = "docker_access_tests.rs"]
mod access_tests;
