use super::*;
use std::sync::Arc;

const OLD: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const NEW: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const IMAGE: &str = "registry.test/app:v2";

fn original() -> Value {
    json!({"Id":OLD,"Name":"/app","Image":"sha256:original",
      "State":{"Running":true,"Paused":false},
      "Config":{"Image":"registry.test/app:v1","Env":["TOKEN=test-secret"],"Cmd":["serve","--port","8080"],"Entrypoint":["/app"],"User":"1000","WorkingDir":"/srv","Labels":{"com.docker.compose.project":"stack"},"Healthcheck":{"Test":["CMD","/app","health"]},"Volumes":{"/data":{}}},
      "HostConfig":{"NetworkMode":"service-net","Memory":4096,"RestartPolicy":{"Name":"always"},"PortBindings":{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]},"Binds":["named-volume:/named:ro"],"Mounts":[{"Type":"bind","Source":"/srv/cache","Target":"/cache","ReadOnly":true}],"DeviceRequests":[{"Driver":"nvidia","Count":1,"Capabilities":[["gpu"]]}]},
      "Mounts":[{"Type":"volume","Name":"original-anonymous","Destination":"/data","RW":true},{"Type":"volume","Name":"named-volume","Destination":"/named","RW":false}],
      "NetworkSettings":{"Networks":{"service-net":{"NetworkID":"runtime-network","EndpointID":"runtime-endpoint","IPAddress":"10.0.0.8","Gateway":"10.0.0.1","Aliases":["app",&OLD[..12]],"IPAMConfig":{"IPv4Address":"10.0.0.8"},"MacAddress":"02:42:0a:00:00:08","DriverOpts":{"test":"option"},"GwPriority":1}}}})
}

#[derive(Default)]
struct Fixture {
    containers: Map<String, Value>,
    images: Map<String, Value>,
    image_tags: std::collections::HashMap<String, Vec<String>>,
    calls: Vec<(Method, String, Option<Value>)>,
    created: Option<Value>,
    pulls: usize,
    failure: &'static str,
}

#[derive(Clone)]
struct FakeEngine(Arc<Mutex<Fixture>>);
impl FakeEngine {
    fn new(failure: &'static str) -> Self {
        Self(Arc::new(Mutex::new(Fixture {
            containers: Map::from_iter([(OLD.into(), original())]),
            images: Map::from_iter([(IMAGE.into(), Value::String("sha256:local".into()))]),
            failure,
            ..Fixture::default()
        })))
    }
    fn lookup(state: &Fixture, target: &str) -> Option<String> {
        state
            .containers
            .iter()
            .find(|(id, data)| {
                id.as_str() == target
                    || data["Name"].as_str().map(|s| s.trim_start_matches('/')) == Some(target)
            })
            .map(|(id, _)| id.clone())
    }
}

fn image_fixture() -> (FakeEngine, String, String, String, String) {
    let engine = FakeEngine::new("");
    let ids: Vec<_> = ['a', 'b', 'c', 'd']
        .into_iter()
        .map(|hex| format!("sha256:{}", hex.to_string().repeat(64)))
        .collect();
    {
        let mut state = engine.0.lock().unwrap();
        state.images.clear();
        state.containers.clear();
        for (index, id) in ids.iter().enumerate() {
            state.images.insert(id.clone(), Value::String(id.clone()));
            state.image_tags.insert(
                id.clone(),
                if index < 2 {
                    vec![format!("app:{index}")]
                } else {
                    vec![]
                },
            );
        }
        state.containers.insert(
            OLD.into(),
            json!({"Image":ids[0],"State":{"Running":false}}),
        );
        state
            .containers
            .insert(NEW.into(), json!({"Image":ids[3],"State":{"Running":true}}));
    }
    (
        engine,
        ids[0].clone(),
        ids[1].clone(),
        ids[2].clone(),
        ids[3].clone(),
    )
}

#[tokio::test]
async fn docker_image_delete_checks_stopped_and_running_references_and_never_forces() {
    let (engine, used, unused, _, used_untagged) = image_fixture();
    for id in [&used, &used_untagged] {
        assert_eq!(
            image_action(&engine, DockerImageAction::Delete, Some(id))
                .await
                .unwrap_err()
                .to_string(),
            "镜像正在被容器使用，无法删除"
        );
    }
    assert!(engine
        .0
        .lock()
        .unwrap()
        .calls
        .iter()
        .all(|(method, _, _)| *method != Method::DELETE));
    image_action(&engine, DockerImageAction::Delete, Some(&unused))
        .await
        .unwrap();
    assert!(!engine.0.lock().unwrap().images.contains_key(&unused));
    image_action(&engine, DockerImageAction::Delete, Some(&unused))
        .await
        .unwrap();
    for failure in ["image-became-used", "image-usage-invalid"] {
        let (engine, _, unused, _, _) = image_fixture();
        engine.0.lock().unwrap().failure = failure;
        let error = image_action(&engine, DockerImageAction::Delete, Some(&unused))
            .await
            .unwrap_err()
            .to_string();
        assert!(!error.contains("private"));
        assert!(engine.0.lock().unwrap().images.contains_key(&unused));
    }
}

#[tokio::test]
async fn docker_image_cleanup_only_prunes_untagged_unused_images() {
    let (engine, used_tagged, unused_tagged, unused_untagged, used_untagged) = image_fixture();
    image_action(&engine, DockerImageAction::PruneUntagged, None)
        .await
        .unwrap();
    let state = engine.0.lock().unwrap();
    assert!(!state.images.contains_key(&unused_untagged));
    for protected in [&used_tagged, &unused_tagged, &used_untagged] {
        assert!(state.images.contains_key(protected));
    }
    assert_eq!(state.calls.len(), 1);
}

#[tokio::test]
async fn docker_image_cleanup_can_opt_in_to_all_unused_images() {
    let (engine, used_tagged, unused_tagged, unused_untagged, used_untagged) = image_fixture();
    image_action(&engine, DockerImageAction::PruneUnused, None)
        .await
        .unwrap();
    let state = engine.0.lock().unwrap();
    assert!(!state.images.contains_key(&unused_tagged));
    assert!(!state.images.contains_key(&unused_untagged));
    for protected in [&used_tagged, &used_untagged] {
        assert!(state.images.contains_key(protected));
    }
    assert_eq!(state.calls.len(), 1);
}

#[tokio::test]
async fn docker_image_actions_reject_invalid_parameters_before_connecting() {
    for (action, id) in [
        (DockerImageAction::Delete, None),
        (DockerImageAction::Delete, Some("--force")),
        (DockerImageAction::Delete, Some("$(id)")),
        (DockerImageAction::PruneUntagged, Some(OLD)),
        (DockerImageAction::PruneUnused, Some(OLD)),
    ] {
        assert!(run_image(0, action, id).await.is_err());
    }
}

fn decode(value: &str) -> String {
    let mut bytes = Vec::new();
    let mut iter = value.bytes();
    while let Some(byte) = iter.next() {
        if byte == b'%' {
            let hex = [iter.next().unwrap(), iter.next().unwrap()];
            bytes.push(u8::from_str_radix(std::str::from_utf8(&hex).unwrap(), 16).unwrap());
        } else {
            bytes.push(byte);
        }
    }
    String::from_utf8(bytes).unwrap()
}

impl Engine for FakeEngine {
    async fn request(&self, method: Method, path: String, body: Option<Value>) -> Result<Response> {
        let mut state = self.0.lock().unwrap();
        state
            .calls
            .push((method.clone(), path.clone(), body.clone()));
        let respond = |status, body: Value| {
            Ok(Response {
                status,
                body: serde_json::to_vec(&body).unwrap(),
            })
        };
        if path == "/containers/json?all=true" {
            if state.failure == "image-usage-invalid" {
                return respond(200, json!([{}]));
            }
            return respond(200, Value::Array(state.containers.values().map(|container| {
                json!({"ImageID":container["Image"], "State":if running(container) { "running" } else { "exited" }})
            }).collect()));
        }
        if let Some(filters) = path.strip_prefix("/images/prune?filters=") {
            assert_eq!(method, Method::POST);
            assert!(body.is_none());
            let filters: Value = serde_json::from_str(&decode(filters)).unwrap();
            assert_eq!(filters.as_object().unwrap().len(), 1);
            let untagged_only = match &filters["dangling"] {
                value if *value == json!(["true"]) => true,
                value if *value == json!(["false"]) => false,
                _ => panic!("expected an explicit image cleanup scope"),
            };
            let used: HashSet<_> = state
                .containers
                .values()
                .filter_map(|container| container["Image"].as_str())
                .map(str::to_owned)
                .collect();
            let deleted: HashSet<_> = state
                .images
                .values()
                .filter_map(Value::as_str)
                .filter(|id| {
                    (!untagged_only || state.image_tags.get(*id).is_some_and(Vec::is_empty))
                        && !used.contains(*id)
                })
                .map(str::to_owned)
                .collect();
            state
                .images
                .retain(|_, id| !deleted.contains(id.as_str().unwrap()));
            return respond(
                200,
                json!({"ImagesDeleted":deleted.iter().map(|id| json!({"Deleted":id})).collect::<Vec<_>>(), "SpaceReclaimed":1234}),
            );
        }
        if method == Method::DELETE && path.starts_with("/images/") {
            assert!(
                path.ends_with("?force=false"),
                "image deletion must not be forced"
            );
            let id = decode(
                path.strip_prefix("/images/")
                    .unwrap()
                    .split('?')
                    .next()
                    .unwrap(),
            );
            if state.failure == "image-became-used"
                || state
                    .containers
                    .values()
                    .any(|container| container["Image"] == id)
            {
                return respond(409, json!({"message":"private runtime conflict"}));
            }
            state
                .images
                .retain(|_, value| value.as_str() != Some(id.as_str()));
            return respond(200, json!([{"Deleted":id}]));
        }
        if let Some(image) = path
            .strip_prefix("/images/")
            .and_then(|p| p.strip_suffix("/json"))
        {
            return match state.images.get(&decode(image)) {
                Some(id) => respond(200, json!({"Id":id})),
                None => respond(404, json!({"message":"missing image"})),
            };
        }
        if let Some(name) = path.strip_prefix("/containers/create?name=") {
            if state.failure == "create" {
                return respond(
                    400,
                    json!({"message":"private path /private/host TOKEN=test-secret"}),
                );
            }
            let config = body.unwrap();
            let image_id = state.images[config["Image"].as_str().unwrap()].clone();
            let mut actual_config = config.clone();
            actual_config.as_object_mut().unwrap().remove("HostConfig");
            actual_config
                .as_object_mut()
                .unwrap()
                .remove("NetworkingConfig");
            state.created = Some(config.clone());
            state.containers.insert(NEW.into(), json!({"Id":NEW,"Name":format!("/{}", decode(name)),"Image":image_id,"Config":actual_config,"HostConfig":config["HostConfig"],"State":{"Running":false}}));
            if state.failure == "create-timeout" {
                return Err(anyhow!(TIMEOUT));
            }
            if state.failure == "create-conflict" {
                return respond(409, json!({"message":"name conflict"}));
            }
            if state.failure == "identity" {
                return respond(201, json!({"Id":OLD}));
            }
            return respond(201, json!({"Id":NEW,"Warnings":[]}));
        }
        let target_path = path.strip_prefix("/containers/").unwrap();
        let target = decode(target_path.split(['/', '?']).next().unwrap());
        let Some(id) = Self::lookup(&state, &target) else {
            return respond(404, json!({}));
        };
        if method == Method::GET {
            return respond(200, state.containers[&id].clone());
        }
        if method == Method::DELETE {
            if (state.failure == "cleanup" && id == OLD)
                || (state.failure == "rollback" && id == NEW)
            {
                return respond(403, json!({}));
            }
            assert!(
                path.contains("v=false"),
                "must preserve named and anonymous volumes"
            );
            state.containers.remove(&id);
            return respond(204, Value::Null);
        }
        if let Some(name) = path.split("/rename?name=").nth(1) {
            let desired = format!("/{}", decode(name));
            if state
                .containers
                .iter()
                .any(|(other, data)| other != &id && data["Name"] == desired)
            {
                return respond(409, Value::Null);
            }
            state.containers.get_mut(&id).unwrap()["Name"] = Value::String(desired);
            return respond(204, Value::Null);
        }
        if path.ends_with("/start") {
            if id == NEW {
                assert!(
                    state.containers.get(OLD).is_none_or(|old| !running(old)),
                    "network and ports are allocated only after stopping the original"
                );
            }
            if (state.failure == "start" || state.failure == "rollback") && id == NEW {
                return respond(500, json!({"message":"private platform error"}));
            }
            let health = match state.failure {
                "healthy" => Some("healthy"),
                "unhealthy" => Some("unhealthy"),
                "starting" => Some("starting"),
                _ => None,
            };
            let container = state.containers.get_mut(&id).unwrap();
            container["State"]["Running"] = Value::Bool(true);
            if let Some(health) = health {
                container["State"]["Health"] = json!({"Status":health});
            }
            return respond(204, Value::Null);
        }
        assert!(path.ends_with("/stop?t=20"));
        state.containers.get_mut(&id).unwrap()["State"]["Running"] = Value::Bool(false);
        respond(204, Value::Null)
    }
    async fn pull(&self, image: &str) -> Result<()> {
        let mut state = self.0.lock().unwrap();
        state.pulls += 1;
        ensure!(
            state.failure != "pull",
            "无法拉取目标镜像，请检查镜像名称、仓库权限和网络"
        );
        state
            .images
            .insert(image.into(), Value::String("sha256:pulled".into()));
        if state.failure == "changed" {
            state.containers.get_mut(OLD).unwrap()["HostConfig"]["Memory"] = json!(8192);
        }
        Ok(())
    }
    async fn tick(&self) {}
    fn recovery(&self) -> Self {
        self.clone()
    }
    fn api_minor(&self) -> u32 {
        53
    }
}

struct WireServer {
    engine: FakeEngine,
    channels: std::collections::HashMap<russh::ChannelId, russh::Channel<russh::server::Msg>>,
    commands: Arc<Mutex<Vec<String>>>,
    sudo: bool,
}

impl russh::server::Handler for WireServer {
    type Error = russh::Error;

    async fn auth_password(
        &mut self,
        _: &str,
        _: &str,
    ) -> std::result::Result<russh::server::Auth, Self::Error> {
        Ok(russh::server::Auth::Accept)
    }

    async fn channel_open_session(
        &mut self,
        channel: russh::Channel<russh::server::Msg>,
        reply: russh::server::ChannelOpenHandle,
        _: &mut russh::server::Session,
    ) -> std::result::Result<(), Self::Error> {
        self.channels.insert(channel.id(), channel);
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        _: russh::ChannelId,
        _: &str,
        _: u32,
        _: u32,
        _: u32,
        _: u32,
        _: &[(russh::Pty, u32)],
        _: &mut russh::server::Session,
    ) -> std::result::Result<(), Self::Error> {
        panic!("container management must not use an interactive PTY");
    }

    async fn exec_request(
        &mut self,
        channel_id: russh::ChannelId,
        command: &[u8],
        session: &mut russh::server::Session,
    ) -> std::result::Result<(), Self::Error> {
        let command = String::from_utf8(command.to_vec()).unwrap();
        self.commands.lock().unwrap().push(command.clone());
        session.channel_success(channel_id)?;
        let channel = self.channels.remove(&channel_id).unwrap();
        if command.contains("PAGA_DOCKER_ACCESS_V1") {
            let endpoint = if self.sudo {
                "unix:///fixture/docker.sock"
            } else {
                ""
            };
            session.data(channel_id, format!("PAGA_DOCKER_ACCESS_V1\n/fixture/docker\n{endpoint}\n{}\n/fixture/user config\n1.53\n", usize::from(self.sudo)).into_bytes())?;
        } else if command.contains("image pull") {
            assert!(command.ends_with(&format!(
                "image pull {} >/dev/null 2>/dev/null",
                shell_argument(IMAGE)
            )));
            self.engine.pull(IMAGE).await.unwrap();
        } else {
            assert!(command.ends_with("system dial-stdio"));
            if self.sudo {
                assert!(command.starts_with("unset DOCKER_CONTEXT DOCKER_HOST; exec sudo -n --"));
                assert!(command.contains(
                    "--config '/fixture/user config' --host 'unix:///fixture/docker.sock'"
                ));
            }
            let engine = self.engine.clone();
            tokio::spawn(async move {
                let service = hyper::service::service_fn(
                    move |request: hyper::Request<hyper::body::Incoming>| {
                        let engine = engine.clone();
                        async move {
                            let method = request.method().clone();
                            let path = request
                                .uri()
                                .path_and_query()
                                .unwrap()
                                .as_str()
                                .strip_prefix("/v1.53")
                                .unwrap()
                                .to_owned();
                            let bytes = request.into_body().collect().await.unwrap().to_bytes();
                            let body = if bytes.is_empty() {
                                None
                            } else {
                                Some(serde_json::from_slice(&bytes).unwrap())
                            };
                            let response = engine.request(method, path, body).await.unwrap();
                            Ok::<_, std::convert::Infallible>(
                                hyper::Response::builder()
                                    .status(response.status)
                                    .body(Full::new(Bytes::from(response.body)))
                                    .unwrap(),
                            )
                        }
                    },
                );
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(TokioIo::new(channel.into_stream()), service)
                    .await;
            });
            return Ok(());
        }
        session.exit_status_request(channel_id, 0)?;
        session.eof(channel_id)?;
        session.close(channel_id)?;
        Ok(())
    }
}

#[tokio::test]
async fn docker_actions_use_real_http_over_dedicated_ssh_channels_with_sudo_and_registry_pull() {
    use crate::api::docker::{ssh_run_docker_container_action, ssh_run_docker_image_action};
    use crate::api::ssh::{ssh_authenticate, ssh_disconnect, ssh_handshake};
    use russh::keys::ssh_key::private::{Ed25519Keypair, KeypairData};

    for sudo in [false, true] {
        let key = russh::keys::PrivateKey::new(
            KeypairData::Ed25519(Ed25519Keypair::from_seed(&[49; 32])),
            "fixture",
        )
        .unwrap();
        let config = Arc::new(russh::server::Config {
            keys: vec![key],
            ..Default::default()
        });
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let engine = FakeEngine::new("healthy");
        let commands = Arc::new(Mutex::new(Vec::new()));
        let handler = WireServer {
            engine: engine.clone(),
            channels: Default::default(),
            commands: commands.clone(),
            sudo,
        };
        let task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let session = russh::server::run_stream(config, socket, handler)
                .await
                .unwrap();
            let _ = session.await;
        });
        let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
        let id = ssh_authenticate(
            handshake.session_id,
            handshake.fingerprint,
            "fixture".into(),
            "test-only".into(),
        )
        .await
        .unwrap();
        for (container, action, image, force) in [
            (
                OLD,
                DockerContainerAction::Upgrade,
                Some(IMAGE.into()),
                true,
            ),
            (NEW, DockerContainerAction::Stop, None, false),
            (NEW, DockerContainerAction::Start, None, false),
            (NEW, DockerContainerAction::Delete, None, false),
        ] {
            tokio::time::timeout(
                Duration::from_secs(10),
                ssh_run_docker_container_action(id, container.into(), action, image, force),
            )
            .await
            .unwrap()
            .unwrap();
        }
        {
            let state = engine.0.lock().unwrap();
            assert!(state.containers.is_empty());
            assert_eq!(state.pulls, 1);
            assert_eq!(
                state.created.as_ref().unwrap()["Env"],
                json!(["TOKEN=test-secret"])
            );
        }
        for action in [
            DockerImageAction::Delete,
            DockerImageAction::PruneUntagged,
            DockerImageAction::PruneUnused,
        ] {
            let (images, used_tagged, unused_tagged, unused_untagged, used_untagged) =
                image_fixture();
            {
                let source = images.0.lock().unwrap();
                let mut state = engine.0.lock().unwrap();
                state.containers = source.containers.clone();
                state.images = source.images.clone();
                state.image_tags = source.image_tags.clone();
            }
            let image = if matches!(action, DockerImageAction::Delete) {
                Some(unused_tagged.clone())
            } else {
                None
            };
            tokio::time::timeout(
                Duration::from_secs(10),
                ssh_run_docker_image_action(id, action, image),
            )
            .await
            .unwrap()
            .unwrap();
            let state = engine.0.lock().unwrap();
            assert!(state.images.contains_key(&used_tagged));
            assert!(state.images.contains_key(&used_untagged));
            assert_eq!(
                state.images.contains_key(&unused_tagged),
                matches!(action, DockerImageAction::PruneUntagged)
            );
            assert_eq!(
                state.images.contains_key(&unused_untagged),
                matches!(action, DockerImageAction::Delete)
            );
        }
        assert!(commands
            .lock()
            .unwrap()
            .iter()
            .all(|command| !command.contains("test-secret") && !command.contains("\"Env\"")));
        ssh_disconnect(id).await.unwrap();
        task.abort();
    }
}

#[test]
fn docker_upgrade_preserves_config_mounts_and_only_configurable_network_fields() {
    let source = original();
    let result = creation_config(&source, IMAGE, 53).unwrap();
    for key in [
        "Env",
        "Cmd",
        "Entrypoint",
        "User",
        "WorkingDir",
        "Labels",
        "Healthcheck",
        "Volumes",
    ] {
        assert_eq!(result[key], source["Config"][key]);
    }
    for key in [
        "Memory",
        "PortBindings",
        "Binds",
        "DeviceRequests",
        "RestartPolicy",
        "NetworkMode",
    ] {
        assert_eq!(result["HostConfig"][key], source["HostConfig"][key]);
    }
    let mounts = result["HostConfig"]["Mounts"].as_array().unwrap();
    assert_eq!(mounts.len(), 2);
    assert_eq!(mounts[1]["Source"], "original-anonymous");
    assert_eq!(mounts[1]["Target"], "/data");
    assert_eq!(mounts[1]["VolumeOptions"]["NoCopy"], true);
    let endpoint = &result["NetworkingConfig"]["EndpointsConfig"]["service-net"];
    assert_eq!(endpoint["IPAMConfig"]["IPv4Address"], "10.0.0.8");
    assert_eq!(endpoint["Aliases"], json!(["app"]));
    assert!(endpoint.get("EndpointID").is_none());
    assert!(endpoint.get("IPAddress").is_none());
    assert!(endpoint.get("Gateway").is_none());
    assert!(result.get("State").is_none());
    assert!(result.get("Mounts").is_none());
}

#[tokio::test]
async fn docker_upgrade_reuses_local_image_or_force_pulls_before_cutover() {
    for force in [false, true] {
        let engine = FakeEngine::new("");
        assert!(upgrade(&engine, OLD, IMAGE, force).await.unwrap().is_none());
        let state = engine.0.lock().unwrap();
        assert_eq!(state.pulls, usize::from(force));
        assert!(!state.containers.contains_key(OLD));
        assert_eq!(state.containers[NEW]["Name"], "/app");
        assert_eq!(state.containers[NEW]["State"]["Running"], true);
        assert_eq!(
            state.containers[NEW]["Image"],
            if force {
                "sha256:pulled"
            } else {
                "sha256:local"
            }
        );
        let create = state
            .calls
            .iter()
            .position(|(_, path, _)| path.starts_with("/containers/create"))
            .unwrap();
        let stop = state
            .calls
            .iter()
            .position(|(_, path, _)| path.ends_with("/stop?t=20"))
            .unwrap();
        assert!(
            create < stop,
            "create must succeed before stopping original container"
        );
    }
}

#[tokio::test]
async fn docker_upgrade_pulls_a_missing_target_and_preserves_original_on_pull_or_create_failure() {
    let engine = FakeEngine::new("");
    engine.0.lock().unwrap().images.clear();
    upgrade(&engine, OLD, IMAGE, false).await.unwrap();
    assert_eq!(engine.0.lock().unwrap().pulls, 1);
    for failure in [
        "pull",
        "create",
        "create-timeout",
        "create-conflict",
        "identity",
        "changed",
    ] {
        let engine = FakeEngine::new(failure);
        let error = upgrade(&engine, OLD, IMAGE, true)
            .await
            .unwrap_err()
            .to_string();
        assert!(!error.contains("test-secret") && !error.contains("/private/host"));
        let state = engine.0.lock().unwrap();
        assert!(state.containers[OLD]["State"]["Running"].as_bool().unwrap());
        assert_eq!(state.containers[OLD]["Name"], "/app");
        assert!(!state
            .calls
            .iter()
            .any(|(_, path, _)| path.ends_with("/stop?t=20")));
        assert_eq!(
            state.containers.contains_key(NEW),
            failure == "create-conflict",
            "never remove someone else's conflicting container"
        );
    }
}

#[test]
fn docker_upgrade_keeps_assigned_random_ports() {
    let mut source = original();
    source["HostConfig"]["PublishAllPorts"] = json!(true);
    source["HostConfig"]["PortBindings"] = json!({"8080/tcp":[{"HostIp":"","HostPort":"0"}]});
    source["NetworkSettings"]["Ports"] = json!({"8080/tcp":[{"HostIp":"0.0.0.0","HostPort":"32768"}],"9000/tcp":[{"HostIp":"127.0.0.1","HostPort":"32769"}]});
    let config = creation_config(&source, IMAGE, 53).unwrap();
    assert_eq!(
        config["HostConfig"]["PortBindings"],
        source["NetworkSettings"]["Ports"]
    );
}

#[tokio::test]
async fn docker_upgrade_preserves_compose_group_labels_and_updates_image_metadata() {
    let engine = FakeEngine::new("healthy");
    engine.0.lock().unwrap().containers.get_mut(OLD).unwrap()["Config"]["Labels"]
        ["com.docker.compose.image"] = json!("sha256:original");
    upgrade(&engine, OLD, IMAGE, true).await.unwrap();
    let state = engine.0.lock().unwrap();
    assert_eq!(
        state.containers[NEW]["Config"]["Labels"]["com.docker.compose.project"],
        "stack"
    );
    assert_eq!(
        state.containers[NEW]["Config"]["Labels"]["com.docker.compose.image"],
        "sha256:pulled"
    );
}

#[tokio::test]
async fn docker_upgrade_rolls_back_start_and_health_failures_and_keeps_original_stop_state() {
    for was_running in [true, false] {
        for failure in ["start", "unhealthy"] {
            let engine = FakeEngine::new(failure);
            engine.0.lock().unwrap().containers.get_mut(OLD).unwrap()["State"]["Running"] =
                json!(was_running);
            assert_eq!(
                upgrade(&engine, OLD, IMAGE, true)
                    .await
                    .unwrap_err()
                    .to_string(),
                "容器升级失败，已恢复原容器"
            );
            let state = engine.0.lock().unwrap();
            assert_eq!(state.containers.len(), 1);
            assert_eq!(state.containers[OLD]["Name"], "/app");
            assert_eq!(state.containers[OLD]["State"]["Running"], was_running);
            assert_eq!(state.containers[OLD]["Image"], "sha256:original");
        }
    }
}

#[tokio::test]
async fn docker_upgrade_keeps_backup_on_incomplete_health_or_cleanup_and_reports_failed_rollback() {
    for failure in ["starting", "cleanup"] {
        let engine = FakeEngine::new(failure);
        assert!(upgrade(&engine, OLD, IMAGE, true).await.unwrap().is_some());
        let state = engine.0.lock().unwrap();
        assert_eq!(state.containers.len(), 2);
        assert!(state.containers[OLD]["Name"]
            .as_str()
            .unwrap()
            .contains("paga-backup"));
        assert_eq!(state.containers[NEW]["State"]["Running"], true);
    }
    let engine = FakeEngine::new("rollback");
    assert_eq!(
        upgrade(&engine, OLD, IMAGE, false)
            .await
            .unwrap_err()
            .to_string(),
        "容器升级失败，自动恢复未完成，请刷新列表检查原容器备份"
    );
    assert!(engine.0.lock().unwrap().containers.contains_key(OLD));
}

#[tokio::test]
async fn docker_upgrade_refuses_auto_remove_paused_and_swarm_before_mutating() {
    for pointer in ["auto", "paused", "swarm"] {
        let engine = FakeEngine::new("");
        {
            let mut state = engine.0.lock().unwrap();
            let old = state.containers.get_mut(OLD).unwrap();
            match pointer {
                "auto" => old["HostConfig"]["AutoRemove"] = json!(true),
                "paused" => old["State"]["Paused"] = json!(true),
                _ => old["Config"]["Labels"]["com.docker.swarm.service.id"] = json!("service"),
            }
        }
        assert!(upgrade(&engine, OLD, IMAGE, true).await.is_err());
        let state = engine.0.lock().unwrap();
        assert_eq!(state.pulls, 0);
        assert_eq!(state.calls.len(), 1);
    }
}

#[test]
fn docker_operations_validate_access_plans_images_and_exclusive_ownership() {
    for image in ["", "--help", "name\nnext", "$(id)", "image;rm", "'image'"] {
        assert!(validate_image(image).is_err());
    }
    for image in [
        IMAGE,
        "nginx:latest",
        "ghcr.io/tale/headplane:latest",
        "[::1]:5000/app:v1",
        "app@sha256:abcd",
    ] {
        assert!(validate_image(image).is_ok());
    }
    for plan in [
        "PAGA_DOCKER_ACCESS_V1\n/bin/docker\n\n0\n/path\n1.53\n",
        "PAGA_DOCKER_ACCESS_V1\n/bin/docker\nunix:///run/docker.sock\n1\n/path\n1.53\n",
    ] {
        assert!(Access::parse(plan.as_bytes()).is_ok());
    }
    for plan in [
        "WRONG\n/bin/docker\n\n0\n/path\n1.53\n",
        "PAGA_DOCKER_ACCESS_V1\n/bin/docker\ntcp://remote:2375\n1\n/path\n1.53\n",
        "PAGA_DOCKER_ACCESS_V1\n/bin/docker\n\n0\n/path\n1.53;id\n",
    ] {
        assert!(Access::parse(plan.as_bytes()).is_err());
    }
    let guard = OperationGuard::acquire("fixture-exclusive").unwrap();
    assert!(OperationGuard::acquire("fixture-exclusive").is_err());
    drop(guard);
    assert!(OperationGuard::acquire("fixture-exclusive").is_ok());
}
