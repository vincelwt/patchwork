//! A minimal, streaming Agent Client Protocol client.
//!
//! ACP is JSON-RPC 2.0 over a child process's stdio. We speak it directly
//! rather than through a framework because Patchwork needs every `session/update`
//! the moment it arrives, and needs to answer the agent's own requests
//! (permissions, file reads) while a prompt turn is still in flight.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, Mutex};

pub const PROTOCOL_VERSION: u32 = 1;

/// A notification or request coming *from* the agent.
#[derive(Debug, Clone)]
pub enum AgentEvent {
    /// `session/update` — the streaming heart of ACP.
    SessionUpdate { session_id: String, update: Value },
    /// The agent asked for permission to run a tool.
    PermissionRequest {
        request_id: Value,
        session_id: String,
        tool_call: Value,
        options: Vec<PermissionOption>,
    },
    /// The child wrote to stderr. Useful for setup failures.
    Stderr(String),
    /// The child exited.
    Exited(Option<i32>),
}

#[derive(Debug, Clone, serde::Deserialize)]
pub struct PermissionOption {
    #[serde(rename = "optionId")]
    pub option_id: String,
    #[serde(default)]
    pub name: String,
    /// `allow_once`, `allow_always`, `reject_once`, `reject_always`.
    #[serde(default)]
    pub kind: String,
}

struct Pending(Mutex<HashMap<i64, oneshot::Sender<Result<Value, String>>>>);

pub struct AcpConnection {
    child: Child,
    stdin_tx: mpsc::UnboundedSender<String>,
    pending: Arc<Pending>,
    next_id: AtomicI64,
    pub agent_capabilities: Value,
    pub auth_methods: Vec<Value>,
}

impl AcpConnection {
    /// Spawn an ACP agent and complete the `initialize` handshake.
    pub async fn spawn(
        command: &[String],
        cwd: &str,
        env: &[(String, String)],
    ) -> Result<(Self, mpsc::UnboundedReceiver<AgentEvent>)> {
        let (program, args) = command
            .split_first()
            .ok_or_else(|| anyhow!("empty agent command"))?;

        let mut cmd = Command::new(program);
        cmd.args(args)
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        for (k, v) in env {
            cmd.env(k, v);
        }

        let mut child = cmd
            .spawn()
            .with_context(|| format!("failed to start agent `{program}`"))?;

        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");

        let (stdin_tx, mut stdin_rx) = mpsc::unbounded_channel::<String>();
        tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(line) = stdin_rx.recv().await {
                if stdin.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
                if stdin.write_all(b"\n").await.is_err() {
                    break;
                }
                let _ = stdin.flush().await;
            }
        });

        let pending = Arc::new(Pending(Mutex::new(HashMap::new())));
        let (event_tx, event_rx) = mpsc::unbounded_channel::<AgentEvent>();

        // stdout: responses to our requests, plus the agent's notifications
        // and its own requests back to us.
        {
            let pending = pending.clone();
            let event_tx = event_tx.clone();
            let stdin_tx = stdin_tx.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let line = line.trim();
                    if line.is_empty() {
                        continue;
                    }
                    let Ok(msg) = serde_json::from_str::<Value>(line) else {
                        tracing::debug!(%line, "non-JSON line from agent");
                        continue;
                    };
                    dispatch(msg, &pending, &event_tx, &stdin_tx).await;
                }
            });
        }

        {
            let event_tx = event_tx.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if !line.trim().is_empty() {
                        let _ = event_tx.send(AgentEvent::Stderr(line));
                    }
                }
            });
        }

        let mut conn = Self {
            child,
            stdin_tx,
            pending,
            next_id: AtomicI64::new(1),
            agent_capabilities: Value::Null,
            auth_methods: Vec::new(),
        };

        let init = conn
            .request(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "clientCapabilities": {
                        "fs": { "readTextFile": true, "writeTextFile": true },
                        // We deliberately do not advertise terminals: runtimes
                        // then execute commands themselves with their own
                        // sandboxing, which is what we want inside a worktree.
                        "terminal": false
                    },
                    "clientInfo": { "name": "patchwork", "version": env!("CARGO_PKG_VERSION") }
                }),
            )
            .await
            .context("ACP initialize failed")?;

        conn.agent_capabilities = init
            .get("agentCapabilities")
            .cloned()
            .unwrap_or(Value::Null);
        conn.auth_methods = init
            .get("authMethods")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();

        Ok((conn, event_rx))
    }

    pub fn supports_load_session(&self) -> bool {
        self.agent_capabilities
            .get("loadSession")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
    }

    pub async fn new_session(&self, cwd: &str, mcp_servers: Value) -> Result<String> {
        let res = self
            .request(
                "session/new",
                json!({ "cwd": cwd, "mcpServers": mcp_servers }),
            )
            .await?;
        res.get("sessionId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| anyhow!("session/new returned no sessionId"))
    }

    pub async fn load_session(&self, session_id: &str, cwd: &str) -> Result<()> {
        self.request(
            "session/load",
            json!({ "sessionId": session_id, "cwd": cwd, "mcpServers": [] }),
        )
        .await?;
        Ok(())
    }

    pub async fn authenticate(&self, method_id: &str) -> Result<()> {
        self.request("authenticate", json!({ "methodId": method_id }))
            .await?;
        Ok(())
    }

    /// Send a prompt turn. Resolves with the stop reason when the turn ends.
    pub async fn prompt(&self, session_id: &str, text: &str) -> Result<String> {
        let res = self
            .request(
                "session/prompt",
                json!({
                    "sessionId": session_id,
                    "prompt": [{ "type": "text", "text": text }]
                }),
            )
            .await?;
        Ok(res
            .get("stopReason")
            .and_then(|v| v.as_str())
            .unwrap_or("end_turn")
            .to_string())
    }

    pub fn cancel(&self, session_id: &str) {
        self.notify("session/cancel", json!({ "sessionId": session_id }));
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.0.lock().await.insert(id, tx);

        let line = serde_json::to_string(&json!({
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        }))?;
        self.stdin_tx
            .send(line)
            .map_err(|_| anyhow!("agent process is gone"))?;

        match rx.await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) => Err(anyhow!("{method}: {e}")),
            Err(_) => Err(anyhow!("{method}: agent closed the connection")),
        }
    }

    pub fn notify(&self, method: &str, params: Value) {
        if let Ok(line) = serde_json::to_string(&json!({
            "jsonrpc": "2.0", "method": method, "params": params
        })) {
            let _ = self.stdin_tx.send(line);
        }
    }

    /// Answer a `session/request_permission` the agent is blocked on.
    pub fn respond_permission(&self, request_id: &Value, option_id: Option<&str>) {
        let outcome = match option_id {
            Some(id) => json!({ "outcome": "selected", "optionId": id }),
            None => json!({ "outcome": "cancelled" }),
        };
        self.respond(request_id, json!({ "outcome": outcome }));
    }

    pub fn respond(&self, request_id: &Value, result: Value) {
        if let Ok(line) = serde_json::to_string(&json!({
            "jsonrpc": "2.0", "id": request_id, "result": result
        })) {
            let _ = self.stdin_tx.send(line);
        }
    }

    pub async fn shutdown(mut self) {
        let _ = self.child.start_kill();
        let _ = self.child.wait().await;
    }
}

async fn dispatch(
    msg: Value,
    pending: &Arc<Pending>,
    event_tx: &mpsc::UnboundedSender<AgentEvent>,
    stdin_tx: &mpsc::UnboundedSender<String>,
) {
    let method = msg.get("method").and_then(|v| v.as_str());
    let has_id = msg.get("id").is_some();

    match (method, has_id) {
        // A response to one of our requests.
        (None, true) => {
            let Some(id) = msg.get("id").and_then(|v| v.as_i64()) else {
                return;
            };
            let slot = pending.0.lock().await.remove(&id);
            if let Some(tx) = slot {
                if let Some(err) = msg.get("error") {
                    let text = err
                        .get("message")
                        .and_then(|v| v.as_str())
                        .unwrap_or("unknown error");
                    let _ = tx.send(Err(text.to_string()));
                } else {
                    let _ = tx.send(Ok(msg.get("result").cloned().unwrap_or(Value::Null)));
                }
            }
        }
        // A notification from the agent.
        (Some(method), false) => {
            if method == "session/update" {
                let params = msg.get("params").cloned().unwrap_or(Value::Null);
                let session_id = params
                    .get("sessionId")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                let update = params.get("update").cloned().unwrap_or(Value::Null);
                let _ = event_tx.send(AgentEvent::SessionUpdate { session_id, update });
            }
        }
        // A request from the agent to us.
        (Some(method), true) => {
            let id = msg.get("id").cloned().unwrap_or(Value::Null);
            let params = msg.get("params").cloned().unwrap_or(Value::Null);
            match method {
                "session/request_permission" => {
                    let options = params
                        .get("options")
                        .and_then(|v| serde_json::from_value::<Vec<PermissionOption>>(v.clone()).ok())
                        .unwrap_or_default();
                    let _ = event_tx.send(AgentEvent::PermissionRequest {
                        request_id: id,
                        session_id: params
                            .get("sessionId")
                            .and_then(|v| v.as_str())
                            .unwrap_or_default()
                            .to_string(),
                        tool_call: params.get("toolCall").cloned().unwrap_or(Value::Null),
                        options,
                    });
                }
                "fs/read_text_file" => {
                    let result = read_text_file(&params).await;
                    reply(stdin_tx, id, result);
                }
                "fs/write_text_file" => {
                    let result = write_text_file(&params).await;
                    reply(stdin_tx, id, result);
                }
                other => {
                    reply(
                        stdin_tx,
                        id,
                        Err(format!("method not supported by this client: {other}")),
                    );
                }
            }
        }
        _ => {}
    }
}

fn reply(stdin_tx: &mpsc::UnboundedSender<String>, id: Value, result: Result<Value, String>) {
    let payload = match result {
        Ok(v) => json!({ "jsonrpc": "2.0", "id": id, "result": v }),
        Err(e) => json!({
            "jsonrpc": "2.0", "id": id,
            "error": { "code": -32000, "message": e }
        }),
    };
    if let Ok(line) = serde_json::to_string(&payload) {
        let _ = stdin_tx.send(line);
    }
}

async fn read_text_file(params: &Value) -> Result<Value, String> {
    let path = params
        .get("path")
        .and_then(|v| v.as_str())
        .ok_or("missing path")?;
    let content = tokio::fs::read_to_string(path)
        .await
        .map_err(|e| e.to_string())?;

    let line = params.get("line").and_then(|v| v.as_u64());
    let limit = params.get("limit").and_then(|v| v.as_u64());
    let content = if line.is_some() || limit.is_some() {
        let start = line.unwrap_or(1).saturating_sub(1) as usize;
        let lines: Vec<&str> = content.lines().collect();
        let end = match limit {
            Some(n) => (start + n as usize).min(lines.len()),
            None => lines.len(),
        };
        lines
            .get(start..end)
            .map(|s| s.join("\n"))
            .unwrap_or_default()
    } else {
        content
    };
    Ok(json!({ "content": content }))
}

async fn write_text_file(params: &Value) -> Result<Value, String> {
    let path = params
        .get("path")
        .and_then(|v| v.as_str())
        .ok_or("missing path")?;
    let content = params
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    if let Some(parent) = std::path::Path::new(path).parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    tokio::fs::write(path, content)
        .await
        .map_err(|e| e.to_string())?;
    Ok(json!({}))
}

/// Pick the permission option that lets autonomous work continue, preferring a
/// durable "always" grant so the agent is not asked again for the same tool.
pub fn choose_permission(options: &[PermissionOption]) -> Option<String> {
    options
        .iter()
        .find(|o| o.kind == "allow_always")
        .or_else(|| options.iter().find(|o| o.kind == "allow_once"))
        .or_else(|| options.first())
        .map(|o| o.option_id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opt(id: &str, kind: &str) -> PermissionOption {
        PermissionOption {
            option_id: id.into(),
            name: id.into(),
            kind: kind.into(),
        }
    }

    #[test]
    fn prefers_a_durable_allow() {
        let options = vec![
            opt("once", "allow_once"),
            opt("always", "allow_always"),
            opt("no", "reject_once"),
        ];
        assert_eq!(choose_permission(&options).as_deref(), Some("always"));
    }

    #[test]
    fn falls_back_to_allow_once() {
        let options = vec![opt("no", "reject_once"), opt("once", "allow_once")];
        assert_eq!(choose_permission(&options).as_deref(), Some("once"));
    }
}
