//! The realtime connection.
//!
//! One socket carries both halves of a Desktop: the collaboration stream a
//! person sees, and the execution channel its local agents run on. A relay-only
//! client simply never sends host messages.

use std::collections::HashMap;

use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::response::IntoResponse;
use futures::{SinkExt, StreamExt};
use patchwork_core::events::{Envelope, Event};
use patchwork_core::host::{HostToRelay, RelayToHost};
use patchwork_core::models::{Host, Presence, PreviewStatus};
use patchwork_core::{now_ms, Id};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::auth;
use crate::orchestrator;
use crate::state::{HostConn, Shared};

#[derive(Debug, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
enum ClientMsg {
    Heartbeat,
    /// Catch up on everything after `since`, then stream live.
    Resume { since: i64 },
    Typing { channel_id: Id },
    Presence { presence: Presence },
    /// This connection is also an execution host.
    Host { msg: HostToRelay },
}

#[derive(Debug, Serialize)]
#[serde(tag = "t", rename_all = "snake_case")]
enum ServerMsg {
    Heartbeat,
    Ready { seq: i64 },
    Event { envelope: Envelope },
    Host { msg: RelayToHost },
    Error { message: String },
}

#[derive(Debug, Deserialize)]
pub struct WsQuery {
    token: String,
    #[serde(default)]
    since: Option<i64>,
}

pub async fn handler(
    ws: WebSocketUpgrade,
    State(state): State<Shared>,
    Query(query): Query<WsQuery>,
) -> impl IntoResponse {
    let Some(caller) = auth::authenticate(&state, &query.token) else {
        return (axum::http::StatusCode::UNAUTHORIZED, "invalid token").into_response();
    };
    let can_host = caller.can_host();
    ws.on_upgrade(move |socket| {
        connection(socket, state, caller.member.id, query.since, can_host)
    })
}

async fn connection(
    socket: WebSocket,
    state: Shared,
    member_id: Id,
    since: Option<i64>,
    can_host: bool,
) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<ServerMsg>();

    // Subscribe before taking the replay boundary. A durable event can land at
    // any point during the handshake; the log supplies everything through
    // `latest`, and the receiver already holds everything after it.
    let mut bus = state.bus.subscribe();
    let latest = state.store.latest_seq().unwrap_or(0);
    if let Some(since) = since {
        if since < latest {
            // The log is retained at roughly 5,000 events, so the upper bound
            // covers the complete catch-up window (including a workspace whose
            // first bootstrap legitimately returned sequence zero).
            if let Ok(missed) = state.store.events_since(since, 10_000) {
                for envelope in missed.into_iter().filter(|event| event.seq <= latest) {
                    if crate::visibility::event(&state.store, &member_id, &envelope) {
                        let _ = tx.send(ServerMsg::Event { envelope });
                    }
                }
            }
        }
    }
    let _ = tx.send(ServerMsg::Ready { seq: latest });

    let bus_tx = tx.clone();
    let bus_state = state.clone();
    let bus_member_id = member_id.clone();
    let bus_task = tokio::spawn(async move {
        loop {
            match bus.recv().await {
                Ok(envelope) => {
                    // Events at or below the boundary were just replayed from
                    // the durable log. Transient events have a negative seq and
                    // are never in that log, so they still pass through.
                    if envelope.seq > 0 && envelope.seq <= latest {
                        continue;
                    }
                    if crate::visibility::event(&bus_state.store, &bus_member_id, &envelope)
                        && bus_tx.send(ServerMsg::Event { envelope }).is_err()
                    {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    });

    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            let Ok(text) = serde_json::to_string(&msg) else {
                continue;
            };
            if sink.send(WsMessage::Text(text.into())).await.is_err() {
                break;
            }
        }
    });

    state.set_presence(&member_id, Presence::Online).await;

    // Hosts this connection registered, so we can clean them up on disconnect.
    let mut registered: Vec<Id> = Vec::new();
    let (host_tx, mut host_rx) = mpsc::unbounded_channel::<RelayToHost>();
    let host_pump = {
        let tx = tx.clone();
        tokio::spawn(async move {
            while let Some(msg) = host_rx.recv().await {
                if tx.send(ServerMsg::Host { msg }).is_err() {
                    break;
                }
            }
        })
    };

    while let Some(Ok(raw)) = stream.next().await {
        let text = match raw {
            WsMessage::Text(text) => text.to_string(),
            WsMessage::Close(_) => break,
            WsMessage::Ping(_) | WsMessage::Pong(_) | WsMessage::Binary(_) => continue,
        };
        let msg: ClientMsg = match serde_json::from_str(&text) {
            Ok(msg) => msg,
            Err(err) => {
                let _ = tx.send(ServerMsg::Error {
                    message: format!("could not parse message: {err}"),
                });
                continue;
            }
        };

        match msg {
            ClientMsg::Heartbeat => {
                let _ = tx.send(ServerMsg::Heartbeat);
            }
            ClientMsg::Resume { since } => {
                if let Ok(missed) = state.store.events_since(since, 2000) {
                    for envelope in missed {
                        if crate::visibility::event(&state.store, &member_id, &envelope) {
                            let _ = tx.send(ServerMsg::Event { envelope });
                        }
                    }
                }
            }
            ClientMsg::Typing { channel_id } => {
                if crate::visibility::channel(&state.store, &member_id, &channel_id)
                    .unwrap_or(false)
                {
                    state.emit_transient(Event::Typing {
                        channel_id,
                        member_id: member_id.clone(),
                    });
                }
            }
            ClientMsg::Presence { presence } => {
                state.set_presence(&member_id, presence).await;
            }
            ClientMsg::Host { msg } => {
                if !can_host {
                    let _ = tx.send(ServerMsg::Error {
                        message: "this device cannot execute agents".into(),
                    });
                    continue;
                }
                if let HostToRelay::Register { registration } = &msg {
                    let host_id = registration.host_id.clone();
                    let mut capabilities = registration.capabilities.clone();
                    // Detection can tell us a runtime is installed; only the
                    // runtime itself can say what it can run, and it only says
                    // so when a session opens. Re-registering must not throw
                    // that away — a reconnect would otherwise empty every model
                    // picker in the workspace until the next run.
                    if let Ok(Some(previous)) = state.store.host(&host_id) {
                        for runtime in &mut capabilities.runtimes {
                            let Some(known) = previous
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
                    }
                    let host = Host {
                        id: host_id.clone(),
                        name: registration.name.clone(),
                        kind: registration.kind,
                        platform: registration.platform.clone(),
                        owner_id: Some(member_id.clone()),
                        online: true,
                        last_seen: now_ms(),
                        capabilities,
                        created_at: now_ms(),
                    };
                    if let Err(err) = state.store.upsert_host(&host) {
                        tracing::warn!(?err, "could not store host");
                        continue;
                    }
                    merge_project_paths(&state, &host_id, &registration.project_paths);

                    state.hosts.write().await.insert(
                        host_id.clone(),
                        HostConn {
                            tx: host_tx.clone(),
                        },
                    );
                    registered.push(host_id.clone());
                    state.emit(Event::HostUpdated { host });
                    continue;
                }

                let Some(host_id) = registered.first().cloned() else {
                    let _ = tx.send(ServerMsg::Error {
                        message: "register this host before sending run messages".into(),
                    });
                    continue;
                };
                orchestrator::handle_host_message(&state, &host_id, msg).await;
            }
        }
    }

    // Teardown.
    for host_id in registered {
        state.hosts.write().await.remove(&host_id);
        fail_host_previews(&state, &host_id);
        if let Ok(Some(mut host)) = state.store.host(&host_id) {
            host.online = false;
            host.last_seen = now_ms();
            let _ = state.store.upsert_host(&host);
            state.emit(Event::HostUpdated { host });
        }
    }
    state.set_presence(&member_id, Presence::Offline).await;
    bus_task.abort();
    host_pump.abort();
    writer.abort();
}

fn fail_host_previews(state: &Shared, host_id: &str) {
    let Ok(previews) = state.store.previews(true) else {
        return;
    };
    for mut preview in previews.into_iter().filter(|preview| preview.host_id == host_id) {
        preview.status = PreviewStatus::Failed;
        preview.stopped_at = Some(now_ms());
        if state.store.upsert_preview(&preview).is_ok() {
            state.emit(Event::PreviewUpdated { preview });
        }
    }
}

/// A desktop tells us where each project lives on it; that is how "run it
/// wherever the project is available" can work at all.
fn merge_project_paths(state: &Shared, host_id: &str, paths: &std::collections::BTreeMap<Id, String>) {
    if paths.is_empty() {
        return;
    }
    let Ok(projects) = state.store.projects() else {
        return;
    };
    let by_id: HashMap<Id, _> = projects.into_iter().map(|p| (p.id.clone(), p)).collect();
    for (project_id, path) in paths {
        let Some(project) = by_id.get(project_id) else {
            continue;
        };
        if project.paths.get(host_id) == Some(path) {
            continue;
        }
        let mut project = project.clone();
        project.paths.insert(host_id.to_string(), path.clone());
        if state.store.upsert_project(&project).is_ok() {
            state.emit(Event::ProjectUpdated { project });
        }
    }
}

/// The relay's own execution host: hosted agents keep working when every
/// laptop is closed.
pub fn register_relay_host(state: &Shared, tx: mpsc::UnboundedSender<RelayToHost>) {
    let host_id = state.relay_host_id.clone();
    tokio::spawn({
        let state = state.clone();
        async move {
            state.hosts.write().await.insert(
                host_id.clone(),
                HostConn { tx },
            );
            if let Ok(Some(mut host)) = state.store.host(&host_id) {
                host.online = true;
                host.last_seen = now_ms();
                let _ = state.store.upsert_host(&host);
                state.emit(Event::HostUpdated { host });
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heartbeat_wire_shape_is_stable() {
        assert!(matches!(
            serde_json::from_str::<ClientMsg>(r#"{"t":"heartbeat"}"#).unwrap(),
            ClientMsg::Heartbeat
        ));
        assert_eq!(
            serde_json::to_string(&ServerMsg::Heartbeat).unwrap(),
            r#"{"t":"heartbeat"}"#
        );
    }
}
