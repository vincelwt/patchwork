//! Turns a `RunSpec` into a conversation.
//!
//! The runtime's raw chatter goes to the run log; what lands in the channel is
//! the agent's own prose, plus short status notes when something material
//! happens. Nobody should have to read execution logs to follow the work.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use anyhow::{anyhow, Result};
use patchwork_core::host::{
    HostToRelay, RelayToHost, RunControlMode, RunControlState, RunFile, RunSpec, WorktreeSpec,
};
use patchwork_core::models::{MessageKind, RunEventKind, RunStatus};
use patchwork_core::Id;
use serde_json::{json, Value};
use tokio::sync::{mpsc, Mutex};

use crate::acp::{choose_permission, AcpConnection, AgentEvent, NewSession};
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
    accepting: bool,
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
            RelayToHost::QuestionAsked { ref run_id }
            | RelayToHost::AnswerQuestion { ref run_id, .. } => {
                if let Some(h) = self.running.lock().await.get(run_id) {
                    let _ = h.control.send(msg.clone());
                }
            }
            RelayToHost::FollowUp {
                ref run_id,
                ref control_id,
                ..
            } => {
                let running = self.running.lock().await;
                if let Some(h) = running.get(run_id).filter(|handle| handle.accepting) {
                    let _ = h.control.send(msg.clone());
                } else {
                    self.emit(HostToRelay::RunControlStatus {
                        run_id: run_id.clone(),
                        control_id: control_id.clone(),
                        state: RunControlState::Rejected,
                    });
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
                // The channel gets the headline; the detail stays in the run
                // log, where someone debugging will look for it.
                let headline = message.lines().next().unwrap_or(&message).trim();
                this.emit(HostToRelay::RunMessage {
                    run_id: run_id.clone(),
                    kind: MessageKind::Status,
                    body: format!("I couldn't complete this run: {headline}"),
                });
            }
            this.running.lock().await.remove(&run_id);
        });

        self.running.lock().await.insert(
            run_id,
            RunHandle {
                control: control_tx,
                task,
                accepting: true,
            },
        );
    }

    async fn set_accepting(&self, run_id: &str, accepting: bool) {
        if let Some(handle) = self.running.lock().await.get_mut(run_id) {
            handle.accepting = accepting;
        }
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
    /// When we last streamed the partial reply, so a fast agent does not turn
    /// every token into a websocket frame.
    streamed_at: Option<std::time::Instant>,
    /// Runtime-specific message phase, when exposed. Codex marks temporary
    /// commentary separately from the final answer.
    message_phase: Option<String>,
    /// The agent did something between two pieces of prose. The next chunk
    /// starts a new paragraph rather than running into the last sentence.
    interrupted: bool,
}

/// Long enough that a chatty model does not flood the relay, short enough that
/// the reply still reads as if it is being typed.
const STREAM_INTERVAL: std::time::Duration = std::time::Duration::from_millis(140);

#[derive(Debug)]
struct QueuedControl {
    control_id: Id,
    prompt: String,
    files: Vec<String>,
}

/// Interrupting feedback goes next; ordinary feedback keeps arrival order.
fn queue_control(
    pending: &mut VecDeque<QueuedControl>,
    interrupted: &mut bool,
    control: QueuedControl,
    mode: RunControlMode,
) -> bool {
    if mode == RunControlMode::Interrupt && !*interrupted {
        pending.push_front(control);
        *interrupted = true;
        true
    } else {
        pending.push_back(control);
        false
    }
}

fn reject_pending(pending: &mut VecDeque<QueuedControl>, run_id: &str, out: &Sink) {
    for control in pending.drain(..) {
        let _ = out.send(HostToRelay::RunControlStatus {
            run_id: run_id.to_string(),
            control_id: control.control_id,
            state: RunControlState::Rejected,
        });
    }
}

async fn begin_message_after_question(state: &Arc<Mutex<TurnState>>) {
    let mut turn = state.lock().await;
    turn.message.clear();
    turn.message_phase = None;
    turn.streamed_at = None;
    turn.interrupted = false;
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
    if let (Some(path), Some(project_id)) = (&prepared.cloned_to, &spec.project_id) {
        emit(HostToRelay::ProjectCheckout {
            project_id: project_id.clone(),
            path: path.clone(),
        });
        emit(HostToRelay::RunEvent {
            run_id: run_id.clone(),
            kind: RunEventKind::Lifecycle,
            text: format!("Cloned the project to {path}"),
            data: None,
        });
    }
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
    let files = fetch_files(&prepared.path, &spec.files).await;
    if !files.is_empty() {
        emit(HostToRelay::RunEvent {
            run_id: run_id.clone(),
            kind: RunEventKind::Lifecycle,
            text: format!("Fetched {} attached file(s)", files.len()),
            data: Some(json!({ "files": files })),
        });
    }

    emit(HostToRelay::RunStatus {
        run_id: run_id.clone(),
        status: RunStatus::Running,
        headline: Some("Thinking".into()),
        session_id: None,
        error: None,
        token_usage: None,
    });

    let (conn, mut events) = tokio::time::timeout(
        std::time::Duration::from_secs(120),
        AcpConnection::spawn(&command, &prepared.path, &env),
    )
    .await
    .map_err(|_| anyhow!("`{}` did not answer the ACP handshake", spec.runtime))??;
    let conn = Arc::new(conn);

    let opened = match spec.resume_session_id.as_deref() {
        Some(sid) if conn.supports_load_session() => {
            match conn.load_session(sid, &prepared.path).await {
                Ok(()) => NewSession {
                    session_id: sid.to_string(),
                    ..Default::default()
                },
                // A stale session id must not strand the task.
                Err(err) => {
                    tracing::debug!(?err, "could not resume session; starting a fresh one");
                    open_session(&conn, &prepared.path, &spec).await?
                }
            }
        }
        _ => open_session(&conn, &prepared.path, &spec).await?,
    };
    let session_id = opened.session_id.clone();

    // Tell the relay what this runtime turned out to offer, so the agent editor
    // can show a real list of models instead of a text box and a hope.
    if !opened.models.is_empty() || !opened.thinking.is_empty() || !opened.modes.is_empty() {
        emit(HostToRelay::RuntimeOptions {
            runtime: spec.runtime.clone(),
            models: opened.models.clone(),
            thinking: opened.thinking.clone(),
            modes: opened.modes.clone(),
            default_model: opened.current_model.clone(),
            default_thinking: opened.current_thinking.clone(),
            default_mode: opened.current_mode.clone(),
        });
    }
    apply_session_preferences(&conn, &session_id, &spec, &opened, &run_id, &out).await;
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
                        // Setup failures live here — a missing login, a bad
                        // config — so they belong in the run log where someone
                        // debugging will actually look.
                        let mut s = state.lock().await;
                        if s.stderr.len() < 200 {
                            s.stderr.push(line.clone());
                            drop(s);
                            let _ = out.send(HostToRelay::RunEvent {
                                run_id: run_id.clone(),
                                kind: classify_stderr(&line),
                                text: line,
                                data: None,
                            });
                        }
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

    // 5. Prompt turns. ACP accepts one prompt at a time, so steering is either
    //    queued for the next turn or cancels only the current turn first.
    let mut pending = VecDeque::new();
    let mut next = Some((None::<Id>, compose_first_prompt(&spec, &files)));
    let mut turns = 0usize;
    let mut stop_run = false;

    while let Some((control_id, prompt)) = next.take() {
        turns += 1;
        if let Some(control_id) = &control_id {
            emit(HostToRelay::RunControlStatus {
                run_id: run_id.clone(),
                control_id: control_id.clone(),
                state: RunControlState::Started,
            });
        }

        let mut prompt_call = Box::pin(conn.prompt(&session_id, &prompt));
        let mut interrupted = false;
        let stop_reason = loop {
            tokio::select! {
                result = &mut prompt_call => break result,
                cmd = control.recv() => match cmd {
                    Some(RelayToHost::FollowUp { control_id, prompt, mode, files, .. }) => {
                        let files = fetch_files(&prepared.path, &files).await;
                        emit(HostToRelay::RunControlStatus {
                            run_id: run_id.clone(),
                            control_id: control_id.clone(),
                            state: RunControlState::Queued,
                        });
                        if queue_control(
                            &mut pending,
                            &mut interrupted,
                            QueuedControl { control_id, prompt, files },
                            mode,
                        ) {
                            conn.cancel(&session_id);
                        }
                    }
                    Some(RelayToHost::CancelRun { .. }) => {
                        stop_run = true;
                        conn.cancel(&session_id);
                        break Ok("cancelled".to_string());
                    }
                    Some(RelayToHost::QuestionAsked { .. }) => {
                        begin_message_after_question(&state).await;
                    }
                    Some(RelayToHost::AnswerQuestion { .. }) => {
                        // The HTTP long-poll carries the value; this signal
                        // preserves the message boundary if the earlier one was lost.
                        begin_message_after_question(&state).await;
                    }
                    Some(_) => {}
                    None => break (&mut prompt_call).await,
                }
            }
        };

        if interrupted {
            let mut turn = state.lock().await;
            if !turn.message.trim().is_empty() {
                turn.message
                    .push_str("\n\n_(Interrupted by new feedback.)_");
            }
        }
        flush_message(&run_id, &out, &state, &spec).await;

        let stop_reason = match stop_reason {
            Ok(reason) => reason,
            Err(_) if interrupted => "cancelled".to_string(),
            Err(err) => {
                runner.set_accepting(&run_id, false).await;
                reject_pending(&mut pending, &run_id, &out);
                while let Ok(cmd) = control.try_recv() {
                    if let RelayToHost::FollowUp { control_id, .. } = cmd {
                        emit(HostToRelay::RunControlStatus {
                            run_id: run_id.clone(),
                            control_id,
                            state: RunControlState::Rejected,
                        });
                    }
                }
                let detail = {
                    let s = state.lock().await;
                    if s.stderr.is_empty() {
                        String::new()
                    } else {
                        format!("\n{}", s.stderr.join("\n"))
                    }
                };
                pump.abort();
                conn.shutdown().await;
                return Err(anyhow!("{err}{detail}"));
            }
        };

        emit(HostToRelay::RunEvent {
            run_id: run_id.clone(),
            kind: RunEventKind::Lifecycle,
            text: format!("Turn {turns} ended: {stop_reason}"),
            data: None,
        });

        let closed = pending.is_empty();
        if closed {
            // Close under the same lock used by `handle`, then drain anything
            // accepted just before the close. Nothing can now land unread.
            runner.set_accepting(&run_id, false).await;
        }
        let mut between_turns = false;
        while let Ok(cmd) = control.try_recv() {
            match cmd {
                RelayToHost::FollowUp {
                    control_id,
                    prompt,
                    mode,
                    files,
                    ..
                } => {
                    let files = fetch_files(&prepared.path, &files).await;
                    emit(HostToRelay::RunControlStatus {
                        run_id: run_id.clone(),
                        control_id: control_id.clone(),
                        state: RunControlState::Queued,
                    });
                    queue_control(
                        &mut pending,
                        &mut between_turns,
                        QueuedControl {
                            control_id,
                            prompt,
                            files,
                        },
                        mode,
                    );
                }
                RelayToHost::CancelRun { .. } => stop_run = true,
                _ => {}
            }
        }
        if stop_run {
            reject_pending(&mut pending, &run_id, &out);
            break;
        }

        if let Some(queued) = pending.pop_front() {
            if closed {
                runner.set_accepting(&run_id, true).await;
            }
            next = Some((
                Some(queued.control_id),
                compose_follow_up(&queued.prompt, &queued.files),
            ));
        }
    }

    pump.abort();
    if stop_run {
        conn.shutdown().await;
        return Ok(());
    }

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

    conn.shutdown().await;
    Ok(())
}

/// Apply the agent's configured model and permission mode.
///
/// A runtime that cannot switch is not a reason to fail the run: the session is
/// already open and perfectly usable on its defaults. But it *is* worth saying
/// out loud, because "I set this agent to a cheap model" silently not happening
/// is exactly the kind of thing that shows up later on a bill.
async fn apply_session_preferences(
    conn: &AcpConnection,
    session_id: &str,
    spec: &RunSpec,
    opened: &NewSession,
    run_id: &str,
    out: &Sink,
) {
    let note = |text: String| {
        let _ = out.send(HostToRelay::RunEvent {
            run_id: run_id.to_string(),
            kind: RunEventKind::Lifecycle,
            text,
            data: None,
        });
    };

    if let Some(model) = spec.model.as_deref().filter(|m| !m.is_empty()) {
        if opened.current_model.as_deref() == Some(model) {
            // Already what was asked for.
        } else if let Err(err) = conn
            .set_model(session_id, model, opened.config_options)
            .await
        {
            note(format!("could not select model `{model}`: {err:#}"));
        } else {
            note(format!("model: {model}"));
        }
    }

    if let Some(level) = spec.thinking.as_deref().filter(|m| !m.is_empty()) {
        if opened.current_thinking.as_deref() == Some(level) {
            // Already what was asked for.
        } else if let Err(err) = conn.set_thinking(session_id, level).await {
            note(format!("could not think `{level}`: {err:#}"));
        } else {
            note(format!("thinking: {level}"));
        }
    }

    // Permissions are not a per-agent setting: an agent here works in its own
    // worktree with its own run log, and being asked to approve every edit
    // while nobody is watching is how a run stalls. Take the widest mode the
    // runtime offers, or leave its default alone when none of them is about
    // permission at all.
    if let Some(mode) = most_permissive(&opened.modes) {
        if opened.current_mode.as_deref() != Some(mode.as_str()) {
            if let Err(err) = conn
                .set_mode(session_id, &mode, opened.config_options)
                .await
            {
                note(format!("could not select mode `{mode}`: {err:#}"));
            } else {
                note(format!("mode: {mode}"));
            }
        }
    }
}

/// The widest of the modes a runtime offers, by the names they use for it.
/// Anything unrecognised is left alone: OpenCode's `build`/`plan` are a
/// different question, and picking one of them at random is not an answer.
fn most_permissive(modes: &[patchwork_core::models::RuntimeOption]) -> Option<String> {
    const WIDEST: [&str; 6] = [
        "bypassPermissions",
        "full-access",
        "dontAsk",
        "yolo",
        "acceptEdits",
        "auto",
    ];
    WIDEST
        .iter()
        .find(|wanted| modes.iter().any(|mode| mode.id == **wanted))
        .map(|found| found.to_string())
}

/// Open a session, authenticating only if the runtime insists — and only with
/// a method that needs no human at a browser, since nobody is watching this
/// process.
async fn open_session(conn: &AcpConnection, cwd: &str, spec: &RunSpec) -> Result<NewSession> {
    match conn.new_session(cwd, json!([])).await {
        Ok(session) => Ok(session),
        Err(first_error) => {
            let Some(method) = non_interactive_auth_method(conn) else {
                // Ours is the one runtime whose credentials Patchwork itself
                // is responsible for, so it can say exactly where to fix it.
                if spec.runtime == detect::PATCHWORK_RUNTIME {
                    return Err(first_error.context(
                        "this machine has no key for the provider this agent uses \
(Settings → Patchwork agent providers)",
                    ));
                }
                return Err(first_error.context(
                    "the runtime needs to be signed in on this machine \
(run it once yourself, or set its API key environment variable)",
                ));
            };
            conn.authenticate(&method).await?;
            conn.new_session(cwd, json!([])).await
        }
    }
}

/// An `env_var` method whose variables are actually set. Interactive logins are
/// never triggered automatically.
fn non_interactive_auth_method(conn: &AcpConnection) -> Option<String> {
    conn.auth_methods.iter().find_map(|method| {
        if method.get("type").and_then(|v| v.as_str()) != Some("env_var") {
            return None;
        }
        let ready = method
            .get("vars")
            .and_then(|v| v.as_array())
            .map(|vars| {
                vars.iter().all(|var| {
                    var.get("name")
                        .and_then(|n| n.as_str())
                        .map(|name| std::env::var(name).is_ok())
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false);
        if !ready {
            return None;
        }
        method
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    })
}

async fn handle_update(run_id: &str, update: Value, out: &Sink, state: &Arc<Mutex<TurnState>>) {
    let kind = update
        .get("sessionUpdate")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    match kind {
        "agent_message_chunk" => {
            if let Some(text) = content_text(update.get("content")) {
                let phase = update
                    .pointer("/_meta/codex/phase")
                    .and_then(|value| value.as_str());
                let mut s = state.lock().await;
                // Codex commentary is useful while work is happening, but the
                // final answer replaces it rather than preserving the preamble.
                if phase == Some("final_answer")
                    && s.message_phase.as_deref() != Some("final_answer")
                {
                    s.message.clear();
                    s.streamed_at = None;
                    s.interrupted = false;
                }
                if let Some(phase) = phase {
                    s.message_phase = Some(phase.to_string());
                }
                // "Let me check the PATH." <tool runs> "Yes, it is at /usr/bin."
                // are two things the agent said, not one sentence. But a tool
                // call in the middle of a sentence does not end the sentence,
                // and breaking there is what put a blank line after the first
                // word of half the replies in the app.
                if s.interrupted {
                    if needs_break(&s.message) {
                        s.message.push_str("\n\n");
                    }
                    s.interrupted = false;
                }
                s.message.push_str(&text);
                let due = s
                    .streamed_at
                    .map(|at| at.elapsed() >= STREAM_INTERVAL)
                    .unwrap_or(true);
                // Nothing is gained by streaming leading whitespace, and an
                // empty draft in the transcript looks like a glitch.
                if due && !s.message.trim().is_empty() {
                    s.streamed_at = Some(std::time::Instant::now());
                    let body = s.message.clone();
                    drop(s);
                    let _ = out.send(HostToRelay::RunMessageDelta {
                        run_id: run_id.to_string(),
                        body,
                    });
                }
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
        // Only a tool actually starting interrupts what is being said. An
        // update to one already running, or the runtime listing its commands,
        // is not the agent pausing mid-thought.
        "tool_call" | "plan" => {
            let mut s = state.lock().await;
            s.interrupted = true;
            // A throttled delta may still be missing the last few words when a
            // tool starts. Publish the complete progress line before it pauses.
            if kind == "tool_call" && !s.message.trim().is_empty() {
                s.streamed_at = Some(std::time::Instant::now());
                let body = s.message.clone();
                drop(s);
                let _ = out.send(HostToRelay::RunMessageDelta {
                    run_id: run_id.to_string(),
                    body,
                });
            }
        }
        _ => {}
    }

    match kind {
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
                    let status = e
                        .get("status")
                        .and_then(|v| v.as_str())
                        .unwrap_or("pending");
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

/// Runtimes are chatty on stderr. A deprecation notice from a package manager
/// is not an error, and marking it as one makes real failures harder to find.
fn classify_stderr(line: &str) -> RunEventKind {
    let lowered = line.to_lowercase();
    let noisy = ["warn", "notice", "deprecat", "info"];
    if noisy.iter().any(|needle| lowered.contains(needle)) && !lowered.contains("error") {
        RunEventKind::Lifecycle
    } else {
        RunEventKind::Error
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

/// Whether a paragraph break belongs between what has been said and what
/// comes next. Only after a finished sentence: a tool call mid-sentence is an
/// interruption to the agent, not to the reader.
fn needs_break(message: &str) -> bool {
    let trimmed = message.trim_end();
    if trimmed.is_empty() || message.ends_with('\n') {
        return false;
    }
    trimmed.ends_with(['.', '!', '?', ':', '\u{201d}', '"', ')', '`'])
}

async fn flush_message(run_id: &str, out: &Sink, state: &Arc<Mutex<TurnState>>, _spec: &RunSpec) {
    let (message, thought) = {
        let mut s = state.lock().await;
        s.streamed_at = None;
        s.message_phase = None;
        s.interrupted = false;
        (
            std::mem::take(&mut s.message),
            std::mem::take(&mut s.thought),
        )
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
            .ok_or_else(|| {
                anyhow!("this agent uses a custom runtime but no command is configured")
            });
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
    // The same PATH detection used, so a run finds what the machine reported —
    // and so `npm test` works in an app that was opened from the Finder.
    let path = detect::search_path();
    env.push((
        "PATH".into(),
        match &cfg.cli_dir {
            Some(dir) => format!("{dir}:{path}"),
            None => path,
        },
    ));
    // Our own agent is Pi with a provider the workspace picked, pointed at a
    // config directory this app owns rather than the user's own `~/.pi`.
    if spec.runtime == detect::PATCHWORK_RUNTIME {
        env.extend(crate::providers::pi_env(
            spec.provider.as_deref(),
            spec.model.as_deref(),
        ));
    }
    env.extend(project_env(spec.project_name.as_deref()));
    env.extend(cfg.env.iter().cloned());
    env.extend(spec.env.iter().cloned());
    env
}

/// What this machine knows about a project that the workspace must not: a
/// database URL, an API key, whatever the code needs to run here.
///
/// `~/.patchwork/env/<project>.env`, plain `KEY=value` lines. It belongs to
/// the machine, so a relay and a laptop can hold different values for the
/// same project and neither is in the workspace database.
pub fn project_env(project_name: Option<&str>) -> Vec<(String, String)> {
    let Some(name) = project_name else {
        return Vec::new();
    };
    let path = project_env_path(name);
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    parse_env(&text)
}

pub fn project_env_path(project_name: &str) -> std::path::PathBuf {
    worktree::work_root().join("env").join(format!(
        "{}.env",
        worktree::sanitize(&project_name.to_lowercase())
    ))
}

/// `KEY=value`, `export KEY=value`, `#` comments, optional quotes. Deliberately
/// not a dotenv library: this is a handful of lines a person typed.
fn parse_env(text: &str) -> Vec<(String, String)> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .filter_map(|line| {
            let line = line.strip_prefix("export ").unwrap_or(line);
            let (key, value) = line.split_once('=')?;
            let key = key.trim();
            if key.is_empty() {
                return None;
            }
            let value = value.trim();
            let value = value
                .strip_prefix('"')
                .and_then(|v| v.strip_suffix('"'))
                .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
                .unwrap_or(value);
            Some((key.to_string(), value.to_string()))
        })
        .collect()
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

/// Task files, downloaded next to the work.
///
/// An agent that can read a file does not need it pasted into its prompt: a
/// screenshot is a path, and every runtime here can open one. Failures are
/// not fatal — a missing screenshot is worth less than the run.
async fn fetch_files(cwd: &str, files: &[RunFile]) -> Vec<String> {
    if files.is_empty() {
        return Vec::new();
    }
    let dir = std::path::Path::new(cwd).join(".patchwork").join("files");
    if tokio::fs::create_dir_all(&dir).await.is_err() {
        return Vec::new();
    }

    let client = reqwest::Client::new();
    let mut taken: HashMap<String, usize> = HashMap::new();
    let mut out = Vec::new();
    for file in files {
        let name = unique_name(&mut taken, &file.file_name);
        let path = dir.join(&name);
        let bytes = match client.get(&file.url).send().await {
            Ok(response) => match response.error_for_status() {
                Ok(response) => response.bytes().await.ok(),
                Err(err) => {
                    tracing::warn!(?err, file = %file.file_name, "could not fetch a task file");
                    None
                }
            },
            Err(err) => {
                tracing::warn!(?err, file = %file.file_name, "could not fetch a task file");
                None
            }
        };
        let Some(bytes) = bytes else { continue };
        if tokio::fs::write(&path, &bytes).await.is_ok() {
            out.push(path.to_string_lossy().to_string());
        }
    }
    out
}

/// Two screenshots called `image.png` are two files, not one.
fn unique_name(taken: &mut HashMap<String, usize>, file_name: &str) -> String {
    let clean: String = file_name
        .chars()
        .map(|c| if c == '/' || c == '\\' { '-' } else { c })
        .collect();
    let clean = if clean.trim().is_empty() {
        "file".to_string()
    } else {
        clean
    };
    let seen = taken.entry(clean.clone()).or_insert(0);
    *seen += 1;
    if *seen == 1 {
        return clean;
    }
    match clean.rsplit_once('.') {
        Some((stem, extension)) => format!("{stem}-{seen}.{extension}"),
        None => format!("{clean}-{seen}"),
    }
}

fn compose_follow_up(prompt: &str, files: &[String]) -> String {
    if files.is_empty() {
        return prompt.to_string();
    }
    format!(
        "{prompt}\n\nFiles attached to this message:\n{}\nRead them from disk.",
        files
            .iter()
            .map(|path| format!("- {path}"))
            .collect::<Vec<_>>()
            .join("\n")
    )
}

fn compose_first_prompt(spec: &RunSpec, files: &[String]) -> String {
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
    if !files.is_empty() {
        s.push_str("## Files on this task\n\n");
        for path in files {
            s.push_str(&format!("- {path}\n"));
        }
        s.push_str("\nRead them from disk; they are not in this prompt.\n\n---\n");
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
            provider: None,
            model: None,
            thinking: None,
            custom_command: None,
            channel_id: "c1".into(),
            task_id: Some("t1".into()),
            project_id: None,
            project_name: None,
            automation_id: None,
            worktree: WorktreeSpec::None,
            prompt: "Fix the failing test".into(),
            context: "#dev — Vince: the checkout test is red".into(),
            files: Vec::new(),
            api_base: "http://localhost:7727".into(),
            api_token: "tok".into(),
            resume_session_id: None,
            env: vec![],
        }
    }

    #[test]
    fn a_run_takes_the_widest_mode_its_runtime_offers() {
        let modes = |ids: &[&str]| -> Vec<patchwork_core::models::RuntimeOption> {
            ids.iter()
                .map(|id| patchwork_core::models::RuntimeOption {
                    id: id.to_string(),
                    name: id.to_string(),
                    description: String::new(),
                })
                .collect()
        };
        assert_eq!(
            most_permissive(&modes(&[
                "default",
                "acceptEdits",
                "plan",
                "bypassPermissions"
            ])),
            Some("bypassPermissions".into())
        );
        assert_eq!(
            most_permissive(&modes(&["read-only", "auto", "full-access"])),
            Some("full-access".into())
        );
        // Build or plan is a different question, and neither answer is "wider".
        assert_eq!(most_permissive(&modes(&["build", "plan"])), None);
        assert_eq!(most_permissive(&[]), None);
    }

    #[test]
    fn a_tool_call_only_breaks_the_text_between_sentences() {
        // What put "Not\n\ndirectly \u2014 the CLI\u2026" in the transcript.
        assert!(!needs_break("Not"));
        assert!(!needs_break("the file is at /usr/bin/"));
        assert!(needs_break("Let me check the PATH."));
        assert!(needs_break("Here is what I found:"));
        assert!(!needs_break(""));
        assert!(!needs_break("Done.\n"));
    }

    #[tokio::test]
    async fn a_confirmed_question_starts_a_new_transcript_message() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let state = Arc::new(Mutex::new(TurnState::default()));
        let chunk = |text: &str| {
            json!({
                "sessionUpdate": "agent_message_chunk",
                "content": { "type": "text", "text": text }
            })
        };

        handle_update("r1", chunk("Before."), &tx, &state).await;
        begin_message_after_question(&state).await;
        assert!(state.lock().await.message.is_empty());

        handle_update("r1", chunk("After."), &tx, &state).await;
        let deltas = std::iter::from_fn(|| rx.try_recv().ok())
            .filter_map(|message| match message {
                HostToRelay::RunMessageDelta { body, .. } => Some(body),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(deltas.last().map(String::as_str), Some("After."));
    }

    #[test]
    fn first_prompt_carries_identity_skill_and_context() {
        let p = compose_first_prompt(&spec(), &[]);
        assert!(p.contains("Developer agent"));
        assert!(p.contains("You ship small, reviewable changes."));
        assert!(p.contains("patchwork ask"));
        assert!(p.contains("the checkout test is red"));
        assert!(p.contains("Fix the failing test"));
    }

    #[test]
    fn an_env_file_is_a_handful_of_lines_a_person_typed() {
        let parsed = parse_env(
            "# the database\nDATABASE_URL=postgres://localhost/dev\n\nexport TOKEN=\"abc 123\"\nBAD\nEMPTY=\n",
        );
        assert_eq!(
            parsed,
            vec![
                ("DATABASE_URL".into(), "postgres://localhost/dev".into()),
                ("TOKEN".into(), "abc 123".into()),
                ("EMPTY".into(), String::new()),
            ]
        );
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

    #[test]
    fn steering_keeps_queue_order_and_puts_the_first_interrupt_next() {
        let control = |id: &str| QueuedControl {
            control_id: id.into(),
            prompt: id.into(),
            files: Vec::new(),
        };
        let mut queue = VecDeque::new();
        let mut interrupted = false;
        assert!(!queue_control(
            &mut queue,
            &mut interrupted,
            control("later"),
            RunControlMode::Queue,
        ));
        assert!(queue_control(
            &mut queue,
            &mut interrupted,
            control("now"),
            RunControlMode::Interrupt,
        ));
        assert!(!queue_control(
            &mut queue,
            &mut interrupted,
            control("after"),
            RunControlMode::Interrupt,
        ));
        assert_eq!(
            queue
                .into_iter()
                .map(|item| item.control_id)
                .collect::<Vec<_>>(),
            vec!["now", "later", "after"]
        );
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
    async fn prose_streams_as_deltas_but_posts_once_per_turn() {
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

        let mut deltas = Vec::new();
        let mut early_messages = 0;
        while let Ok(msg) = rx.try_recv() {
            match msg {
                HostToRelay::RunMessageDelta { body, .. } => deltas.push(body),
                HostToRelay::RunMessage { .. } => early_messages += 1,
                _ => {}
            }
        }
        // A delta rewrites a draft; a RunMessage is the turn's final word. Only
        // the second may happen before the turn is over.
        assert_eq!(early_messages, 0, "chunks must not post the message itself");
        // Each delta carries the whole reply so far, never just the newest
        // fragment — that is what makes a dropped frame harmless.
        assert!(
            !deltas.is_empty(),
            "a reply should stream while it is written"
        );
        for delta in &deltas {
            assert!("Fixed the test.".starts_with(delta.as_str()));
        }

        flush_message("r1", &tx, &state, &spec()).await;
        let mut bodies = Vec::new();
        while let Ok(msg) = rx.try_recv() {
            if let HostToRelay::RunMessage { body, .. } = msg {
                bodies.push(body);
            }
        }
        assert_eq!(bodies, vec!["Fixed the test.".to_string()]);
    }

    #[tokio::test]
    async fn final_answer_replaces_a_complete_progress_draft() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let state = Arc::new(Mutex::new(TurnState::default()));
        let commentary = |text: &str| json!({
            "sessionUpdate": "agent_message_chunk",
            "content": { "type": "text", "text": text },
            "_meta": { "codex": { "phase": "commentary" } }
        });

        handle_update("r1", commentary("I'm "), &tx, &state).await;
        handle_update("r1", commentary("checking now."), &tx, &state).await;
        handle_update(
            "r1",
            json!({ "sessionUpdate": "tool_call", "title": "bash", "status": "pending" }),
            &tx,
            &state,
        )
        .await;

        let mut deltas = Vec::new();
        while let Ok(msg) = rx.try_recv() {
            if let HostToRelay::RunMessageDelta { body, .. } = msg {
                deltas.push(body);
            }
        }
        assert_eq!(deltas.last().map(String::as_str), Some("I'm checking now."));

        handle_update(
            "r1",
            json!({
                "sessionUpdate": "agent_message_chunk",
                "content": { "type": "text", "text": "Done." },
                "_meta": { "codex": { "phase": "final_answer" } }
            }),
            &tx,
            &state,
        )
        .await;
        flush_message("r1", &tx, &state, &spec()).await;

        let mut bodies = Vec::new();
        while let Ok(msg) = rx.try_recv() {
            if let HostToRelay::RunMessage { body, .. } = msg {
                bodies.push(body);
            }
        }
        assert_eq!(bodies, vec!["Done.".to_string()]);
    }

    #[tokio::test]
    async fn work_between_two_sentences_becomes_a_paragraph_break() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let state = Arc::new(Mutex::new(TurnState::default()));
        let chunk = |text: &str| json!({ "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": text } });

        handle_update("r1", chunk("Let me check the PATH."), &tx, &state).await;
        handle_update(
            "r1",
            json!({ "sessionUpdate": "tool_call", "title": "bash", "status": "completed" }),
            &tx,
            &state,
        )
        .await;
        handle_update("r1", chunk("Yes, it is at /usr/bin."), &tx, &state).await;
        flush_message("r1", &tx, &state, &spec()).await;

        let mut bodies = Vec::new();
        while let Ok(msg) = rx.try_recv() {
            if let HostToRelay::RunMessage { body, .. } = msg {
                bodies.push(body);
            }
        }
        assert_eq!(
            bodies,
            vec!["Let me check the PATH.\n\nYes, it is at /usr/bin.".to_string()],
            "two things the agent said must not arrive glued together",
        );
    }

    #[tokio::test]
    async fn a_new_turn_starts_a_new_draft() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let state = Arc::new(Mutex::new(TurnState::default()));
        let chunk = |text: &str| json!({ "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": text } });

        handle_update("r1", chunk("first"), &tx, &state).await;
        flush_message("r1", &tx, &state, &spec()).await;
        handle_update("r1", chunk("second"), &tx, &state).await;
        flush_message("r1", &tx, &state, &spec()).await;

        let mut bodies = Vec::new();
        while let Ok(msg) = rx.try_recv() {
            if let HostToRelay::RunMessage { body, .. } = msg {
                bodies.push(body);
            }
        }
        // The second turn must not repeat the first: flushing resets the buffer
        // and the streaming clock together.
        assert_eq!(bodies, vec!["first".to_string(), "second".to_string()]);
    }
}
