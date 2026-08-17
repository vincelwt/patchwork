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
use patchwork_core::models::RuntimeOption;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, Mutex};

pub const PROTOCOL_VERSION: u32 = 1;

/// How long a handshake, session open or authentication may take.
const SETUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

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

/// What opening a session told us about the runtime behind it.
#[derive(Debug, Clone, Default)]
pub struct NewSession {
    pub session_id: String,
    pub models: Vec<RuntimeOption>,
    /// How hard to think. Its own knob, because it is its own question:
    /// Claude's modes are permissions, OpenCode's are build or plan, and
    /// neither has anything to do with reasoning effort.
    pub thinking: Vec<RuntimeOption>,
    /// Permission or session modes, whatever this runtime means by them.
    pub modes: Vec<RuntimeOption>,
    pub current_model: Option<String>,
    pub current_thinking: Option<String>,
    pub current_mode: Option<String>,
    /// Runtime-defined option IDs. These need not match their categories.
    pub model_config_id: Option<String>,
    pub thinking_config_id: Option<String>,
    pub mode_config_id: Option<String>,
    /// Runtime-authored setup text that is also sent as an agent message.
    pub startup_message: Option<String>,
    /// The runtime described itself with `configOptions` rather than the older
    /// `models`/`modes` groups, so changing one goes through
    /// `session/set_config_option`.
    pub config_options: bool,
}

/// `{ "models": { "availableModels": [ { modelId, name, description } ] } }`.
/// The id key differs per group (`modelId` / `id`), so take whichever is there.
fn options_of(res: &Value, group: &str, list: &str) -> Vec<RuntimeOption> {
    let Some(items) = res
        .get(group)
        .and_then(|g| g.get(list))
        .and_then(|v| v.as_array())
    else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let id = item
                .get("modelId")
                .or_else(|| item.get("modeId"))
                .or_else(|| item.get("id"))
                .and_then(|v| v.as_str())?;
            Some(RuntimeOption {
                id: id.to_string(),
                name: item
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(id)
                    .to_string(),
                description: item
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string(),
            })
        })
        .collect()
}

fn current_of(res: &Value, group: &str, key: &str) -> Option<String> {
    res.get(group)
        .and_then(|g| g.get(key))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

/// The newer shape: one flat list of settings, each tagged with what it is.
///
/// ```json
/// "configOptions": [{ "id": "model", "category": "model", "currentValue": "…",
///                     "options": [{ "value": "…", "name": "…" }] }]
/// ```
///
/// Agents built on recent ACP SDKs report *only* this. Reading it is what keeps
/// "which model does this agent think with" a real list rather than an empty
/// one on every runtime that has moved on.
fn config_option<'a>(res: &'a Value, category: &str) -> Option<&'a Value> {
    res.get("configOptions")?
        .as_array()?
        .iter()
        .find(|option| option.get("category").and_then(|c| c.as_str()) == Some(category))
}

fn config_choices(option: &Value) -> Vec<RuntimeOption> {
    option
        .get("options")
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let id = item.get("value").and_then(|v| v.as_str())?;
                    Some(RuntimeOption {
                        id: id.to_string(),
                        name: item
                            .get("name")
                            .and_then(|v| v.as_str())
                            .unwrap_or(id)
                            .to_string(),
                        description: item
                            .get("description")
                            .and_then(|v| v.as_str())
                            .unwrap_or_default()
                            .to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn config_current(option: &Value) -> Option<String> {
    option
        .get("currentValue")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

fn config_id(option: &Value) -> Option<String> {
    option.get("id").and_then(|v| v.as_str()).map(str::to_owned)
}

fn restore_method(capabilities: &Value) -> Option<&'static str> {
    if capabilities
        .get("sessionCapabilities")
        .and_then(|v| v.get("resume"))
        .is_some()
    {
        Some("session/resume")
    } else if capabilities
        .get("loadSession")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
    {
        Some("session/load")
    } else {
        None
    }
}

/// Read a `session/new`, `session/load`, or `session/resume` result in either dialect.
fn describe_session(session_id: String, res: &Value) -> NewSession {
    let startup_message = res
        .pointer("/_meta/piAcp/startupInfo")
        .and_then(Value::as_str)
        .map(str::to_string);
    let model = config_option(res, "model");
    let thinking = config_option(res, "thought_level");
    let mode = config_option(res, "mode");
    if model.is_some() || thinking.is_some() || mode.is_some() {
        return NewSession {
            session_id,
            models: model.map(config_choices).unwrap_or_default(),
            thinking: thinking.map(config_choices).unwrap_or_default(),
            modes: mode.map(config_choices).unwrap_or_default(),
            current_model: model.and_then(config_current),
            current_thinking: thinking.and_then(config_current),
            current_mode: mode.and_then(config_current),
            model_config_id: model.and_then(config_id),
            thinking_config_id: thinking.and_then(config_id),
            mode_config_id: mode.and_then(config_id),
            startup_message,
            config_options: true,
        };
    }
    // The older dialect has no thinking knob at all: runtimes that speak it
    // put reasoning effort in the model id.
    NewSession {
        session_id,
        models: options_of(res, "models", "availableModels"),
        thinking: Vec::new(),
        modes: options_of(res, "modes", "availableModes"),
        current_model: current_of(res, "models", "currentModelId"),
        current_thinking: None,
        current_mode: current_of(res, "modes", "currentModeId"),
        model_config_id: None,
        thinking_config_id: None,
        mode_config_id: None,
        startup_message,
        config_options: false,
    }
}

pub struct AcpConnection {
    /// Behind a mutex so shutdown never needs to own the connection: the
    /// event pump holds a clone for as long as the run lives.
    child: Mutex<Option<Child>>,
    stdin_tx: mpsc::UnboundedSender<String>,
    pending: Arc<Pending>,
    suppressed_updates: Arc<Mutex<Option<String>>>,
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
        // Patchwork is this agent's harness. Markers left by whatever launched
        // Patchwork itself would make some runtimes refuse to start, believing
        // they are nested inside another session.
        for marker in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            cmd.env_remove(marker);
        }
        for (k, v) in env {
            cmd.env(k, v);
        }

        // Adapters spawn the real agent CLI, which spawns its own tools. Give
        // the whole run its own process group so ending a run ends all of it —
        // an orphaned runtime would keep burning CPU forever.
        #[cfg(unix)]
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
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
        let suppressed_updates = Arc::new(Mutex::new(None));
        let (event_tx, event_rx) = mpsc::unbounded_channel::<AgentEvent>();

        // stdout: responses to our requests, plus the agent's notifications
        // and its own requests back to us.
        {
            let pending = pending.clone();
            let event_tx = event_tx.clone();
            let stdin_tx = stdin_tx.clone();
            let suppressed_updates = suppressed_updates.clone();
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
                    dispatch(msg, &pending, &event_tx, &stdin_tx, &suppressed_updates).await;
                }
            });
        }

        {
            let event_tx = event_tx.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let line = strip_ansi(&line);
                    if !line.trim().is_empty() {
                        let _ = event_tx.send(AgentEvent::Stderr(line));
                    }
                }
            });
        }

        let mut conn = Self {
            child: Mutex::new(Some(child)),
            stdin_tx,
            pending,
            suppressed_updates,
            next_id: AtomicI64::new(1),
            agent_capabilities: Value::Null,
            auth_methods: Vec::new(),
        };

        let init = conn
            .setup_request(
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

    pub fn supports_restore_session(&self) -> bool {
        restore_method(&self.agent_capabilities).is_some()
    }

    /// Setup calls get a deadline; a runtime that never answers must fail the
    /// run rather than leave a task looking busy forever.
    async fn setup_request(&self, method: &str, params: Value) -> Result<Value> {
        tokio::time::timeout(SETUP_TIMEOUT, self.request(method, params))
            .await
            .map_err(|_| anyhow!("{method}: the agent did not answer in time"))?
    }

    /// A new session, plus what this runtime turned out to offer. The models
    /// and modes are only knowable by asking — the catalogue is the runtime's,
    /// not ours — and opening a session is the moment it tells us.
    pub async fn new_session(&self, cwd: &str, mcp_servers: Value) -> Result<NewSession> {
        let res = self
            .setup_request(
                "session/new",
                json!({ "cwd": cwd, "mcpServers": mcp_servers }),
            )
            .await?;
        let session_id = res
            .get("sessionId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| anyhow!("session/new returned no sessionId"))?;
        Ok(describe_session(session_id, &res))
    }

    /// Ask for a specific model. The caller decides whether rejection is fatal.
    pub async fn set_model(
        &self,
        session_id: &str,
        model_id: &str,
        config_id: Option<&str>,
    ) -> Result<()> {
        if let Some(config_id) = config_id {
            self.setup_request(
                "session/set_config_option",
                json!({ "sessionId": session_id, "configId": config_id, "value": model_id }),
            )
            .await?;
            return Ok(());
        }
        self.setup_request(
            "session/set_model",
            json!({ "sessionId": session_id, "modelId": model_id }),
        )
        .await?;
        Ok(())
    }

    /// How hard to think. Only the config-option dialect has one.
    pub async fn set_thinking(&self, session_id: &str, config_id: &str, level: &str) -> Result<()> {
        self.setup_request(
            "session/set_config_option",
            json!({ "sessionId": session_id, "configId": config_id, "value": level }),
        )
        .await?;
        Ok(())
    }

    pub async fn set_mode(
        &self,
        session_id: &str,
        mode_id: &str,
        config_id: Option<&str>,
    ) -> Result<()> {
        if let Some(config_id) = config_id {
            self.setup_request(
                "session/set_config_option",
                json!({ "sessionId": session_id, "configId": config_id, "value": mode_id }),
            )
            .await?;
            return Ok(());
        }
        self.setup_request(
            "session/set_mode",
            json!({ "sessionId": session_id, "modeId": mode_id }),
        )
        .await?;
        Ok(())
    }

    pub async fn restore_session(&self, session_id: &str, cwd: &str) -> Result<NewSession> {
        let method = restore_method(&self.agent_capabilities)
            .ok_or_else(|| anyhow!("runtime cannot restore sessions"))?;
        if method == "session/load" {
            *self.suppressed_updates.lock().await = Some(session_id.to_string());
        }
        let result = self
            .setup_request(
                method,
                json!({ "sessionId": session_id, "cwd": cwd, "mcpServers": [] }),
            )
            .await;
        *self.suppressed_updates.lock().await = None;
        Ok(describe_session(session_id.to_string(), &result?))
    }

    pub async fn authenticate(&self, method_id: &str) -> Result<()> {
        self.setup_request("authenticate", json!({ "methodId": method_id }))
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

    pub async fn shutdown(&self) {
        let Some(mut child) = self.child.lock().await.take() else {
            return;
        };
        let pid = child.id();

        // Ask the whole process group to stop, give it a moment to unwind, then
        // insist.
        #[cfg(unix)]
        if let Some(pid) = pid {
            unsafe { libc::kill(-(pid as i32), libc::SIGTERM) };
            for _ in 0..20 {
                if matches!(child.try_wait(), Ok(Some(_))) {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
            // The adapter may have exited while a TERM-resistant tool it
            // launched is still alive, so always finish the process group.
            unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
        }

        let _ = child.start_kill();
        let _ = child.wait().await;
    }
}

/// A dropped connection — a cancelled run, a stopping relay — must not leave a
/// runtime behind.
impl Drop for AcpConnection {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Ok(mut guard) = self.child.try_lock() {
            if let Some(pid) = guard.as_mut().and_then(|child| child.id()) {
                unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
            }
        }
    }
}

async fn dispatch(
    msg: Value,
    pending: &Arc<Pending>,
    event_tx: &mpsc::UnboundedSender<AgentEvent>,
    stdin_tx: &mpsc::UnboundedSender<String>,
    suppressed_updates: &Arc<Mutex<Option<String>>>,
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
                if suppressed_updates.lock().await.as_deref() == Some(session_id.as_str()) {
                    return;
                }
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
                        .and_then(|v| {
                            serde_json::from_value::<Vec<PermissionOption>>(v.clone()).ok()
                        })
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

/// Runtimes colour their logs. Those escape codes are noise once the text is
/// stored in a run event and rendered in the UI.
pub fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\u{1b}' {
            out.push(ch);
            continue;
        }
        // CSI sequences end at a byte in the range @ to ~.
        if chars.peek() == Some(&'[') {
            chars.next();
            for next in chars.by_ref() {
                if ('\u{40}'..='\u{7e}').contains(&next) {
                    break;
                }
            }
        }
    }
    out
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
    fn a_session_describes_itself_in_either_dialect() {
        let modern = json!({
            "sessionId": "s1",
            "_meta": { "piAcp": { "startupInfo": "pi v0.84.1\n" } },
            "configOptions": [
                {
                    "type": "select", "id": "model", "category": "model",
                    "currentValue": "openrouter/deepseek/deepseek-v4-flash",
                    "options": [{ "value": "openrouter/deepseek/deepseek-v4-flash", "name": "DeepSeek V4 Flash" }]
                },
                {
                    "type": "select", "id": "reasoning_effort", "category": "thought_level",
                    "currentValue": "medium",
                    "options": [{ "value": "xhigh", "name": "Xhigh" }]
                }
            ]
        });
        let session = describe_session("s1".into(), &modern);
        assert!(session.config_options);
        assert_eq!(session.models.len(), 1);
        assert_eq!(
            session.current_model.as_deref(),
            Some("openrouter/deepseek/deepseek-v4-flash")
        );
        assert_eq!(
            session.thinking_config_id.as_deref(),
            Some("reasoning_effort")
        );
        assert_eq!(session.current_thinking.as_deref(), Some("medium"));
        assert_eq!(session.startup_message.as_deref(), Some("pi v0.84.1\n"));

        let legacy = json!({
            "sessionId": "s2",
            "models": {
                "currentModelId": "gpt-5.6",
                "availableModels": [{ "modelId": "gpt-5.6", "name": "GPT-5.6" }]
            }
        });
        let session = describe_session("s2".into(), &legacy);
        assert!(!session.config_options);
        assert_eq!(session.models[0].id, "gpt-5.6");
        assert_eq!(session.current_model.as_deref(), Some("gpt-5.6"));
    }

    #[test]
    fn resume_is_preferred_over_history_replaying_load() {
        assert_eq!(
            restore_method(&json!({
                "loadSession": true,
                "sessionCapabilities": { "resume": {} }
            })),
            Some("session/resume")
        );
        assert_eq!(
            restore_method(&json!({ "loadSession": true })),
            Some("session/load")
        );
        assert_eq!(restore_method(&json!({})), None);
    }

    #[tokio::test]
    async fn legacy_load_history_is_not_forwarded_as_a_new_answer() {
        let pending = Arc::new(Pending(Mutex::new(HashMap::new())));
        let (event_tx, mut events) = mpsc::unbounded_channel();
        let (stdin_tx, _stdin) = mpsc::unbounded_channel::<String>();
        let suppressed = Arc::new(Mutex::new(Some("s1".to_string())));
        let update = json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": { "sessionId": "s1", "update": { "sessionUpdate": "agent_message_chunk" } }
        });

        dispatch(update.clone(), &pending, &event_tx, &stdin_tx, &suppressed).await;
        assert!(events.try_recv().is_err());

        *suppressed.lock().await = None;
        dispatch(update, &pending, &event_tx, &stdin_tx, &suppressed).await;
        assert!(matches!(
            events.try_recv(),
            Ok(AgentEvent::SessionUpdate { session_id, .. }) if session_id == "s1"
        ));
    }

    #[tokio::test]
    async fn load_preserves_session_configuration_and_restore_capability() {
        let (stdin_tx, mut stdin_rx) = mpsc::unbounded_channel::<String>();
        let pending = Arc::new(Pending(Mutex::new(HashMap::new())));
        let conn = AcpConnection {
            child: Mutex::new(None),
            stdin_tx,
            pending: pending.clone(),
            suppressed_updates: Arc::new(Mutex::new(None)),
            next_id: AtomicI64::new(1),
            agent_capabilities: json!({ "loadSession": true }),
            auth_methods: Vec::new(),
        };
        let runtime = tokio::spawn(async move {
            let request: Value =
                serde_json::from_str(&stdin_rx.recv().await.expect("session/load request"))
                    .expect("valid JSON-RPC");
            assert_eq!(request["method"], "session/load");
            let id = request["id"].as_i64().expect("numeric request id");
            pending
                .0
                .lock()
                .await
                .remove(&id)
                .expect("pending request")
                .send(Ok(json!({
                    "configOptions": [
                        {
                            "id": "model", "category": "model",
                            "currentValue": "openai/gpt-5.6-sol",
                            "options": [{ "value": "openai/gpt-5.6-sol" }]
                        },
                        {
                            "id": "reasoning_effort", "category": "thought_level",
                            "currentValue": "xhigh",
                            "options": [{ "value": "xhigh" }]
                        }
                    ]
                })))
                .expect("request receiver alive");
        });

        let restored = conn.restore_session("s1", "/tmp").await.unwrap();
        assert!(conn.supports_restore_session());
        assert!(restored.config_options);
        assert_eq!(
            restored.current_model.as_deref(),
            Some("openai/gpt-5.6-sol")
        );
        assert_eq!(restored.current_thinking.as_deref(), Some("xhigh"));
        assert_eq!(restored.model_config_id.as_deref(), Some("model"));
        runtime.await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn shutdown_kills_term_resistant_descendants() {
        let pid_file =
            std::env::temp_dir().join(format!("patchwork-descendant-{}", uuid::Uuid::now_v7()));
        let script = r#"
trap 'exit 0' TERM
sh -c 'trap "" TERM; echo $$ > "$PID_FILE"; while :; do sleep 1; done' &
read _
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}'
wait
"#;
        let command = vec!["sh".to_string(), "-c".to_string(), script.to_string()];
        let env = vec![(
            "PID_FILE".to_string(),
            pid_file.to_string_lossy().to_string(),
        )];
        let (conn, _events) = AcpConnection::spawn(&command, "/tmp", &env).await.unwrap();
        let pid: i32 = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if let Ok(pid) = tokio::fs::read_to_string(&pid_file).await {
                    break pid.trim().parse().unwrap();
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the descendant should publish its pid");

        conn.shutdown().await;
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while unsafe { libc::kill(pid, 0) } == 0 {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the descendant process should be gone");
        let _ = tokio::fs::remove_file(pid_file).await;
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
    fn ansi_colour_is_removed_from_runtime_logs() {
        let coloured = "\u{1b}[2m2026-08-01\u{1b}[0m \u{1b}[31mERROR\u{1b}[0m failed to load";
        assert_eq!(strip_ansi(coloured), "2026-08-01 ERROR failed to load");
        assert_eq!(strip_ansi("plain text"), "plain text");
    }

    #[test]
    fn falls_back_to_allow_once() {
        let options = vec![opt("no", "reject_once"), opt("once", "allow_once")];
        assert_eq!(choose_permission(&options).as_deref(), Some("once"));
    }

    #[tokio::test]
    async fn thinking_uses_the_runtime_advertised_config_id() {
        let (stdin_tx, mut stdin_rx) = mpsc::unbounded_channel::<String>();
        let pending = Arc::new(Pending(Mutex::new(HashMap::new())));
        let conn = AcpConnection {
            child: Mutex::new(None),
            stdin_tx,
            pending: pending.clone(),
            suppressed_updates: Arc::new(Mutex::new(None)),
            next_id: AtomicI64::new(1),
            agent_capabilities: Value::Null,
            auth_methods: Vec::new(),
        };

        let runtime = tokio::spawn(async move {
            let line = stdin_rx.recv().await.expect("configuration request");
            let request: Value = serde_json::from_str(&line).expect("valid JSON-RPC");
            assert_eq!(request["method"], "session/set_config_option");
            assert_eq!(request["params"]["sessionId"], "codex-session");
            assert_eq!(request["params"]["configId"], "reasoning_effort");
            assert_eq!(request["params"]["value"], "xhigh");

            let id = request["id"].as_i64().expect("numeric request id");
            let sender = pending.0.lock().await.remove(&id).expect("pending request");
            sender.send(Ok(json!({}))).expect("request receiver alive");
        });

        conn.set_thinking("codex-session", "reasoning_effort", "xhigh")
            .await
            .expect("Codex thinking configuration accepted");
        runtime.await.expect("mock Codex runtime completed");
    }
}
