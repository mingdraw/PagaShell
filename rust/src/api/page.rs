//! Page v1 settings. An empty server fingerprint selects unencrypted TCP.
#[derive(Clone)]
pub struct PageGateway {
    pub server_host: String,
    pub server_port: u16,
    pub client_id: String,
    pub token: String,
    pub server_fingerprint: String,
}
