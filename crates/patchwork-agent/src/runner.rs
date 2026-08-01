//! Turns a `RunSpec` into a conversation.
//!
//! The runtime's raw chatter goes to the run log; what lands in the channel is
//! the agent's own prose, plus short status notes when something material
//! happens. Nobody should have to read execution logs to follow the work.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{anyhow, Result};
use patchwork_core::host::{HostToRelay, RelayToHost, RunSpec, WorktreeSpec};
use patchwork_core::models::{MessageKind, RunEventKind, RunStatus};
use patchwork_core::Id;
use serde_json::{json, Value};
use tokio::sync::{mpsc, Mutex};

use crate::acp::{choose_permission, AcpConnection, AgentEvent};
use crate::preview::PreviewManager;
use crate::{detect, worktree};

pub type Sink = mpsc::UnboundedSender<HostToRelay>;

#[derive(Debug, Clone, Default)]
pub struct RunnerConfig {
    /// Directory containing the `patchwork` CLI, prepended to the agent's PATH.
    pub cli_dir: Option<String>,
    /// Extra environment for every agent process.
    pub env: Vec<(String, String)>,
}

pub struct RunHandle {
    control: mpsc::UnboundedSender<RelayToHost>,
    task: tokio::task::JoinHandle<()>,
}

pub struct Runner {
    cfg: RunnerConfig,
    out: Sink,
    running: Mutex<HashMap<Id, RunHandle>>,
    previews: PreviewManager,
}

impl Runner {
    pub fn new(cfg: RunnerConfig, out: Sink) -> Arc<Self> {
        Arc::new(Self {
            cfg,
            out: out.clone(),
            running: Mutex::new(HashMap::new()),
            previews: PreviewManager::new(out),
        })
    }

    pub async fn active_runs(&self) -> usize {
        self.running.lock().await.len()
    }

    /// Route a relay command to the run it belongs to.
    pub async fn handle(self: &Arc<Self>, msg: RelayToHost) {
        match msg {
            RelayToHost::StartRun { spec } => self.start(*spec).await,
            RelayToHost::CancelRun { ref run_id } => {
                let handle = self.running.lock().await.remove(run_id);
                if let Some(h) = handle {
                    let _ = h.control.send(msg.clone());
                    // Give the runtime a moment to unwind before we abort.
                    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
                    h.task.abort();
                }
                self.emit(HostToRelay::RunStatus {
                    run_id: run_id.clone(),
                    status: RunStatus::Cancelled,
                    headline: Some("Cancelled".into()),
                    session_id: None,
                    error: None,
                    token_usage: None,
                });
            }
            RelayToHost::AnswerQuestion { ref run_id, .. }
            | RelayToHost::FollowUp { ref run_id, .. } => {
                if let Some(h) = self.running.lock().await.get(run_id) {
                    let _ = h.control.send(msg.clone());
                }
            }
            RelayToHost::StartPreview {
                preview_id,
                task_id,
                cwd,
                command,
                port,
                label,
            } => {
                self.previews
                    .start(preview_id, task_id, cwd, command, port, label)
                    .await;
            }
            RelayToHost::StopPreview { preview_id } => {
                self.previews.stop(&preview_id).await;
            }
            RelayToHost::Ping => {
                self.emit(HostToRelay::Pong {
                    at: patchwork_core::now_ms(),
                });
            }
        }
    }

    pub async fn start(self: &Arc<Self>, spec: RunSpec) {
        let run_id = spec.run_id.clone();
        let (control_tx, control_rx) = mpsc::unbounded_channel();
        let this = self.clone();
        let task = tokio::spawn(async move {
            let run_id = spec.run_id.clone();
            if let Err(err) = execute(this.clone(), spec, control_rx).await {
                let message = format!("{err:#}");
                this.emit(HostToRelay::RunEvent {
                    run_id: run_id.clone(),
                    kind: RunEventKind::Error,
                    text: message.clone(),
                    data: None,
                });
                this.emit(HostToRelay::RunStatus {
                    run_id: run_id.clone(),
                    status: RunStatus::Failed,
                    headline: Some("Failed".into()),
                    session_id: None,
                    error: Some(message.clone()),
                    token_usage: None,
                });
                this.emit(HostToRelay::RunMessage {
                    run_id: run_id.clone(),
                    kind: MessageKind::Status,
                    body: format!("I couldn't complete this run: {message}"),
                });
            }
            this.running.lock().await.remove(&run_id);
        });

        self.running
            .lock()
            .await
            .insert(run_id, RunHandle { control: control_tx, task });
    }

    fn emit(&self, msg: HostToRelay) {
        let _ = self.out.send(msg);
    }

    pub async fn shutdown(&self) {
        let mut running = self.running.lock().await;
        for (_, handle) in running.drain() {
            handle.task.abort();
        }
        self.previews.stop_all().await;
    }
}

/// Text the agent has produced but that we have not posted yet.
#[derive(Default)]
struct TurnState {
    message: String,
    thought: String,
    plan_posted: bool,
    stderr: Vec<String>,
}

async fn execute(
    runner: Arc<Runner>,
    spec: RunSpec,
    mut control: mpsc::UnboundedReceiver<RelayToHost>,
) -> Result<()> {
    let run_id = spec.run_id.clone();
    let out = runner.out.clone();
    let emit = |msg: HostToRelay| {
        let _ = out.send(msg);
    };

    emit(HostToRelay::RunStatus {
        run_id: run_id.clone(),
        status: RunStatus::Running,
        headline: Some("Preparing workspace".into()),
        session_id: None,
        error: None,
        token_usage: None,
    });

    // 1. Working directory.
    let task_key = spec.task_id.clone().unwrap_or_else(|| run_id.clone());
    let prepared = worktree::prepare(&spec.worktree, &task_key).await?;
    emit(HostToRelay::RunAccepted {
        run_id: run_id.clone(),
        cwd: Some(prepared.path.clone()),
    });
    if !matches!(spec.worktree, WorktreeSpec::None) {
        emit(HostToRelay::WorktreeReady {
            run_id: run_id.clone(),
            path: prepared.path.clone(),
            branch: prepared.branch.clone(),
            base_branch: prepared.base_branch.clone(),
            is_main_checkout: prepared.is_main_checkout,
        });
    }
    emit(HostToRelay::RunEvent {
        run_id: run_id.clone(),
        kind: RunEventKind::Lifecycle,
        text: format!("Working in {}", prepared.path),
        data: Some(json!({ "cwd": prepared.path, "branch": prepared.branch })),
    });

    // 2. Runtime.
    let command = resolve_command(&spec)?;
    emit(HostToRelay::RunEvent {
        run_id: run_id.clone(),
        kind: RunEventKind::Lifecycle,
        text: format!("Starting {} via ACP", spec.runtime),
        data: Some(json!({ "command": command })),
    });

    // 3. Environment: the agent's native access to Patchwork.
    let env = build_env(&runner.cfg, &spec, &prepared.path);
    write_skill(&prepared.path).await;

    emit(HostToRelay::RunStatus {
        run_id: run_id.clone(),
        status: RunStatus::Running,
        headline: Some("Thinking".into()),
        session_id: None,
        error: None,
        token_usage: None,
    });

    let (conn, mut events) = AcpConnection::spawn(&command, &prepared.path, &env).await?;
    let conn = Arc::new(conn);

    // Some runtimes require an explicit auth handshake before sessions work.
    if let Some(method) = conn
        .auth_methods
        .first()
        .and_then(|m| m.get("id"))
        .and_then(|v| v.as_str())
    {
        if let Err(err) = conn.authenticate(method).await {
            tracing::debug!(?err, "authenticate declined; continuing");
        }
    }

    let session_id = match spec.resume_session_id.as_deref() {
        Some(sid) if conn.supports_load_session() => {
            conn.load_session(sid, &prepared.path).await?;
            sid.to_string()
        }
        _ => conn.new_session(&prepared.path, json!([])).await?,
    };
    emit(HostToRelay::RunStatus {
        run_id: run_id.clone(),
        status: RunStatus::Running,
        headline: Some("Working".into()),
        session_id: Some(session_id.clone()),
        error: None,
        token_usage: None,
    });

    let state = Arc::new(Mutex::new(TurnState::default()));

    // 4. Pump the runtime's stream into run events, permission answers and
    //    accumulated prose.
    let pump = {
        let out = out.clone();
        let conn = conn.clone();
        let state = state.clone();
        let run_id = run_id.clone();
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                match event {
                    AgentEvent::SessionUpdate { update, .. } => {
                        handle_update(&run_id, update, &out, &state).await;
                    }
                    AgentEvent::PermissionRequest {
                        request_id,
                        tool_call,
                        options,
                        ..
                    } => {
                        let title = tool_call
                            .get("title")
                            .and_then(|v| v.as_str())
                            .unwrap_or("a tool")
                            .to_string();
                        let chosen = choose_permission(&options);
                        let _ = out.send(HostToRelay::RunEvent {
                            run_id: run_id.clone(),
                            kind: RunEventKind::Permission,
                            text: match &chosen {
                                Some(id) => format!("Allowed: {title} ({id})"),
                                None => format!("Denied: {title}"),
                            },
                            data: Some(json!({ "toolCall": tool_call, "options": options.iter().map(|o| json!({"id": o.option_id, "kind": o.kind, "name": o.name})).collect::<Vec<_>>() })),
                        });
                        conn.respond_permission(&request_id, chosen.as_deref());
                    }
                    AgentEvent::Stderr(line) => {
                        let mut s = state.lock().await;
                        if s.stderr.len() < 200 {
                            s.stderr.push(line.clone());
                        }
                        tracing::debug!(target: "acp_stderr", "{line}");
                    }
                    AgentEvent::Exited(code) => {
                        let _ = out.send(HostToRelay::RunEvent {
                            run_id: run_id.clone(),
                            kind: RunEventKind::Lifecycle,
                            text: format!("Runtime exited with {code:?}"),
                            data: None,
                        });
                    }
                }
            }
        })
    };

    // 5. Prompt turns. The first carries identity and context; later turns are
    //    follow-ups the user typed while the run was still going.
    let mut next_prompt = Some(compose_first_prompt(&spec));
    let mut turns = 0usize;

    loop {
        let Some(prompt) = next_prompt.take() else {
            break;
        };
        turns += 1;

        let stop_reason = tokio::select! {
            result = conn.prompt(&session_id, &prompt) => result,
            cmd = wait_for_cancel(&mut control) => {
                conn.cancel(&session_id);
                let _ = cmd;
                Ok("cancelled".to_string())
            }
        };

        flush_message(&run_id, &out, &state, &spec).await;

        let stop_reason = match stop_reason {
            Ok(reason) => reason,
            Err(err) => {
                let detail = {
                    let s = state.lock().await;
                    if s.stderr.is_empty() {
                        String::new()
                    } else {
                        format!("\n{}", s.stderr.join("\n"))
                    }
                };
                pump.abort();
                Arc::try_unwrap(conn).ok().unwrap().shutdown().await;
                return Err(anyhow!("{err}{detail}"));
            }
        };

        emit(HostToRelay::RunEvent {
            run_id: run_id.clone(),
            kind: RunEventKind::Lifecycle,
            text: format!("Turn {turns} ended: {stop_reason}"),
            data: None,
        });

        if stop_reason == "cancelled" {
            break;
        }

        // Drain anything queued while the turn was running.
        while let Ok(cmd) = control.try_recv() {
            match cmd {
                RelayToHost::FollowUp { prompt, .. } => {
                    next_prompt = Some(prompt);
                }
                RelayToHost::AnswerQuestion { .. } => {
                    // Answers reach the agent through the blocking
                    // `patchwork ask` call it made; nothing to inject here.
                }
                RelayToHost::CancelRun { .. } => {
                    next_prompt = None;
                    break;
                }
                _ => {}
            }
        }
    }

    pump.abort();

    // 6. Wrap up: report what changed so review has something concrete.
    if !prepared.branch.is_empty() {
        if let Some(summary) = worktree::status_summary(&prepared.path).await {
            emit(HostToRelay::RunEvent {
                run_id: run_id.clone(),
                kind: RunEventKind::FileChange,
                text: summary,
                data: None,
            });
        }
    }

    emit(HostToRelay::RunStatus {
        run_id: run_id.clone(),
        status: RunStatus::Succeeded,
        headline: Some("Done".into()),
        session_id: Some(session_id.clone()),
        error: None,
        token_usage: None,
    });

    if let Ok(conn) = Arc::try_unwrap(conn) {
        conn.shutdown().await;
    }
    Ok(())
}

async fn wait_for_cancel(control: &mut mpsc::UnboundedReceiver<RelayToHost>) -> Option<RelayToHost> {
    loop {
        match control.recv().await {
            Some(RelayToHost::CancelRun { run_id }) => {
                return Some(RelayToHost::CancelRun { run_id })
            }
            Some(_) => continue,
            None => {
                // No more control messages will arrive; park forever so the
                // prompt branch of the select decides the outcome.
                futures::future::pending::<()>().await;
                return None;
            }
        }
    }
}

async fn handle_update(
    run_id: &str,
    update: Value,
    out: &Sink,
    state: &Arc<Mutex<TurnState>>,
) {
    let kind = update
        .get("sessionUpdate")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    match kind {
        "agent_message_chunk" => {
            if let Some(text) = content_text(update.get("content")) {
                state.lock().await.message.push_str(&text);
            }
        }
        "agent_thought_chunk" => {
            if let Some(text) = content_text(update.get("content")) {
                let mut s = state.lock().await;
                s.thought.push_str(&text);
                if s.thought.len() > 400 {
                    let text = std::mem::take(&mut s.thought);
                    drop(s);
                    let _ = out.send(HostToRelay::RunEvent {
                        run_id: run_id.to_string(),
                        kind: RunEventKind::Thought,
                        text,
                        data: None,
                    });
                }
            }
        }
        "tool_call" | "tool_call_update" => {
            let title = update
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or("tool")
                .to_string();
            let status = update
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let event_kind = if kind == "tool_call" {
                RunEventKind::ToolCall
            } else {
                RunEventKind::ToolResult
            };
            let _ = out.send(HostToRelay::RunEvent {
                run_id: run_id.to_string(),
                kind: event_kind,
                text: if status.is_empty() {
                    title.clone()
                } else {
                    format!("{title} — {status}")
                },
                data: Some(update.clone()),
            });
            // Keep the run's one-line headline honest without spamming chat.
            if kind == "tool_call" {
                let _ = out.send(HostToRelay::RunStatus {
                    run_id: run_id.to_string(),
                    status: RunStatus::Running,
                    headline: Some(headline_for(&title)),
                    session_id: None,
                    error: None,
                    token_usage: None,
                });
            }
        }
        "plan" => {
            let entries = update
                .get("entries")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            let text = entries
                .iter()
                .map(|e| {
                    let status = e.get("status").and_then(|v| v.as_str()).unwrap_or("pending");
                    let mark = match status {
                        "completed" => "x",
                        "in_progress" => "~",
                        _ => " ",
                    };
                    format!(
                        "[{mark}] {}",
                        e.get("content").and_then(|v| v.as_str()).unwrap_or("")
                    )
                })
                .collect::<Vec<_>>()
                .join("\n");
            let _ = out.send(HostToRelay::RunEvent {
                run_id: run_id.to_string(),
                kind: RunEventKind::Plan,
                text: text.clone(),
                data: Some(update.clone()),
            });

            let mut s = state.lock().await;
            if !s.plan_posted && entries.len() > 1 {
                s.plan_posted = true;
                drop(s);
                let _ = out.send(HostToRelay::RunMessage {
                    run_id: run_id.to_string(),
                    kind: MessageKind::Status,
                    body: format!("Plan:\n{text}"),
                });
            }
        }
        _ => {
            let _ = out.send(HostToRelay::RunEvent {
                run_id: run_id.to_string(),
                kind: RunEventKind::Lifecycle,
                text: kind.to_string(),
                data: Some(update.clone()),
            });
        }
    }
}

/// `Read file src/main.rs` → `Reading src/main.rs`. Purely cosmetic, but the
/// run header is the thing people watch.
fn headline_for(title: &str) -> String {
    let trimmed = title.trim();
    if trimmed.len() > 80 {
        format!("{}…", &trimmed[..79])
    } else {
        trimmed.to_string()
    }
}

async fn flush_message(run_id: &str, out: &Sink, state: &Arc<Mutex<TurnState>>, _spec: &RunSpec) {
    let (message, thought) = {
        let mut s = state.lock().await;
        (std::mem::take(&mut s.message), std::mem::take(&mut s.thought))
    };
    if !thought.trim().is_empty() {
        let _ = out.send(HostToRelay::RunEvent {
            run_id: run_id.to_string(),
            kind: RunEventKind::Thought,
            text: thought,
            data: None,
        });
    }
    let body = message.trim();
    if !body.is_empty() {
        let _ = out.send(HostToRelay::RunEvent {
            run_id: run_id.to_string(),
            kind: RunEventKind::Message,
            text: body.to_string(),
            data: None,
        });
        let _ = out.send(HostToRelay::RunMessage {
            run_id: run_id.to_string(),
            kind: MessageKind::Text,
            body: body.to_string(),
        });
    }
}

fn content_text(content: Option<&Value>) -> Option<String> {
    let content = content?;
    if let Some(text) = content.get("text").and_then(|v| v.as_str()) {
        return Some(text.to_string());
    }
    if let Some(arr) = content.as_array() {
        let joined: String = arr
            .iter()
            .filter_map(|c| c.get("text").and_then(|v| v.as_str()))
            .collect::<Vec<_>>()
            .join("");
        if !joined.is_empty() {
            return Some(joined);
        }
    }
    None
}

fn resolve_command(spec: &RunSpec) -> Result<Vec<String>> {
    if spec.runtime == "custom" {
        return spec
            .custom_command
            .clone()
            .filter(|c| !c.is_empty())
            .ok_or_else(|| anyhow!("this agent uses a custom runtime but no command is configured"));
    }
    detect::runtime_command(&spec.runtime).ok_or_else(|| {
        anyhow!(
            "no usable `{}` ACP installation on this machine",
            spec.runtime
        )
    })
}

fn build_env(cfg: &RunnerConfig, spec: &RunSpec, cwd: &str) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = vec![
        ("PATCHWORK".into(), "1".into()),
        ("PATCHWORK_API_BASE".into(), spec.api_base.clone()),
        ("PATCHWORK_TOKEN".into(), spec.api_token.clone()),
        ("PATCHWORK_RUN_ID".into(), spec.run_id.clone()),
        ("PATCHWORK_AGENT_ID".into(), spec.agent_id.clone()),
        ("PATCHWORK_CHANNEL_ID".into(), spec.channel_id.clone()),
        ("PATCHWORK_CWD".into(), cwd.to_string()),
    ];
    if let Some(task_id) = &spec.task_id {
        env.push(("PATCHWORK_TASK_ID".into(), task_id.clone()));
    }
    if let Some(project_id) = &spec.project_id {
        env.push(("PATCHWORK_PROJECT_ID".into(), project_id.clone()));
    }
    if let Some(dir) = &cfg.cli_dir {
        let path = std::env::var("PATH").unwrap_or_default();
        env.push(("PATH".into(), format!("{dir}:{path}")));
    }
    env.extend(cfg.env.iter().cloned());
    env.extend(spec.env.iter().cloned());
    env
}

/// The Patchwork skill: how an agent talks back to the workspace it lives in.
pub const SKILL: &str = include_str!("../skill/PATCHWORK.md");

async fn write_skill(cwd: &str) {
    let dir = std::path::Path::new(cwd).join(".patchwork");
    if tokio::fs::create_dir_all(&dir).await.is_ok() {
        let _ = tokio::fs::write(dir.join("PATCHWORK.md"), SKILL).await;
        let _ = tokio::fs::write(dir.join(".gitignore"), "*\n").await;
    }
}

fn compose_first_prompt(spec: &RunSpec) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "You are {} (@{}), a teammate in a Patchwork workspace.\n",
        spec.agent_name, spec.agent_handle
    ));
    if !spec.agent_description.trim().is_empty() {
        s.push_str(&format!("\n{}\n", spec.agent_description.trim()));
    }
    s.push_str("\n---\n");
    s.push_str(SKILL);
    s.push_str("\n---\n");
    if !spec.context.trim().is_empty() {
        s.push_str("## Context\n\n");
        s.push_str(spec.context.trim());
        s.push_str("\n\n---\n");
    }
    s.push_str("## Your turn\n\n");
    s.push_str(spec.prompt.trim());
    s.push_str(
        "\n\nWrite your reply as a teammate would: short, concrete, and about the outcome. \
Your final message is posted to the conversation verbatim, so do not narrate tool use — \
the run log already has it. If something is genuinely ambiguous, ask with `patchwork ask` \
instead of guessing.",
    );
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> RunSpec {
        RunSpec {
            run_id: "r1".into(),
            agent_id: "a1".into(),
            agent_handle: "dev".into(),
            agent_name: "Developer agent".into(),
            agent_description: "You ship small, reviewable changes.".into(),
            runtime: "codex".into(),
            custom_command: None,
            channel_id: "c1".into(),
            task_id: Some("t1".into()),
            project_id: None,
            automation_id: None,
            worktree: WorktreeSpec::None,
            prompt: "Fix the failing test".into(),
            context: "#dev — Vince: the checkout test is red".into(),
            api_base: "http://localhost:7717".into(),
            api_token: "tok".into(),
            resume_session_id: None,
            env: vec![],
        }
    }

    #[test]
    fn first_prompt_carries_identity_skill_and_context() {
        let p = compose_first_prompt(&spec());
        assert!(p.contains("Developer agent"));
        assert!(p.contains("You ship small, reviewable changes."));
        assert!(p.contains("patchwork ask"));
        assert!(p.contains("the checkout test is red"));
        assert!(p.contains("Fix the failing test"));
    }

    #[test]
    fn env_gives_the_agent_native_access() {
        let env = build_env(&RunnerConfig::default(), &spec(), "/tmp/wt");
        let map: std::collections::HashMap<_, _> = env.into_iter().collect();
        assert_eq!(map.get("PATCHWORK_RUN_ID").unwrap(), "r1");
        assert_eq!(map.get("PATCHWORK_TASK_ID").unwrap(), "t1");
        assert_eq!(map.get("PATCHWORK_TOKEN").unwrap(), "tok");
    }

    #[test]
    fn custom_runtime_requires_a_command() {
        let mut s = spec();
        s.runtime = "custom".into();
        assert!(resolve_command(&s).is_err());
        s.custom_command = Some(vec!["my-agent".into(), "--acp".into()]);
        assert_eq!(resolve_command(&s).unwrap(), vec!["my-agent", "--acp"]);
    }

    #[tokio::test]
    async fn tool_calls_go_to_the_run_log_not_the_channel() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let state = Arc::new(Mutex::new(TurnState::default()));
        handle_update(
            "r1",
            json!({ "sessionUpdate": "tool_call", "title": "Read src/main.rs", "status": "pending" }),
            &tx,
            &state,
        )
        .await;
        let mut messages = 0;
        let mut events = 0;
        while let Ok(msg) = rx.try_recv() {
            match msg {
                HostToRelay::RunMessage { .. } => messages += 1,
                HostToRelay::RunEvent { .. } | HostToRelay::RunStatus { .. } => events += 1,
                _ => {}
            }
        }
        assert_eq!(messages, 0, "tool activity must not reach the channel");
        assert!(events >= 1);
    }

    #[tokio::test]
    async fn prose_is_buffered_then_posted_once_per_turn() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let state = Arc::new(Mutex::new(TurnState::default()));
        for chunk in ["Fixed ", "the ", "test."] {
            handle_update(
                "r1",
                json!({ "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": chunk } }),
                &tx,
                &state,
            )
            .await;
        }
        assert!(rx.try_recv().is_err(), "chunks must not post individually");
        flush_message("r1", &tx, &state, &spec()).await;
        let mut bodies = Vec::new();
        while let Ok(msg) = rx.try_recv() {
            if let HostToRelay::RunMessage { body, .. } = msg {
                bodies.push(body);
            }
        }
        assert_eq!(bodies, vec!["Fixed the test.".to_string()]);
    }
}
