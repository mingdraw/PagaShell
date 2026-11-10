use anyhow::{anyhow, Result};
use std::time::Duration;

use super::ssh::{read_only_exec, server_status_command, ReadOnlyExecPolicy};

#[cfg(all(test, unix))]
#[path = "docker_cli_tests.rs"]
mod cli_tests;

#[cfg(all(test, unix))]
#[path = "docker_terminal_tests.rs"]
mod terminal_tests;

#[derive(Clone, Copy, Debug)]
pub enum DockerResourceKind {
    Container,
    Image,
    Network,
    Volume,
    Compose,
}

#[derive(Clone, Copy, Debug)]
pub enum DockerContainerAction {
    Start,
    Stop,
    Upgrade,
    Delete,
}

#[derive(Clone, Copy, Debug)]
pub enum DockerImageAction {
    Delete,
    PruneUntagged,
    PruneUnused,
}

#[derive(Clone, Copy, Debug)]
pub enum DockerComposeAction {
    Start,
    Stop,
    Rebuild,
    Delete,
}

/// 仅接受 Compose 项目名及固定操作；重建从远端原配置读取，不传回配置内容。
pub async fn ssh_run_docker_compose_action(
    session_id: u32,
    project_name: String,
    action: DockerComposeAction,
) -> Result<Option<String>> {
    crate::docker_operations::compose::run(session_id, &project_name, action).await
}

/// 镜像删除不强制；批量清理按所选范围执行，保留容器引用。
pub async fn ssh_run_docker_image_action(
    session_id: u32,
    action: DockerImageAction,
    image_id: Option<String>,
) -> Result<()> {
    crate::docker_operations::run_image(session_id, action, image_id.as_deref()).await
}

/// 仅接受固定容器操作；配置保留在 Rust 与远端 Docker 之间，不返回界面。
/// 成功时可返回需要用户查看的固定提示。
pub async fn ssh_run_docker_container_action(
    session_id: u32,
    container_id: String,
    action: DockerContainerAction,
    target_image: Option<String>,
    force_pull: bool,
) -> Result<Option<String>> {
    crate::docker_operations::run(
        session_id,
        &container_id,
        action,
        target_image.as_deref(),
        force_pull,
    )
    .await
}

const DOCKER_EXEC_POLICY: ReadOnlyExecPolicy = ReadOnlyExecPolicy {
    overall_timeout: Some(Duration::from_secs(8)),
    closed: "Docker 管理连接已关闭",
    timeout: "Docker 查询超时，请重试",
    connection: "无法查询 Docker，请检查连接",
    denied: "此连接不允许 Docker 查询",
    too_large: "Docker 数据过大，请减少远端资源后重试",
    incomplete: "Docker 查询未完成，请重试",
};

/// 只查询当前分类；搜索在 Dart 本地完成，不接受任意 Docker 参数或 shell。
pub async fn ssh_read_docker_resources(
    session_id: u32,
    kind: DockerResourceKind,
) -> Result<String> {
    query(session_id, kind, None).await
}

/// 单项详情只输出固定字段；Compose 只投影明确的元数据标签。
/// 不读取环境变量、命令参数、任意标签或驱动凭据。
pub async fn ssh_read_docker_details(
    session_id: u32,
    kind: DockerResourceKind,
    resource_id: String,
) -> Result<String> {
    query(session_id, kind, Some(&resource_id)).await
}

async fn query(session_id: u32, kind: DockerResourceKind, id: Option<&str>) -> Result<String> {
    let command = docker_command(kind, id)?;
    let max_bytes = if id.is_some() {
        256 * 1024
    } else {
        2 * 1024 * 1024
    };
    let (output, code) =
        read_only_exec(session_id, command, &DOCKER_EXEC_POLICY, max_bytes).await?;
    match code {
        0 => Ok(String::from_utf8_lossy(&output).into_owned()),
        64 => Err(anyhow!("Docker 管理仅支持 Linux 和 macOS")),
        70 => Err(anyhow!("Docker 未运行")),
        74 => Err(anyhow!(DOCKER_EXEC_POLICY.too_large)),
        77 => Err(anyhow!("没有权限获取 Docker 信息")),
        78 => Err(anyhow!("Docker 资源可能已移除，请刷新后重试")),
        _ if id.is_some() => Err(anyhow!("无法读取 Docker 详情，请重试")),
        _ => Err(anyhow!("无法读取 Docker，请重试")),
    }
}

pub(super) fn docker_command(kind: DockerResourceKind, id: Option<&str>) -> Result<String> {
    if let Some(id) = id {
        validate_docker_id(kind, id)?;
    }
    let resource = match kind {
        DockerResourceKind::Container => "container",
        DockerResourceKind::Image => "image",
        DockerResourceKind::Network => "network",
        DockerResourceKind::Volume => "volume",
        DockerResourceKind::Compose => "compose",
    };
    Ok(format!(
        "{} paga-docker {resource} '{}'",
        server_status_command(include_str!("docker_read.sh")),
        id.unwrap_or("")
    ))
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn validate_docker_id(kind: DockerResourceKind, id: &str) -> Result<()> {
    let valid = match kind {
        DockerResourceKind::Compose => {
            !id.is_empty()
                && id.len() <= 255
                && (id.as_bytes()[0].is_ascii_lowercase() || id.as_bytes()[0].is_ascii_digit())
                && id
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"_-".contains(&b))
        }
        DockerResourceKind::Volume => {
            !id.is_empty()
                && id.len() <= 255
                && id.as_bytes()[0].is_ascii_alphanumeric()
                && id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
        }
        _ => {
            let digest = id.strip_prefix("sha256:").unwrap_or(id);
            (12..=64).contains(&digest.len())
                && digest.bytes().all(|b| b.is_ascii_hexdigit())
                && (!id.starts_with("sha256:") || matches!(kind, DockerResourceKind::Image))
        }
    };
    if !valid {
        return Err(anyhow!("Docker 资源标识无效，请刷新列表"));
    }
    Ok(())
}

pub(super) fn docker_terminal_error(code: u32) -> &'static str {
    match code {
        64 => "容器终端仅支持 Linux 和 macOS",
        70 => "Docker 未运行",
        76 => "容器终端预检返回的数据无效，请重试",
        77 => "没有权限获取 Docker 信息",
        79 => "容器未运行或已移除，请刷新列表",
        80 => "容器中未找到可用的 bash 或 sh",
        81 => "无法创建容器终端预检临时文件，请检查远端临时目录",
        _ => "无法打开容器终端，请检查容器状态后重试",
    }
}

pub(super) fn docker_terminal_exec_error(code: u32, diagnostic: &[u8]) -> String {
    // Never forward raw daemon output: it may contain host paths or runtime configuration.
    let text = String::from_utf8_lossy(diagnostic).to_ascii_lowercase();
    let reason = if text.contains("is restarting") {
        Some("容器正在重启，暂时无法打开终端")
    } else if text.contains("is paused") {
        Some("容器已暂停，请恢复运行后重试")
    } else if text.contains("is not running")
        || text.contains("no such container:")
        || text.contains("no such object:")
    {
        Some(docker_terminal_error(79))
    } else if (text.contains("chdir to cwd") || text.contains("working directory"))
        && text.contains("no such file or directory")
    {
        Some("容器配置的工作目录不存在，无法启动终端")
    } else if text.contains("unable to find user")
        || text.contains("no matching entries in passwd file")
    {
        Some("容器配置的用户不存在，无法启动终端")
    } else if text.contains("executable file not found")
        || (text.contains("no such file or directory")
            && ["exec: ", "/bin/bash", "/bin/sh"]
                .iter()
                .any(|part| text.contains(part)))
    {
        Some(docker_terminal_error(80))
    } else if text.contains("exec format error") {
        Some("容器中的 bash 或 sh 可执行文件格式错误")
    } else if text.contains("permission denied") || text.contains("operation not permitted") {
        Some(if text.contains("oci runtime") || text.contains("exec: ") {
            "容器中的 bash 或 sh 没有执行权限"
        } else {
            docker_terminal_error(77)
        })
    } else if text.contains("authorization denied")
        || text.contains("403 forbidden")
        || text.contains("sudo:")
    {
        Some(docker_terminal_error(77))
    } else if text.contains("cannot connect to the docker daemon")
        || text.contains("is the docker daemon running")
        || text.contains("connection refused")
    {
        Some(docker_terminal_error(70))
    } else {
        None
    };
    reason.map(str::to_owned).unwrap_or_else(|| match code {
        64 | 70 | 77 | 79 | 80 | 81 => docker_terminal_error(code).to_owned(),
        126 => "容器内的 bash 或 sh 无法执行（退出码 126）".to_owned(),
        127 => "容器内命令未找到，无法启动 bash 或 sh（退出码 127）".to_owned(),
        _ => format!("Docker 执行容器终端失败（退出码 {code}）"),
    })
}

fn docker_terminal_preflight_error(code: u32, output: &[u8]) -> String {
    let text = String::from_utf8_lossy(output);
    let mut fields = text.splitn(3, '\n');
    if fields.next() == Some("PAGA_DOCKER_TERMINAL_FAILURE_V1") {
        if let Some(exit_code) = fields
            .next()
            .and_then(|value| value.parse::<u32>().ok())
            .filter(|value| (1..=255).contains(value))
        {
            return docker_terminal_exec_error(exit_code, fields.next().unwrap_or("").as_bytes());
        }
    }
    docker_terminal_exec_error(code, output)
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn shell_argument(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub(super) async fn docker_terminal_command(session_id: u32, id: &str) -> Result<String> {
    validate_docker_id(DockerResourceKind::Container, id)?;
    let command = format!(
        "{} paga-docker-terminal '{}'",
        server_status_command(include_str!("docker_terminal_prepare.sh")),
        id
    );
    let (output, code) =
        read_only_exec(session_id, command, &DOCKER_EXEC_POLICY, 16 * 1024).await?;
    if code != 0 {
        return Err(anyhow!(docker_terminal_preflight_error(code, &output)));
    }
    docker_terminal_launch_command(id, &output)
}

fn docker_terminal_launch_command(id: &str, output: &[u8]) -> Result<String> {
    validate_docker_id(DockerResourceKind::Container, id)?;
    let text = std::str::from_utf8(output).map_err(|_| anyhow!(docker_terminal_error(76)))?;
    let fields: Vec<_> = text.lines().collect();
    if fields.len() != 5
        || fields[0] != "PAGA_DOCKER_TERMINAL_V1"
        || fields[1].is_empty()
        || fields[1].starts_with('-')
        || !matches!(
            fields[2],
            "/bin/bash" | "/usr/bin/bash" | "bash" | "/bin/sh" | "/usr/bin/sh" | "sh"
        )
        || !matches!(fields[4], "0" | "1")
        || (fields[4] == "1" && (!fields[3].starts_with("unix://") || fields[3].len() <= 7))
        || fields
            .iter()
            .any(|field| field.chars().any(char::is_control))
    {
        return Err(anyhow!(docker_terminal_error(76)));
    }
    Ok(format!(
        "{} paga-docker-terminal {} {} {} {} {}",
        server_status_command(include_str!("docker_terminal.sh")),
        shell_argument(id),
        shell_argument(fields[1]),
        shell_argument(fields[2]),
        shell_argument(fields[3]),
        shell_argument(fields[4])
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn docker_details_reject_shell_input_options_and_wrong_ids() {
        for kind in [
            DockerResourceKind::Container,
            DockerResourceKind::Image,
            DockerResourceKind::Network,
            DockerResourceKind::Volume,
        ] {
            for id in ["", "--help", "$(id)", "x';id", "../name", "name\nnext"] {
                assert!(docker_command(kind, Some(id)).is_err());
            }
            assert!(docker_command(kind, None).is_ok());
        }
        assert!(docker_command(DockerResourceKind::Container, Some(&"a".repeat(64))).is_ok());
        assert!(docker_command(
            DockerResourceKind::Image,
            Some(&format!("sha256:{}", "b".repeat(64)))
        )
        .is_ok());
        assert!(docker_command(DockerResourceKind::Volume, Some("project_data-1.0")).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn docker_script_only_invokes_list_or_projected_inspect_and_hides_stderr() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let binary = directory.path().join("docker");
        std::fs::write(&binary, "#!/bin/sh\nif [ \"$1:$2:$4\" = container:ls:--quiet ]; then exit 0; fi\nprintf '%s\\n' \"$@\"\nprintf 'private daemon diagnostic' >&2\nexit \"${PAGA_DOCKER_TEST_EXIT:-0}\"\n").unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        for kind in ["container", "image", "network", "volume"] {
            for target in ["", "aabbccddeeff"] {
                let output = std::process::Command::new("sh")
                    .args([
                        "-c",
                        include_str!("docker_read.sh"),
                        "paga-docker",
                        kind,
                        target,
                    ])
                    .env(
                        "PATH",
                        format!("{}:/usr/bin:/bin", directory.path().display()),
                    )
                    .output()
                    .unwrap();
                assert!(output.status.success());
                assert!(output.stderr.is_empty());
                let args = String::from_utf8(output.stdout).unwrap();
                if target.is_empty() {
                    assert!(args.starts_with(&format!("{kind}\nls\n")));
                    if kind == "container" {
                        assert!(args.contains("--all\n"));
                    }
                } else {
                    assert!(args.starts_with(&format!("inspect\n--type\n{kind}\n--format\n")));
                    assert!(args.ends_with(&format!("\n{target}\n")));
                }
                for forbidden in [".Env", ".Args", ".Labels", ".Options", "DriverOpts"] {
                    assert!(!args.contains(forbidden));
                }
            }
        }
        let failure = std::process::Command::new("sh")
            .args([
                "-c",
                include_str!("docker_read.sh"),
                "paga-docker",
                "container",
                "",
            ])
            .env(
                "PATH",
                format!("{}:/usr/bin:/bin", directory.path().display()),
            )
            .env("PAGA_DOCKER_TEST_EXIT", "71")
            .output()
            .unwrap();
        assert_eq!(failure.status.code(), Some(75));
        assert!(failure.stderr.is_empty());
    }

    #[cfg(unix)]
    struct ScriptFixture {
        directory: tempfile::TempDir,
    }

    #[cfg(unix)]
    impl ScriptFixture {
        fn new(with_sudo: bool) -> Self {
            use std::os::unix::fs::{symlink, PermissionsExt};
            let directory = tempfile::tempdir().unwrap();
            let bin = directory.path().join("bin");
            std::fs::create_dir(&bin).unwrap();
            std::fs::create_dir(directory.path().join("tmp")).unwrap();
            // Isolate PATH: none of these tests can execute the machine's Docker or sudo.
            for name in ["uname", "mktemp", "rm", "rmdir", "cat", "head", "tr", "wc"] {
                let source = ["/usr/bin", "/bin"]
                    .into_iter()
                    .map(|base| std::path::Path::new(base).join(name))
                    .find(|path| path.is_file())
                    .unwrap();
                symlink(source, bin.join(name)).unwrap();
            }
            let docker = r#"#!/bin/sh
printf 'docker' >> "$PAGA_DOCKER_TRACE"
printf ' <%s>' "$@" >> "$PAGA_DOCKER_TRACE"
printf '\n' >> "$PAGA_DOCKER_TRACE"
docker_success() {
  [ "$1:$2:$4" != container:ls:--quiet ] || return 0
  printf '{"id":"allowed"}\n'
}
if [ "$1" = context ]; then
  [ "$PAGA_DOCKER_SCENARIO" != context_unavailable ] || exit 1
  printf '%s\n' "${PAGA_DOCKER_ENDPOINT:-unix:///var/run/docker.sock}"
  exit 0
fi
if [ "$1" = --host ]; then
  shift 2
  case "$PAGA_DOCKER_SCENARIO" in
    sudo_stopped) printf 'Cannot connect to the Docker daemon. Is the docker daemon running?' >&2; exit 1 ;;
    sudo_still_denied) printf 'permission denied while trying to connect to the Docker daemon socket' >&2; exit 1 ;;
    sudo_missing) printf 'Error: No such object: private-name' >&2; exit 1 ;;
  esac
  docker_success "$@"
  exit 0
fi
case "$PAGA_DOCKER_SCENARIO" in
  success) docker_success "$@"; exit 0 ;;
  image_list)
    case "$1:$2" in
      image:ls) cat "$PAGA_IMAGE_LIST" ;;
      container:ls) cat "$PAGA_CONTAINER_IDS" ;;
      container:inspect)
        [ "$4" = '{"usedImageId":{{json .Image}}}' ] || exit 99
        shift 4
        for container in "$@"; do printf '{"usedImageId":"%s"}\n' "$PAGA_USED_IMAGE"; done ;;
      *) exit 99 ;;
    esac
    exit 0 ;;
  missing) printf 'docker: not found' >&2; exit 127 ;;
  stopped) printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2; exit 1 ;;
  refused) printf 'failed to connect to the docker API: connect: connection refused' >&2; exit 1 ;;
  resource_missing) printf 'Error: No such volume: forbidden-data' >&2; exit 1 ;;
  container_missing) printf 'Error response from daemon: No such container: aabbccddeeff' >&2; exit 1 ;;
  object_missing) printf 'Error: No such object: aabbccddeeff' >&2; exit 1 ;;
  unknown) printf 'private platform diagnostic /private/host' >&2; exit 1 ;;
  permission_case) printf 'Operation Not Permitted' >&2; exit 1 ;;
  *) printf '{"partial":'; printf 'Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock' >&2; exit 1 ;;
esac
"#;
            let sudo = r#"#!/bin/sh
printf 'sudo' >> "$PAGA_DOCKER_TRACE"
printf ' <%s>' "$@" >> "$PAGA_DOCKER_TRACE"
printf '\n' >> "$PAGA_DOCKER_TRACE"
[ "$1" = -n ] && [ "$2" = -- ] || exit 99
shift 2
case "$PAGA_DOCKER_SCENARIO" in
  sudo_denied) printf 'sudo: user is not allowed to execute this command' >&2; exit 1 ;;
  sudo_password) printf 'sudo: a password is required' >&2; exit 1 ;;
  sudo_tty) printf 'sudo: sorry, you must have a tty to run sudo' >&2; exit 1 ;;
esac
exec "$@"
"#;
            for (name, script) in [("docker", docker), ("sudo", sudo)] {
                if name == "sudo" && !with_sudo {
                    continue;
                }
                let path = bin.join(name);
                std::fs::write(&path, script).unwrap();
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
            }
            Self { directory }
        }

        fn run(
            &self,
            kind: &str,
            target: &str,
            scenario: &str,
            variables: &[(&str, &str)],
        ) -> std::process::Output {
            let mut command = std::process::Command::new("/bin/sh");
            command
                .args([
                    "-c",
                    include_str!("docker_read.sh"),
                    "paga-docker",
                    kind,
                    target,
                ])
                .env("PATH", self.directory.path().join("bin"))
                .env("TMPDIR", self.directory.path().join("tmp"))
                .env("PAGA_DOCKER_TRACE", self.directory.path().join("trace"))
                .env("PAGA_DOCKER_SCENARIO", scenario)
                .env_remove("DOCKER_HOST")
                .env_remove("DOCKER_CONTEXT")
                .env_remove("PAGA_DOCKER_ENDPOINT")
                .envs(variables.iter().copied());
            command.output().unwrap()
        }

        fn trace(&self) -> String {
            std::fs::read_to_string(self.directory.path().join("trace")).unwrap()
        }

        fn assert_clean(&self) {
            assert_eq!(
                std::fs::read_dir(self.directory.path().join("tmp"))
                    .unwrap()
                    .count(),
                0
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn docker_permission_retry_is_noninteractive_for_all_kinds_and_never_mixes_failed_output() {
        for kind in ["container", "image", "network", "volume"] {
            for target in ["", "aabbccddeeff"] {
                let fixture = ScriptFixture::new(true);
                let output = fixture.run(kind, target, "permission", &[]);
                assert!(output.status.success());
                let image_list = kind == "image" && target.is_empty();
                assert_eq!(
                    output.stdout,
                    if image_list {
                        b"{\"id\":\"allowed\"}\n{\"imageUsageComplete\":true}\n".as_slice()
                    } else {
                        b"{\"id\":\"allowed\"}\n".as_slice()
                    }
                );
                assert!(output.stderr.is_empty());
                let trace = fixture.trace();
                assert_eq!(
                    trace
                        .lines()
                        .filter(|line| line.starts_with("sudo "))
                        .count(),
                    if image_list { 2 } else { 1 }
                );
                assert!(trace.contains("sudo <-n> <-->"));
                assert!(trace.contains("<--host> <unix:///var/run/docker.sock>"));
                fixture.assert_clean();
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn docker_image_list_includes_untagged_and_collects_only_immutable_references_in_batches() {
        let fixture = ScriptFixture::new(false);
        let images = fixture.directory.path().join("images");
        let containers = fixture.directory.path().join("containers");
        let image_id = format!("sha256:{}", "a".repeat(64));
        std::fs::write(
            &images,
            format!("{{\"id\":\"{image_id}\",\"repository\":\"<none>\",\"tag\":\"<none>\"}}\n"),
        )
        .unwrap();
        std::fs::write(
            &containers,
            (0..129)
                .map(|id| format!("{id:064x}\n"))
                .collect::<String>(),
        )
        .unwrap();
        let variables = [
            ("PAGA_IMAGE_LIST", images.to_str().unwrap()),
            ("PAGA_CONTAINER_IDS", containers.to_str().unwrap()),
            ("PAGA_USED_IMAGE", image_id.as_str()),
        ];
        let output = fixture.run("image", "", "image_list", &variables);
        assert!(output.status.success(), "{:?}", output.status);
        assert!(output.stderr.is_empty());
        let lines: Vec<serde_json::Value> = String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(lines.len(), 131);
        assert_eq!(lines[0]["tag"], "<none>");
        assert!(lines[1..130]
            .iter()
            .all(|line| line["usedImageId"] == image_id));
        assert_eq!(lines[130], serde_json::json!({"imageUsageComplete":true}));
        let trace = fixture.trace();
        assert!(trace.contains("<image> <ls> <--all>"));
        assert!(trace.contains("<container> <ls> <--all> <--quiet> <--no-trunc>"));
        assert_eq!(
            trace
                .lines()
                .filter(|line| line.contains("<container> <inspect>"))
                .count(),
            2
        );
        for forbidden in [".Env", ".Args", ".Config", ".Labels"] {
            assert!(!trace.contains(forbidden));
        }
        fixture.assert_clean();

        std::fs::write(&containers, "--help\n").unwrap();
        let rejected = fixture.run("image", "", "image_list", &variables);
        assert_eq!(rejected.status.code(), Some(75));
        assert!(!String::from_utf8(rejected.stdout)
            .unwrap()
            .contains("imageUsageComplete"));
        fixture.assert_clean();
    }

    #[cfg(unix)]
    #[test]
    fn docker_success_unavailable_daemon_and_resource_errors_do_not_trigger_sudo() {
        for (scenario, code) in [
            ("success", 0),
            ("missing", 70),
            ("stopped", 70),
            ("refused", 70),
            ("resource_missing", 78),
            ("container_missing", 78),
            ("object_missing", 78),
            ("unknown", 75),
        ] {
            let fixture = ScriptFixture::new(true);
            let output = fixture.run("container", "aabbccddeeff", scenario, &[]);
            assert_eq!(output.status.code(), Some(code), "scenario {scenario}");
            assert!(output.stderr.is_empty());
            if code != 0 {
                assert!(output.stdout.is_empty());
            }
            assert!(!fixture.trace().contains("sudo "));
            fixture.assert_clean();
        }
    }

    #[cfg(unix)]
    #[test]
    fn docker_denied_sudo_or_missing_sudo_is_reported_as_permission_without_private_output() {
        for scenario in [
            "sudo_denied",
            "sudo_password",
            "sudo_tty",
            "sudo_still_denied",
            "context_unavailable",
        ] {
            let fixture = ScriptFixture::new(true);
            let output = fixture.run("volume", "", scenario, &[]);
            assert_eq!(output.status.code(), Some(77), "scenario {scenario}");
            assert!(output.stdout.is_empty());
            assert!(output.stderr.is_empty());
            fixture.assert_clean();
        }
        let fixture = ScriptFixture::new(false);
        let output = fixture.run("network", "", "permission", &[]);
        assert_eq!(output.status.code(), Some(77));
        assert!(output.stdout.is_empty());
        assert!(output.stderr.is_empty());
        fixture.assert_clean();
    }

    #[cfg(unix)]
    #[test]
    fn docker_retry_preserves_explicit_host_or_context_and_reports_actual_daemon_result() {
        for (variables, expected) in [
            (
                vec![("DOCKER_HOST", "unix:///custom/docker.sock")],
                "unix:///custom/docker.sock",
            ),
            (
                vec![
                    ("DOCKER_HOST", "unix:///ignored.sock"),
                    ("DOCKER_CONTEXT", "desktop-linux"),
                    (
                        "PAGA_DOCKER_ENDPOINT",
                        "unix:///users/test/.docker/run/docker.sock",
                    ),
                ],
                "unix:///users/test/.docker/run/docker.sock",
            ),
        ] {
            let fixture = ScriptFixture::new(true);
            let output = fixture.run("image", "", "permission_case", &variables);
            assert!(output.status.success());
            assert!(fixture.trace().contains(&format!("<--host> <{expected}>")));
            if variables.iter().any(|(name, _)| *name == "DOCKER_CONTEXT") {
                assert!(fixture
                    .trace()
                    .contains("<context> <inspect> <desktop-linux>"));
            }
            fixture.assert_clean();
        }
        for (scenario, code) in [("sudo_stopped", 70), ("sudo_missing", 78)] {
            let fixture = ScriptFixture::new(true);
            let output = fixture.run("container", "aabbccddeeff", scenario, &[]);
            assert_eq!(output.status.code(), Some(code));
            assert!(output.stdout.is_empty());
            assert!(output.stderr.is_empty());
            fixture.assert_clean();
        }
        let fixture = ScriptFixture::new(true);
        let output = fixture.run(
            "network",
            "",
            "permission",
            &[("DOCKER_HOST", "tcp://remote:2375")],
        );
        assert_eq!(output.status.code(), Some(77));
        assert!(!fixture.trace().contains("sudo "));
        fixture.assert_clean();
    }
}
