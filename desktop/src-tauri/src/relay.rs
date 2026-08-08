//! This machine as the relay.
//!
//! A solo user should not have to run a server to use Patchwork. The relay is
//! a library, so the app can simply hold one: same code, same data directory
//! and same API as the standalone binary, listening for as long as the app is
//! open.
//!
//! ponytail: loopback only. A relay on a laptop is for the person sitting at
//! it; bind it to the network when Desktop can also ask about the risk of
//! doing that on a café's wifi.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use tokio::sync::Mutex;

/// 7717 belongs to an older, unrelated Patchwork; stay off it.
pub const PORT: u16 = 7727;
const DEFAULT_MANAGED_RELAY: &str = "https://relay.patchwork.sh";

pub struct Hosted {
    data_dir: PathBuf,
    port: u16,
    managed_relay: Option<String>,
    handle: Arc<Mutex<Option<patchwork_relay::Handle>>>,
}

impl Default for Hosted {
    fn default() -> Self {
        // The same directory the standalone binary uses, so moving between
        // the two is a matter of which one you start.
        let managed = std::env::var("PATCHWORK_MANAGED_RELAY")
            .ok()
            .filter(|value| !value.eq_ignore_ascii_case("off"))
            .or_else(|| Some(DEFAULT_MANAGED_RELAY.into()));
        Self::with_managed(patchwork_relay::default_data_dir(), PORT, managed)
    }
}

impl Hosted {
    #[cfg(test)]
    pub fn new(data_dir: PathBuf, port: u16) -> Self {
        Self::with_managed(data_dir, port, None)
    }

    fn with_managed(data_dir: PathBuf, port: u16, managed_relay: Option<String>) -> Self {
        Self {
            data_dir,
            port,
            managed_relay,
            handle: Arc::new(Mutex::new(None)),
        }
    }

    /// Start serving unless it already is. Idempotent, because both app
    /// startup and the onboarding button want to be sure it is up.
    pub async fn ensure_started(&self) -> Result<String> {
        let mut current = self.handle.lock().await;
        if let Some(handle) = current.as_ref() {
            return Ok(handle.public_url.clone());
        }
        let handle = patchwork_relay::start(patchwork_relay::Config {
            data_dir: self.data_dir.clone(),
            bind: "127.0.0.1".into(),
            port: self.port,
            public_url: None,
            // A relay inside the app runs agents on this machine, so it gets
            // the same model provider keys the local host hands out. They
            // still never travel: this relay *is* the machine.
            agent_env: crate::settings::load().provider_env(),
            managed_relay: self.managed_relay.clone(),
        })
        .await
        .context("could not start the relay on this device")?;
        let url = handle.public_url.clone();
        *current = Some(handle);
        Ok(url)
    }

    pub async fn is_running(&self) -> bool {
        self.handle.lock().await.is_some()
    }

    /// Make sure there is a workspace to join, and return an invite for it.
    /// A relay that already has workspaces keeps them: this adds one only
    /// when the machine has never hosted anything.
    pub async fn adopt(&self, workspace_name: &str) -> Result<String> {
        let current = self.handle.lock().await;
        let handle = current
            .as_ref()
            .context("the relay on this device is not running")?;

        if handle.relay.is_empty().await {
            let (_, code) = handle.relay.create(workspace_name).await?;
            return Ok(code);
        }
        patchwork_relay::mint_invite(&self.data_dir, None)
    }

    /// Stop hosted agents deliberately rather than orphaning their runtimes.
    pub async fn shutdown(&self) {
        if let Some(handle) = self.handle.lock().await.take() {
            handle.shutdown().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole "use this device" path: serve, make a workspace, and hand
    /// back an invite that the ordinary join accepts.
    #[tokio::test]
    async fn hosting_here_produces_a_workspace_you_can_join() {
        let dir = std::env::temp_dir().join(format!("patchwork-hosted-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        // Port 0: the OS picks a free one, so the test never fights the app.
        let hosted = Hosted::new(dir.clone(), 0);

        hosted.ensure_started().await.unwrap();
        let port = hosted.handle.lock().await.as_ref().unwrap().port;
        let url = format!("http://127.0.0.1:{port}");

        let code = hosted.adopt("Solo").await.unwrap();
        // Starting again is a no-op, and does not make a second workspace.
        hosted.ensure_started().await.unwrap();

        let response: serde_json::Value = reqwest::Client::new()
            .post(format!("{url}/api/auth/join"))
            .json(&serde_json::json!({
                "invite_code": code,
                "display_name": "Vince",
            }))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();

        assert_eq!(response["workspace"]["name"], "Solo");
        assert!(response["token"].as_str().is_some_and(|t| !t.is_empty()));
        assert_eq!(hosted.handle.lock().await.as_ref().unwrap().port, port);

        hosted.shutdown().await;
        assert!(!hosted.is_running().await);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
