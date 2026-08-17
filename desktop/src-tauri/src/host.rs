//! This machine as an execution host.
//!
//! There is no separate host product: the Desktop keeps a WebSocket open per
//! joined workspace, registers what it can run, and executes the runs each
//! relay sends it. Close the app and its local agents simply stop being
//! offered work.
//!
//! One connection per workspace, all of them live at once: switching what the
//! window shows is a UI decision and must never stop an agent working in the
//! workspace you just looked away from.

use std::collections::HashMap;
use std::sync::Arc;

use futures::{SinkExt, StreamExt};
use patchwork_agent::{Runner, RunnerConfig};
use patchwork_core::host::{HostRegistration, HostToRelay, RelayToHost};
use patchwork_core::models::HostKind;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch, Mutex};
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::settings::{Settings, WorkspaceSettings};

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
    /// True when every joined workspace has this machine online.
    pub connected: bool,
    pub host_id: String,
    pub host_name: String,
    pub last_error: Option<String>,
    pub workspaces_online: usize,
    pub workspaces: usize,
}

#[derive(Default)]
struct Links {
    host_id: String,
    host_name: String,
    /// Workspace id -> is this machine online in it.
    online: HashMap<String, bool>,
    last_error: Option<String>,
}

impl Links {
    fn status(&self) -> HostStatus {
        let online = self.online.values().filter(|up| **up).count();
        HostStatus {
            connected: online > 0 && online == self.online.len(),
            host_id: self.host_id.clone(),
            host_name: self.host_name.clone(),
            last_error: self.last_error.clone(),
            workspaces_online: online,
            workspaces: self.online.len(),
        }
    }
}

struct ConnectionLoop {
    stop: watch::Sender<bool>,
    task: tokio::task::JoinHandle<()>,
}

pub struct LocalHost {
    links: Arc<Mutex<Links>>,
    stop: Arc<Mutex<Vec<ConnectionLoop>>>,
    awake: Arc<crate::awake::Keeper>,
}

impl LocalHost {
    pub fn new(awake: Arc<crate::awake::Keeper>) -> Self {
        Self {
            links: Arc::new(Mutex::new(Links::default())),
            stop: Arc::new(Mutex::new(Vec::new())),
            awake,
        }
    }

    pub async fn status(&self) -> HostStatus {
        self.links.lock().await.status()
    }

    /// Reconnect every workspace with the current settings. Safe to call
    /// whenever settings change.
    pub async fn restart(&self, settings: Settings) {
        // Keep overlapping settings saves from creating overlapping socket
        // loops for the same workspace.
        let mut connections = self.stop.lock().await;
        let previous = connections.drain(..).collect::<Vec<_>>();
        for connection in &previous {
            let _ = connection.stop.send(true);
        }
        for connection in previous {
            let _ = connection.task.await;
        }
        {
            let mut links = self.links.lock().await;
            links.host_id = settings.host_id.clone();
            links.host_name = settings.host_name.clone();
            links.online.clear();
            links.last_error = None;
        }

        for workspace in settings.workspaces.clone() {
            self.links
                .lock()
                .await
                .online
                .insert(workspace.id.clone(), false);

            let links = self.links.clone();
            let awake = self.awake.clone();
            let shared = settings.clone();
            let (stop, mut stopping) = watch::channel(false);
            let task = tokio::spawn(async move {
                loop {
                    if let Err(err) =
                        connect(&shared, &workspace, &links, &awake, stopping.clone()).await
                    {
                        links.lock().await.last_error = Some(format!("{err:#}"));
                    }
                    {
                        let mut links = links.lock().await;
                        links.online.insert(workspace.id.clone(), false);
                    }
                    awake.set_running(&workspace.id, 0);
                    if *stopping.borrow() {
                        break;
                    }
                    tokio::select! {
                        _ = tokio::time::sleep(std::time::Duration::from_secs(5)) => {}
                        _ = stopping.changed() => break,
                    }
                }
            });
            connections.push(ConnectionLoop { stop, task });
        }
    }
}

async fn connect(
    settings: &Settings,
    workspace: &WorkspaceSettings,
    links: &Arc<Mutex<Links>>,
    awake: &Arc<crate::awake::Keeper>,
    mut stopping: watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let ws_url = websocket_url(&workspace.base_url(), &workspace.token);
    let (socket, _) = tokio::select! {
        result = tokio_tungstenite::connect_async(&ws_url) => result?,
        _ = stopping.changed() => return Ok(()),
    };
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
    let mut stop_runs = StopOnDrop(Some(runner.clone()));

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

    // What each runtime can run, asked once per connection rather than left
    // until the first run — the agent editor needs the list before that.
    tokio::spawn(patchwork_agent::report_runtime_options(
        out_tx.clone(),
        settings.provider_env(),
    ));

    {
        let mut links = links.lock().await;
        links.online.insert(workspace.id.clone(), true);
        links.last_error = None;
    }

    let mut heartbeat = tokio::time::interval(std::time::Duration::from_secs(30));
    heartbeat.tick().await;
    loop {
        tokio::select! {
            _ = stopping.changed() => break,
            outgoing = out_rx.recv() => {
                let Some(msg) = outgoing else { break };
                let Ok(text) = serde_json::to_string(&ClientMsg::Host { msg }) else {
                    continue;
                };
                tokio::select! {
                    result = sink.send(WsMessage::Text(text.into())) => {
                        if result.is_err() {
                            break;
                        }
                    }
                    _ = stopping.changed() => break,
                }
            }
            incoming = stream.next() => {
                let text = match incoming {
                    Some(Ok(WsMessage::Text(text))) => text,
                    Some(Ok(_)) => continue,
                    Some(Err(_)) | None => break,
                };
                match serde_json::from_str::<ServerMsg>(&text) {
                    Ok(ServerMsg::Host { msg }) => {
                        runner.handle(msg).await;
                        // Checked on every command rather than only on the heartbeat,
                        // so a run that starts now is covered now.
                        awake.set_running(&workspace.id, runner.active_run_ids().await.len());
                    }
                    Ok(ServerMsg::Error { message }) => {
                        tracing::warn!(%message, "relay rejected a host message");
                    }
                    Ok(ServerMsg::Ready { .. }) | Ok(ServerMsg::Event { .. }) => {}
                    Err(_) => {}
                }
            }
            _ = heartbeat.tick() => {
                let runs = runner.active_run_ids().await;
                awake.set_running(&workspace.id, runs.len());
                let _ = out_tx.send(HostToRelay::Heartbeat {
                    capabilities: None,
                    runs: Some(runs),
                });
            }
        }
    }

    runner.shutdown().await;
    stop_runs.0 = None;
    awake.set_running(&workspace.id, 0);
    Ok(())
}

/// Agents stop even if the connection task itself is aborted.
struct StopOnDrop(Option<Arc<Runner>>);

impl Drop for StopOnDrop {
    fn drop(&mut self) {
        if let Some(runner) = self.0.take() {
            tokio::spawn(async move { runner.shutdown().await });
        }
    }
}

/// The workspace's own WebSocket, derived from its base URL.
fn websocket_url(base_url: &str, token: &str) -> String {
    let base = base_url.trim_end_matches('/');
    let base = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        format!("ws://{base}")
    };
    format!("{base}/ws?token={token}&heartbeat=1&connection=host")
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

    #[tokio::test]
    async fn reconnect_storm_keeps_one_loop_per_workspace() {
        let host = Arc::new(LocalHost::new(Arc::new(crate::awake::Keeper::default())));
        let settings = Settings {
            host_id: "host".into(),
            host_name: "Desktop".into(),
            workspaces: vec![WorkspaceSettings {
                id: "workspace".into(),
                relay_url: "http://127.0.0.1:9".into(),
                token: "token".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let gate = Arc::new(tokio::sync::Barrier::new(21));
        let mut restarts = Vec::new();
        for _ in 0..20 {
            let host = host.clone();
            let settings = settings.clone();
            let gate = gate.clone();
            restarts.push(tokio::spawn(async move {
                gate.wait().await;
                host.restart(settings).await;
            }));
        }
        gate.wait().await;
        for restart in restarts {
            restart.await.unwrap();
        }

        assert_eq!(host.stop.lock().await.len(), 1);
        host.restart(Settings::default()).await;
        assert!(host.stop.lock().await.is_empty());
    }

    #[test]
    fn websocket_urls_follow_the_relay_scheme_and_stay_inside_the_workspace() {
        assert_eq!(
            websocket_url("https://relay.example.com/w/ws1/", "abc"),
            "wss://relay.example.com/w/ws1/ws?token=abc&heartbeat=1&connection=host"
        );
        assert_eq!(
            websocket_url("http://127.0.0.1:7727/w/ws1", "abc"),
            "ws://127.0.0.1:7727/w/ws1/ws?token=abc&heartbeat=1&connection=host"
        );
    }
}
