//! Several workspaces in one relay process.
//!
//! A workspace is a whole Patchwork: its own SQLite file, event bus, hosts,
//! automations and hosted agents. They share the process and the port and
//! nothing else, and each is reached under `/w/{workspace_id}/`.
//!
//! Everything below that prefix is the single-workspace API, unchanged: the
//! request is stripped of the prefix and handed to that workspace's router.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Weak};
use std::time::Duration;

use anyhow::{Context, Result};
use axum::Router;
use patchwork_agent::{Runner, RunnerConfig};
use patchwork_core::events::Event;
use patchwork_core::models::*;
use patchwork_core::{new_id, now_ms, Id};
use tokio::sync::{mpsc, RwLock};

use crate::state::{AppState, Shared};
use crate::store::Store;
use crate::{api, automations, github, orchestrator, ws};

struct Mounted {
    state: Shared,
    /// Built once and cloned per request; a `Router` clone is cheap.
    router: Router,
    runner: Arc<Runner>,
}

pub struct Relay {
    data_dir: PathBuf,
    public_url: String,
    /// Handed to every agent this relay runs itself.
    agent_env: Vec<(String, String)>,
    mounted: RwLock<HashMap<Id, Mounted>>,
}

impl Relay {
    /// Open every workspace already on disk.
    pub async fn open(
        data_dir: PathBuf,
        public_url: String,
        agent_env: Vec<(String, String)>,
    ) -> Result<Arc<Self>> {
        let relay = Arc::new(Self {
            data_dir,
            public_url,
            agent_env,
            mounted: RwLock::new(HashMap::new()),
        });
        std::fs::create_dir_all(relay.workspaces_dir())?;
        for id in workspace_ids(&relay.data_dir)? {
            relay
                .mount(&id)
                .await
                .with_context(|| format!("failed to open workspace {id}"))?;
        }
        tokio::spawn(prune_worktrees(Arc::downgrade(&relay)));
        Ok(relay)
    }

    fn workspaces_dir(&self) -> PathBuf {
        self.data_dir.join("workspaces")
    }

    /// The URL a client uses for this workspace: everything it calls hangs
    /// off it, including the WebSocket.
    pub fn workspace_url(&self, workspace_id: &str) -> String {
        format!("{}/w/{}", self.public_url, workspace_id)
    }

    pub async fn router(&self, workspace_id: &str) -> Option<Router> {
        self.mounted
            .read()
            .await
            .get(workspace_id)
            .map(|m| m.router.clone())
    }

    pub async fn state(&self, workspace_id: &str) -> Option<Shared> {
        self.mounted
            .read()
            .await
            .get(workspace_id)
            .map(|m| m.state.clone())
    }

    pub async fn states(&self) -> Vec<Shared> {
        self.mounted
            .read()
            .await
            .values()
            .map(|m| m.state.clone())
            .collect()
    }

    pub async fn workspaces(&self) -> Vec<Workspace> {
        let mut list: Vec<Workspace> = self
            .states()
            .await
            .iter()
            .filter_map(|state| state.store.workspace().ok())
            .collect();
        list.sort_by_key(|w| w.created_at);
        list
    }

    pub async fn is_empty(&self) -> bool {
        self.mounted.read().await.is_empty()
    }

    /// Which workspace an unused invite code belongs to.
    ///
    /// ponytail: a scan across mounted workspaces. A relay holds a handful of
    /// them; index invite codes centrally only if that stops being true.
    pub async fn workspace_for_invite(&self, code: &str) -> Option<Shared> {
        for state in self.states().await {
            let found = state
                .store
                .invites()
                .unwrap_or_default()
                .into_iter()
                .any(|invite| invite.code == code && invite.used_at.is_none());
            if found {
                return Some(state);
            }
        }
        None
    }

    /// Preview hostnames omit workspace ids to stay inside one DNS label.
    /// ponytail: scan the handful of mounted workspaces; index previews
    /// relay-wide only if a relay ever carries enough workspaces to notice.
    pub async fn router_for_preview(&self, preview_id: &str) -> Option<Router> {
        for mounted in self.mounted.read().await.values() {
            if mounted
                .state
                .store
                .preview(preview_id)
                .ok()
                .flatten()
                .is_some()
            {
                return Some(mounted.router.clone());
            }
        }
        None
    }

    /// Which workspace a device token belongs to. Same scan, same reasoning.
    pub async fn workspace_for_token(&self, token: &str) -> Option<(Shared, crate::auth::Caller)> {
        for state in self.states().await {
            if let Some(caller) = crate::auth::authenticate(&state, token) {
                return Some((state, caller));
            }
        }
        None
    }

    /// Create a workspace and its first admin invite.
    pub async fn create(&self, name: &str) -> Result<(Shared, String)> {
        let id = new_id();
        let store = Store::open(&self.workspaces_dir().join(&id).join("patchwork.db"))?;
        store.create_workspace(&id, name)?;
        seed(&store)?;
        let state = self.mount(&id).await?;
        let code = crate::auth::generate_invite_code();
        state.store.insert_invite(&Invite {
            code: code.clone(),
            created_by: "system".into(),
            created_at: now_ms(),
            email: None,
            is_admin: true,
            used_at: None,
            used_by: None,
        })?;
        Ok((state, code))
    }

    /// Open a workspace's database and bring everything it owns to life:
    /// its API, its hosted agents, its schedules.
    async fn mount(&self, id: &str) -> Result<Shared> {
        let dir = self.workspaces_dir().join(id);
        let store = Store::open(&dir.join("patchwork.db"))?;
        store.workspace()?;
        let relay_host_id = ensure_relay_host(&store)?;
        let state: Shared = Arc::new(AppState::new(
            store,
            dir.join("files"),
            self.workspace_url(id),
            relay_host_id,
        ));

        let runner = start_hosted_execution(&state, self.agent_env.clone()).await;
        reconcile_interrupted_runs(&state).await;
        tokio::spawn(orchestrator::watch_hosts(state.clone()));
        tokio::spawn(automations::scheduler(state.clone()));
        tokio::spawn(github::watcher(state.clone()));

        let router = api::router(state.clone());
        self.mounted.write().await.insert(
            id.to_string(),
            Mounted {
                state: state.clone(),
                router,
                runner,
            },
        );
        Ok(state)
    }

    /// Stop hosted agents deliberately rather than orphaning their runtimes.
    pub async fn shutdown(&self) {
        let runners: Vec<Arc<Runner>> = self
            .mounted
            .read()
            .await
            .values()
            .map(|m| m.runner.clone())
            .collect();
        for runner in runners {
            runner.shutdown().await;
        }
    }
}

async fn prune_worktrees(relay: Weak<Relay>) {
    const DEFAULT_DAYS: u64 = 2;
    let days = std::env::var("PATCHWORK_WORKTREE_RETENTION_DAYS")
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|days| *days > 0)
        .unwrap_or(DEFAULT_DAYS);
    let retention = Duration::from_secs(days.saturating_mul(24 * 60 * 60));
    let mut ticker = tokio::time::interval(Duration::from_secs(60 * 60));
    loop {
        ticker.tick().await;
        let Some(relay) = relay.upgrade() else {
            return;
        };
        let mut in_use = HashSet::new();
        let mut complete = true;
        for state in relay.states().await {
            match state.store.active_runs() {
                Ok(runs) => in_use.extend(
                    runs.into_iter()
                        .filter_map(|run| run.cwd.map(PathBuf::from)),
                ),
                Err(err) => {
                    tracing::warn!(?err, "could not read active runs before worktree pruning");
                    complete = false;
                    break;
                }
            }
        }
        if complete {
            if let Err(err) = patchwork_agent::worktree::prune(&in_use, retention).await {
                tracing::warn!(?err, "worktree pruning failed");
            }
        }
    }
}

/// Which workspaces are on disk, without opening any of them.
pub fn workspace_ids(data_dir: &std::path::Path) -> Result<Vec<Id>> {
    let dir = data_dir.join("workspaces");
    let mut ids = Vec::new();
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Ok(ids);
    };
    for entry in entries {
        let entry = entry?;
        if entry.file_type()?.is_dir() && entry.path().join("patchwork.db").exists() {
            ids.push(entry.file_name().to_string_lossy().to_string());
        }
    }
    Ok(ids)
}

pub fn workspace_db(data_dir: &std::path::Path, id: &str) -> PathBuf {
    data_dir.join("workspaces").join(id).join("patchwork.db")
}

pub(crate) fn preserve_runtime_options(fresh: &mut HostCapabilities, known: &HostCapabilities) {
    for runtime in &mut fresh.runtimes {
        let Some(known) = known
            .runtimes
            .iter()
            .find(|candidate| candidate.id == runtime.id)
        else {
            continue;
        };
        if runtime.models.is_empty() {
            runtime.models = known.models.clone();
            runtime.default_model = known.default_model.clone();
        }
        if runtime.thinking.is_empty() {
            runtime.thinking = known.thinking.clone();
            runtime.default_thinking = known.default_thinking.clone();
        }
        if runtime.modes.is_empty() {
            runtime.modes = known.modes.clone();
            runtime.default_mode = known.default_mode.clone();
        }
    }
}

fn ensure_relay_host(store: &Store) -> Result<Id> {
    if let Some(existing) = store
        .hosts()?
        .into_iter()
        .find(|h| h.kind == HostKind::Relay)
    {
        return Ok(existing.id);
    }
    let host = Host {
        id: new_id(),
        name: "Relay".into(),
        kind: HostKind::Relay,
        platform: patchwork_agent::detect::platform(),
        owner_id: None,
        online: false,
        last_seen: 0,
        capabilities: HostCapabilities::default(),
        created_at: now_ms(),
    };
    store.upsert_host(&host)?;
    Ok(host.id)
}

/// The relay is itself an execution host: hosted agents keep working when
/// every laptop is closed.
async fn start_hosted_execution(state: &Shared, env: Vec<(String, String)>) -> Arc<Runner> {
    let (out_tx, mut out_rx) = mpsc::unbounded_channel();
    tokio::spawn(patchwork_agent::report_runtime_options(
        out_tx.clone(),
        env.clone(),
    ));
    let cli_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_string_lossy().to_string()));
    let runner = Runner::new(RunnerConfig { cli_dir, env }, out_tx);

    // Host -> relay.
    {
        let state = state.clone();
        let host_id = state.relay_host_id.clone();
        tokio::spawn(async move {
            while let Some(msg) = out_rx.recv().await {
                orchestrator::handle_host_message(&state, &host_id, msg).await;
            }
        });
    }

    // Relay -> host.
    let (in_tx, mut in_rx) = mpsc::unbounded_channel();
    {
        let runner = runner.clone();
        tokio::spawn(async move {
            while let Some(msg) = in_rx.recv().await {
                runner.handle(msg).await;
            }
        });
    }

    ws::register_relay_host(state, in_tx).await;

    // Report what this machine can do, so setup problems are visible in the UI.
    {
        let state = state.clone();
        tokio::spawn(async move {
            let mut capabilities = patchwork_agent::detect_capabilities().await;
            if let Ok(Some(mut host)) = state.store.host(&state.relay_host_id) {
                // Detection cannot know what a runtime can *run* — only opening
                // a session tells us that — so carry forward what we learned.
                preserve_runtime_options(&mut capabilities, &host.capabilities);
                host.capabilities = capabilities;
                host.last_seen = now_ms();
                host.online = true;
                if state.store.upsert_host(&host).is_ok() {
                    state.emit(Event::HostUpdated { host });
                }
            }
        });
    }

    runner
}

/// Resume relay-hosted work after the in-process host has been registered.
/// A run owned by another machine is left alone: that machine takes it back
/// when it registers again, and `orchestrator::watch_hosts` ends it if it
/// never does.
async fn reconcile_interrupted_runs(state: &Shared) {
    let Ok(runs) = state.store.active_runs() else {
        return;
    };
    for run in runs {
        if run.host_id.as_deref() != Some(&state.relay_host_id) {
            let _ = orchestrator::append_run_event(
                state,
                &run.id,
                RunEventKind::Lifecycle,
                "The relay restarted; waiting for the machine running this to reconnect".into(),
                None,
            );
            continue;
        }
        if let Err(err) = orchestrator::resume_interrupted_run(state, &run).await {
            tracing::warn!(?err, run = %run.id, "could not resume interrupted run");
            let why =
                format!("the relay restarted while this run was in flight, and it could not be resumed: {err:#}");
            if let Err(err) = orchestrator::fail_run(state, &run, &why).await {
                tracing::warn!(?err, run = %run.id, "could not finish interrupted run");
            }
        }
    }
    // Startup is the one moment we know which runs are really alive, so it is
    // also when a task left pointing at a dead one gets released.
    match state.store.clear_finished_task_runs() {
        Ok(count) if count > 0 => tracing::info!(count, "freed tasks left on a finished run"),
        Err(err) => tracing::warn!(?err, "could not free tasks left on a finished run"),
        _ => {}
    }
    if let Ok(previews) = state.store.previews(true) {
        for mut preview in previews {
            preview.status = PreviewStatus::Failed;
            preview.stopped_at = Some(now_ms());
            if state.store.upsert_preview(&preview).is_ok() {
                state.emit(Event::PreviewUpdated { preview });
            }
        }
    }
}

/// What a brand new workspace contains: someone to author system messages,
/// and one channel to talk in.
fn seed(store: &Store) -> Result<()> {
    let system = Member {
        id: new_id(),
        kind: MemberKind::Human,
        handle: "patchwork".into(),
        display_name: "Patchwork".into(),
        email: None,
        avatar: Some("◆".into()),
        is_admin: false,
        created_at: now_ms(),
        agent: None,
        presence: Presence::Offline,
    };
    store.insert_member(&system)?;

    let section = Section {
        id: new_id(),
        name: "OPERATIONS".into(),
        position: 0.0,
    };
    store.upsert_section(&section)?;

    let general = Channel {
        id: new_id(),
        kind: ChannelKind::Channel,
        section_id: Some(section.id.clone()),
        slug: "general".into(),
        name: "general".into(),
        topic: "Everything that does not have a better home yet".into(),
        position: 0.0,
        created_at: now_ms(),
        member_ids: Vec::new(),
        task_id: None,
        last_message_at: 0,
    };
    store.insert_channel(&general)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A restart must not kill work on a machine that is simply reconnecting:
    /// the run stays as it was, and that machine takes it back when it
    /// registers again.
    #[tokio::test]
    async fn a_restart_leaves_a_desktop_run_for_its_machine_to_take_back() {
        let path = std::env::temp_dir().join(format!("patchwork-restart-{}.sqlite", new_id()));
        let store = Store::open(&path).unwrap();
        store.create_workspace("workspace", "Test").unwrap();
        let run = Run {
            id: "run".into(),
            agent_id: "agent".into(),
            status: RunStatus::Running,
            trigger: RunTrigger::Manual { by: "human".into() },
            channel_id: "channel".into(),
            task_id: None,
            host_id: Some("desktop".into()),
            project_id: None,
            worktree_id: None,
            cwd: None,
            automation_id: None,
            session_id: Some("session".into()),
            runtime: "codex".into(),
            prompt: "Keep going".into(),
            headline: "Working".into(),
            error: None,
            token_usage: None,
            created_at: 1,
            started_at: Some(1),
            ended_at: None,
        };
        store.insert_run(&run, 0).unwrap();
        let state: Shared = Arc::new(AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "relay".into(),
        ));

        reconcile_interrupted_runs(&state).await;

        let kept = store.run("run").unwrap().unwrap();
        assert_eq!(kept.status, RunStatus::Running);
        assert_eq!(kept.session_id.as_deref(), Some("session"));

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn capability_refresh_keeps_every_learned_runtime_option() {
        let mut fresh: HostCapabilities = serde_json::from_value(serde_json::json!({
            "runtimes": [{
                "id": "codex", "label": "Codex", "available": true,
                "models": [{ "id": "fresh", "name": "Fresh" }],
                "default_model": "fresh"
            }]
        }))
        .unwrap();
        let known: HostCapabilities = serde_json::from_value(serde_json::json!({
            "runtimes": [{
                "id": "codex", "label": "Codex", "available": true,
                "models": [{ "id": "old", "name": "Old" }],
                "thinking": [{ "id": "xhigh", "name": "Xhigh" }],
                "modes": [{ "id": "agent-full-access", "name": "Full access" }],
                "default_model": "old", "default_thinking": "xhigh",
                "default_mode": "agent-full-access"
            }]
        }))
        .unwrap();

        preserve_runtime_options(&mut fresh, &known);
        let runtime = &fresh.runtimes[0];
        assert_eq!(runtime.models[0].id, "fresh");
        assert_eq!(runtime.default_model.as_deref(), Some("fresh"));
        assert_eq!(runtime.thinking[0].id, "xhigh");
        assert_eq!(runtime.default_thinking.as_deref(), Some("xhigh"));
        assert_eq!(runtime.modes[0].id, "agent-full-access");
        assert_eq!(runtime.default_mode.as_deref(), Some("agent-full-access"));
    }
}
