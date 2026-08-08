//! The Patchwork relay: one self-hostable service holding the shared data,
//! realtime collaboration, files, automations and hosted agent execution.
//!
//! It runs on an ordinary VPS with nothing but its own binary — embedded
//! SQLite, local file storage, no Postgres, no Docker — and it is a library
//! so Desktop can *be* the relay on a machine that already has the app open,
//! without a second process to install, supervise or orphan.

mod api;
mod auth;
mod automations;
mod error;
mod github;
mod managed;
mod orchestrator;
mod preview_proxy;
mod visibility;
mod ws;

pub mod relay;
/// Internal, but reachable: an embedder holding a [`Relay`] gets at a
/// workspace through these.
pub mod state;
pub mod store;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use patchwork_core::models::Invite;
use patchwork_core::now_ms;
use tower_http::cors::{Any, CorsLayer};

pub use crate::relay::Relay;

pub struct Config {
    /// Where the databases, uploaded files and worktrees live.
    pub data_dir: PathBuf,
    pub bind: String,
    /// 7717 belongs to an older, unrelated Patchwork; stay off it.
    pub port: u16,
    /// The URL desktops and agents should call back on.
    pub public_url: Option<String>,
    /// Environment for agents this relay runs itself — model provider keys,
    /// mostly. An embedder has them; a relay on a VPS reads its own.
    pub agent_env: Vec<(String, String)>,
    /// Optional hosted ingress. The relay connects out and receives a public
    /// HTTPS URL without exposing its own port.
    pub managed_relay: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            data_dir: default_data_dir(),
            bind: "127.0.0.1".into(),
            port: 7727,
            public_url: None,
            agent_env: Vec::new(),
            managed_relay: None,
        }
    }
}

/// A relay that is listening. Dropping this does not stop it; call
/// [`Handle::shutdown`] so hosted agents stop deliberately rather than being
/// orphaned.
pub struct Handle {
    pub relay: Arc<Relay>,
    pub public_url: String,
    pub port: u16,
    server: tokio::task::JoinHandle<()>,
    connector: Option<managed::Connector>,
}

impl Handle {
    pub async fn shutdown(self) {
        if let Some(connector) = self.connector {
            connector.stop();
        }
        self.server.abort();
        self.relay.shutdown().await;
    }
}

/// Open every workspace on disk and start serving. Returns as soon as the
/// port is bound, so a caller can talk to it straight away.
pub async fn start(config: Config) -> Result<Handle> {
    std::fs::create_dir_all(&config.data_dir)?;
    let addr: SocketAddr = format!("{}:{}", config.bind, config.port)
        .parse()
        .context("invalid bind address")?;
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("could not listen on {addr}"))?;
    let port = listener.local_addr()?.port();
    let local_url = format!("http://127.0.0.1:{port}");
    let connector = match config.managed_relay.as_deref() {
        Some(broker) => {
            Some(managed::Connector::start(&config.data_dir, broker, local_url.clone()).await?)
        }
        None => None,
    };
    let public_url = connector
        .as_ref()
        .map(|connector| connector.public_url.clone())
        .or(config.public_url.clone())
        .unwrap_or_else(|| local_url.clone());
    let relay = Relay::open(
        config.data_dir.clone(),
        public_url.clone(),
        config.agent_env.clone(),
    )
    .await?;

    let app = api::relay_router(relay.clone()).layer(
        CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any),
    );
    tracing::info!("relay listening on {local_url} (public: {public_url})");

    let server = tokio::spawn(async move {
        if let Err(err) = axum::serve(listener, app).await {
            tracing::error!(?err, "relay stopped serving");
        }
    });

    Ok(Handle {
        relay,
        public_url,
        port,
        server,
        connector,
    })
}

/// A fresh admin invite, minted straight against the database.
///
/// Deliberately without starting anything: `--invite` is normally run while
/// the relay it mints for is already serving, and must not disturb it.
pub fn mint_invite(data_dir: &std::path::Path, workspace_id: Option<&str>) -> Result<String> {
    let store = match workspace_id {
        Some(id) => store::Store::open(&relay::workspace_db(data_dir, id))?,
        None => {
            // The oldest workspace is the one a relay-wide command means.
            let mut oldest: Option<(i64, store::Store)> = None;
            for id in relay::workspace_ids(data_dir)? {
                let store = store::Store::open(&relay::workspace_db(data_dir, &id))?;
                let created_at = store.workspace()?.created_at;
                if oldest.as_ref().is_none_or(|(at, _)| created_at < *at) {
                    oldest = Some((created_at, store));
                }
            }
            oldest.context("this relay has no workspace yet")?.1
        }
    };

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
    Ok(code)
}

pub fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("patchwork-relay")
}
