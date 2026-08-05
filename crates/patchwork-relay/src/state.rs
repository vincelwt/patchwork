use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Result;
use patchwork_core::events::{Envelope, Event};
use patchwork_core::host::RelayToHost;
use patchwork_core::models::*;
use patchwork_core::{now_ms, Id, Millis};
use tokio::sync::{broadcast, mpsc, oneshot, RwLock};

use crate::store::Store;

/// A host that is currently connected and able to take work.
pub struct HostConn {
    pub tx: mpsc::UnboundedSender<RelayToHost>,
}

pub struct AppState {
    pub store: Store,
    pub bus: broadcast::Sender<Envelope>,
    pub hosts: RwLock<HashMap<Id, HostConn>>,
    pub presence: RwLock<HashMap<Id, Presence>>,
    /// Agents waiting inside a blocking `patchwork ask`.
    pub question_waiters: RwLock<HashMap<Id, Vec<oneshot::Sender<Question>>>>,
    /// Replies still being written, by run: the message the next delta rewrites.
    pub streaming_messages: RwLock<HashMap<Id, Id>>,
    /// Where each live run is talking: the thread it was asked in, or `None`
    /// for the channel itself. A follow-up can move it, which is why this is
    /// not read off the run's trigger. Runs do not outlive the process, so
    /// neither does this.
    pub run_threads: RwLock<HashMap<Id, Option<Id>>>,
    pub files_dir: PathBuf,
    /// The URL desktops and agents should call back on.
    pub public_url: String,
    pub relay_host_id: Id,
    pub started_at: Millis,
}

pub type Shared = Arc<AppState>;

impl AppState {
    pub fn new(store: Store, files_dir: PathBuf, public_url: String, relay_host_id: Id) -> Self {
        let (bus, _) = broadcast::channel(1024);
        Self {
            store,
            bus,
            hosts: RwLock::new(HashMap::new()),
            presence: RwLock::new(HashMap::new()),
            question_waiters: RwLock::new(HashMap::new()),
            streaming_messages: RwLock::new(HashMap::new()),
            run_threads: RwLock::new(HashMap::new()),
            files_dir,
            public_url,
            relay_host_id,
            started_at: now_ms(),
        }
    }

    /// Persist an event and fan it out to every connected client.
    pub fn emit(&self, event: Event) {
        match self.store.append_event(&event) {
            Ok(envelope) => {
                let _ = self.bus.send(envelope);
            }
            Err(err) => tracing::error!(?err, "failed to persist event"),
        }
    }

    /// Ephemeral events (typing, presence) skip the durable log.
    pub fn emit_transient(&self, event: Event) {
        let _ = self.bus.send(Envelope {
            seq: -1,
            at: now_ms(),
            event,
        });
    }

    pub async fn send_to_host(&self, host_id: &str, msg: RelayToHost) -> bool {
        let hosts = self.hosts.read().await;
        match hosts.get(host_id) {
            Some(conn) => conn.tx.send(msg).is_ok(),
            None => false,
        }
    }

    pub async fn host_online(&self, host_id: &str) -> bool {
        self.hosts.read().await.contains_key(host_id)
    }

    pub async fn online_host_ids(&self) -> Vec<Id> {
        self.hosts.read().await.keys().cloned().collect()
    }

    /// Hosts as stored, with live connection state merged in.
    pub async fn hosts_with_presence(&self) -> Result<Vec<Host>> {
        let online = self.online_host_ids().await;
        let mut hosts = self.store.hosts()?;
        for host in &mut hosts {
            host.online = online.contains(&host.id);
        }
        Ok(hosts)
    }

    pub async fn members_with_presence(&self) -> Result<Vec<Member>> {
        let presence = self.presence.read().await;
        let mut members = self.store.members()?;
        for member in &mut members {
            member.presence = presence.get(&member.id).copied().unwrap_or(Presence::Offline);
        }
        Ok(members)
    }

    pub async fn set_presence(&self, member_id: &str, presence: Presence) {
        let changed = {
            let mut map = self.presence.write().await;
            let previous = map.insert(member_id.to_string(), presence);
            previous != Some(presence)
        };
        if changed {
            self.emit_transient(Event::PresenceChanged {
                member_id: member_id.to_string(),
                presence,
            });
        }
    }

    /// Wake an agent blocked in `patchwork ask`.
    pub async fn resolve_question(&self, question: &Question) {
        let waiters = self.question_waiters.write().await.remove(&question.id);
        for tx in waiters.unwrap_or_default() {
            let _ = tx.send(question.clone());
        }
    }

    pub async fn wait_for_answer(&self, question_id: &str) -> oneshot::Receiver<Question> {
        let (tx, rx) = oneshot::channel();
        self.question_waiters
            .write()
            .await
            .entry(question_id.to_string())
            .or_default()
            .push(tx);
        rx
    }
}
