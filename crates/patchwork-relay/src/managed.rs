//! Zero-configuration public ingress through the open-source Cloudflare broker.
//!
//! The relay owns all data and execution. This connector only keeps one
//! outbound WebSocket open and turns broker frames back into loopback HTTP and
//! WebSocket calls, so no inbound port, domain, or certificate is needed.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use base64::Engine;
use futures::{SinkExt, StreamExt};
use rand::RngCore;
use reqwest::header::{HeaderName, HeaderValue};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};

const MAX_BODY_BYTES: usize = 20 * 1024 * 1024;
const IDENTITY_FILE: &str = "managed-relay.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Identity {
    relay_id: String,
    host_token: String,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum BrokerFrame {
    Request {
        id: String,
        method: String,
        path: String,
        headers: Vec<(String, String)>,
        body: String,
    },
    SocketOpen {
        id: String,
        path: String,
        headers: Vec<(String, String)>,
    },
    SocketData {
        id: String,
        data: String,
    },
    SocketClose {
        id: String,
        code: Option<u16>,
        reason: Option<String>,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum HostFrame {
    Response {
        id: String,
        status: u16,
        headers: Vec<(String, String)>,
        body: String,
    },
    SocketReady {
        id: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        status: Option<u16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    SocketData {
        id: String,
        data: String,
    },
    SocketClose {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<u16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
}

#[derive(Debug)]
enum SocketCommand {
    Data(String),
    Close(Option<u16>, Option<String>),
}

pub struct Connector {
    pub public_url: String,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Connector {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Connector {
    pub async fn start(data_dir: &Path, broker_url: &str, local_url: String) -> Result<Self> {
        let broker_url = broker_url.trim_end_matches('/').to_string();
        let parsed = reqwest::Url::parse(&broker_url).context("invalid managed relay URL")?;
        let local_development = parsed.scheme() == "http"
            && matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "::1"));
        if parsed.scheme() != "https" && !local_development {
            bail!("managed relay URL must use HTTPS");
        }
        let identity = load_or_create(data_dir)?;
        let public_url = format!("{broker_url}/r/{}", identity.relay_id);
        let task = tokio::spawn(run_forever(broker_url, local_url, identity));
        Ok(Self { public_url, task })
    }

    pub fn stop(self) {
        self.task.abort();
    }
}

async fn run_forever(broker_url: String, local_url: String, identity: Identity) {
    let mut delay = Duration::from_secs(1);
    loop {
        match run_once(&broker_url, &local_url, &identity).await {
            Ok(()) => tracing::warn!("managed relay connection closed"),
            Err(err) => tracing::warn!(?err, "managed relay connection failed"),
        }
        tokio::time::sleep(delay).await;
        delay = (delay * 2).min(Duration::from_secs(20));
    }
}

async fn run_once(broker_url: &str, local_url: &str, identity: &Identity) -> Result<()> {
    let mut url = reqwest::Url::parse(broker_url)?;
    url.set_scheme(if url.scheme() == "https" { "wss" } else { "ws" })
        .map_err(|_| anyhow::anyhow!("invalid managed relay scheme"))?;
    url.set_path(&format!("/connect/{}", identity.relay_id));
    url.set_query(None);

    let mut request = url.as_str().into_client_request()?;
    request.headers_mut().insert(
        "authorization",
        HeaderValue::from_str(&format!("Bearer {}", identity.host_token))?,
    );
    let (socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .context("could not connect to managed relay")?;
    tracing::info!(public = %format!("{broker_url}/r/{}", identity.relay_id), "managed relay connected");

    let (mut writer, mut reader) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<HostFrame>();
    let sockets = Arc::new(Mutex::new(HashMap::<
        String,
        mpsc::UnboundedSender<SocketCommand>,
    >::new()));
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()?;

    loop {
        tokio::select! {
            outgoing = out_rx.recv() => {
                let Some(outgoing) = outgoing else { break };
                writer.send(Message::Text(serde_json::to_string(&outgoing)?.into())).await?;
            }
            incoming = reader.next() => {
                let Some(incoming) = incoming else { break };
                match incoming? {
                    Message::Text(text) => {
                        let frame: BrokerFrame = serde_json::from_str(&text).context("invalid managed relay frame")?;
                        handle_frame(frame, local_url, &client, &out_tx, &sockets).await;
                    }
                    Message::Ping(data) => writer.send(Message::Pong(data)).await?,
                    Message::Close(_) => break,
                    _ => {}
                }
            }
        }
    }
    sockets.lock().await.clear();
    Ok(())
}

async fn handle_frame(
    frame: BrokerFrame,
    local_url: &str,
    client: &reqwest::Client,
    out: &mpsc::UnboundedSender<HostFrame>,
    sockets: &Arc<Mutex<HashMap<String, mpsc::UnboundedSender<SocketCommand>>>>,
) {
    match frame {
        BrokerFrame::Request {
            id,
            method,
            path,
            headers,
            body,
        } => {
            let client = client.clone();
            let local_url = local_url.to_string();
            let out = out.clone();
            tokio::spawn(async move {
                let response =
                    proxy_request(&client, &local_url, &method, &path, headers, &body).await;
                let frame = match response {
                    Ok((status, headers, body)) => HostFrame::Response { id, status, headers, body },
                    Err(err) => HostFrame::Response {
                        id,
                        status: 502,
                        headers: vec![("content-type".into(), "application/json".into())],
                        body: base64::engine::general_purpose::STANDARD.encode(
                            serde_json::json!({ "error": { "message": format!("managed relay proxy failed: {err}") } }).to_string(),
                        ),
                    },
                };
                let _ = out.send(frame);
            });
        }
        BrokerFrame::SocketOpen { id, path, headers } => {
            let local_url = local_url.to_string();
            let out = out.clone();
            let sockets = sockets.clone();
            tokio::spawn(async move {
                open_socket(id, local_url, path, headers, out, sockets).await;
            });
        }
        BrokerFrame::SocketData { id, data } => {
            if let Some(socket) = sockets.lock().await.get(&id).cloned() {
                let _ = socket.send(SocketCommand::Data(data));
            }
        }
        BrokerFrame::SocketClose { id, code, reason } => {
            if let Some(socket) = sockets.lock().await.remove(&id) {
                let _ = socket.send(SocketCommand::Close(code, reason));
            }
        }
    }
}

async fn proxy_request(
    client: &reqwest::Client,
    local_url: &str,
    method: &str,
    path: &str,
    headers: Vec<(String, String)>,
    body: &str,
) -> Result<(u16, Vec<(String, String)>, String)> {
    let url = local_target(local_url, path)?;
    let body = base64::engine::general_purpose::STANDARD
        .decode(body)
        .context("invalid request body")?;
    if body.len() > MAX_BODY_BYTES {
        bail!("request exceeds 20 MB managed relay limit");
    }

    let mut request = client.request(method.parse()?, url).body(body);
    for (name, value) in headers {
        if let (Ok(name), Ok(value)) = (HeaderName::try_from(name), HeaderValue::from_str(&value)) {
            request = request.header(name, value);
        }
    }
    let response = request.send().await?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|value| (name.to_string(), value.to_string()))
        })
        .collect();
    let body = response.bytes().await?;
    if body.len() > MAX_BODY_BYTES {
        bail!("response exceeds 20 MB managed relay limit");
    }
    Ok((
        status,
        headers,
        base64::engine::general_purpose::STANDARD.encode(body),
    ))
}

async fn open_socket(
    id: String,
    local_url: String,
    path: String,
    headers: Vec<(String, String)>,
    out: mpsc::UnboundedSender<HostFrame>,
    sockets: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<SocketCommand>>>>,
) {
    let connection = async {
        let local_url = local_url
            .replacen("http://", "ws://", 1)
            .replacen("https://", "wss://", 1);
        let mut request = local_target(&local_url, &path)?.into_client_request()?;
        for (name, value) in headers {
            if let (Ok(name), Ok(value)) =
                (HeaderName::try_from(name), HeaderValue::from_str(&value))
            {
                request.headers_mut().insert(name, value);
            }
        }
        tokio_tungstenite::connect_async(request)
            .await
            .map_err(anyhow::Error::from)
    }
    .await;

    let (socket, response) = match connection {
        Ok(connection) => connection,
        Err(err) => {
            let _ = out.send(HostFrame::SocketReady {
                id,
                ok: false,
                status: Some(502),
                error: Some(format!("could not open local relay WebSocket: {err}")),
            });
            return;
        }
    };

    let (mut writer, mut reader) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel();
    sockets.lock().await.insert(id.clone(), tx);
    let _ = out.send(HostFrame::SocketReady {
        id: id.clone(),
        ok: true,
        status: Some(response.status().as_u16()),
        error: None,
    });

    let mut close_reported = false;
    let result: Result<()> = async {
        loop {
            tokio::select! {
                command = rx.recv() => match command {
                    Some(SocketCommand::Data(data)) => writer.send(Message::Text(data.into())).await?,
                    Some(SocketCommand::Close(code, reason)) => {
                        let frame = tokio_tungstenite::tungstenite::protocol::CloseFrame {
                            code: code.unwrap_or(1000).into(),
                            reason: reason.unwrap_or_default().into(),
                        };
                        writer.send(Message::Close(Some(frame))).await?;
                        break;
                    }
                    None => break,
                },
                message = reader.next() => match message {
                    Some(Ok(Message::Text(data))) => {
                        let _ = out.send(HostFrame::SocketData { id: id.clone(), data: data.to_string() });
                    }
                    Some(Ok(Message::Close(frame))) => {
                        close_reported = true;
                        let _ = out.send(HostFrame::SocketClose {
                            id: id.clone(),
                            code: frame.as_ref().map(|frame| frame.code.into()),
                            reason: frame.map(|frame| frame.reason.to_string()),
                        });
                        break;
                    }
                    Some(Ok(Message::Ping(data))) => writer.send(Message::Pong(data)).await?,
                    Some(Ok(_)) => {}
                    Some(Err(err)) => return Err(err.into()),
                    None => break,
                }
            }
        }
        Ok(())
    }
    .await;

    sockets.lock().await.remove(&id);
    if !close_reported {
        let (code, reason) = match result {
            Ok(()) => (1000, "Local relay closed".to_string()),
            Err(err) => (1011, format!("Local relay WebSocket failed: {err}")),
        };
        let _ = out.send(HostFrame::SocketClose {
            id,
            code: Some(code),
            reason: Some(reason),
        });
    }
}

fn local_target(local_url: &str, path: &str) -> Result<String> {
    if !path.starts_with('/') || path.starts_with("//") || path.contains(['\r', '\n']) {
        bail!("invalid proxy path");
    }
    Ok(format!("{}{}", local_url.trim_end_matches('/'), path))
}

fn load_or_create(data_dir: &Path) -> Result<Identity> {
    std::fs::create_dir_all(data_dir)?;
    let path = identity_path(data_dir);
    if let Ok(text) = std::fs::read_to_string(&path) {
        let identity: Identity =
            serde_json::from_str(&text).context("invalid managed relay identity")?;
        if identity.relay_id.len() == 32
            && identity
                .relay_id
                .chars()
                .all(|character| character.is_ascii_hexdigit() && !character.is_ascii_uppercase())
            && identity.host_token.len() == 43
            && identity.host_token.chars().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '-' | '_')
            })
        {
            return Ok(identity);
        }
        bail!("invalid managed relay identity");
    }

    let mut id = [0u8; 16];
    let mut token = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut id);
    rand::thread_rng().fill_bytes(&mut token);
    let identity = Identity {
        relay_id: id.iter().map(|byte| format!("{byte:02x}")).collect(),
        host_token: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(token),
    };
    std::fs::write(&path, serde_json::to_vec_pretty(&identity)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(identity)
}

fn identity_path(data_dir: &Path) -> PathBuf {
    data_dir.join(IDENTITY_FILE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_stable_private_and_targets_stay_local() {
        let dir = std::env::temp_dir().join(format!("patchwork-managed-{}", uuid::Uuid::new_v4()));
        let first = load_or_create(&dir).unwrap();
        let second = load_or_create(&dir).unwrap();
        assert_eq!(first.relay_id, second.relay_id);
        assert_eq!(first.host_token, second.host_token);
        assert_eq!(first.relay_id.len(), 32);
        assert_eq!(first.host_token.len(), 43);
        assert_eq!(
            local_target("http://127.0.0.1:7727", "/api/health?x=1").unwrap(),
            "http://127.0.0.1:7727/api/health?x=1"
        );
        assert!(local_target("http://127.0.0.1:7727", "https://evil.example").is_err());
        assert!(local_target("http://127.0.0.1:7727", "//evil.example").is_err());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(identity_path(&dir))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        let _ = std::fs::remove_dir_all(dir);
    }
}
