//! What this desktop remembers between launches: the workspaces it has joined
//! and their device tokens, its stable host identity, and where each project
//! lives on this machine.

use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// One joined workspace. A relay can hold several, and this machine can be in
/// workspaces on different relays at once.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct WorkspaceSettings {
    pub id: String,
    pub name: String,
    /// The relay root, without the workspace prefix.
    pub relay_url: String,
    pub token: String,
    pub member_id: String,
    pub member_name: String,
}

impl WorkspaceSettings {
    /// Everything this workspace is reached through hangs off here.
    pub fn base_url(&self) -> String {
        format!("{}/w/{}", self.relay_url.trim_end_matches('/'), self.id)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default)]
    pub workspaces: Vec<WorkspaceSettings>,
    /// Which one the window is showing. Every one of them stays connected.
    #[serde(default)]
    pub active: String,
    /// This machine *is* the relay: the app serves one for as long as it is
    /// open, instead of talking to a server somewhere else.
    #[serde(default)]
    pub hosts_relay: bool,
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
        !self.workspaces.is_empty()
    }

    pub fn workspace(&self, id: &str) -> Option<&WorkspaceSettings> {
        self.workspaces.iter().find(|w| w.id == id)
    }

    pub fn active_workspace(&self) -> Option<&WorkspaceSettings> {
        self.workspace(&self.active).or_else(|| self.workspaces.first())
    }

    /// Adding the same workspace twice replaces the old token rather than
    /// leaving two entries fighting over one member.
    pub fn upsert(&mut self, workspace: WorkspaceSettings) {
        match self.workspaces.iter_mut().find(|w| w.id == workspace.id) {
            Some(existing) => *existing = workspace.clone(),
            None => self.workspaces.push(workspace.clone()),
        }
        self.active = workspace.id;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_workspace_is_reached_under_its_own_prefix() {
        let workspace = WorkspaceSettings {
            id: "ws1".into(),
            relay_url: "http://127.0.0.1:7727/".into(),
            ..Default::default()
        };
        assert_eq!(workspace.base_url(), "http://127.0.0.1:7727/w/ws1");
    }

    #[test]
    fn rejoining_replaces_rather_than_duplicates() {
        let mut settings = Settings::default();
        settings.upsert(WorkspaceSettings {
            id: "a".into(),
            token: "one".into(),
            ..Default::default()
        });
        settings.upsert(WorkspaceSettings {
            id: "b".into(),
            ..Default::default()
        });
        settings.upsert(WorkspaceSettings {
            id: "a".into(),
            token: "two".into(),
            ..Default::default()
        });
        assert_eq!(settings.workspaces.len(), 2);
        assert_eq!(settings.workspace("a").unwrap().token, "two");
        assert_eq!(settings.active, "a");
    }
}
