//! Runs the actual Docker CLI formatter against an isolated HTTP fixture daemon.
//! No Docker service, images or containers on the developer's machine are used.
//!
//! Run with `cargo test docker_container_inspect_formats_optional_health_with_actual_cli -- --ignored --nocapture`.
//! `PAGASHELL_DOCKER_CLI` optionally selects the Docker CLI executable.

use super::{docker_command, DockerResourceKind};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::time::Duration;

struct FixtureDaemon {
    address: SocketAddr,
    value: Arc<Mutex<Value>>,
    requests: Arc<Mutex<Vec<(String, String)>>>,
    stopping: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl FixtureDaemon {
    fn new() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let value = Arc::new(Mutex::new(Value::Null));
        let stopping = Arc::new(AtomicBool::new(false));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let calls = requests.clone();
        let data = value.clone();
        let stop = stopping.clone();
        let thread = std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => Self::serve(stream, &data, &calls),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("fixture accept failed: {error}"),
                }
            }
        });
        Self {
            address,
            value,
            requests,
            stopping,
            thread: Some(thread),
        }
    }

    fn serve(mut stream: TcpStream, value: &Mutex<Value>, calls: &Mutex<Vec<(String, String)>>) {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut request = Vec::new();
        let mut bytes = [0; 1024];
        while !request.windows(4).any(|part| part == b"\r\n\r\n") {
            match stream.read(&mut bytes) {
                Ok(0) | Err(_) => return,
                Ok(count) => request.extend_from_slice(&bytes[..count]),
            }
            if request.len() > 16 * 1024 {
                return;
            }
        }
        let request = String::from_utf8_lossy(&request);
        let mut first_line = request.lines().next().unwrap().split_whitespace();
        let method = first_line.next().unwrap();
        let path = first_line.next().unwrap();
        calls.lock().unwrap().push((method.into(), path.into()));
        let route = path.split('?').next().unwrap();
        let (status, body) = if path.ends_with("/_ping") {
            ("200 OK", "OK".to_owned())
        } else if route.ends_with("/containers/json") {
            ("200 OK", value.lock().unwrap().to_string())
        } else if route.ends_with("/networks") {
            ("200 OK", "[]".into())
        } else if route.ends_with("/volumes") {
            (
                "200 OK",
                json!({"Volumes": [], "Warnings": null}).to_string(),
            )
        } else if method == "POST" && (route.ends_with("/start") || route.ends_with("/stop")) {
            let mut value = value.lock().unwrap();
            value[0]["State"] = json!(if route.ends_with("/start") {
                "running"
            } else {
                "exited"
            });
            ("204 No Content", String::new())
        } else if method == "DELETE" && route.contains("/containers/") {
            *value.lock().unwrap() = json!([]);
            ("204 No Content", String::new())
        } else if path.contains("/containers/") && path.ends_with("/json") {
            let value = value.lock().unwrap();
            if value.is_array() {
                let mut details = container(value[0]["Id"].as_str().unwrap(), None);
                details["Config"]["Labels"] = value[0]["Labels"].clone();
                details["State"]["Status"] = value[0]["State"].clone();
                details["State"]["Running"] = json!(value[0]["State"] == "running");
                details["HostConfig"] = json!({});
                ("200 OK", details.to_string())
            } else {
                ("200 OK", value.to_string())
            }
        } else {
            (
                "404 Not Found",
                json!({"message": format!("Unexpected fixture endpoint: {method} {path}")})
                    .to_string(),
            )
        };
        let headers = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nApi-Version: 1.53\r\nOstype: linux\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()
        );
        let _ = stream.write_all(headers.as_bytes());
        if method != "HEAD" {
            let _ = stream.write_all(body.as_bytes());
        }
    }
}

#[tokio::test]
#[ignore = "requires Docker Compose CLI; only connects to a loopback fixture daemon"]
async fn docker_compose_lists_metadata_and_controls_projects_without_source_yaml_with_actual_cli() {
    use std::os::unix::fs::symlink;
    let cli = docker_cli();
    let temp = tempfile::tempdir().unwrap();
    let bin = temp.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    symlink(&cli, bin.join("docker")).unwrap();
    let daemon = FixtureDaemon::new();
    let project = json!([{
        "Id": "a".repeat(64), "Names": ["/app-api-1"], "Image": "example:latest",
        "ImageID": format!("sha256:{}", "b".repeat(64)), "State": "exited", "Status": "Exited (0)",
        "Labels": {
            "com.docker.compose.project": "app", "com.docker.compose.service": "api",
            "com.docker.compose.oneoff": "False", "com.docker.compose.config-hash": "fixture",
            "com.docker.compose.project.working_dir": "/missing/app",
            "com.docker.compose.project.config_files": "/missing/app/compose.yaml",
            "com.docker.compose.version": "2.40.0", "password": "PAGA_TEST_SECRET"
        },
        "HostConfig": {"NetworkMode":"bridge"}, "NetworkSettings": {"Networks": {}}, "Mounts": []
    }]);
    *daemon.value.lock().unwrap() = project.clone();
    // Run the production projection using the real Docker Go-template formatter.
    for target in [None, Some("app")] {
        let command = docker_command(DockerResourceKind::Compose, target).unwrap();
        let mut process = tokio::process::Command::new("sh");
        process
            .args(["-c", &command])
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("DOCKER_HOST", format!("tcp://{}", daemon.address))
            .env("DOCKER_API_VERSION", "1.53")
            .env("DOCKER_CONFIG", temp.path())
            .env_remove("DOCKER_CONTEXT")
            .env_remove("DOCKER_TLS_VERIFY")
            .env_remove("DOCKER_TLS")
            .env_remove("DOCKER_CERT_PATH")
            .kill_on_drop(true);
        let output = tokio::time::timeout(Duration::from_secs(10), process.output())
            .await
            .unwrap()
            .unwrap();
        assert!(output.status.success(), "{:?}", output.status);
        let raw = String::from_utf8(output.stdout).unwrap();
        assert!(!raw.contains("PAGA_TEST_SECRET"));
        let row: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(row["id"], "app");
        assert_eq!(row["service"], "api");
        assert_eq!(row["configFiles"], "/missing/app/compose.yaml");
    }
    // No YAML exists in the working directory or at the recorded source location.
    // The actual plugin must use project labels for start/stop/down.
    for args in [
        vec!["start"],
        vec!["stop", "--timeout", "20"],
        vec!["down", "--remove-orphans", "--timeout", "20"],
    ] {
        let mut process = tokio::process::Command::new(&cli);
        process
            .args([
                "--host",
                &format!("tcp://{}", daemon.address),
                "compose",
                "--ansi",
                "never",
                "--project-name",
                "app",
            ])
            .args(&args)
            .current_dir(temp.path())
            .env("DOCKER_API_VERSION", "1.53")
            // Preserve plugin discovery from the user's Docker config; the explicit
            // loopback --host above and cleared context keep every request isolated.
            .env_remove("COMPOSE_FILE")
            .env_remove("DOCKER_CONTEXT")
            .env_remove("DOCKER_TLS_VERIFY")
            .env_remove("DOCKER_TLS")
            .env_remove("DOCKER_CERT_PATH")
            .kill_on_drop(true);
        let output = tokio::time::timeout(Duration::from_secs(10), process.output())
            .await
            .unwrap()
            .unwrap();
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let calls = daemon.requests.lock().unwrap();
    assert!(calls
        .iter()
        .any(|(method, path)| method == "POST" && path.ends_with("/start")));
    assert!(calls
        .iter()
        .any(|(method, path)| method == "POST" && path.contains("/stop")));
    assert!(calls
        .iter()
        .any(|(method, path)| method == "DELETE" && path.contains("/containers/")));
    assert!(!calls.iter().any(|(method, path)| method == "DELETE"
        && (path.contains("/images/") || path.contains("/volumes/"))));
}

impl Drop for FixtureDaemon {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Relaxed);
        self.thread.take().unwrap().join().unwrap();
    }
}

fn docker_cli() -> PathBuf {
    if let Some(path) = std::env::var_os("PAGASHELL_DOCKER_CLI") {
        return std::path::absolute(path).expect("PAGASHELL_DOCKER_CLI must name a Docker CLI");
    }
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|directory| directory.join("docker"))
        .find(|path| path.is_file())
        // Docker wrappers such as OrbStack dispatch by argv[0]; keep the docker symlink name.
        .and_then(|path| std::path::absolute(path).ok())
        .expect("requires Docker CLI in PATH or PAGASHELL_DOCKER_CLI")
}

fn container(id: &str, health: Option<Value>) -> Value {
    let mut value = json!({
        "Id": id, "Name": "/fixture-api", "Created": "2026-11-07T00:00:00Z",
        "Config": {"Image": "example:latest", "Env": ["TOKEN=PAGA_TEST_SECRET"],
            "Labels": {"password": "PAGA_TEST_SECRET"}},
        "Args": ["--token", "PAGA_TEST_SECRET"],
        "State": {"Status": "running", "StartedAt": "2026-11-07T00:00:00Z", "FinishedAt": "", "ExitCode": 0},
        "RestartCount": 0,
        "NetworkSettings": {"Ports": {"80/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]},
            "Networks": {"bridge": {"IPAddress": "172.17.0.2", "GlobalIPv6Address": "",
                "DriverOpts": {"password": "PAGA_TEST_SECRET"}}}},
        "Mounts": []
    });
    if let Some(health) = health {
        value["State"]["Health"] = health;
    }
    value
}

#[tokio::test]
#[ignore = "requires Docker CLI; only connects to a loopback fixture daemon"]
async fn docker_container_inspect_formats_optional_health_with_actual_cli() {
    use std::os::unix::fs::symlink;
    let cli = docker_cli();
    let version = std::process::Command::new(&cli)
        .arg("--version")
        .output()
        .unwrap();
    assert!(
        version.status.success(),
        "Docker CLI could not run: {}",
        String::from_utf8_lossy(&version.stderr)
    );
    eprintln!("{}", String::from_utf8_lossy(&version.stdout).trim());
    let directory = tempfile::tempdir().unwrap();
    let bin = directory.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    symlink(cli, bin.join("docker")).unwrap();
    let daemon = FixtureDaemon::new();
    let id = "a".repeat(64);
    let mut host = container(&id, None);
    host["NetworkSettings"] =
        json!({"Ports": {}, "Networks": {"host": {"IPAddress": "", "GlobalIPv6Address": ""}}});
    let mut disabled = container(&id, None);
    disabled["Config"]["Healthcheck"] = json!({"Test": ["NONE"]});
    let cases = [
        ("no-healthcheck", container(&id, None), ""),
        (
            "healthy",
            container(
                &id,
                Some(json!({"Status": "healthy", "Log": [{"Output": "PAGA_TEST_SECRET"}]})),
            ),
            "healthy",
        ),
        (
            "unhealthy",
            container(&id, Some(json!({"Status": "unhealthy"}))),
            "unhealthy",
        ),
        ("null-health", container(&id, Some(Value::Null)), ""),
        ("empty-health", container(&id, Some(json!({}))), ""),
        ("host-network", host, ""),
        ("disabled-healthcheck", disabled, ""),
    ];
    let command = docker_command(DockerResourceKind::Container, Some(&id)).unwrap();
    for (name, fixture, health) in cases {
        *daemon.value.lock().unwrap() = fixture;
        let mut process = tokio::process::Command::new("/bin/sh");
        process
            .args(["-c", &command])
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("DOCKER_HOST", format!("tcp://{}", daemon.address))
            .env("DOCKER_API_VERSION", "1.53")
            .env("DOCKER_CONFIG", directory.path())
            .env("TMPDIR", directory.path())
            .env_remove("DOCKER_CONTEXT")
            .env_remove("DOCKER_TLS_VERIFY")
            .env_remove("DOCKER_TLS")
            .env_remove("DOCKER_CERT_PATH")
            .kill_on_drop(true);
        let output = tokio::time::timeout(Duration::from_secs(5), process.output())
            .await
            .expect("Docker fixture query timed out")
            .unwrap();
        assert!(
            output.status.success(),
            "{name}: script exited {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(output.stderr.is_empty(), "{name}: unexpected diagnostics");
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(value["id"], id, "{name}");
        assert_eq!(value["name"], "/fixture-api", "{name}");
        assert_eq!(value["health"], health, "{name}");
        assert!(
            !String::from_utf8_lossy(&output.stdout).contains("PAGA_TEST_SECRET"),
            "{name}: private fields were projected"
        );
        assert!(
            std::fs::read_dir(directory.path())
                .unwrap()
                .all(|entry| !entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("paga-docker.")),
            "{name}: temporary output leaked"
        );
    }
}
