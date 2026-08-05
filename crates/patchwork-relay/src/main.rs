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
mod relay;
mod state;
mod store;
mod ws;

use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use patchwork_core::models::*;
use patchwork_core::now_ms;
use tower_http::cors::{Any, CorsLayer};

use crate::relay::Relay;

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

    /// Which workspace `--invite` belongs to. Defaults to the oldest one.
    #[arg(long)]
    workspace: Option<String>,
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

    let public_url = args
        .public_url
        .clone()
        .unwrap_or_else(|| format!("http://127.0.0.1:{}", args.port));
    let relay = Relay::open(data_dir, public_url.clone()).await?;

    if args.invite {
        let state = match &args.workspace {
            Some(id) => relay.state(id).await.context("no such workspace")?,
            None => relay
                .states()
                .await
                .into_iter()
                .min_by_key(|s| s.store.workspace().map(|w| w.created_at).unwrap_or(0))
                .context("this relay has no workspace yet")?,
        };
        let code = crate::auth::generate_invite_code();
        let admin = state
            .store
            .members()?
            .into_iter()
            .find(|m| m.is_admin)
            .map(|m| m.id)
            .unwrap_or_else(|| "system".into());
        state.store.insert_invite(&Invite {
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

    if relay.is_empty().await {
        let (state, code) = relay.create(&args.workspace_name).await?;
        let workspace = state.store.workspace()?;
        println!();
        println!("  Patchwork is ready.");
        println!();
        println!("  Relay URL:   {public_url}");
        println!("  Workspace:   {} ({})", workspace.name, workspace.id);
        println!("  Invite code: {code}");
        println!();
        println!("  Open the Desktop app and join with the URL and the code.");
        println!();
    }

    let app = api::relay_router(relay.clone()).layer(
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

    relay.shutdown().await;
    Ok(())
}

fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("patchwork-relay")
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
