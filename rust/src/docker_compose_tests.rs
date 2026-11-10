use super::*;

const ID: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const IMAGE: &str = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn fixture() -> Value {
    json!([{
        "Id": ID, "ImageID": IMAGE,
        "Labels": {
            "com.docker.compose.project": "app",
            "com.docker.compose.service": "api",
            "com.docker.compose.project.working_dir": "/srv/app",
            "com.docker.compose.project.config_files": "/srv/app/compose.yaml,/srv/app/override.yaml",
            "com.docker.compose.project.environment_file": "/srv/app/app.env"
        }
    }])
}

#[test]
fn project_identity_and_original_sources_are_required_before_rebuilding() {
    let data = fixture();
    let project = project_from_json("app", &data, true).unwrap();
    assert_eq!(project.services, BTreeSet::from(["api".into()]));
    assert_eq!(project.source.as_ref().unwrap().configs.len(), 2);
    assert_eq!(
        project.source.as_ref().unwrap().environment,
        ["/srv/app/app.env"]
    );
    assert!(project_from_json("other", &data, true).is_err());
    assert!(project_from_json("app", &json!([]), true).is_err());
    let mut missing = fixture();
    missing[0]["Labels"]["com.docker.compose.project.config_files"] = json!("");
    assert!(project_from_json("app", &missing, true).is_err());
    // Start, stop and delete work by project labels even after the YAML was moved.
    assert!(project_from_json("app", &missing, false).is_ok());
    let mut inconsistent = fixture();
    let mut second = inconsistent[0].clone();
    second["Id"] = json!("c".repeat(64));
    second["Labels"]["com.docker.compose.project.working_dir"] = json!("/different");
    inconsistent.as_array_mut().unwrap().push(second);
    assert!(project_from_json("app", &inconsistent, true).is_err());
    let mut injected = fixture();
    injected[0]["Labels"]["com.docker.compose.service"] = json!("--remove-orphans");
    assert!(project_from_json("app", &injected, true).is_err());
}

struct Fake {
    calls: Mutex<Vec<String>>,
    invalid_config: bool,
    shared_image: bool,
    image_error: Option<&'static str>,
}

impl Fake {
    fn new(invalid_config: bool, shared_image: bool) -> Self {
        Self {
            calls: Mutex::new(Vec::new()),
            invalid_config,
            shared_image,
            image_error: None,
        }
    }
}

impl Engine for Fake {
    async fn request(&self, method: Method, path: String, _: Option<Value>) -> Result<Response> {
        if let Some(message) = self.image_error {
            return Err(anyhow!(message));
        }
        self.calls.lock().unwrap().push(format!("{method} {path}"));
        let body = if path.ends_with("/json") {
            json!({"Id": IMAGE})
        } else if path == "/containers/json?all=true" {
            if self.shared_image {
                json!([{"ImageID": IMAGE}])
            } else {
                json!([])
            }
        } else {
            assert_eq!(method, Method::DELETE);
            assert!(path.ends_with("?force=false"));
            json!([])
        };
        Ok(Response {
            status: 200,
            body: serde_json::to_vec(&body).unwrap(),
        })
    }
    async fn pull(&self, _: &str) -> Result<()> {
        unreachable!()
    }
    async fn tick(&self) {}
    fn recovery(&self) -> Self {
        unreachable!()
    }
    fn api_minor(&self) -> u32 {
        53
    }
}

impl ComposeEngine for Fake {
    async fn compose(&self, _: &Project, phase: Phase) -> Result<()> {
        self.calls.lock().unwrap().push(
            match phase {
                Phase::Check => "check",
                Phase::Start => "start",
                Phase::Stop => "stop",
                Phase::Down => "down",
                Phase::Rebuild => "rebuild",
            }
            .into(),
        );
        ensure!(
            !(self.invalid_config && phase == Phase::Check),
            "bad config"
        );
        Ok(())
    }
}

#[tokio::test]
async fn rebuild_validates_before_stopping_then_removes_images_without_force_and_builds() {
    let project = project_from_json("app", &fixture(), true).unwrap();
    let invalid = Fake::new(true, false);
    assert!(operate(&invalid, &project, DockerComposeAction::Rebuild)
        .await
        .is_err());
    assert_eq!(*invalid.calls.lock().unwrap(), ["check"]);
    let valid = Fake::new(false, false);
    assert!(operate(&valid, &project, DockerComposeAction::Rebuild)
        .await
        .unwrap()
        .is_none());
    let calls = valid.calls.lock().unwrap();
    assert_eq!(&calls[..2], ["check", "down"]);
    assert!(calls[4].starts_with("DELETE /images/"));
    assert_eq!(calls.last().unwrap(), "rebuild");
    assert!(!calls
        .iter()
        .any(|s| s.contains("force=true") || s.contains("volumes")));
}

#[tokio::test]
async fn shared_images_are_kept_and_simple_actions_never_delete_images() {
    let project = project_from_json("app", &fixture(), true).unwrap();
    let shared = Fake::new(false, true);
    let warning = operate(&shared, &project, DockerComposeAction::Rebuild)
        .await
        .unwrap();
    assert!(warning.unwrap().contains("旧镜像已保留"));
    assert!(!shared
        .calls
        .lock()
        .unwrap()
        .iter()
        .any(|s| s.starts_with("DELETE")));
    for (action, expected) in [
        (DockerComposeAction::Start, "start"),
        (DockerComposeAction::Stop, "stop"),
        (DockerComposeAction::Delete, "down"),
    ] {
        let fake = Fake::new(false, false);
        operate(&fake, &project, action).await.unwrap();
        assert_eq!(*fake.calls.lock().unwrap(), [expected]);
    }
}

#[tokio::test]
async fn image_removal_keeps_timeout_and_permission_errors_after_stopping() {
    let project = project_from_json("app", &fixture(), true).unwrap();
    for message in [TIMEOUT, PERMISSION] {
        let mut engine = Fake::new(false, false);
        engine.image_error = Some(message);
        let error = operate(&engine, &project, DockerComposeAction::Rebuild)
            .await
            .unwrap_err();
        assert_eq!(error.to_string(), message);
        assert_eq!(*engine.calls.lock().unwrap(), ["check", "down"]);
    }
}

#[cfg(unix)]
#[test]
fn fixed_compose_commands_preserve_quoted_sources_sudo_target_and_rebuild_steps() {
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;
    let temp = tempfile::tempdir().unwrap();
    let binary = temp.path().join("docker");
    let log = temp.path().join("calls");
    std::fs::write(
        &binary,
        r#"#!/bin/sh
[ -z "${COMPOSE_FILE:-}" ] || exit 1
printf 'CALL\n' >> "$COMPOSE_TEST_LOG"
for arg do printf '%s\n' "$arg" >> "$COMPOSE_TEST_LOG"; done
case " $* " in
  *' config --services '*) printf 'api\n';;
esac
"#,
    )
    .unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
    let sudo = temp.path().join("sudo");
    std::fs::write(
        &sudo,
        r#"#!/bin/sh
[ "$1" = -n ] && [ "$2" = -- ] || exit 1
[ -z "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}" ] || exit 1
shift 2
exec "$@"
"#,
    )
    .unwrap();
    std::fs::set_permissions(&sudo, std::fs::Permissions::from_mode(0o755)).unwrap();
    for elevated in [false, true] {
        let access = Access {
            binary: binary.to_str().unwrap().into(),
            endpoint: "unix:///original/docker.sock".into(),
            sudo: elevated,
            config: "/home/user/.docker config".into(),
            api: "1.53".into(),
            api_minor: 53,
        };
        let mut project = project_from_json("app", &fixture(), true).unwrap();
        project.source.as_mut().unwrap().configs[0] =
            "/srv/a' $(touch INJECTED) @COMPOSE_STEPS@/compose.yaml".into();
        std::fs::write(&log, "").unwrap();
        for phase in [
            Phase::Check,
            Phase::Start,
            Phase::Stop,
            Phase::Down,
            Phase::Rebuild,
        ] {
            let command = compose_command(&access, &project, phase).unwrap();
            let result = Command::new("sh")
                .arg("-c")
                .arg(command)
                .env(
                    "PATH",
                    format!(
                        "{}:{}",
                        temp.path().display(),
                        std::env::var("PATH").unwrap()
                    ),
                )
                .env("COMPOSE_TEST_LOG", &log)
                .env("COMPOSE_FILE", "wrong.yaml")
                .env("DOCKER_HOST", "invalid")
                .env("DOCKER_CONTEXT", "invalid")
                .current_dir(temp.path())
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
        }
        let calls = std::fs::read_to_string(&log).unwrap();
        assert!(calls.contains("/srv/a' $(touch INJECTED) @COMPOSE_STEPS@/compose.yaml"));
        assert!(calls.contains("--env-file\n/srv/app/app.env"));
        assert!(!temp.path().join("INJECTED").exists());
        assert!(calls.contains("pull\n--ignore-buildable\n--include-deps\napi"));
        assert!(calls.contains("build\n--with-dependencies\n--no-cache\n--pull\napi"));
        assert!(calls.contains("up\n--detach\n--no-build\n--pull\nnever\napi"));
        assert!(calls.contains("down\n--remove-orphans\n--timeout\n20"));
        assert!(!calls.contains("--volumes") && !calls.contains("--rmi"));
        if elevated {
            assert!(calls.contains(
                "--config\n/home/user/.docker config\n--host\nunix:///original/docker.sock"
            ));
        }
    }
}
