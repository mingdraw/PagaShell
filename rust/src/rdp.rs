//! RDP desktop configuration, image limits, and certificate review.
use std::sync::{Arc, LazyLock};

use anyhow::{bail, Result};
use ironrdp::connector::{self, Credentials};
use ironrdp::graphics::image_processing::PixelFormat;
use ironrdp::pdu;
use ironrdp::session::image::DecodedImage;
use tokio_rustls::rustls;

pub(crate) fn validate_desktop_size(width: u16, height: u16) -> Result<()> {
    if width == 0 || height == 0 || u32::from(width) * u32::from(height) > 16_777_216 {
        bail!("RDP 桌面尺寸超限");
    }
    Ok(())
}

pub(crate) fn new_image(size: connector::DesktopSize) -> Result<DecodedImage> {
    validate_desktop_size(size.width, size.height)?;
    Ok(DecodedImage::new(
        PixelFormat::RgbA32,
        size.width,
        size.height,
    ))
}

pub(crate) fn config() -> connector::Config {
    use pdu::gcc::{ConnectionType, KeyboardType};
    use pdu::rdp::capability_sets::{MajorPlatformType, RailSupportLevel};
    use pdu::rdp::client_info::{CompressionType, PerformanceFlags, TimezoneInfo};
    connector::Config {
        credentials: Credentials::UsernamePassword {
            username: String::new(),
            password: String::new(),
        },
        domain: None,
        // Offer TLS as well as NLA, matching the upstream client and MS-RDPBCGR.
        // Some Windows hosts reject a request that advertises only HYBRID modes.
        enable_tls: true,
        enable_credssp: true,
        enable_standard_rdp_security: false,
        desktop_size: connector::DesktopSize {
            width: 640,
            height: 480,
        },
        monitor_layout: None,
        desktop_scale_factor: 0,
        keyboard_type: KeyboardType::IBM_ENHANCED,
        keyboard_subtype: 0,
        keyboard_layout: 0,
        keyboard_functional_keys_count: 12,
        connection_type: ConnectionType::Lan,
        ime_file_name: String::new(),
        dig_product_id: String::new(),
        bitmap: None,
        client_build: 0,
        client_name: "PagaShell".into(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".into(),
        platform: MajorPlatformType::UNIX,
        enable_server_pointer: false,
        request_data: None,
        autologon: true,
        enable_audio_playback: false,
        enable_audio_capture: false,
        compression_type: Some(CompressionType::K64),
        pointer_software_rendering: false,
        multitransport_flags: None,
        support_dyn_vc_gfx_protocol: false,
        performance_flags: PerformanceFlags::default(),
        hardware_id: None,
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        remote_application_mode: false,
        rail_support_level: RailSupportLevel::empty(),
    }
}

/// Collect PKI failures for explicit UI consent on this exact TLS stream before
/// CredSSP. TLS handshake signatures remain mandatory and cannot be overridden.
#[derive(Debug)]
pub(crate) struct FingerprintVerifier {
    provider: Arc<rustls::crypto::CryptoProvider>,
    verifier: Option<Arc<rustls::client::WebPkiServerVerifier>>,
    error: std::sync::Mutex<Option<String>>,
}

impl FingerprintVerifier {
    pub(crate) fn new(provider: Arc<rustls::crypto::CryptoProvider>) -> Self {
        // Snapshot once; native roots include locally installed enterprise CAs.
        static ROOTS: LazyLock<Arc<rustls::RootCertStore>> = LazyLock::new(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
            Arc::new(roots)
        });
        Self::with_roots(provider, ROOTS.clone())
    }

    fn with_roots(
        provider: Arc<rustls::crypto::CryptoProvider>,
        roots: Arc<rustls::RootCertStore>,
    ) -> Self {
        let verifier =
            rustls::client::WebPkiServerVerifier::builder_with_provider(roots, provider.clone())
                .build()
                .ok();
        Self {
            provider,
            verifier,
            error: std::sync::Mutex::new(None),
        }
    }

    pub(crate) fn certificate_error(&self) -> Option<String> {
        self.error.lock().unwrap().clone()
    }
}

impl rustls::client::danger::ServerCertVerifier for FingerprintVerifier {
    fn verify_server_cert(
        &self,
        cert: &rustls::pki_types::CertificateDer<'_>,
        intermediates: &[rustls::pki_types::CertificateDer<'_>],
        name: &rustls::pki_types::ServerName<'_>,
        ocsp: &[u8],
        now: rustls::pki_types::UnixTime,
    ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        let error = match &self.verifier {
            None => Some("trustStoreUnavailable"),
            Some(verifier) => {
                use rustls::CertificateError as Cert;
                match verifier.verify_server_cert(cert, intermediates, name, ocsp, now) {
                    Ok(_) => None,
                    Err(rustls::Error::InvalidCertificate(error)) => Some(match error {
                        Cert::UnknownIssuer => "unknownIssuer",
                        Cert::Expired | Cert::ExpiredContext { .. } => "expired",
                        Cert::NotValidYet | Cert::NotValidYetContext { .. } => "notValidYet",
                        Cert::NotValidForName | Cert::NotValidForNameContext { .. } => {
                            "nameMismatch"
                        }
                        _ => "invalidCertificate",
                    }),
                    Err(_) => Some("invalidCertificate"),
                }
            }
        };
        *self.error.lock().unwrap() = error.map(str::to_owned);
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::client::danger::ServerCertVerifier;
    use std::time::Duration;

    #[test]
    fn certificate_validation_reports_failures_for_ui_consent() {
        let certificate = |from, to| {
            let mut params = rcgen::CertificateParams::new(vec!["windows.test".into()]).unwrap();
            params.not_before = rcgen::date_time_ymd(from, 1, 1);
            params.not_after = rcgen::date_time_ymd(to, 1, 1);
            params
                .self_signed(&rcgen::KeyPair::generate().unwrap())
                .unwrap()
        };
        let cert = certificate(2010, 2040);
        let mut roots = rustls::RootCertStore::empty();
        roots.add(cert.der().clone()).unwrap();
        let verifier = FingerprintVerifier::with_roots(
            Arc::new(rustls::crypto::ring::default_provider()),
            Arc::new(roots),
        );
        let now = rustls::pki_types::UnixTime::since_unix_epoch(Duration::from_secs(1_577_836_800));
        let check = |cert: &rustls::pki_types::CertificateDer<'_>, name: &str| {
            verifier
                .verify_server_cert(cert, &[], &name.to_owned().try_into().unwrap(), &[], now)
                .unwrap();
            verifier.certificate_error()
        };
        assert_eq!(check(cert.der(), "windows.test"), None);
        assert_eq!(
            check(cert.der(), "other.test").as_deref(),
            Some("nameMismatch")
        );
        assert_eq!(
            check(certificate(2000, 2001).der(), "windows.test").as_deref(),
            Some("expired")
        );
        assert_eq!(
            check(certificate(2030, 2040).der(), "windows.test").as_deref(),
            Some("notValidYet")
        );
        let mut untrusted = rcgen::CertificateParams::new(vec!["windows.test".into()]).unwrap();
        untrusted
            .distinguished_name
            .push(rcgen::DnType::CommonName, "untrusted issuer");
        let untrusted = untrusted
            .self_signed(&rcgen::KeyPair::generate().unwrap())
            .unwrap();
        assert_eq!(
            check(untrusted.der(), "windows.test").as_deref(),
            Some("unknownIssuer")
        );
        // A successful later validation must clear an earlier failure.
        assert_eq!(check(cert.der(), "windows.test"), None);
        assert!(!verifier.supported_verify_schemes().is_empty());
        let missing_roots = FingerprintVerifier::with_roots(
            Arc::new(rustls::crypto::ring::default_provider()),
            Arc::new(rustls::RootCertStore::empty()),
        );
        missing_roots
            .verify_server_cert(
                cert.der(),
                &[],
                &"windows.test".try_into().unwrap(),
                &[],
                now,
            )
            .unwrap();
        assert_eq!(
            missing_roots.certificate_error().as_deref(),
            Some("trustStoreUnavailable")
        );
    }
}
