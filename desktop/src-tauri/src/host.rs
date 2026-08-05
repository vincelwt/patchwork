//! This machine as an execution host.
//!
//! There is no separate host product: the Desktop keeps a WebSocket open to the
//! relay, registers what it can run, and executes the runs the relay sends it.
//! Close the app and its local agents simply stop being offered work.

use std::sync::Arc;

use futures::{SinkExt, StreamExt};
use patchwork_agent::{Runner, RunnerConfig};
use patchwork_core::host::{HostRegistration, HostToRelay, RelayToHost};
use patchwork_core::models::HostKind;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::settings::Settings;

#[derive(Debug, Serialize)]
#[serde(tag = "t", rename_all = "snake_case")]
enum ClientMsg {
    Host { msg: HostToRelay },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
enum ServerMsg {
    Ready {
        #[allow(dead_code)]
        seq: i64,
    },
    Event {
        #[serde(default)]
        #[allow(dead_code)]
        envelope: serde_json::Value,
    },
    Host {
        msg: RelayToHost,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct HostStatus {
    pub connected: bool,
    pub host_id: String,
    pub host_name: String,
    pub last_error: Option<String>,
}

pub struct LocalHost {
    status: Arc<Mutex<HostStatus>>,
    stop: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
    awake: Arc<crate::awake::Keeper>,
}

impl LocalHost {
    pub fn new(awake: Arc<crate::awake::Keeper>) -> Self {
        Self {
            status: Arc::new(Mutex::new(HostStatus::default())),
            stop: Arc::new(Mutex::new(None)),
            awake,
        }
    }

    pub async fn status(&self) -> HostStatus {
        self.status.lock().await.clone()
    }

    /// Restart the connection with the current settings. Safe to call whenever
    /// settings change.
    pub async fn restart(&self, settings: Settings) {
        if let Some(handle) = self.stop.lock().await.take() {
            handle.abort();
        }
        {
            let mut status = self.status.lock().await;
            status.connected = false;
            status.host_id = settings.host_id.clone();
            status.host_name = settings.host_name.clone();
        }
        if !settings.is_connected() {
            return;
        }

        let status = self.status.clone();
        let awake = self.awake.clone();
        let handle = tokio::spawn(async move {
            loop {
                match connect(&settings, &status, &awake).await {
                    Ok(()) => {}
                    Err(err) => {
                        let mut status = status.lock().await;
                        status.connected = false;
                        status.last_error = Some(format!("{err:#}"));
                    }
                }
                {
                    let mut status = status.lock().await;
                    status.connected = false;
                }
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            }
        });
        *self.stop.lock().await = Some(handle);
    }
}

async fn connect(
    settings: &Settings,
    status: &Arc<Mutex<HostStatus>>,
    awake: &Arc<crate::awake::Keeper>,
) -> anyhow::Result<()> {
    let ws_url = websocket_url(&settings.relay_url, &settings.token);
    let (socket, _) = tokio_tungstenite::connect_async(&ws_url).await?;
    let (mut sink, mut stream) = socket.split();

    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<HostToRelay>();
    let runner = Runner::new(
        RunnerConfig {
            cli_dir: cli_dir(),
            // Provider keys never leave this machine: they are read from its
            // own settings and handed to the agent process, not to the relay.
            env: settings.provider_env(),
        },
        out_tx.clone(),
    );

    // Announce what this machine can actually do.
    let registration = HostRegistration {
        host_id: settings.host_id.clone(),
        name: settings.host_name.clone(),
        kind: HostKind::Desktop,
        platform: patchwork_agent::detect::platform(),
        capabilities: patchwork_agent::detect_capabilities().await,
        project_paths: settings.project_paths.clone().into_iter().collect(),
    };
    let _ = out_tx.send(HostToRelay::Register {
        registration: Box::new(registration),
    });

    let writer = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            let Ok(text) = serde_json::to_string(&ClientMsg::Host { msg }) else {
                continue;
            };
            if sink.send(WsMessage::Text(text.into())).await.is_err() {
                break;
            }
        }
    });

    {
        let mut status = status.lock().await;
        status.connected = true;
        status.last_error = None;
    }

    // Keep the relay's view of this host fresh, and keep the machine awake for
    // exactly as long as it is doing work.
    let heartbeat = {
        let out_tx = out_tx.clone();
        let runner = runner.clone();
        let awake = awake.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                awake.set_running(runner.active_runs().await);
                if out_tx
                    .send(HostToRelay::Heartbeat { capabilities: None })
                    .is_err()
                {
                    break;
                }
            }
        })
    };

    while let Some(Ok(message)) = stream.next().await {
        let WsMessage::Text(text) = message else {
            continue;
        };
        match serde_json::from_str::<ServerMsg>(&text) {
            Ok(ServerMsg::Host { msg }) => {
                runner.handle(msg).await;
                // Checked on every command rather than only on the heartbeat,
                // so a run that starts now is covered now.
                awake.set_running(runner.active_runs().await);
            }
            Ok(ServerMsg::Error { message }) => {
                tracing::warn!(%message, "relay rejected a host message");
            }
            Ok(ServerMsg::Ready { .. }) | Ok(ServerMsg::Event { .. }) => {}
            Err(_) => {}
        }
    }

    heartbeat.abort();
    writer.abort();
    runner.shutdown().await;
    awake.set_running(0);
    Ok(())
}

fn websocket_url(relay_url: &str, token: &str) -> String {
    let base = relay_url.trim_end_matches('/');
    let base = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        format!("ws://{base}")
    };
    format!("{base}/ws?token={token}")
}

/// The bundled `patchwork` CLI, so agents we launch have native access.
fn cli_dir() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    // Packaged: Contents/MacOS next to the binary. Development: target/debug.
    for candidate in [dir.to_path_buf(), dir.join("../Resources")] {
        if candidate.join("patchwork").exists() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }
    Some(dir.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn websocket_urls_follow_the_relay_scheme() {
        assert_eq!(
            websocket_url("https://relay.example.com/", "abc"),
            "wss://relay.example.com/ws?token=abc"
        );
        assert_eq!(
            websocket_url("http://127.0.0.1:7717", "abc"),
            "ws://127.0.0.1:7717/ws?token=abc"
        );
    }
}
