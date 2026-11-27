//! A reliable sideband for direct RDP. Its TLS identity is the exact
//! certificate already reviewed for the authenticated primary connection.
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use ironrdp::connector::MultitransportResult;
use ironrdp::core::{decode, encode_vec};
use ironrdp::pdu::gcc::MultiTransportFlags;
use ironrdp::pdu::rdp::autodetect::{
    AutoDetectReqPdu, AutoDetectRequest, AutoDetectResponse, AutoDetectRspPdu,
    BW_RESULTS_CONTINUOUS, BW_START_RELIABLE_UDP, BW_STOP_RELIABLE_UDP,
};
use ironrdp::pdu::rdp::multitransport::{
    MultitransportRequestPdu, MultitransportResponsePdu, RequestedProtocol,
};
use ironrdp_rdpemt::{SubHeaderType, TunnelSubHeader};
use ironrdp_rdpeudp_tokio::{
    MultitransportBootstrap, TunnelMessage, UdpTlsConfig, UdpTransport, UdpTransportStats,
};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, Error, SignatureScheme};
use tokio_rustls::rustls;

const UDP_TIMEOUT: Duration = Duration::from_secs(3);

pub(crate) fn advertised_flags() -> MultiTransportFlags {
    MultiTransportFlags::TRANSPORT_TYPE_UDP_FECR | MultiTransportFlags::SOFT_SYNC_TCP_TO_UDP
}

struct Candidate {
    peer: SocketAddr,
    host: String,
    tls: UdpTlsConfig,
}

#[derive(Default)]
pub(crate) struct Sideband {
    candidate: Option<Candidate>,
    pub transport: Option<UdpTransport>,
    bw_window: Option<(std::time::Instant, u32)>,
}

impl Sideband {
    pub fn direct(
        peer: SocketAddr,
        host: String,
        certificate: CertificateDer<'static>,
    ) -> Result<Self> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let verifier = Arc::new(PinnedPeer {
            provider: provider.clone(),
            certificate,
        });
        let mut config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            .dangerous()
            .with_custom_certificate_verifier(verifier)
            .with_no_client_auth();
        config.resumption = rustls::client::Resumption::disabled();
        let mut tls = UdpTlsConfig::new(peer.to_string());
        tls.client_config = Some(config);
        Ok(Self {
            candidate: Some(Candidate { peer, host, tls }),
            transport: None,
            bw_window: None,
        })
    }

    pub async fn connect(
        &mut self,
        request: MultitransportRequestPdu,
        soft_sync: bool,
    ) -> MultitransportResult {
        let abort = MultitransportResult::Failure(MultitransportResponsePdu::E_ABORT);
        if !soft_sync || request.requested_protocol != RequestedProtocol::UdpFecR {
            return abort;
        }
        // At most one reliable attempt per primary connection. Duplicate
        // requests must not replace a tunnel on which channels already run.
        let Some(config) = self.candidate.take() else {
            return abort;
        };
        let mut bootstrap = MultitransportBootstrap::new(request);
        if let Ok(Ok(())) = tokio::time::timeout(
            UDP_TIMEOUT,
            bootstrap.connect(config.peer, config.host, Default::default(), config.tls),
        )
        .await
        {
            self.transport = bootstrap.take_transport();
            if self.transport.is_some() {
                return MultitransportResult::Success;
            }
        }
        tracing::debug!("RDP reliable UDP unavailable; continuing on TCP");
        abort
    }

    pub async fn recv(&mut self) -> Option<TunnelMessage> {
        match self.transport.as_mut() {
            Some(transport) => transport.recv_message().await,
            None => std::future::pending().await,
        }
    }

    pub fn stats(&self) -> Option<UdpTransportStats> {
        self.transport.as_ref().map(UdpTransport::stats)
    }

    /// Processes MS-RDPEMT continuous Auto-Detect sub-headers riding on a reliable
    /// UDP Tunnel Data PDU, answering RTT and bandwidth probes and returning any
    /// server-reported network characteristics `(base_rtt_ms, avg_rtt_ms, bw_kbps)`.
    pub async fn handle_autodetect_subheaders(
        &mut self,
        payload_len: usize,
        sub_headers: &[TunnelSubHeader],
    ) -> Vec<(Option<u32>, u32, Option<u32>)> {
        if let Some((_, bytes)) = self.bw_window.as_mut() {
            *bytes = bytes.saturating_add(u32::try_from(payload_len).unwrap_or(u32::MAX));
        }
        let mut characteristics = Vec::new();
        let mut responses = Vec::new();
        let now = std::time::Instant::now();
        for header in sub_headers {
            if header.sub_header_type != SubHeaderType::AutoDetectRequest {
                continue;
            }
            let Ok(req) = decode::<AutoDetectReqPdu>(&header.data) else {
                continue;
            };
            match req.request {
                AutoDetectRequest::RttRequest {
                    sequence_number, ..
                } => {
                    responses.push(AutoDetectResponse::RttResponse { sequence_number });
                }
                AutoDetectRequest::BandwidthMeasureStart {
                    request_type: BW_START_RELIABLE_UDP,
                    ..
                } => {
                    self.bw_window = Some((now, 0));
                }
                AutoDetectRequest::BandwidthMeasureStop {
                    sequence_number,
                    request_type: BW_STOP_RELIABLE_UDP,
                    ..
                } => {
                    let (time_delta_ms, byte_count) = match self.bw_window.take() {
                        Some((started, bytes)) => (
                            u32::try_from(now.saturating_duration_since(started).as_millis())
                                .unwrap_or(u32::MAX)
                                .max(1),
                            bytes,
                        ),
                        None => (1, 0),
                    };
                    responses.push(AutoDetectResponse::BandwidthMeasureResults {
                        sequence_number,
                        response_type: BW_RESULTS_CONTINUOUS,
                        time_delta_ms,
                        byte_count,
                    });
                }
                AutoDetectRequest::NetworkCharacteristicsResult {
                    base_rtt_ms,
                    bandwidth_kbps,
                    average_rtt_ms,
                    ..
                } => {
                    characteristics.push((base_rtt_ms, average_rtt_ms, bandwidth_kbps));
                }
                _ => {}
            }
        }
        if !responses.is_empty() {
            if let Some(transport) = self.transport.as_ref() {
                for response in responses {
                    if let Ok(encoded) = encode_vec(&AutoDetectRspPdu::new(response)) {
                        let _ = transport
                            .send_message(TunnelMessage {
                                sub_headers: vec![TunnelSubHeader {
                                    sub_header_type: SubHeaderType::AutoDetectResponse,
                                    data: encoded,
                                }],
                                data: Vec::new(),
                            })
                            .await;
                    }
                }
            }
        }
        characteristics
    }
}

#[derive(Debug)]
struct PinnedPeer {
    provider: Arc<rustls::crypto::CryptoProvider>,
    certificate: CertificateDer<'static>,
}

impl ServerCertVerifier for PinnedPeer {
    fn verify_server_cert(
        &self,
        certificate: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> std::result::Result<ServerCertVerified, Error> {
        if certificate.as_ref() == self.certificate.as_ref() {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(Error::InvalidCertificate(
                rustls::CertificateError::ApplicationVerificationFailure,
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server_config(leaf: &rcgen::CertifiedKey<rcgen::KeyPair>) -> Arc<rustls::ServerConfig> {
        Arc::new(
            rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![leaf.cert.der().clone()],
                rustls::pki_types::PrivatePkcs8KeyDer::from(leaf.signing_key.serialize_der())
                    .into(),
            )
            .unwrap(),
        )
    }

    #[tokio::test]
    async fn sideband_tls_accepts_only_the_reviewed_leaf() {
        let approved = rcgen::generate_simple_self_signed(["localhost".to_owned()]).unwrap();
        let different = rcgen::generate_simple_self_signed(["localhost".to_owned()]).unwrap();
        let peer = "127.0.0.1:3389".parse().unwrap();
        for (leaf, accepted) in [(&different, false), (&approved, true)] {
            let sideband =
                Sideband::direct(peer, "localhost".into(), approved.cert.der().clone()).unwrap();
            let client = tokio_rustls::TlsConnector::from(Arc::new(
                sideband.candidate.unwrap().tls.client_config.unwrap(),
            ));
            let server = tokio_rustls::TlsAcceptor::from(server_config(leaf));
            let (left, right) = tokio::io::duplex(8192);
            let result = tokio::time::timeout(Duration::from_secs(2), async {
                tokio::join!(
                    client.connect(ServerName::try_from("localhost").unwrap(), left),
                    server.accept(right),
                )
            })
            .await
            .unwrap();
            assert_eq!(result.0.is_ok(), accepted);
            assert_eq!(result.1.is_ok(), accepted);
        }
    }

    #[tokio::test]
    async fn reliable_sideband_round_trips_and_rejects_duplicate_setup() {
        use ironrdp::pdu::rdp::headers::{BasicSecurityHeader, BasicSecurityHeaderFlags};
        use ironrdp_rdpeudp_tokio::{accept_udp, UdpAcceptConfig};
        let approved = rcgen::generate_simple_self_signed(["localhost".to_owned()]).unwrap();
        let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let mut client = Sideband::direct(
            socket.local_addr().unwrap(),
            "localhost".into(),
            approved.cert.der().clone(),
        )
        .unwrap();
        let request = MultitransportRequestPdu {
            security_header: BasicSecurityHeader {
                flags: BasicSecurityHeaderFlags::TRANSPORT_REQ,
            },
            request_id: 17,
            requested_protocol: RequestedProtocol::UdpFecR,
            security_cookie: [42; 16],
        };
        let server = accept_udp(
            socket,
            UdpAcceptConfig {
                tls_config: server_config(&approved),
                tunnel_config: ironrdp_rdpemt::TunnelConfig {
                    request_id: request.request_id,
                    security_cookie: request.security_cookie,
                },
                connection_config: Default::default(),
                accept_timeout: UDP_TIMEOUT,
            },
        );
        assert!(matches!(
            client.connect(request.clone(), false).await,
            MultitransportResult::Failure(MultitransportResponsePdu::E_ABORT)
        ));
        let (connected, server) = tokio::join!(client.connect(request.clone(), true), server);
        assert!(matches!(connected, MultitransportResult::Success));
        let mut server = server.unwrap();
        assert!(matches!(
            client.connect(request, true).await,
            MultitransportResult::Failure(MultitransportResponsePdu::E_ABORT)
        ));
        tokio::time::timeout(UDP_TIMEOUT, async {
            server.send(vec![1, 2, 3]).await.unwrap();
            assert_eq!(client.recv().await.unwrap().data, [1, 2, 3]);
            client
                .transport
                .as_ref()
                .unwrap()
                .send(vec![4, 5])
                .await
                .unwrap();
            assert_eq!(server.recv().await.unwrap(), [4, 5]);
        })
        .await
        .unwrap();
    }
}
