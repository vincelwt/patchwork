//! Several workspaces in one relay process.
//!
//! A workspace is a whole Patchwork: its own SQLite file, event bus, hosts,
//! automations and hosted agents. They share the process and the port and
//! nothing else, and each is reached under `/w/{workspace_id}/`.
//!
//! Everything below that prefix is the single-workspace API, unchanged: the
//! request is stripped of the prefix and handed to that workspace's router.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

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

        reconcile_interrupted_runs(&state).await;
        let runner = start_hosted_execution(&state, self.agent_env.clone());
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
fn start_hosted_execution(state: &Shared, env: Vec<(String, String)>) -> Arc<Runner> {
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

    ws::register_relay_host(state, in_tx);

    // Report what this machine can do, so setup problems are visible in the UI.
    {
        let state = state.clone();
        tokio::spawn(async move {
            let mut capabilities = patchwork_agent::detect_capabilities().await;
            if let Ok(Some(mut host)) = state.store.host(&state.relay_host_id) {
                // Detection cannot know what a runtime can *run* — only opening
                // a session tells us that — so carry forward what we learned.
                for runtime in &mut capabilities.runtimes {
                    let Some(known) = host
                        .capabilities
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
                    if runtime.modes.is_empty() {
                        runtime.modes = known.modes.clone();
                        runtime.default_mode = known.default_mode.clone();
                    }
                }
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

/// A run that was in flight when the relay stopped is never left claiming to
/// be running.
async fn reconcile_interrupted_runs(state: &Shared) {
    let Ok(runs) = state.store.active_runs() else {
        return;
    };
    for mut run in runs {
        run.status = RunStatus::Failed;
        run.error = Some("the relay restarted while this run was in flight".into());
        run.ended_at = Some(now_ms());
        if state.store.update_run(&run).is_ok() {
            state.store.revoke_run_tokens(&run.id).ok();
            if let Err(err) = orchestrator::cancel_questions_for_run(state, &run.id).await {
                tracing::warn!(?err, run = %run.id, "could not cancel interrupted run questions");
            }
            state.emit(Event::RunUpdated { run: run.clone() });
            if let Err(err) = orchestrator::finish_run(state, &run).await {
                tracing::warn!(?err, run = %run.id, "could not finish interrupted run");
            }
        }
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
