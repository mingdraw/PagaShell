use super::*;
use std::io::Write;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::process::{Command, Output, Stdio};

const CONTAINER: &str = "aabbccddeeff";

struct TerminalFixture {
    directory: tempfile::TempDir,
}

impl TerminalFixture {
    fn new(with_sudo: bool) -> Self {
        // Include spaces and a quote to exercise the Rust shell argument quoting.
        let directory = tempfile::Builder::new()
            .prefix("paga 'terminal ")
            .tempdir()
            .unwrap();
        let bin = directory.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        std::fs::create_dir(directory.path().join("tmp")).unwrap();
        for name in ["sh", "uname", "mktemp", "rm", "rmdir", "cat", "head", "tr"] {
            let source = ["/usr/bin", "/bin"]
                .into_iter()
                .map(|base| std::path::Path::new(base).join(name))
                .find(|path| path.is_file())
                .unwrap();
            symlink(source, bin.join(name)).unwrap();
        }
        let docker = r#"#!/bin/sh
printf 'docker' >> "$PAGA_TERMINAL_TRACE"
printf ' <%s>' "$@" >> "$PAGA_TERMINAL_TRACE"
printf '\n' >> "$PAGA_TERMINAL_TRACE"
if [ "$1" = context ]; then
  printf '%s\n' "${PAGA_TEST_ENDPOINT:-unix:///var/run/docker.sock}"
  exit 0
fi
if [ "$1" = --host ]; then shift 2; fi
case "$PAGA_TERMINAL_SCENARIO" in
  permission|sudo_denied)
    if [ "${PAGA_TEST_SUDO:-0}" != 1 ]; then
      printf 'permission denied while trying to connect to Docker /private/socket' >&2
      exit 1
    fi ;;
  unavailable) printf 'Cannot connect to the Docker daemon' >&2; exit 1 ;;
  missing) printf 'Error: No such container: private-name' >&2; exit 1 ;;
esac
if [ "$1" = container ]; then
  if [ "$PAGA_TERMINAL_SCENARIO" = stopped ]; then printf 'exited\n'; else printf 'running\n'; fi
  exit 0
fi
[ "$1" = exec ] || exit 98
if [ "$2" = -it ]; then cat; exit 0; fi
case "$PAGA_TERMINAL_SCENARIO:$3" in
  no_shell:*|sh_only:*bash) exit 127 ;;
  usr_bin_bash:/usr/bin/bash|path_sh:sh) ;;
  usr_bin_bash:*|path_sh:*) printf 'executable file not found in $PATH' >&2; exit 127 ;;
  sh_oci:*bash) printf 'OCI runtime exec failed: exec: "%s": stat %s: no such file or directory' "$3" "$3" >&2; exit 1 ;;
  sh_oci_stdout:*bash|no_shell_oci_stdout:*) printf 'OCI runtime exec failed: exec: "%s": stat %s: no such file or directory' "$3" "$3"; exit 126 ;;
  cwd_missing:*) printf 'OCI runtime exec failed: chdir to cwd ("/private/app") set in config.json failed: no such file or directory'; exit 126 ;;
  shell_permission:*) printf 'OCI runtime exec failed: exec: "%s": permission denied' "$3" >&2; exit 126 ;;
  shell_architecture:*) printf 'OCI runtime exec failed: exec: "%s": exec format error' "$3"; exit 126 ;;
  missing_user:*) printf 'unable to find user private-user: no matching entries in passwd file' >&2; exit 126 ;;
  denied_shell:*) printf 'authorization denied' >&2; exit 1 ;;
  unknown_exec:*) printf 'private OCI runtime failure /private/host' >&2; exit 1 ;;
  unknown_126:*) printf 'private runtime failure' >&2; exit 126 ;;
  unknown_127:*) printf 'private runtime failure' >&2; exit 127 ;;
esac
[ "$4" = -c ] && [ "$5" = : ] || exit 99
"#;
        let sudo = r#"#!/bin/sh
printf 'sudo' >> "$PAGA_TERMINAL_TRACE"
printf ' <%s>' "$@" >> "$PAGA_TERMINAL_TRACE"
printf '\n' >> "$PAGA_TERMINAL_TRACE"
[ "$1" = -n ] && [ "$2" = -- ] || exit 99
[ "$PAGA_TERMINAL_SCENARIO" != sudo_denied ] || { printf 'sudo: a password is required' >&2; exit 1; }
shift 2
PAGA_TEST_SUDO=1
export PAGA_TEST_SUDO
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

    fn command(&self, scenario: &str, variables: &[(&str, &str)]) -> Command {
        let mut command = Command::new("/bin/sh");
        command
            .env("PATH", self.directory.path().join("bin"))
            .env("TMPDIR", self.directory.path().join("tmp"))
            .env("PAGA_TERMINAL_TRACE", self.directory.path().join("trace"))
            .env("PAGA_TERMINAL_SCENARIO", scenario)
            .env_remove("PAGA_TEST_SUDO")
            .env_remove("PAGA_TEST_ENDPOINT")
            .env_remove("DOCKER_HOST")
            .env_remove("DOCKER_CONTEXT")
            .envs(variables.iter().copied());
        command
    }

    fn prepare(&self, scenario: &str, variables: &[(&str, &str)]) -> Output {
        let output = self
            .command(scenario, variables)
            .args([
                "-c",
                include_str!("docker_terminal_prepare.sh"),
                "paga-docker-terminal",
                CONTAINER,
            ])
            .output()
            .unwrap();
        assert!(output.stderr.is_empty());
        assert_eq!(
            std::fs::read_dir(self.directory.path().join("tmp"))
                .unwrap()
                .count(),
            0
        );
        output
    }

    fn trace(&self) -> String {
        std::fs::read_to_string(self.directory.path().join("trace")).unwrap()
    }
}

#[test]
fn docker_terminal_preflight_selects_bash_or_sh_without_opening_a_host_shell() {
    for (scenario, shell) in [
        ("bash", "/bin/bash"),
        ("sh_only", "/bin/sh"),
        ("sh_oci", "/bin/sh"),
        ("sh_oci_stdout", "/bin/sh"),
        ("usr_bin_bash", "/usr/bin/bash"),
        ("path_sh", "sh"),
    ] {
        let fixture = TerminalFixture::new(false);
        let output = fixture.prepare(scenario, &[]);
        assert!(output.status.success(), "{scenario}: {:?}", output.status);
        let text = String::from_utf8(output.stdout).unwrap();
        let fields: Vec<_> = text.lines().collect();
        assert_eq!(fields.len(), 5);
        assert_eq!(fields[0], "PAGA_DOCKER_TERMINAL_V1");
        assert_eq!(fields[2], shell);
        assert_eq!(fields[3], "");
        assert_eq!(fields[4], "0");
        assert!(fixture
            .trace()
            .contains(&format!("<exec> <{CONTAINER}> <{shell}> <-c> <:>")));
        assert!(!fixture.trace().contains("<-it>"));
        assert!(!fixture.trace().contains("sudo "));
    }
}

#[test]
fn docker_terminal_preflight_reports_reasons_without_forwarding_private_diagnostics() {
    for (scenario, code, message) in [
        ("stopped", 79, "容器未运行或已移除，请刷新列表"),
        ("missing", 79, "容器未运行或已移除，请刷新列表"),
        ("unavailable", 70, "Docker 未运行"),
        ("no_shell", 80, "容器中未找到可用的 bash 或 sh"),
        ("no_shell_oci_stdout", 80, "容器中未找到可用的 bash 或 sh"),
        ("denied_shell", 77, "没有权限获取 Docker 信息"),
        ("sudo_denied", 77, "没有权限获取 Docker 信息"),
        ("cwd_missing", 75, "容器配置的工作目录不存在，无法启动终端"),
        ("shell_permission", 77, "容器中的 bash 或 sh 没有执行权限"),
        (
            "shell_architecture",
            75,
            "容器中的 bash 或 sh 可执行文件格式错误",
        ),
        ("missing_user", 75, "容器配置的用户不存在，无法启动终端"),
        ("unknown_exec", 75, "Docker 执行容器终端失败（退出码 1）"),
        (
            "unknown_126",
            75,
            "容器内的 bash 或 sh 无法执行（退出码 126）",
        ),
        (
            "unknown_127",
            75,
            "容器内命令未找到，无法启动 bash 或 sh（退出码 127）",
        ),
    ] {
        let fixture = TerminalFixture::new(true);
        let output = fixture.prepare(scenario, &[]);
        assert_eq!(output.status.code(), Some(code), "{scenario}");
        let reason = docker_terminal_preflight_error(code as u32, &output.stdout);
        assert_eq!(reason, message, "{scenario}");
        assert!(!reason.contains("private"));
    }
    let fixture = TerminalFixture::new(false);
    assert_eq!(fixture.prepare("permission", &[]).status.code(), Some(77));
}

#[test]
fn docker_terminal_exec_failures_keep_the_reason_and_hide_unclassified_output() {
    for (code, output, message) in [
        (
            127,
            "",
            "容器内命令未找到，无法启动 bash 或 sh（退出码 127）",
        ),
        (
            127,
            "private runtime failure at /private/host",
            "容器内命令未找到，无法启动 bash 或 sh（退出码 127）",
        ),
        (126, "", "容器内的 bash 或 sh 无法执行（退出码 126）"),
        (
            127,
            "OCI runtime exec failed: exec: \"/bin/sh\": stat /bin/sh: no such file or directory",
            "容器中未找到可用的 bash 或 sh",
        ),
        (
            127,
            "OCI runtime exec failed: chdir to cwd (\"/private/app\"): no such file or directory",
            "容器配置的工作目录不存在，无法启动终端",
        ),
        (
            126,
            "OCI runtime exec failed: exec: \"/bin/sh\": stat /bin/sh: no such file or directory",
            "容器中未找到可用的 bash 或 sh",
        ),
        (
            126,
            "OCI runtime exec failed: exec: \"/bin/sh\": permission denied",
            "容器中的 bash 或 sh 没有执行权限",
        ),
        (
            126,
            "OCI runtime exec failed: exec: \"/bin/sh\": exec format error",
            "容器中的 bash 或 sh 可执行文件格式错误",
        ),
        (
            1,
            "Container private-name is restarting, wait until the container is running",
            "容器正在重启，暂时无法打开终端",
        ),
        (
            1,
            "Container private-name is paused",
            "容器已暂停，请恢复运行后重试",
        ),
        (
            125,
            "private runtime failure at /private/host",
            "Docker 执行容器终端失败（退出码 125）",
        ),
    ] {
        assert_eq!(docker_terminal_exec_error(code, output.as_bytes()), message);
    }
    for output in [
        b"".as_slice(),
        b"PAGA_DOCKER_TERMINAL_FAILURE_V1\n0\nprivate diagnostic",
        b"PAGA_DOCKER_TERMINAL_FAILURE_V1\n999\nprivate diagnostic",
    ] {
        assert_eq!(
            docker_terminal_preflight_error(75, output),
            "Docker 执行容器终端失败（退出码 75）"
        );
    }
}

#[test]
fn docker_terminal_sudo_preserves_same_unix_endpoint_and_never_requests_a_password() {
    for (variables, endpoint) in [
        (vec![], "unix:///var/run/docker.sock"),
        (
            vec![("DOCKER_HOST", "unix:///custom/docker.sock")],
            "unix:///custom/docker.sock",
        ),
        (
            vec![
                ("DOCKER_HOST", "unix:///ignored.sock"),
                ("DOCKER_CONTEXT", "desktop-linux"),
                ("PAGA_TEST_ENDPOINT", "unix:///users/test/docker.sock"),
            ],
            "unix:///users/test/docker.sock",
        ),
    ] {
        let fixture = TerminalFixture::new(true);
        let output = fixture.prepare("permission", &variables);
        assert!(output.status.success());
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(text.ends_with(&format!("{endpoint}\n1\n")));
        let trace = fixture.trace();
        assert!(trace.contains("sudo <-n> <-->"));
        assert!(trace.contains(&format!("<--host> <{endpoint}>")));
    }
    let fixture = TerminalFixture::new(true);
    let output = fixture.prepare("permission", &[("DOCKER_HOST", "tcp://remote:2375")]);
    assert_eq!(output.status.code(), Some(77));
    assert!(!fixture.trace().contains("sudo "));
}

#[test]
fn docker_terminal_launch_uses_interactive_exec_and_preserves_input_for_both_permission_modes() {
    for (scenario, shell) in [
        ("bash", "/bin/bash"),
        ("permission", "/bin/bash"),
        ("usr_bin_bash", "/usr/bin/bash"),
        ("path_sh", "sh"),
    ] {
        let fixture = TerminalFixture::new(true);
        let plan = fixture.prepare(scenario, &[]);
        assert!(plan.status.success());
        let launch = docker_terminal_launch_command(CONTAINER, &plan.stdout).unwrap();
        let mut child = fixture
            .command(scenario, &[])
            .args(["-c", &launch])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let input = "echo 中文\r\x03".as_bytes();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{scenario}: {:?}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(output.stdout, input);
        assert!(output.stderr.is_empty());
        assert!(fixture.trace().contains(&format!(
            "<exec> <-it> <-e> <TERM=xterm-256color> <{CONTAINER}> <{shell}>"
        )));
    }
}

#[test]
fn docker_terminal_rejects_malformed_plans_and_ids_before_launch() {
    for plan in [
        "PAGA_DOCKER_TERMINAL_V1\n/bin/docker\n/bin/sh\n\n0\nextra\n",
        "WRONG\n/bin/docker\n/bin/sh\n\n0\n",
        "PAGA_DOCKER_TERMINAL_V1\n--help\n/bin/sh\n\n0\n",
        "PAGA_DOCKER_TERMINAL_V1\n/bin/docker\n/bin/zsh\n\n0\n",
        "PAGA_DOCKER_TERMINAL_V1\n/bin/docker\nsh;id\n\n0\n",
        "PAGA_DOCKER_TERMINAL_V1\n/bin/docker\n/bin/sh\n\n2\n",
        "PAGA_DOCKER_TERMINAL_V1\n/bin/docker\n/bin/sh\ntcp://localhost:2375\n1\n",
        "PAGA_DOCKER_TERMINAL_V1\n/bin/docker\0\n/bin/sh\n\n0\n",
    ] {
        assert!(docker_terminal_launch_command(CONTAINER, plan.as_bytes()).is_err());
    }
    let valid = b"PAGA_DOCKER_TERMINAL_V1\n/bin/docker\n/bin/sh\n\n0\n";
    for id in ["", "--help", "$(id)", "x'; id", "abc"] {
        assert!(docker_terminal_launch_command(id, valid).is_err());
    }
    assert!(docker_terminal_launch_command(CONTAINER, valid).is_ok());
}
