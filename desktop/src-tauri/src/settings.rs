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
}

impl Settings {
    pub fn is_connected(&self) -> bool {
        !self.relay_url.is_empty() && !self.token.is_empty()
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
