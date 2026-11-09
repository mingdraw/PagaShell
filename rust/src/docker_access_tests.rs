use super::*;
use std::os::unix::fs::{symlink, PermissionsExt};

#[test]
fn docker_access_probe_preserves_context_and_user_config_during_noninteractive_sudo() {
    for scenario in ["direct", "sudo", "denied", "unavailable"] {
        let directory = tempfile::tempdir().unwrap();
        let bin = directory.path().join("bin");
        let temporary = directory.path().join("tmp");
        std::fs::create_dir(&bin).unwrap();
        std::fs::create_dir(&temporary).unwrap();
        for name in ["uname", "mktemp", "rm", "rmdir", "head", "tr", "cat"] {
            let source = ["/usr/bin", "/bin"]
                .into_iter()
                .map(|base| std::path::Path::new(base).join(name))
                .find(|path| path.is_file())
                .unwrap();
            symlink(source, bin.join(name)).unwrap();
        }
        let docker = r#"#!/bin/sh
if [ "$1" = context ]; then printf 'unix:///fixture/context.sock\n'; exit 0; fi
if [ "$PAGA_ACCESS_SCENARIO" = unavailable ]; then printf 'Cannot connect to the Docker daemon' >&2; exit 1; fi
if [ "$PAGA_ACCESS_SCENARIO" != direct ] && [ "${PAGA_ACCESS_ROOT:-0}" != 1 ]; then printf 'permission denied while connecting to Docker' >&2; exit 1; fi
if [ "${PAGA_ACCESS_ROOT:-0}" = 1 ]; then
  [ -z "$DOCKER_CONTEXT" ] && [ -z "$DOCKER_HOST" ] || exit 98
  [ "$1" = --config ] && [ "$2" = "$DOCKER_CONFIG" ] && [ "$3" = --host ] && [ "$4" = unix:///fixture/context.sock ] || exit 97
  shift 4
fi
[ "$1" = version ] && [ "$2" = --format ] && [ "$3" = '{{.Server.APIVersion}}' ] || exit 96
printf '1.53\n'
"#;
        let sudo = r#"#!/bin/sh
[ "$1" = -n ] && [ "$2" = -- ] || exit 95
[ "$PAGA_ACCESS_SCENARIO" != denied ] || { printf 'sudo: a password is required' >&2; exit 1; }
shift 2
PAGA_ACCESS_ROOT=1
export PAGA_ACCESS_ROOT
exec "$@"
"#;
        for (name, script) in [("docker", docker), ("sudo", sudo)] {
            let path = bin.join(name);
            std::fs::write(&path, script).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let config = directory.path().join("user config");
        let output = std::process::Command::new("/bin/sh")
            .args(["-c", include_str!("api/docker_access.sh")])
            .env("PATH", &bin)
            .env("TMPDIR", &temporary)
            .env("DOCKER_CONFIG", &config)
            .env("DOCKER_CONTEXT", "desktop")
            .env("DOCKER_HOST", "unix:///fixture/ignored.sock")
            .env("PAGA_ACCESS_SCENARIO", scenario)
            .env_remove("PAGA_ACCESS_ROOT")
            .output()
            .unwrap();
        assert!(output.stderr.is_empty());
        assert_eq!(std::fs::read_dir(&temporary).unwrap().count(), 0);
        if matches!(scenario, "denied" | "unavailable") {
            assert_eq!(
                output.status.code(),
                Some(if scenario == "denied" { 77 } else { 70 })
            );
            assert!(output.stdout.is_empty());
        } else {
            assert!(output.status.success());
            let access = Access::parse(&output.stdout).unwrap();
            assert_eq!(access.config, config.to_str().unwrap());
            assert_eq!(access.sudo, scenario == "sudo");
            assert_eq!(access.api, "1.53");
            if scenario == "sudo" {
                assert_eq!(access.endpoint, "unix:///fixture/context.sock");
            }
        }
    }
}
