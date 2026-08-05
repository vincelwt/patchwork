//! The Patchwork relay: one self-hostable service holding the shared data,
//! realtime collaboration, files, automations and hosted agent execution.
//!
//! It runs on an ordinary VPS with nothing but its own binary — embedded
//! SQLite, local file storage, no Postgres, no Docker.

mod api;
mod auth;
mod automations;
mod error;
mod github;
mod orchestrator;
mod preview_proxy;
mod state;
mod store;
mod ws;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use patchwork_agent::{Runner, RunnerConfig};
use patchwork_core::events::Event;
use patchwork_core::models::*;
use patchwork_core::{new_id, now_ms};
use tokio::sync::mpsc;
use tower_http::cors::{Any, CorsLayer};

use crate::state::{AppState, Shared};
use crate::store::Store;

#[derive(Parser, Debug)]
#[command(name = "patchwork-relay", version, about = "The Patchwork relay")]
struct Args {
    /// Where the database, uploaded files and worktrees live.
    #[arg(long, env = "PATCHWORK_DATA_DIR")]
    data_dir: Option<PathBuf>,

    /// 7717 belongs to an older, unrelated Patchwork; stay off it.
    #[arg(long, env = "PATCHWORK_PORT", default_value_t = 7727)]
    port: u16,

    #[arg(long, env = "PATCHWORK_BIND", default_value = "0.0.0.0")]
    bind: String,

    /// The URL desktops and agents should call back on.
    #[arg(long, env = "PATCHWORK_PUBLIC_URL")]
    public_url: Option<String>,

    /// Name used the first time the workspace is created.
    #[arg(long, default_value = "Patchwork")]
    workspace_name: String,

    /// Print a fresh admin invite code and exit.
    #[arg(long)]
    invite: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "patchwork_relay=info,patchwork_agent=info,warn".into()),
        )
        .with_target(false)
        .init();

    let args = Args::parse();
    let data_dir = args.data_dir.clone().unwrap_or_else(default_data_dir);
    std::fs::create_dir_all(&data_dir)?;

    let store = Store::open(&data_dir.join("patchwork.db"))?;
    let first_run = store.workspace().is_err();
    if first_run {
        store.create_workspace(&args.workspace_name)?;
    }

    if args.invite {
        let code = crate::auth::generate_invite_code();
        let admin = store
            .members()?
            .into_iter()
            .find(|m| m.is_admin)
            .map(|m| m.id)
            .unwrap_or_else(|| "system".into());
        store.insert_invite(&Invite {
            code: code.clone(),
            created_by: admin,
            created_at: now_ms(),
            email: None,
            is_admin: true,
            used_at: None,
            used_by: None,
        })?;
        println!("{code}");
        return Ok(());
    }

    let public_url = args
        .public_url
        .clone()
        .unwrap_or_else(|| format!("http://127.0.0.1:{}", args.port));
    let relay_host_id = ensure_relay_host(&store)?;

    let state: Shared = Arc::new(AppState::new(
        store,
        data_dir.join("files"),
        public_url.clone(),
        relay_host_id.clone(),
    ));

    if first_run {
        seed_workspace(&state).await?;
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
        println!();
        println!("  Patchwork is ready.");
        println!();
        println!("  Relay URL:   {public_url}");
        println!("  Invite code: {code}");
        println!();
        println!("  Open the Desktop app and join with those two values.");
        println!();
    }

    let runner = start_hosted_execution(&state);
    tokio::spawn(automations::scheduler(state.clone()));
    tokio::spawn(github::watcher(state.clone()));
    reconcile_interrupted_runs(&state).await;

    let app = api::router(state.clone()).layer(
        CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any),
    );

    let addr: SocketAddr = format!("{}:{}", args.bind, args.port)
        .parse()
        .context("invalid bind address")?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("relay listening on http://{addr} (public: {public_url})");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    // Stop hosted agents deliberately rather than orphaning their runtimes.
    runner.shutdown().await;
    Ok(())
}

fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("patchwork-relay")
}

fn ensure_relay_host(store: &Store) -> Result<String> {
    if let Some(existing) = store.hosts()?.into_iter().find(|h| h.kind == HostKind::Relay) {
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
fn start_hosted_execution(state: &Shared) -> std::sync::Arc<Runner> {
    let (out_tx, mut out_rx) = mpsc::unbounded_channel();
    let cli_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_string_lossy().to_string()));
    let runner = Runner::new(
        RunnerConfig {
            cli_dir,
            env: Vec::new(),
        },
        out_tx,
    );

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
            state.store.cancel_questions_for_run(&run.id).ok();
            state.emit(Event::RunUpdated { run });
        }
    }
}

async fn seed_workspace(state: &Shared) -> Result<()> {
    // A member to author system messages.
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
    state.store.insert_member(&system)?;

    let section = Section {
        id: new_id(),
        name: "OPERATIONS".into(),
        position: 0.0,
    };
    state.store.upsert_section(&section)?;

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
    state.store.insert_channel(&general)?;
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c().await.ok();
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutting down");
}
