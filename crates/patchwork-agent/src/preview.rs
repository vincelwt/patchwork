//! Application previews.
//!
//! An agent starts a dev server in its worktree and exposes the port; the
//! preview, the evidence it attached, and the pull request are then shown
//! together when work is ready for review.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;

use base64::Engine;
use futures::{SinkExt, StreamExt};
use patchwork_core::host::HostToRelay;
use patchwork_core::models::PreviewStatus;
use patchwork_core::Id;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};

use crate::runner::Sink;

const MAX_BODY_BYTES: usize = 20 * 1024 * 1024;

struct Running {
    child: Option<Child>,
    port: u16,
}

enum SocketCommand {
    Data { data: String, binary: bool },
    Close,
}

struct PreviewSocket {
    preview_id: Id,
    tx: mpsc::UnboundedSender<SocketCommand>,
}

pub struct PreviewManager {
    out: Sink,
    running: Arc<Mutex<HashMap<Id, Running>>>,
    sockets: Arc<Mutex<HashMap<Id, PreviewSocket>>>,
}

impl PreviewManager {
    pub fn new(out: Sink) -> Self {
        Self {
            out,
            running: Arc::new(Mutex::new(HashMap::new())),
            sockets: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn start(
        &self,
        preview_id: Id,
        _task_id: Id,
        cwd: String,
        command: Option<String>,
        port: u16,
        _label: String,
    ) {
        let _ = self.out.send(HostToRelay::PreviewStatus {
            preview_id: preview_id.clone(),
            status: PreviewStatus::Starting,
            url: None,
            error: None,
        });

        let mut child = if let Some(command) = command {
            let mut cmd = Command::new("sh");
            cmd.arg("-lc")
                .arg(&command)
                .current_dir(&cwd)
                .env("PORT", port.to_string())
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true);
            #[cfg(unix)]
            cmd.process_group(0);
            match cmd.spawn() {
                Ok(child) => Some(child),
                Err(err) => {
                    let _ = self.out.send(HostToRelay::PreviewStatus {
                        preview_id,
                        status: PreviewStatus::Failed,
                        url: None,
                        error: Some(format!("could not start `{command}`: {err}")),
                    });
                    return;
                }
            }
        } else {
            None
        };

        // Drain output so a process Patchwork started never blocks on a full pipe.
        if let Some(stdout) = child.as_mut().and_then(|child| child.stdout.take()) {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                while let Ok(Some(_)) = lines.next_line().await {}
            });
        }
        if let Some(stderr) = child.as_mut().and_then(|child| child.stderr.take()) {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    tracing::debug!(target: "preview", "{line}");
                }
            });
        }

        self.running
            .lock()
            .await
            .insert(preview_id.clone(), Running { child, port });

        // Wait for the port to actually answer before telling anyone it is live.
        let out = self.out.clone();
        let running = self.running.clone();
        tokio::spawn(async move {
            if !wait_for_port(port, std::time::Duration::from_secs(60)).await {
                let stopped = running.lock().await.remove(&preview_id);
                if let Some(mut child) = stopped.and_then(|mut stopped| stopped.child.take()) {
                    kill_child(&mut child).await;
                }
                let _ = out.send(HostToRelay::PreviewStatus {
                    preview_id,
                    status: PreviewStatus::Failed,
                    url: None,
                    error: Some(format!("nothing was listening on port {port} after 60s")),
                });
                return;
            }
            let _ = out.send(HostToRelay::PreviewStatus {
                preview_id: preview_id.clone(),
                status: PreviewStatus::Live,
                url: Some(format!("http://127.0.0.1:{port}")),
                error: None,
            });

            let mut misses = 0;
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                if !running.lock().await.contains_key(&preview_id) {
                    return;
                }
                if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
                    misses = 0;
                    continue;
                }
                misses += 1;
                if misses < 2 {
                    continue;
                }
                let stopped = running.lock().await.remove(&preview_id);
                if let Some(mut child) = stopped.and_then(|mut stopped| stopped.child.take()) {
                    kill_child(&mut child).await;
                }
                let _ = out.send(HostToRelay::PreviewStatus {
                    preview_id,
                    status: PreviewStatus::Failed,
                    url: None,
                    error: Some(format!("nothing is listening on preview port {port}")),
                });
                return;
            }
        });
    }

    pub async fn stop(&self, preview_id: &Id) {
        let socket_ids: Vec<_> = self
            .sockets
            .lock()
            .await
            .iter()
            .filter(|(_, socket)| &socket.preview_id == preview_id)
            .map(|(id, _)| id.clone())
            .collect();
        for socket_id in socket_ids {
            self.close_socket(&socket_id).await;
        }
        let running = self.running.lock().await.remove(preview_id);
        if let Some(mut child) = running.and_then(|mut running| running.child.take()) {
            kill_child(&mut child).await;
        }
        let _ = self.out.send(HostToRelay::PreviewStatus {
            preview_id: preview_id.clone(),
            status: PreviewStatus::Stopped,
            url: None,
            error: None,
        });
    }

    pub async fn stop_all(&self) {
        let ids: Vec<Id> = self.running.lock().await.keys().cloned().collect();
        for id in ids {
            self.stop(&id).await;
        }
    }

    pub async fn port_of(&self, preview_id: &Id) -> Option<u16> {
        self.running.lock().await.get(preview_id).map(|r| r.port)
    }

    pub async fn request(
        &self,
        request_id: Id,
        preview_id: Id,
        method: String,
        path: String,
        headers: Vec<(String, String)>,
        body: String,
    ) {
        let result = async {
            let port = self
                .port_of(&preview_id)
                .await
                .ok_or_else(|| anyhow::anyhow!("preview is not running on this host"))?;
            let body = base64::engine::general_purpose::STANDARD.decode(body)?;
            if body.len() > MAX_BODY_BYTES {
                anyhow::bail!("preview request exceeds 20 MB");
            }
            let client = reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()?;
            let mut request = client
                .request(method.parse()?, format!("http://127.0.0.1:{port}{path}"))
                .body(body);
            for (name, value) in headers {
                let lower = name.to_ascii_lowercase();
                if matches!(
                    lower.as_str(),
                    "authorization"
                        | "connection"
                        | "content-length"
                        | "host"
                        | "proxy-authorization"
                        | "transfer-encoding"
                        | "upgrade"
                ) {
                    continue;
                }
                request = request.header(name, local_header_value(&lower, &value, port));
            }
            let response = request.send().await?;
            let status = response.status().as_u16();
            let headers = response
                .headers()
                .iter()
                .filter(|(name, _)| {
                    !matches!(
                        name.as_str(),
                        "connection" | "content-length" | "transfer-encoding" | "upgrade"
                    )
                })
                .filter_map(|(name, value)| {
                    value
                        .to_str()
                        .ok()
                        .map(|value| (name.to_string(), value.to_string()))
                })
                .collect();
            let body = base64::engine::general_purpose::STANDARD
                .encode(bounded_body(response, MAX_BODY_BYTES).await?);
            Ok::<_, anyhow::Error>((status, headers, body))
        }
        .await;

        let (status, headers, body, error) = match result {
            Ok((status, headers, body)) => (status, headers, body, None),
            Err(error) => (502, Vec::new(), String::new(), Some(format!("{error:#}"))),
        };
        let _ = self.out.send(HostToRelay::PreviewResponse {
            request_id,
            status,
            headers,
            body,
            error,
        });
    }

    pub async fn open_socket(
        &self,
        socket_id: Id,
        preview_id: Id,
        path: String,
        headers: Vec<(String, String)>,
    ) {
        let Some(port) = self.port_of(&preview_id).await else {
            let _ = self.out.send(HostToRelay::PreviewSocketReady {
                socket_id,
                error: Some("preview is not running on this host".into()),
            });
            return;
        };
        let mut request = match format!("ws://127.0.0.1:{port}{path}").into_client_request() {
            Ok(request) => request,
            Err(error) => {
                let _ = self.out.send(HostToRelay::PreviewSocketReady {
                    socket_id,
                    error: Some(error.to_string()),
                });
                return;
            }
        };
        for (name, value) in headers {
            let lower = name.to_ascii_lowercase();
            if matches!(
                lower.as_str(),
                "authorization"
                    | "connection"
                    | "host"
                    | "proxy-authorization"
                    | "sec-websocket-accept"
                    | "sec-websocket-key"
                    | "sec-websocket-version"
                    | "upgrade"
            ) {
                continue;
            }
            if let (Ok(name), Ok(value)) = (
                tokio_tungstenite::tungstenite::http::HeaderName::try_from(name),
                tokio_tungstenite::tungstenite::http::HeaderValue::try_from(value),
            ) {
                let value = local_header_value(&lower, value.to_str().unwrap_or_default(), port);
                if let Ok(value) = tokio_tungstenite::tungstenite::http::HeaderValue::try_from(value) {
                    request.headers_mut().insert(name, value);
                }
            }
        }
        let (socket, _) = match tokio_tungstenite::connect_async(request).await {
            Ok(socket) => socket,
            Err(error) => {
                let _ = self.out.send(HostToRelay::PreviewSocketReady {
                    socket_id,
                    error: Some(error.to_string()),
                });
                return;
            }
        };
        let (tx, mut rx) = mpsc::unbounded_channel();
        self.sockets.lock().await.insert(
            socket_id.clone(),
            PreviewSocket {
                preview_id,
                tx,
            },
        );
        let _ = self.out.send(HostToRelay::PreviewSocketReady {
            socket_id: socket_id.clone(),
            error: None,
        });

        let out = self.out.clone();
        let sockets = self.sockets.clone();
        tokio::spawn(async move {
            let (mut writer, mut reader) = socket.split();
            loop {
                tokio::select! {
                    incoming = reader.next() => {
                        match incoming {
                            Some(Ok(Message::Text(data))) => {
                                let _ = out.send(HostToRelay::PreviewSocketData {
                                    socket_id: socket_id.clone(),
                                    data: data.to_string(),
                                    binary: false,
                                });
                            }
                            Some(Ok(Message::Binary(data))) => {
                                let _ = out.send(HostToRelay::PreviewSocketData {
                                    socket_id: socket_id.clone(),
                                    data: base64::engine::general_purpose::STANDARD.encode(data),
                                    binary: true,
                                });
                            }
                            Some(Ok(Message::Ping(data))) => {
                                let _ = writer.send(Message::Pong(data)).await;
                            }
                            Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                            _ => {}
                        }
                    }
                    command = rx.recv() => {
                        match command {
                            Some(SocketCommand::Data { data, binary: false }) => {
                                if writer.send(Message::Text(data.into())).await.is_err() { break; }
                            }
                            Some(SocketCommand::Data { data, binary: true }) => {
                                let Ok(data) = base64::engine::general_purpose::STANDARD.decode(data) else { break };
                                if writer.send(Message::Binary(data.into())).await.is_err() { break; }
                            }
                            Some(SocketCommand::Close) | None => break,
                        }
                    }
                }
            }
            sockets.lock().await.remove(&socket_id);
            let _ = out.send(HostToRelay::PreviewSocketClose { socket_id });
        });
    }

    pub async fn socket_data(&self, socket_id: &Id, data: String, binary: bool) {
        if let Some(socket) = self.sockets.lock().await.get(socket_id) {
            let _ = socket.tx.send(SocketCommand::Data { data, binary });
        }
    }

    pub async fn close_socket(&self, socket_id: &Id) {
        if let Some(socket) = self.sockets.lock().await.remove(socket_id) {
            let _ = socket.tx.send(SocketCommand::Close);
        }
    }
}

fn local_header_value(name: &str, value: &str, port: u16) -> String {
    if name == "origin" {
        return format!("http://127.0.0.1:{port}");
    }
    if name == "referer" {
        return reqwest::Url::parse(value)
            .ok()
            .map(|url| {
                format!(
                    "http://127.0.0.1:{port}{}{}",
                    url.path(),
                    url.query()
                        .map(|query| format!("?{query}"))
                        .unwrap_or_default()
                )
            })
            .unwrap_or_else(|| format!("http://127.0.0.1:{port}/"));
    }
    value.to_string()
}

async fn kill_child(child: &mut Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        // The shell, package runner, and dev server all belong to this group.
        unsafe {
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
        let _ = child.wait().await;
        return;
    }
    let _ = child.start_kill();
    let _ = child.wait().await;
}

async fn bounded_body(response: reqwest::Response, limit: usize) -> anyhow::Result<Vec<u8>> {
    if response.content_length().is_some_and(|size| size > limit as u64) {
        anyhow::bail!("preview response exceeds 20 MB");
    }
    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len() + chunk.len() > limit {
            anyhow::bail!("preview response exceeds 20 MB");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn wait_for_port(port: u16, timeout: std::time::Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    }
}

/// Pick a free port for a preview, starting from the project's preferred one.
pub async fn pick_port(preferred: Option<u16>) -> u16 {
    if let Some(p) = preferred {
        if tokio::net::TcpListener::bind(("127.0.0.1", p)).await.is_ok() {
            return p;
        }
    }
    for port in 4300u16..4400 {
        if tokio::net::TcpListener::bind(("127.0.0.1", port)).await.is_ok() {
            return port;
        }
    }
    4399
}

#[cfg(test)]
mod tests {
    use super::local_header_value;

    #[test]
    fn public_origins_are_local_at_the_dev_server() {
        assert_eq!(
            local_header_value("origin", "https://preview.example", 5173),
            "http://127.0.0.1:5173"
        );
        assert_eq!(
            local_header_value("referer", "https://preview.example/cart?q=hat", 5173),
            "http://127.0.0.1:5173/cart?q=hat"
        );
    }
}
