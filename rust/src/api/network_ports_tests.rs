use std::os::unix::fs::PermissionsExt;
use std::process::Command;

fn executable(dir: &std::path::Path, name: &str, script: &str) {
    let path = dir.join(name);
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn collector_reads_both_families_and_falls_back_when_sudo_is_denied() {
    let dir = tempfile::tempdir().unwrap();
    executable(dir.path(), "uname", "#!/bin/sh\nprintf 'Linux\\n'\n");
    executable(dir.path(), "id", "#!/bin/sh\nprintf '1000\\n'\n");
    executable(
        dir.path(),
        "sudo",
        "#!/bin/sh\necho 'private sudo diagnostic' >&2\nexit 1\n",
    );
    executable(
        dir.path(),
        "ss",
        r#"#!/bin/sh
case " $* " in
  *' -4 '*) printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=42,fd=3))\n';;
  *' -6 '*) printf 'udp UNCONN 0 0 [::]:5353 [::]:*\n';;
  *) exit 1;;
esac
"#,
    );
    let result = Command::new("sh")
        .arg("-c")
        .arg(include_str!("network_ports.sh"))
        .env("PATH", format!("{}:/usr/bin:/bin", dir.path().display()))
        .env("TMPDIR", dir.path())
        .output()
        .unwrap();
    assert!(result.status.success());
    let text = String::from_utf8(result.stdout).unwrap();
    assert!(text.starts_with("PAGA_NETWORK_PORTS_V1\nACCESS LIMITED\nSS4\n"));
    assert!(text.contains("SS6\nudp UNCONN"));
    assert!(text.ends_with("END_PORTS\n"));
    assert!(!text.contains("private"));
    assert!(result.stderr.is_empty());
    assert!(std::fs::read_dir(dir.path()).unwrap().all(|entry| !entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with("paga-ports.")));
}

#[test]
fn macos_lsof_machine_fields_and_empty_udp_are_valid() {
    let dir = tempfile::tempdir().unwrap();
    executable(dir.path(), "uname", "#!/bin/sh\nprintf 'Darwin\\n'\n");
    executable(dir.path(), "id", "#!/bin/sh\nprintf '0\\n'\n");
    executable(
        dir.path(),
        "lsof",
        r#"#!/bin/sh
case " $* " in
  *' -iTCP '*) printf 'p42\ncExample App\nf3\ntIPv6\nPTCP\nn[::1]:8080\nTST=LISTEN\n';;
  *' -iUDP '*) exit 1;;
  *) exit 1;;
esac
"#,
    );
    let result = Command::new("sh")
        .arg("-c")
        .arg(include_str!("network_ports.sh"))
        .env("PATH", format!("{}:/usr/bin:/bin", dir.path().display()))
        .env("TMPDIR", dir.path())
        .output()
        .unwrap();
    assert!(result.status.success());
    let text = String::from_utf8(result.stdout).unwrap();
    assert!(text.starts_with("PAGA_NETWORK_PORTS_V1\nACCESS FULL\nLSOF\n"));
    assert!(text.contains("cExample App\n"));
    assert!(text.ends_with("END_PORTS\n"));
    assert!(result.stderr.is_empty());
}

#[cfg(target_os = "macos")]
#[test]
fn real_macos_lsof_observes_owned_tcp_udp_and_ipv6_sockets() {
    let tcp = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let udp = std::net::UdpSocket::bind(("127.0.0.1", 0)).unwrap();
    let ipv6 = std::net::TcpListener::bind(("::1", 0)).unwrap();
    let dir = tempfile::tempdir().unwrap();
    // Avoid sudo in this local acceptance check; lsof can see sockets owned by this test.
    executable(dir.path(), "id", "#!/bin/sh\nprintf '0\\n'\n");
    let output = Command::new("sh")
        .arg("-c")
        .arg(include_str!("network_ports.sh"))
        .env(
            "PATH",
            format!("{}:/usr/bin:/bin:/usr/sbin", dir.path().display()),
        )
        .output()
        .unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.contains(&format!("n127.0.0.1:{}", tcp.local_addr().unwrap().port())));
    assert!(text.contains(&format!("n127.0.0.1:{}", udp.local_addr().unwrap().port())));
    assert!(text.contains(&format!("n[::1]:{}", ipv6.local_addr().unwrap().port())));
    assert!(text.contains(&format!("p{}\n", std::process::id())));
}
