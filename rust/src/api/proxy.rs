//! Local explicit proxies, with a lifecycle independent of terminal/forward sessions.
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::LazyLock;

use anyhow::Result;
use tokio::sync::Mutex;

use crate::api::page::PageGateway;
use crate::proxy::{self, RunningProxy};

static NEXT_ID: AtomicU32 = AtomicU32::new(1);
static PROXIES: LazyLock<Mutex<HashMap<u32, RunningProxy>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// All enabled ports are bound before returning. Settings contain no credentials.
pub async fn proxy_start(
    config_json: String,
    ssh_gateway_id: Option<u32>,
    page_gateway: Option<PageGateway>,
) -> Result<u32> {
    let running = proxy::start(&config_json, ssh_gateway_id, page_gateway).await?;
    let mut proxies = PROXIES.lock().await;
    let mut id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    while proxies.contains_key(&id) {
        id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    }
    proxies.insert(id, running);
    Ok(id)
}

/// None means an explicit stop; a message means the listener unexpectedly ended.
pub async fn proxy_wait(proxy_id: u32) -> Result<Option<String>> {
    let Some(mut status) = PROXIES
        .lock()
        .await
        .get(&proxy_id)
        .map(|p| p.status.clone())
    else {
        return Ok(None);
    };
    loop {
        if let Some(message) = status.borrow_and_update().clone() {
            return Ok((!message.is_empty()).then_some(message));
        }
        if status.changed().await.is_err() {
            return Ok(None);
        }
    }
}

/// Cancels negotiations, tunnels and HTTP drivers, then releases every listener.
pub async fn proxy_stop(proxy_id: u32) -> Result<()> {
    let running = PROXIES.lock().await.remove(&proxy_id);
    if let Some(running) = running {
        running.stop().await;
    }
    Ok(())
}
