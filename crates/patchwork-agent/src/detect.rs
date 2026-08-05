//! What this machine can actually do.
//!
//! Every host reports its own capabilities so the UI can explain a setup
//! failure ("Codex is installed but the ACP adapter needs Node") instead of a
//! run mysteriously refusing to start.
//!
//! Answering the question is expensive: a dozen PATH walks, a subprocess per
//! runtime to read its version, and `gh auth status`, which goes to the
//! network. So the answer is computed once, in parallel, and remembered —
//! [`detect_capabilities`] is cheap to call from anywhere, and only
//! [`refresh_capabilities`] pays the cost again.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use patchwork_core::models::{HostCapabilities, RuntimeInstallation};
use tokio::process::Command;

/// `gh auth status` contacts GitHub. On a captive-portal network it can hang
/// far longer than anyone is willing to wait for a badge in the settings page.
const GH_AUTH_TIMEOUT: Duration = Duration::from_secs(4);

/// Reading a version means starting a Node process for some runtimes; a few
/// seconds is already pathological.
const VERSION_TIMEOUT: Duration = Duration::from_secs(5);

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

/// Where each binary we care about lives, resolved at most once.
///
/// `which` walks every PATH entry and stats a candidate in each — a couple of
/// hundred syscalls per lookup on a normal developer's PATH. The same handful
/// of names are asked for repeatedly (once per builtin, again when a run
/// starts), and PATH does not change under a running process, so the answer is
/// worth keeping. [`refresh_capabilities`] drops it, which is what makes
/// "I just installed Claude Code" work without a restart.
fn path_cache() -> &'static Mutex<HashMap<String, Option<String>>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Option<String>>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn on_path(bin: &str) -> Option<String> {
    if let Some(hit) = path_cache().lock().ok().and_then(|c| c.get(bin).cloned()) {
        return hit;
    }
    let found = which::which(bin)
        .ok()
        .map(|p| p.to_string_lossy().to_string());
    if let Ok(mut cache) = path_cache().lock() {
        cache.insert(bin.to_string(), found.clone());
    }
    found
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
    // Every runtime whose version we still have to ask for, so the processes
    // can run at the same time. Read serially they add up to most of the time
    // this function takes, and they have nothing to do with each other.
    let mut pending = Vec::new();

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

        if base.is_some() && available {
            pending.push((out.len(), b.base_cli));
        }

        out.push(RuntimeInstallation {
            id: b.id.to_string(),
            label: b.label.to_string(),
            available,
            command,
            version: None,
            problem,
            models: Vec::new(),
            modes: Vec::new(),
            default_model: None,
            default_mode: None,
        });
    }

    let versions =
        futures::future::join_all(pending.iter().map(|(_, cli)| version_of(cli))).await;
    for ((index, _), version) in pending.into_iter().zip(versions) {
        out[index].version = version;
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
    let child = Command::new(bin)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let out = match tokio::time::timeout(VERSION_TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(out)) => out,
        _ => return None,
    };
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines().next().map(|l| l.trim().to_string())
}

async fn gh_is_authenticated() -> bool {
    let Ok(mut child) = Command::new("gh")
        .args(["auth", "status"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
    else {
        return false;
    };
    matches!(
        tokio::time::timeout(GH_AUTH_TIMEOUT, child.wait()).await,
        Ok(Ok(status)) if status.success()
    )
}

/// How long a detection is trusted before the next caller quietly re-runs it
/// in the background. Long enough that nothing polls the filesystem, short
/// enough that installing a missing runtime is noticed without a restart.
const CAPABILITY_TTL: Duration = Duration::from_secs(300);

type Cached = (HostCapabilities, std::time::Instant);

/// This machine's capabilities, computed once and remembered.
///
/// Callers sit on user-visible paths — the settings page, host registration —
/// so this must be cheap on the second call and every call after it. A cached
/// answer is returned immediately even when it is past its TTL; the refresh
/// happens behind it, so nothing ever waits on a subprocess twice.
pub async fn detect_capabilities() -> HostCapabilities {
    let cache = capability_cache();
    if let Some((known, at)) = cache.read().await.clone() {
        // One refresh at a time: several callers noticing the same stale entry
        // must not each start their own tree of subprocesses.
        if at.elapsed() >= CAPABILITY_TTL
            && !refresh_in_flight().swap(true, std::sync::atomic::Ordering::AcqRel)
        {
            tokio::spawn(async {
                refresh_capabilities().await;
                refresh_in_flight().store(false, std::sync::atomic::Ordering::Release);
            });
        }
        return known;
    }
    // Held across the probe on purpose: two callers racing at startup — the UI
    // asking, and the host registering — should share one detection rather
    // than each spawning their own tree of subprocesses.
    let mut slot = cache.write().await;
    if let Some((known, _)) = slot.clone() {
        return known;
    }
    let fresh = probe_capabilities().await;
    *slot = Some((fresh.clone(), std::time::Instant::now()));
    fresh
}

/// Ask the machine again — for after somebody installs a missing runtime.
pub async fn refresh_capabilities() -> HostCapabilities {
    if let Ok(mut cache) = path_cache().lock() {
        cache.clear();
    }
    let fresh = probe_capabilities().await;
    *capability_cache().write().await = Some((fresh.clone(), std::time::Instant::now()));
    fresh
}

fn capability_cache() -> &'static tokio::sync::RwLock<Option<Cached>> {
    static CACHE: OnceLock<tokio::sync::RwLock<Option<Cached>>> = OnceLock::new();
    CACHE.get_or_init(|| tokio::sync::RwLock::new(None))
}

fn refresh_in_flight() -> &'static std::sync::atomic::AtomicBool {
    static IN_FLIGHT: std::sync::atomic::AtomicBool =
        std::sync::atomic::AtomicBool::new(false);
    &IN_FLIGHT
}

async fn probe_capabilities() -> HostCapabilities {
    let has_git = on_path("git").is_some();
    let has_gh = on_path("gh").is_some();
    let has_node = on_path("node").is_some();

    // The GitHub round trip is the slowest single thing here and it has no
    // bearing on which runtimes exist, so it runs alongside them.
    let (runtimes, gh_authenticated) = futures::join!(detect_runtimes(), async {
        if has_gh {
            gh_is_authenticated().await
        } else {
            false
        }
    });

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
