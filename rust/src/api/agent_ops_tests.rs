use super::*;
use std::fs;
use std::io::Write;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::process::{Command, Output, Stdio};

use russh::keys::ssh_key::private::{Ed25519Keypair, KeypairData};
use russh::keys::PrivateKey;
use russh::server;
use std::sync::Arc;

use crate::api::ssh::{ssh_authenticate, ssh_disconnect, ssh_handshake};

fn file_op(script: &str, arguments: &[&str], input: &[u8]) -> Output {
    let remote_command = file_command(script, arguments, false);
    if !input.is_empty() {
        assert!(!remote_command.contains(&format!("'{}'", String::from_utf8_lossy(input))));
    }
    let mut child = Command::new("/bin/sh")
        .args(["-c", &remote_command])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _ = child.stdin.take().unwrap().write_all(input);
    child.wait_with_output().unwrap()
}

const READ: &str = include_str!("agent_read_file.sh");
const WRITE: &str = include_str!("agent_write_file.sh");
const RESTORE: &str = include_str!("agent_restore_file.sh");

#[test]
fn preserves_mode_and_refuses_to_overwrite_external_changes() {
    let directory = tempfile::tempdir().unwrap();
    let file = directory.path().join("db config's.conf");
    let path = file.to_str().unwrap();
    let backup = format!("{path}.pagashell.bak.test-1");
    fs::write(&file, b"old\n").unwrap();
    fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).unwrap();
    let before = hash(b"old\n");
    let after = hash(b"new\n");
    let bad_write = file_op(WRITE, &[path, &after, "0", "0", "test-1", &after], b"new\n");
    assert_eq!(bad_write.status.code(), Some(66));
    assert!(!std::path::Path::new(&backup).exists());

    let write = file_op(
        WRITE,
        &[path, &before, "0", "0", "test-1", &after],
        b"new\n",
    );
    assert!(write.status.success(), "{write:?}");
    assert_eq!(fs::read(&file).unwrap(), b"new\n");
    assert_eq!(fs::read(&backup).unwrap(), b"old\n");
    assert_eq!(
        fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o640
    );
    let read = file_op(READ, &[path], &[]);
    assert!(read.status.success(), "{read:?}");
    assert!(read.stdout.ends_with(b"\nnew\n"));

    assert_eq!(
        file_op(RESTORE, &[path, &before, "test-1", &before], &[])
            .status
            .code(),
        Some(66)
    );
    let restore = file_op(RESTORE, &[path, &after, "test-1", &before], &[]);
    assert!(restore.status.success(), "{restore:?}");
    assert_eq!(fs::read(&file).unwrap(), b"old\n");
}

#[test]
fn creation_requires_complete_stdin_and_does_not_overwrite_an_existing_file() {
    let directory = tempfile::tempdir().unwrap();
    let file = directory.path().join("new/nested/service.conf");
    let path = file.to_str().unwrap();
    let digest = hash(b"feature=on\n");
    let args = [path, "", "1", "1", "new", &digest];
    assert_eq!(file_op(READ, &[path], &[]).status.code(), Some(67));
    assert_eq!(file_op(WRITE, &args, b"feature").status.code(), Some(66));
    assert!(!file.exists());
    let create = file_op(WRITE, &args, b"feature=on\n");
    assert!(create.status.success(), "{create:?}");
    assert_eq!(
        file_op(WRITE, &args, b"feature=on\n").status.code(),
        Some(68)
    );
    assert!(file_op(RESTORE, &[path, &digest, "", ""], &[])
        .status
        .success());
    assert!(!file.exists());
}

#[test]
fn rejects_sensitive_files_and_symbolic_links() {
    let directory = tempfile::tempdir().unwrap();
    let secret = directory.path().join(".ssh");
    fs::create_dir(&secret).unwrap();
    fs::write(secret.join("custom"), "credential").unwrap();
    let link = directory.path().join("public-dir");
    symlink(&secret, &link).unwrap();
    assert_eq!(
        file_op(READ, &[link.join("custom").to_str().unwrap()], &[])
            .status
            .code(),
        Some(76)
    );
    let final_link = directory.path().join("not-a-config");
    symlink(secret.join("custom"), &final_link).unwrap();
    assert_eq!(
        file_op(READ, &[final_link.to_str().unwrap()], &[])
            .status
            .code(),
        Some(78)
    );
    for path in [
        "/etc/../etc/shadow",
        "/etc/shadow",
        "/home/me/.ssh/key",
        "/etc/cert.pem",
    ] {
        assert!(validate_path(path).is_err());
    }
    for bytes in [
        b"-----BEGIN OPENSSH PRIVATE KEY-----".as_slice(),
        b"-----begin rsa private key-----",
        b"requirepass example",
        b"password = example",
        b"DB_PASSWORD=secret",
        b"\"Api_Key\": \"abc\"",
        b"auth_token: xyz",
    ] {
        assert!(validate_text(bytes).is_err());
    }
    for bytes in [
        b"# password = ignored comment\ninnodb_buffer_pool_size = 4G\n".as_slice(),
        b"; requirepass commented\nmax_connections = 500\n",
        b"password =\n",
    ] {
        assert!(validate_text(bytes).is_ok());
    }
}

#[test]
fn local_profile_returns_versioned_section_fields() {
    let profile = Command::new("/bin/sh")
        .args(["-c", include_str!("agent_profile.sh")])
        .output()
        .unwrap();
    assert!(profile.status.success(), "{profile:?}");
    let output = String::from_utf8(profile.stdout).unwrap();
    assert!(output.lines().any(|line| line.starts_with("system=")));
    assert!(output.lines().any(|line| line.starts_with("privilege=")));
}

#[tokio::test]
async fn cancellation_is_scoped_and_registration_is_released() {
    let (guard, token) = ExecRegistration::register(333, 222).unwrap();
    let (_other, other) = ExecRegistration::register(334, 223).unwrap();
    let (_file, file) = ExecRegistration::register_operation(333, OperationId::File(222)).unwrap();
    ssh_exec_cancel(334, 222).await;
    assert!(!token.is_cancelled());
    close_session(333);
    assert!(token.is_cancelled());
    assert!(file.is_cancelled());
    assert!(!other.is_cancelled());
    drop(guard);
    assert!(ExecRegistration::register(333, 222).is_ok());
}

#[test]
fn utf8_packets_join_without_corrupting_multibyte_output() {
    let mut decoder = Utf8Chunks(Vec::new());
    let text = "你好".as_bytes();
    assert_eq!(decoder.push(&text[..1]), "");
    assert_eq!(decoder.push(&text[1..4]), "你");
    assert_eq!(decoder.push(&text[4..]), "好");
    assert_eq!(decoder.push(&[255, b'!']), "�!");
}

struct LoopbackExec {
    channels: HashMap<russh::ChannelId, (bool, Vec<u8>)>,
    ready: tokio::sync::mpsc::UnboundedSender<()>,
}

impl server::Handler for LoopbackExec {
    type Error = russh::Error;

    async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
        Ok(server::Auth::Accept)
    }

    async fn channel_open_session(
        &mut self,
        _: russh::Channel<server::Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel: russh::ChannelId,
        command: &[u8],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.channels
            .insert(channel, (command == b"fixture", Vec::new()));
        session.channel_success(channel)?;
        Ok(())
    }

    async fn data(
        &mut self,
        channel: russh::ChannelId,
        data: &[u8],
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.channels
            .get_mut(&channel)
            .unwrap()
            .1
            .extend_from_slice(data);
        Ok(())
    }

    async fn channel_eof(
        &mut self,
        channel: russh::ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        let (reply, input) = self.channels.remove(&channel).unwrap();
        if reply {
            session.data(channel, input)?;
            session.extended_data(channel, 1, b"fixture stderr".to_vec())?;
            session.exit_status_request(channel, 7)?;
            session.eof(channel)?;
            session.close(channel)?;
        } else {
            let _ = self.ready.send(());
        }
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
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        panic!("Agent exec must not allocate a terminal");
    }
}

#[tokio::test]
async fn ssh_exec_delivers_stdin_streams_and_exit_and_cancels_only_its_channel() {
    let (ready, mut started) = tokio::sync::mpsc::unbounded_channel();
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let config = Arc::new(server::Config {
            keys: vec![PrivateKey::new(
                KeypairData::Ed25519(Ed25519Keypair::from_seed(&[84; 32])),
                "loopback fixture",
            )
            .unwrap()],
            ..Default::default()
        });
        let (socket, _) = listener.accept().await.unwrap();
        let channel = server::run_stream(
            config,
            socket,
            LoopbackExec {
                channels: HashMap::new(),
                ready,
            },
        )
        .await
        .unwrap();
        let _ = channel.await;
    });
    let handshake = ssh_handshake("127.0.0.1".into(), port).await.unwrap();
    let session = ssh_authenticate(
        handshake.session_id,
        handshake.fingerprint,
        "fixture".into(),
        "fixture".into(),
    )
    .await
    .unwrap();
    let (registered, token) = ExecRegistration::register(session, 456).unwrap();
    let hanging = tokio::spawn(async move {
        run_channel(
            session,
            "fixture waits".into(),
            &[],
            Duration::from_secs(8),
            &token,
            |_, _| true,
        )
        .await
    });
    timeout(Duration::from_secs(2), started.recv())
        .await
        .unwrap()
        .unwrap();
    ssh_exec_cancel(session, 456).await;
    assert!(matches!(
        timeout(Duration::from_secs(2), hanging)
            .await
            .unwrap()
            .unwrap(),
        ChannelExit::Cancelled
    ));
    drop(registered);

    // A second SSH channel on the same authenticated connection still works.
    let mut output = [Vec::new(), Vec::new()];
    let result = run_channel(
        session,
        "fixture".into(),
        "测试 stdin\n".as_bytes(),
        Duration::from_secs(2),
        &CancellationToken::new(),
        |stderr, bytes| {
            output[usize::from(stderr)].extend_from_slice(bytes);
            true
        },
    )
    .await;
    assert!(matches!(result, ChannelExit::Status(7)));
    assert_eq!(output[0], "测试 stdin\n".as_bytes());
    assert_eq!(output[1], b"fixture stderr");

    let timeout_result = run_channel(
        session,
        "fixture waits".into(),
        &[],
        Duration::from_millis(100),
        &CancellationToken::new(),
        |_, _| true,
    )
    .await;
    assert!(matches!(timeout_result, ChannelExit::Timeout));
    ssh_disconnect(session).await.unwrap();
    server.abort();
}
