//! What this desktop remembers between launches: which relay it belongs to,
//! its device token, its stable host identity, and where each project lives on
//! this machine.

use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default)]
    pub relay_url: String,
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub member_id: String,
    #[serde(default)]
    pub member_name: String,
    /// Stable across restarts so this machine keeps one host identity.
    #[serde(default)]
    pub host_id: String,
    #[serde(default)]
    pub host_name: String,
    /// Project id -> absolute path on this machine.
    #[serde(default)]
    pub project_paths: BTreeMap<String, String>,
    /// Whether to stop this machine sleeping, and when.
    #[serde(default)]
    pub awake: crate::awake::AwakePolicy,
    /// Provider id -> API key for the Patchwork agent. Deliberately here and
    /// not in the workspace: a key is this machine's, and syncing it to a
    /// relay would put every teammate's device between it and the model.
    #[serde(default)]
    pub provider_keys: BTreeMap<String, String>,
}

impl Settings {
    pub fn is_connected(&self) -> bool {
        !self.relay_url.is_empty() && !self.token.is_empty()
    }

    /// The same settings with the keys' values replaced by the fact that they
    /// exist. Everything the UI needs, and nothing it could leak.
    pub fn redacted(&self) -> Settings {
        let mut copy = self.clone();
        for value in copy.provider_keys.values_mut() {
            *value = "stored".into();
        }
        copy
    }

    /// What an agent process needs to reach the models it was configured with.
    pub fn provider_env(&self) -> Vec<(String, String)> {
        self.provider_keys
            .iter()
            .filter(|(_, key)| !key.is_empty())
            .filter_map(|(id, key)| {
                let provider = patchwork_agent::providers::provider(id)?;
                (!provider.env_var.is_empty())
                    .then(|| (provider.env_var.to_string(), key.clone()))
            })
            .collect()
    }
}

/// Deliberately not plain `patchwork`: on a case-insensitive filesystem that
/// would share a directory with anything else of that name.
pub fn settings_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("patchwork-desktop")
        .join("settings.json")
}

pub fn load() -> Settings {
    std::fs::read_to_string(settings_path())
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

pub fn save(settings: &Settings) -> Result<()> {
    let path = settings_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, serde_json::to_string_pretty(settings)?)?;
    // This file holds provider API keys, so it is nobody else's business.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// A host id derived from the machine, so reconnecting never creates a second
/// "Vince's laptop" in the workspace.
pub fn stable_host_id() -> String {
    use base64::Engine;
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(patchwork_agent::detect::machine_key().as_bytes());
    let short = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&digest[..12]);
    format!("host-{short}")
}
