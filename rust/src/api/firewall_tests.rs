use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::Path;
use std::process::{Command, Output};

use super::*;

struct Fixture {
    dir: tempfile::TempDir,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        std::fs::create_dir(dir.path().join("tmp")).unwrap();
        for name in [
            "awk", "cat", "cp", "grep", "head", "mktemp", "rm", "rmdir", "sed", "tr",
        ] {
            let source = ["/usr/bin", "/bin"]
                .into_iter()
                .map(|base| Path::new(base).join(name))
                .find(|p| p.is_file())
                .unwrap_or_else(|| panic!("missing system binary {name}"));
            symlink(source, bin.join(name)).unwrap();
        }
        Self { dir }
    }

    fn install(&self, name: &str, script: &str) {
        let path = self.dir.path().join("bin").join(name);
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    fn linux_root(&self) {
        self.install("uname", "#!/bin/sh\nprintf 'Linux\\n'\n");
        self.install("id", "#!/bin/sh\nprintf '0\\n'\n");
    }

    fn run_script(&self, script: &str, args: &[&str]) -> Output {
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(script)
            .arg("paga-fw-test")
            .args(args)
            .env("PATH", self.dir.path().join("bin"))
            .env("TMPDIR", self.dir.path().join("tmp"))
            .env("PAGA_FW_TRACE", self.dir.path().join("trace"));
        command.output().unwrap()
    }

    fn trace(&self) -> String {
        std::fs::read_to_string(self.dir.path().join("trace")).unwrap_or_default()
    }

    fn assert_clean(&self) {
        assert_eq!(
            std::fs::read_dir(self.dir.path().join("tmp"))
                .unwrap()
                .count(),
            0
        );
    }
}

#[test]
fn validates_ports_sources_comments_and_raw_tokens() {
    assert_eq!(validate_port("80").unwrap(), "80");
    assert_eq!(validate_port("00443").unwrap(), "443");
    assert_eq!(validate_port("8080-8089").unwrap(), "8080-8089");
    for bad in [
        "", "0", "65536", "80-80", "90-80", "80,443", "80;id", "-80", "0-10",
    ] {
        assert!(validate_port(bad).is_err(), "should reject port {bad}");
    }

    assert_eq!(validate_source("").unwrap(), (String::new(), "any"));
    assert_eq!(
        validate_source("172.16.10.11").unwrap(),
        ("172.16.10.11".into(), "ipv4")
    );
    assert_eq!(
        validate_source("172.16.0.0/24").unwrap(),
        ("172.16.0.0/24".into(), "ipv4")
    );
    assert_eq!(
        validate_source("2001:db8::1").unwrap(),
        ("2001:db8::1".into(), "ipv6")
    );
    assert_eq!(
        validate_source("2001:db8::/64").unwrap(),
        ("2001:db8::/64".into(), "ipv6")
    );
    for bad in [
        "172.16.0.0/33",
        "2001:db8::/129",
        "not-an-ip",
        "1.2.3.4;id",
        "1.2.3.4/-1",
    ] {
        assert!(validate_source(bad).is_err(), "should reject source {bad}");
    }

    assert_eq!(validate_comment("Web 服务 443").unwrap(), "Web 服务 443");
    for bad in ["bad\"quote", "bad'quote", "bad;cmd", "bad$(id)", "line\n2"] {
        assert!(
            validate_comment(bad).is_err(),
            "should reject comment {bad}"
        );
    }
    assert!(validate_comment(&"a".repeat(129)).is_err());

    assert!(validate_existing_raw(FirewallBackendKind::Firewalld, "port:80/tcp").is_ok());
    assert!(validate_existing_raw(
        FirewallBackendKind::Firewalld,
        "rich:rule family=\"ipv4\" port port=\"443\" protocol=\"tcp\" accept"
    )
    .is_ok());
    assert!(validate_existing_raw(FirewallBackendKind::Firewalld, "port:80/icmp").is_err());
    assert!(
        validate_existing_raw(FirewallBackendKind::Ufw, "ufw:1:22/tcp ALLOW IN Anywhere").is_ok()
    );
    assert!(validate_existing_raw(FirewallBackendKind::Ufw, "ufw:0:bad").is_err());
    assert!(
        validate_existing_raw(FirewallBackendKind::Nftables, "nft:inet|filter|input|7").is_ok()
    );
    assert!(
        validate_existing_raw(FirewallBackendKind::Nftables, "nft:inet|bad;name|input|7").is_err()
    );
    assert!(validate_existing_raw(
        FirewallBackendKind::Iptables,
        "iptables:v4:3:-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT"
    )
    .is_ok());
    assert!(
        validate_existing_raw(FirewallBackendKind::Iptables, "iptables:v4:3:-D INPUT 1").is_err()
    );
    assert!(firewall_service_command(
        FirewallBackendKind::Iptables,
        FirewallServiceActionKind::Disable
    )
    .is_err());
}

#[test]
fn rejects_macos_and_missing_firewall_and_denied_sudo() {
    let mac = Fixture::new();
    mac.install("uname", "#!/bin/sh\nprintf 'Darwin\\n'\n");
    mac.install("id", "#!/bin/sh\nprintf '0\\n'\n");
    let out = mac.run_script(include_str!("firewall_read.sh"), &[""]);
    assert_eq!(out.status.code(), Some(64));

    let none = Fixture::new();
    none.linux_root();
    let out = none.run_script(include_str!("firewall_read.sh"), &[""]);
    assert_eq!(out.status.code(), Some(69));
    none.assert_clean();

    let denied = Fixture::new();
    denied.install("uname", "#!/bin/sh\nprintf 'Linux\\n'\n");
    denied.install("id", "#!/bin/sh\nprintf '1000\\n'\n");
    denied.install(
        "sudo",
        "#!/bin/sh\nprintf 'sudo: a password is required\\n' >&2\nexit 1\n",
    );
    denied.install("ufw", "#!/bin/sh\nexit 0\n");
    let out = denied.run_script(include_str!("firewall_read.sh"), &[""]);
    assert_eq!(out.status.code(), Some(77));
    assert!(out.stdout.is_empty());
    assert!(out.stderr.is_empty());
    denied.assert_clean();
}

#[test]
fn reads_and_mutates_firewalld_rules_with_reload() {
    let fixture = Fixture::new();
    fixture.linux_root();
    fixture.install(
        "firewall-cmd",
        r#"#!/bin/sh
printf 'firewall-cmd' >> "$PAGA_FW_TRACE"
printf ' <%s>' "$@" >> "$PAGA_FW_TRACE"
printf '\n' >> "$PAGA_FW_TRACE"
case "$*" in
  '--version') printf '2.4.3\n' ;;
  '--state') printf 'running\n' ;;
  '--get-default-zone') printf 'public\n' ;;
  *'--list-ports') printf '10458/tcp 8080-8089/udp\n' ;;
  *'--list-rich-rules') printf 'rule family="ipv4" port port="443" protocol="tcp" accept\n' ;;
  *'--query-port=10458/tcp') exit 0 ;;
  *'--query-rich-rule=rule family="ipv4" port port="443" protocol="tcp" accept') exit 0 ;;
  *'--query-'*) exit 1 ;;
  *) exit 0 ;;
esac
"#,
    );
    fixture.install(
        "ss",
        r#"#!/bin/sh
case " $* " in
  *' -4 '*) printf 'tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("openresty",pid=88,fd=6))\n' ;;
  *' -6 '*) printf 'tcp LISTEN 0 128 [::]:10458 [::]:* users:(("1panel-core",pid=99,fd=7))\n' ;;
esac
"#,
    );

    let read = fixture.run_script(include_str!("firewall_read.sh"), &[""]);
    assert!(read.status.success(), "{:?}", read.status);
    let text = String::from_utf8(read.stdout).unwrap();
    assert!(text.starts_with("PAGA_FIREWALL_V1\nBACKEND firewalld\n"));
    assert!(text.contains("STATE active\nVERSION 2.4.3\nZONE public\n"));
    assert!(text.contains("SERVICE_ACTIONS disable,reload\n"));
    assert!(text.contains("10458/tcp 8080-8089/udp\n"));
    assert!(text.contains("openresty"));
    assert!(text.ends_with("END_FIREWALL\n"));
    fixture.assert_clean();

    // Add both simple port rule and rich rule in one batch -> single reload.
    let add = fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &[
            "add",
            "firewalld",
            "2",
            "allow",
            "tcp",
            "80",
            "",
            "any",
            "",
            "",
            "deny",
            "udp",
            "3478",
            "10.0.0.0/8",
            "ipv4",
            "-10",
            "",
        ],
    );
    assert!(add.status.success(), "{:?}", add.status);
    let trace = fixture.trace();
    assert!(trace.contains("<--permanent> <--zone=public> <--add-port=80/tcp>"));
    assert!(trace.contains(
        r#"<--permanent> <--zone=public> <--add-rich-rule=rule priority="-10" family="ipv4" source address="10.0.0.0/8" port port="3478" protocol="udp" drop>"#
    ));
    assert_eq!(trace.matches("<--reload>").count(), 1);
    fixture.assert_clean();

    // Delete missing rule returns conflict exit 78.
    let stale = fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &["delete", "firewalld", "port:9999/tcp"],
    );
    assert_eq!(stale.status.code(), Some(78));
    fixture.assert_clean();
}

#[test]
fn reads_and_safely_deletes_shifted_ufw_rule() {
    let fixture = Fixture::new();
    fixture.linux_root();
    fixture.install(
        "ufw",
        r#"#!/bin/sh
printf 'ufw' >> "$PAGA_FW_TRACE"
printf ' <%s>' "$@" >> "$PAGA_FW_TRACE"
printf '\n' >> "$PAGA_FW_TRACE"
case "$*" in
  'version') printf 'ufw 0.36.2\n' ;;
  'status') printf 'Status: active\n' ;;
  'status numbered')
    printf 'Status: active\n\n     To                         Action      From\n     --                         ------      ----\n'
    printf '[ 1] 22/tcp                     ALLOW IN    Anywhere                   # ssh\n'
    printf '[ 2] 8080:8089/udp              DENY IN     192.168.1.0/24             # block test\n'
    ;;
  *) exit 0 ;;
esac
"#,
    );

    let read = fixture.run_script(include_str!("firewall_read.sh"), &[""]);
    assert!(read.status.success());
    let text = String::from_utf8(read.stdout).unwrap();
    assert!(text.contains("BACKEND ufw\nAVAILABLE ufw\nSTATE active\nVERSION 0.36.2\n"));
    assert!(text.contains("[ 2] 8080:8089/udp"));

    // Expected index was 3, but rule shifted to 2 -> script verifies exact body and deletes 2.
    let del = fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &[
            "delete",
            "ufw",
            "ufw:3:8080:8089/udp              DENY IN     192.168.1.0/24             # block test",
        ],
    );
    assert!(del.status.success(), "{:?}", del.status);
    assert!(fixture.trace().contains("ufw <--force> <delete> <2>"));

    // Add rule with range + source + comment.
    let add = fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &[
            "add",
            "ufw",
            "1",
            "allow",
            "tcpudp",
            "9000-9005",
            "192.168.1.0/24",
            "ipv4",
            "",
            "app range",
        ],
    );
    assert!(add.status.success());
    let trace = fixture.trace();
    assert!(trace.contains(
        "ufw <allow> <in> <proto> <tcp> <from> <192.168.1.0/24> <to> <any> <port> <9000:9005> <comment> <app range>"
    ));
    assert!(trace.contains(
        "ufw <allow> <in> <proto> <udp> <from> <192.168.1.0/24> <to> <any> <port> <9000:9005> <comment> <app range>"
    ));
    fixture.assert_clean();
}

#[test]
fn reads_adds_before_catchall_and_deletes_nftables_rules() {
    let fixture = Fixture::new();
    fixture.linux_root();
    fixture.install(
        "nft",
        r#"#!/bin/sh
printf 'nft' >> "$PAGA_FW_TRACE"
printf ' <%s>' "$@" >> "$PAGA_FW_TRACE"
printf '\n' >> "$PAGA_FW_TRACE"
case "$*" in
  '--version') printf 'nftables v1.0.9 (Old Doc Yak #3)\n' ;;
  'list tables') printf 'table inet filter\n' ;;
  '-a list ruleset')
    cat <<'EOF'
table inet filter { # handle 1
	chain input { # handle 1
		type filter hook input priority filter; policy accept;
		tcp dport 22 accept # handle 5
		drop # handle 9
	}
}
EOF
    ;;
  '-a list chain inet filter input')
    cat <<'EOF'
	chain input { # handle 1
		type filter hook input priority filter; policy accept;
		tcp dport 22 accept # handle 5
		drop # handle 9
	}
EOF
    ;;
  *) exit 0 ;;
esac
"#,
    );

    let read = fixture.run_script(include_str!("firewall_read.sh"), &[""]);
    assert!(read.status.success());
    let text = String::from_utf8(read.stdout).unwrap();
    assert!(text.contains("BACKEND nftables\nAVAILABLE nftables\nSTATE active\nVERSION 1.0.9\n"));

    let add = fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &[
            "add",
            "nftables",
            "1",
            "allow",
            "tcp",
            "443",
            "2001:db8::/64",
            "ipv6",
            "",
            "web tls",
        ],
    );
    assert!(add.status.success(), "{:?}", add.status);
    let trace = fixture.trace();
    assert!(trace.contains(
        r#"nft <insert> <rule> <inet> <filter> <input> <position> <9> <ip6> <saddr> <2001:db8::/64> <tcp> <dport> <443> <accept> <comment> <"web tls">"#
    ));

    let del = fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &["delete", "nftables", "nft:inet|filter|input|5"],
    );
    assert!(del.status.success());
    assert!(fixture
        .trace()
        .contains("nft <delete> <rule> <inet> <filter> <input> <handle> <5>"));
    fixture.assert_clean();
}

#[test]
fn reads_adds_and_deletes_iptables_and_ip6tables_rules() {
    let fixture = Fixture::new();
    fixture.linux_root();
    fixture.install(
        "iptables",
        r#"#!/bin/sh
printf 'iptables' >> "$PAGA_FW_TRACE"
printf ' <%s>' "$@" >> "$PAGA_FW_TRACE"
printf '\n' >> "$PAGA_FW_TRACE"
case "$*" in
  '--version') printf 'iptables v1.8.9 (nf_tables)\n' ;;
  '-w 5 -S INPUT')
    printf '%s\n' '-P INPUT DROP'
    printf '%s\n' '-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT'
    printf '%s\n' '-A INPUT -j DROP'
    ;;
  '-w 5 -C INPUT'*) exit 1 ;;
  *) exit 0 ;;
esac
"#,
    );
    fixture.install(
        "ip6tables",
        r#"#!/bin/sh
printf 'ip6tables' >> "$PAGA_FW_TRACE"
printf ' <%s>' "$@" >> "$PAGA_FW_TRACE"
printf '\n' >> "$PAGA_FW_TRACE"
case "$*" in
  '-w 5 -S INPUT')
    printf '%s\n' '-P INPUT ACCEPT'
    ;;
  '-w 5 -C INPUT'*) exit 1 ;;
  *) exit 0 ;;
esac
"#,
    );

    let read = fixture.run_script(include_str!("firewall_read.sh"), &[""]);
    assert!(read.status.success());
    let text = String::from_utf8(read.stdout).unwrap();
    assert!(text.contains("BACKEND iptables\nAVAILABLE iptables\nSTATE active\nVERSION 1.8.9 (nf_tables)\nZONE \nPOLICY DROP\n"));

    // Add for any source -> inserts before catch-all DROP in v4 and appends in v6.
    let add = fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &[
            "add",
            "iptables",
            "1",
            "allow",
            "tcp",
            "8080-8089",
            "",
            "any",
            "",
            "app pool",
        ],
    );
    assert!(add.status.success(), "{:?}", add.status);
    let trace = fixture.trace();
    assert!(trace.contains(
        "iptables <-w> <5> <-I> <INPUT> <2> <-p> <tcp> <-m> <tcp> <--dport> <8080:8089> <-m> <comment> <--comment> <app pool> <-j> <ACCEPT>"
    ));
    assert!(trace.contains(
        "ip6tables <-w> <5> <-A> <INPUT> <-p> <tcp> <-m> <tcp> <--dport> <8080:8089> <-m> <comment> <--comment> <app pool> <-j> <ACCEPT>"
    ));

    let del = fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &[
            "delete",
            "iptables",
            "iptables:v4:1:-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT",
        ],
    );
    assert!(del.status.success());
    assert!(fixture
        .trace()
        .contains("iptables <-w> <5> <-D> <INPUT> <1>"));
    fixture.assert_clean();
}

#[test]
fn service_actions_run_expected_commands() {
    let fixture = Fixture::new();
    fixture.linux_root();
    fixture.install(
        "firewall-cmd",
        "#!/bin/sh\nprintf 'firewall-cmd %s\\n' \"$*\" >> \"$PAGA_FW_TRACE\"\n",
    );
    fixture.install(
        "systemctl",
        "#!/bin/sh\nprintf 'systemctl %s\\n' \"$*\" >> \"$PAGA_FW_TRACE\"\n",
    );
    fixture.install(
        "ufw",
        "#!/bin/sh\nprintf 'ufw %s\\n' \"$*\" >> \"$PAGA_FW_TRACE\"\n",
    );

    assert!(fixture
        .run_script(
            include_str!("firewall_service.sh"),
            &["firewalld", "enable"]
        )
        .status
        .success());
    assert!(fixture
        .run_script(
            include_str!("firewall_service.sh"),
            &["firewalld", "reload"]
        )
        .status
        .success());
    assert!(fixture
        .run_script(include_str!("firewall_service.sh"), &["ufw", "disable"])
        .status
        .success());
    let trace = fixture.trace();
    assert!(trace.contains("systemctl start firewalld"));
    assert!(trace.contains("firewall-cmd --reload"));
    assert!(trace.contains("ufw --force disable"));
    fixture.assert_clean();
}

#[test]
fn nftables_delete_rejects_stale_handle() {
    let nft_fixture = Fixture::new();
    nft_fixture.linux_root();
    nft_fixture.install(
        "nft",
        r#"#!/bin/sh
printf 'nft' >> "$PAGA_FW_TRACE"
printf ' <%s>' "$@" >> "$PAGA_FW_TRACE"
printf '\n' >> "$PAGA_FW_TRACE"
case "$*" in
  '-a list ruleset'|'-a list chain inet filter input')
    printf 'table inet filter {\n\tchain input {\n\t\ttype filter hook input priority 0; policy accept;\n\t\ttcp dport 22 accept # handle 5\n\t}\n}\n'
    ;;
  *) exit 0 ;;
esac
"#,
    );
    let stale_delete = nft_fixture.run_script(
        include_str!("firewall_mutate.sh"),
        &["delete", "nftables", "nft:inet|filter|input|999"],
    );
    assert_eq!(stale_delete.status.code(), Some(78));
    assert!(!nft_fixture.trace().contains("delete> <rule"));
    nft_fixture.assert_clean();
}
