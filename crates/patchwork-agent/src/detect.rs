//! What this machine can actually do.
//!
//! Every host reports its own capabilities so the UI can explain a setup
//! failure ("Codex is installed but the ACP adapter needs Node") instead of a
//! run mysteriously refusing to start.

use std::collections::HashMap;
use std::process::Stdio;

use patchwork_core::models::{HostCapabilities, RuntimeInstallation};
use tokio::process::Command;

/// A built-in runtime: a well-known agent plus the ACP adapter that fronts it.
struct Builtin {
    id: &'static str,
    label: &'static str,
    /// Native binary that already speaks ACP, if the user installed one.
    native: &'static [&'static str],
    /// The underlying agent CLI whose presence means "this is worth offering".
    base_cli: &'static str,
    /// npm package providing the ACP adapter.
    npm_package: &'static str,
}

const BUILTINS: &[Builtin] = &[
    Builtin {
        id: "codex",
        label: "Codex",
        native: &["codex-acp"],
        base_cli: "codex",
        npm_package: "@agentclientprotocol/codex-acp",
    },
    Builtin {
        id: "claude",
        label: "Claude Code",
        native: &["claude-code-acp"],
        base_cli: "claude",
        npm_package: "@zed-industries/claude-code-acp",
    },
    Builtin {
        id: "pi",
        label: "Pi",
        native: &["pi-acp"],
        base_cli: "pi",
        npm_package: "pi-acp",
    },
];

fn on_path(bin: &str) -> Option<String> {
    which::which(bin)
        .ok()
        .map(|p| p.to_string_lossy().to_string())
}

/// Resolve the command line used to launch a runtime's ACP adapter.
///
/// `custom` returns whatever the agent profile carries; the caller supplies it.
pub fn runtime_command(runtime: &str) -> Option<Vec<String>> {
    let b = BUILTINS.iter().find(|b| b.id == runtime)?;
    for native in b.native {
        if let Some(path) = on_path(native) {
            return Some(vec![path]);
        }
    }
    if on_path(b.base_cli).is_some() {
        if let Some(npx) = on_path("npx") {
            return Some(vec![
                npx,
                "-y".into(),
                "--".into(),
                b.npm_package.to_string(),
            ]);
        }
    }
    None
}

pub async fn detect_runtimes() -> Vec<RuntimeInstallation> {
    let has_npx = on_path("npx").is_some();
    let mut out = Vec::new();

    for b in BUILTINS {
        let native = b.native.iter().find_map(|n| on_path(n));
        let base = on_path(b.base_cli);

        let (available, command, problem) = match (&native, &base, has_npx) {
            (Some(path), _, _) => (true, vec![path.clone()], None),
            (None, Some(_), true) => (
                true,
                runtime_command(b.id).unwrap_or_default(),
                None,
            ),
            (None, Some(_), false) => (
                false,
                vec![],
                Some(format!(
                    "`{}` is installed but its ACP adapter needs Node.js (npx) on PATH",
                    b.base_cli
                )),
            ),
            (None, None, _) => (
                false,
                vec![],
                Some(format!("`{}` is not installed on this machine", b.base_cli)),
            ),
        };

        let version = match &base {
            Some(_) if available => version_of(b.base_cli).await,
            _ => None,
        };

        out.push(RuntimeInstallation {
            id: b.id.to_string(),
            label: b.label.to_string(),
            available,
            command,
            version,
            problem,
            models: Vec::new(),
            modes: Vec::new(),
            default_model: None,
            default_mode: None,
        });
    }

    out.push(RuntimeInstallation {
        id: "custom".to_string(),
        label: "Custom ACP command".to_string(),
        available: true,
        command: vec![],
        version: None,
        problem: None,
            models: Vec::new(),
        modes: Vec::new(),
        default_model: None,
        default_mode: None,
    });

    out
}

async fn version_of(bin: &str) -> Option<String> {
    let out = Command::new(bin)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines().next().map(|l| l.trim().to_string())
}

pub async fn detect_capabilities() -> HostCapabilities {
    let runtimes = detect_runtimes().await;
    let has_git = on_path("git").is_some();
    let has_gh = on_path("gh").is_some();
    let has_node = on_path("node").is_some();

    let gh_authenticated = if has_gh {
        Command::new("gh")
            .args(["auth", "status"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .map(|s| s.success())
            .unwrap_or(false)
    } else {
        false
    };

    let mut notes = Vec::new();
    if !has_git {
        notes.push("git is not installed: worktree-based code tasks will fail".into());
    }
    if has_gh && !gh_authenticated {
        notes.push("gh is installed but not authenticated: run `gh auth login`".into());
    }
    if !has_gh {
        notes.push("gh is not installed: pull request work is unavailable".into());
    }
    if !runtimes.iter().any(|r| r.available && r.id != "custom") {
        notes.push("no ACP agent installation detected on this machine".into());
    }

    HostCapabilities {
        runtimes,
        has_git,
        has_gh,
        gh_authenticated,
        has_node,
        // Agents use their own browser tooling; we report whether a driver is
        // even plausible so the UI can explain a failure.
        browser_automation: has_node || on_path("playwright").is_some(),
        machine_key: machine_key(),
        home_dir: dirs::home_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default(),
        notes,
    }
}

/// Stable per-machine id so a desktop keeps the same host identity across
/// restarts.
pub fn machine_key() -> String {
    let host = hostname();
    let user = std::env::var("USER").unwrap_or_else(|_| "user".into());
    format!("{user}@{host}")
}

pub fn hostname() -> String {
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            std::process::Command::new("hostname")
                .output()
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "unknown-host".into())
}

pub fn platform() -> String {
    format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH)
}

/// Environment shared by every agent process we launch.
pub fn base_env(extra: &[(String, String)]) -> HashMap<String, String> {
    let mut env: HashMap<String, String> = HashMap::new();
    env.insert("PATCHWORK".into(), "1".into());
    for (k, v) in extra {
        env.insert(k.clone(), v.clone());
    }
    env
}
