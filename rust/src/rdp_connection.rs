//! Post-certificate connection stages for RDP desktops.
use std::time::Duration;

use anyhow::{anyhow, Result};
use ironrdp::connector::{
    self, credssp::CredsspSequence, sspi, ClientConnector, ClientConnectorState, ConnectorError,
    ConnectorErrorKind,
};
use ironrdp::core::WriteBuf;
use ironrdp_tokio::{TokioFramed, Upgraded};
use tokio::io::{AsyncRead, AsyncWrite};

const TIMEOUT: Duration = Duration::from_secs(30);
const NLA: &str = "RDP NLA 认证失败";
const SESSION: &str = "RDP 会话初始化失败";

/// The caller must verify certificate consent before supplying credentials here.
pub(crate) async fn finalize<S>(
    upgraded: Upgraded,
    mut connector: ClientConnector,
    framed: &mut TokioFramed<S>,
    host: String,
    public_key: Vec<u8>,
) -> Result<connector::ConnectionResult>
where
    S: Send + Sync + Unpin + AsyncRead + AsyncWrite,
{
    // Drive the public CredSSP sequence separately so a later RDP capability or
    // licensing failure is not incorrectly reported as a password failure.
    if let ClientConnectorState::Credssp {
        selected_protocol, ..
    } = connector.state
    {
        let (sequence, request) = CredsspSequence::init(
            connector.config.credentials.clone(),
            connector.config.domain.as_deref(),
            selected_protocol,
            host.clone().into(),
            public_key,
            None,
        )
        .map_err(|error| connection_error(NLA, error))?;
        tokio::time::timeout(
            TIMEOUT,
            ironrdp_tokio::perform_credssp(
                framed,
                &mut NtlmOnly,
                &mut WriteBuf::new(),
                sequence,
                request,
            ),
        )
        .await
        .map_err(|_| anyhow!("RDP NLA 认证超时"))?
        .map_err(|error| connection_error(NLA, error))?;
        connector.mark_credssp_as_done();
    }

    tokio::time::timeout(
        TIMEOUT,
        ironrdp_tokio::connect_finalize(
            upgraded,
            connector,
            framed,
            &mut NtlmOnly,
            host.into(),
            Vec::new(), // CredSSP is complete; ordinary TLS does not use this key.
            None,
        ),
    )
    .await
    .map_err(|_| anyhow!("RDP 会话初始化超时"))?
    .map_err(|error| connection_error(SESSION, error))
}

// No external HTTP/KDC calls or ambient credentials for password-based NTLM.
struct NtlmOnly;
impl ironrdp_tokio::NetworkClient for NtlmOnly {
    async fn send(
        &mut self,
        _: &sspi::generator::NetworkRequest,
    ) -> connector::ConnectorResult<Vec<u8>> {
        Err(connector::general_err!("RDP 当前仅支持 NLA/NTLM 认证"))
    }
}

fn connection_error(stage: &str, error: ConnectorError) -> anyhow::Error {
    // Never format the upstream error or retain it as an anyhow source: SSPI
    // descriptions and protocol errors may contain credentials or packet data.
    let mut source: Option<&(dyn std::error::Error + 'static)> = Some(&error);
    while let Some(current) = source {
        if let Some(error) = current.downcast_ref::<sspi::Error>() {
            let code = format!(
                "SSPI {:?} / 0x{:08X}",
                error.error_type,
                u32::from(error.error_type)
            );
            if let Some(status) = error.nstatus {
                use sspi::credssp::NStatusCode as Status;
                let reason = match status {
                    Status::WRONG_PASSWORD => "Windows 报告密码不正确",
                    Status::NO_SUCH_USER => "Windows 未找到该账号",
                    Status::INVALID_ACCOUNT_NAME => "Windows 账号名称无效",
                    Status::LOGON_FAILURE => "Windows 拒绝了登录",
                    Status::LOGON_TYPE_NOT_GRANTED | Status::LOGON_NOT_GRANTED => {
                        "账号没有远程桌面登录权限"
                    }
                    Status::PASSWORD_EXPIRED => "Windows 账号密码已过期",
                    Status::PASSWORD_MUST_CHANGE => "Windows 要求先修改账号密码",
                    Status::ACCOUNT_DISABLED => "Windows 账号已禁用",
                    Status::ACCOUNT_LOCKED_OUT => "Windows 账号已锁定",
                    Status::ACCOUNT_RESTRICTION => "Windows 账号受到登录限制",
                    Status::TIME_DIFFERENCE_AT_DC => "客户端与认证服务器时间不同步",
                    Status::NO_LOGON_SERVERS => "Windows 无法联系登录服务器",
                    Status::SMARTCARD_LOGON_REQUIRED => "Windows 要求智能卡登录",
                    _ => "Windows 返回了认证错误",
                };
                return anyhow!(
                    "{stage}：{reason}（{} / 0x{:08X}; {code}）",
                    status.name().unwrap_or("NTSTATUS"),
                    status.0,
                );
            }
            let reason = match error.error_type {
                sspi::ErrorKind::LogonDenied => "Windows 拒绝了登录",
                sspi::ErrorKind::NoCredentials | sspi::ErrorKind::UnknownCredentials => {
                    "登录凭据不可用或格式无效"
                }
                sspi::ErrorKind::UnsupportedFunction | sspi::ErrorKind::OperationNotSupported => {
                    "服务器要求的认证方式暂不支持"
                }
                sspi::ErrorKind::MessageAltered | sspi::ErrorKind::BadBindings => {
                    "认证消息完整性或通道绑定验证失败"
                }
                sspi::ErrorKind::TimeSkew => "客户端与认证服务器时间不同步",
                _ => "认证协议处理失败",
            };
            return anyhow!("{stage}：{reason}（{code}）");
        }
        if let Some(error) = current.downcast_ref::<std::io::Error>() {
            return anyhow!("{stage}：连接读写失败（IO {:?}）", error.kind());
        }
        source = current.source();
    }
    let (reason, code) = match error.kind() {
        ConnectorErrorKind::AccessDenied => ("Windows 拒绝了登录", "AccessDenied"),
        ConnectorErrorKind::Encode(_) => ("RDP 协议数据编码失败", "Encode"),
        ConnectorErrorKind::Decode(_) => ("RDP 协议数据解析失败", "Decode"),
        ConnectorErrorKind::Reason(_) => ("RDP 协议处理失败", "Reason"),
        ConnectorErrorKind::Negotiation(_) => ("RDP 安全协议协商失败", "Negotiation"),
        _ => ("RDP 协议处理失败", "ConnectorError"),
    };
    anyhow!("{stage}：{reason}（{code}）")
}

#[cfg(test)]
mod tests {
    use super::*;
    use ironrdp::core::encode_vec;
    use ironrdp::pdu::nego::{ConnectionConfirm, ResponseFlags, SecurityProtocol};
    use ironrdp::pdu::x224::X224;
    use ironrdp_tokio::FramedWrite;
    use sspi::credssp::NStatusCode;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn peer_errors_report_the_actual_nla_or_tls_session_stage() {
        for protocol in [SecurityProtocol::HYBRID, SecurityProtocol::SSL] {
            tokio::time::timeout(Duration::from_secs(3), async {
                // The stream represents an already reviewed TLS connection.
                let (local, remote) = tokio::io::duplex(16_384);
                let peer = tokio::spawn(async move {
                    let mut framed = TokioFramed::new(remote);
                    framed.read_pdu().await.unwrap();
                    framed
                        .write_all(
                            &encode_vec(&X224(ConnectionConfirm::Response {
                                flags: ResponseFlags::empty(),
                                protocol,
                            }))
                            .unwrap(),
                        )
                        .await
                        .unwrap();
                    let mut remote = framed.into_inner_no_leftover();
                    let mut request = [0; 4096];
                    assert!(remote.read(&mut request).await.unwrap() > 0);
                    if protocol == SecurityProtocol::HYBRID {
                        let mut bytes = Vec::new();
                        sspi::credssp::TsRequest {
                            error_code: Some(NStatusCode::LOGON_FAILURE),
                            ..Default::default()
                        }
                        .encode_ts_request(&mut bytes)
                        .unwrap();
                        remote.write_all(&bytes).await.unwrap();
                    }
                });
                let mut config = crate::rdp::config();
                config.credentials = connector::Credentials::UsernamePassword {
                    username: "user@example.com".into(),
                    password: "secret-password".into(),
                };
                assert!(config.domain.is_none());
                let mut connector = ClientConnector::new(config, "127.0.0.1:0".parse().unwrap());
                let mut framed = TokioFramed::new(local);
                let upgrade = ironrdp_tokio::connect_begin(&mut framed, &mut connector)
                    .await
                    .unwrap();
                let upgraded = ironrdp_tokio::mark_as_upgraded(upgrade, &mut connector);
                let message = finalize(
                    upgraded,
                    connector,
                    &mut framed,
                    "windows.test".into(),
                    vec![1; 32],
                )
                .await
                .err()
                .unwrap()
                .to_string();
                if protocol == SecurityProtocol::HYBRID {
                    assert!(message.starts_with(NLA), "{message}");
                    assert!(message.contains("STATUS_LOGON_FAILURE / 0xC000006D"));
                } else {
                    assert!(message.starts_with(SESSION), "{message}");
                }
                assert!(!message.contains("secret-password"));
                assert!(!message.contains("user@example.com"));
                peer.await.unwrap();
            })
            .await
            .unwrap();
        }
    }

    #[test]
    fn reports_windows_status_without_retaining_sensitive_sspi_descriptions() {
        for (status, reason) in [
            (NStatusCode::LOGON_FAILURE, "Windows 拒绝了登录"),
            (NStatusCode::WRONG_PASSWORD, "Windows 报告密码不正确"),
            (
                NStatusCode::LOGON_TYPE_NOT_GRANTED,
                "账号没有远程桌面登录权限",
            ),
            (NStatusCode::ACCOUNT_LOCKED_OUT, "Windows 账号已锁定"),
            (NStatusCode(0xDEAD_BEEF), "Windows 返回了认证错误"),
        ] {
            let error = ConnectorError::new(
                "secret context",
                ConnectorErrorKind::Credssp(sspi::Error::new_with_nstatus(
                    sspi::ErrorKind::LogonDenied,
                    "secret-password\nuser@example.com",
                    status,
                )),
            );
            let error = connection_error(NLA, error);
            let message = format!("{error:#}");
            assert!(message.starts_with(NLA));
            assert!(message.contains(reason));
            assert!(message.contains(&format!("0x{:08X}", status.0)));
            assert!(!message.contains("secret"));
            assert!(!message.contains("user@example.com"));
            assert!(!message.contains('\n'));
            assert_eq!(error.chain().count(), 1);
        }
    }

    #[test]
    fn separates_protocol_failures_from_authentication_rejection() {
        let error =
            ConnectorError::new("sensitive context", ConnectorErrorKind::Custom).with_source(
                std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "secret-password"),
            );
        let message = connection_error(SESSION, error).to_string();
        assert_eq!(
            message,
            "RDP 会话初始化失败：连接读写失败（IO UnexpectedEof）"
        );
        let error = ConnectorError::new(
            "sensitive context",
            ConnectorErrorKind::Reason("secret-password".into()),
        );
        assert_eq!(
            connection_error(SESSION, error).to_string(),
            "RDP 会话初始化失败：RDP 协议处理失败（Reason）",
        );
    }
}
