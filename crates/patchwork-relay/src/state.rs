use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};

use anyhow::Result;
use patchwork_core::events::{Envelope, Event};
use patchwork_core::host::RelayToHost;
use patchwork_core::models::*;
use patchwork_core::{now_ms, Id, Millis};
use tokio::sync::{broadcast, mpsc, oneshot, Mutex, RwLock};

use crate::store::Store;

/// A host that is currently connected and able to take work.
pub struct HostConn {
    pub tx: mpsc::UnboundedSender<RelayToHost>,
}

#[derive(Clone)]
pub struct PendingUpload {
    pub id: Id,
    pub member_id: Id,
    pub run_id: Option<Id>,
    pub task_id: Option<Id>,
    pub file_name: String,
    pub mime: String,
    pub caption: String,
    pub size: i64,
    pub received: i64,
    pub created_at: Millis,
    pub path: PathBuf,
}

#[derive(Clone, Default)]
pub struct RunDestination {
    pub parent_id: Option<Id>,
    pub reply_to_id: Option<Id>,
}

pub enum PreviewSocketEvent {
    Ready(Option<String>),
    Data { data: String, binary: bool },
    Close,
}

pub struct PreviewReply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub error: Option<String>,
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
    /// Where each live run is talking. One value keeps thread and inline reply
    /// destinations atomic while a follow-up moves the conversation.
    pub run_destinations: RwLock<HashMap<Id, RunDestination>>,
    /// A queued follow-up changes the destination only when its ACP turn starts.
    pub control_destinations: RwLock<HashMap<Id, RunDestination>>,
    /// Short-lived capabilities for execution hosts fetching attached files.
    pub file_grants: StdMutex<HashMap<Id, (Id, Millis)>>,
    /// Browser-loadable preview URLs cannot carry a bearer header on every asset.
    pub preview_grants: StdMutex<HashMap<Id, (Id, Millis)>>,
    /// HTTP requests currently travelling to an execution host.
    pub preview_waiters: RwLock<HashMap<Id, oneshot::Sender<PreviewReply>>>,
    pub preview_sockets: RwLock<HashMap<Id, mpsc::UnboundedSender<PreviewSocketEvent>>>,
    pub uploads: Mutex<HashMap<Id, PendingUpload>>,
    pub files_dir: PathBuf,
    /// The URL desktops and agents should call back on.
    pub public_url: String,
    pub relay_host_id: Id,
    pub started_at: Millis,
}

pub type Shared = Arc<AppState>;

fn compact_id(id: &str) -> Option<String> {
    let hex = id.replace('-', "");
    if hex.len() != 32 {
        return None;
    }
    let mut value = u128::from_str_radix(&hex, 16).ok()?;
    if value == 0 {
        return Some("0".into());
    }
    let mut encoded = Vec::new();
    while value > 0 {
        encoded.push(b"0123456789abcdefghijklmnopqrstuvwxyz"[(value % 36) as usize]);
        value /= 36;
    }
    encoded.reverse();
    String::from_utf8(encoded).ok()
}

impl AppState {
    pub fn new(store: Store, files_dir: PathBuf, public_url: String, relay_host_id: Id) -> Self {
        let (bus, _) = broadcast::channel(1024);
        let _ = std::fs::remove_dir_all(files_dir.join(".uploads"));
        Self {
            store,
            bus,
            hosts: RwLock::new(HashMap::new()),
            presence: RwLock::new(HashMap::new()),
            question_waiters: RwLock::new(HashMap::new()),
            streaming_messages: RwLock::new(HashMap::new()),
            run_destinations: RwLock::new(HashMap::new()),
            control_destinations: RwLock::new(HashMap::new()),
            file_grants: StdMutex::new(HashMap::new()),
            preview_grants: StdMutex::new(HashMap::new()),
            preview_waiters: RwLock::new(HashMap::new()),
            preview_sockets: RwLock::new(HashMap::new()),
            uploads: Mutex::new(HashMap::new()),
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
    pub fn grant_file(&self, attachment: &Attachment) -> String {
        let token = patchwork_core::new_id();
        let expires = now_ms() + 2 * 60 * 60 * 1000;
        if let Ok(mut grants) = self.file_grants.lock() {
            grants.retain(|_, (_, expiry)| *expiry > now_ms());
            grants.insert(token.clone(), (attachment.id.clone(), expires));
        }
        format!("{}{}?grant={token}", self.public_url, attachment.url)
    }

    pub fn valid_file_grant(&self, attachment_id: &str, token: &str) -> bool {
        self.file_grants
            .lock()
            .ok()
            .and_then(|grants| grants.get(token).cloned())
            .is_some_and(|(id, expires)| id == attachment_id && expires > now_ms())
    }

    pub fn grant_preview(&self, preview_id: &str) -> String {
        let token = patchwork_core::new_id();
        let expires = now_ms() + 2 * 60 * 60 * 1000;
        if let Ok(mut grants) = self.preview_grants.lock() {
            grants.retain(|_, (_, expiry)| *expiry > now_ms());
            grants.insert(token.clone(), (preview_id.to_string(), expires));
        }
        token
    }

    pub fn valid_preview_grant(&self, preview_id: &str, token: &str) -> bool {
        self.preview_grants
            .lock()
            .ok()
            .and_then(|grants| grants.get(token).cloned())
            .is_some_and(|(id, expires)| id == preview_id && expires > now_ms())
    }

    pub fn preview_url(&self, preview_id: &str, grant: &str) -> String {
        let Ok(url) = reqwest::Url::parse(&self.public_url) else {
            return format!("{}/preview/{preview_id}/?grant={grant}", self.public_url);
        };
        let segments: Vec<_> = url
            .path_segments()
            .map(|segments| segments.collect())
            .unwrap_or_default();
        if segments.len() >= 4 && segments[0] == "r" && segments[2] == "w" {
            if let (Some(host), Some(relay), Some(preview)) = (
                url.host_str().and_then(|host| host.strip_prefix("relay.")),
                compact_id(segments[1]),
                compact_id(preview_id),
            ) {
                return format!(
                    "{}://p-{relay}-{preview}.{host}/?grant={grant}",
                    url.scheme()
                );
            }
        }
        format!("{}/preview/{preview_id}/?grant={grant}", self.public_url)
    }

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
            member.presence = presence
                .get(&member.id)
                .copied()
                .unwrap_or(Presence::Offline);
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

#[cfg(test)]
mod tests {
    use super::{compact_id, AppState};

    #[test]
    fn ids_fit_in_one_dns_label() {
        let relay = compact_id("80e9ceddb6d0ce1916a5f2286d067910").unwrap();
        let preview = compact_id("019fe3ec-926c-7cc2-bef6-f9c251bc3ebe").unwrap();
        assert!(format!("p-{relay}-{preview}").len() <= 63);
        assert_eq!(relay, "7mr1nww5f2hub8gu1ppwskftc");
        assert_eq!(preview, "3gnb2cxz3cqcb7oph55d4n26");
        assert_eq!(
            compact_id("00000000-0000-0000-0000-000000000001").as_deref(),
            Some("1")
        );
    }

    #[test]
    fn managed_previews_get_their_own_first_level_origin() {
        let path =
            std::env::temp_dir().join(format!("patchwork-state-{}.sqlite", uuid::Uuid::new_v4()));
        let store = crate::store::Store::open(&path).unwrap();
        store.create_workspace("workspace", "Test").unwrap();
        let files = path.with_extension("files");
        let state = AppState::new(
            store,
            files.clone(),
            "https://relay.patchwork.sh/r/80e9ceddb6d0ce1916a5f2286d067910/w/workspace".into(),
            "host".into(),
        );
        assert_eq!(
            state.preview_url("019fe3ec-926c-7cc2-bef6-f9c251bc3ebe", "secret"),
            "https://p-7mr1nww5f2hub8gu1ppwskftc-3gnb2cxz3cqcb7oph55d4n26.patchwork.sh/?grant=secret"
        );
        drop(state);
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_dir_all(files);
    }
}
