//! Protocol between the relay and an execution host.
//!
//! There is no separately installed host product: a Desktop app registers
//! itself as a host over the same WebSocket it uses for the UI, and the relay
//! registers itself as the built-in `relay` host. Both sides speak the messages
//! below, so local and hosted execution follow one code path.

use serde::{Deserialize, Serialize};
use serde_json::Value as Json;

use crate::ids::{Id, Millis};
use crate::models::*;

/// How a run's working directory is prepared.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WorktreeSpec {
    /// Non-code work: run in a scratch directory.
    None,
    /// Create (or reuse) a git worktree owned by the task.
    New {
        /// Where the project is on this machine, when it is already there.
        /// Absent means the host clones `repo_url` for itself: a checkout is
        /// something a machine can get, not something a person should have to
        /// put there by hand.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        project_path: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        repo_url: Option<String>,
        /// Names the directory a clone lands in.
        #[serde(default)]
        project_name: String,
        branch: String,
        base_branch: String,
    },
    /// Continue in a worktree this task already owns.
    Existing { path: String },
    /// The project's primary checkout, when explicitly desired.
    MainCheckout { project_path: String },
}

/// Everything a host needs to execute one run without calling back for more.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunSpec {
    pub run_id: Id,
    pub agent_id: Id,
    pub agent_handle: String,
    pub agent_name: String,
    /// The agent's public description / personality prompt.
    #[serde(default)]
    pub agent_description: String,
    /// Workspace-wide instructions available to every agent.
    #[serde(default)]
    pub skills: Vec<WorkspaceSkill>,
    /// `codex`, `claude`, `gemini`, `grok`, `opencode`, `pi`, `patchwork`,
    /// `custom`.
    pub runtime: String,
    /// For the `patchwork` runtime: whose models to think with. The credential
    /// stays on the host; this is only the choice.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// The model this agent should think with, named as the runtime names it.
    /// Unset leaves the machine's own runtime configuration alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// How hard to think, in the runtime's own words.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_command: Option<Vec<String>>,
    pub channel_id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Id>,
    /// Names the project's env file on the machine that runs it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation_id: Option<Id>,
    pub worktree: WorktreeSpec,
    /// The instruction for this turn.
    pub prompt: String,
    /// Compact, human-readable context: who is talking, recent messages, task
    /// outcome. Deep history stays retrievable through the Patchwork CLI.
    #[serde(default)]
    pub context: String,
    /// Files attached to this task. The host downloads them next to the work
    /// and hands the agent paths: a screenshot is a file, not a wall of
    /// base64 in a prompt.
    #[serde(default)]
    pub files: Vec<RunFile>,
    /// Base URL and token the agent's `patchwork` CLI should use.
    pub api_base: String,
    pub api_token: String,
    /// Resume this ACP session instead of starting a new one, when the runtime
    /// supports it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_session_id: Option<String>,
    #[serde(default)]
    pub env: Vec<(String, String)>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunFile {
    pub file_name: String,
    /// Absolute, so the host does not have to know how the relay is addressed.
    pub url: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunControlMode {
    #[default]
    Queue,
    Interrupt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunControlState {
    Queued,
    Started,
    Rejected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostRegistration {
    pub host_id: Id,
    pub name: String,
    pub kind: HostKind,
    pub platform: String,
    pub capabilities: HostCapabilities,
    /// Project id -> absolute path on this machine.
    #[serde(default)]
    pub project_paths: std::collections::BTreeMap<Id, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum RelayToHost {
    StartRun {
        spec: Box<RunSpec>,
    },
    CancelRun {
        run_id: Id,
    },
    /// The relay committed a question card. Prose after this belongs below it.
    QuestionAsked {
        run_id: Id,
    },
    /// A user answered the agent's question; resume the waiting turn.
    AnswerQuestion {
        run_id: Id,
        question_id: Id,
        answers: Vec<QuestionAnswer>,
    },
    /// Another prompt for the run's existing ACP session.
    FollowUp {
        run_id: Id,
        control_id: Id,
        prompt: String,
        #[serde(default)]
        mode: RunControlMode,
        #[serde(default)]
        files: Vec<RunFile>,
    },
    StartPreview {
        preview_id: Id,
        task_id: Id,
        cwd: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<String>,
        port: u16,
        label: String,
    },
    PreviewRequest {
        request_id: Id,
        preview_id: Id,
        method: String,
        path: String,
        #[serde(default)]
        headers: Vec<(String, String)>,
        #[serde(default)]
        body: String,
    },
    PreviewSocketOpen {
        socket_id: Id,
        preview_id: Id,
        path: String,
        #[serde(default)]
        headers: Vec<(String, String)>,
    },
    PreviewSocketData {
        socket_id: Id,
        data: String,
        #[serde(default)]
        binary: bool,
    },
    PreviewSocketClose {
        socket_id: Id,
    },
    StopPreview {
        preview_id: Id,
    },
    Ping,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum HostToRelay {
    Register {
        registration: Box<HostRegistration>,
    },
    Heartbeat {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        capabilities: Option<HostCapabilities>,
    },
    RunAccepted {
        run_id: Id,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    /// Detailed activity for the run log.
    RunEvent {
        run_id: Id,
        kind: RunEventKind,
        #[serde(default)]
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        data: Option<Json>,
    },
    RunControlStatus {
        run_id: Id,
        control_id: Id,
        state: RunControlState,
    },
    RunStatus {
        run_id: Id,
        status: RunStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        headline: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        token_usage: Option<TokenUsage>,
    },
    /// What a runtime on this machine offered when a session was opened.
    /// Sent as it is learned rather than at startup, because asking costs a
    /// process launch and the answer only matters once somebody runs something.
    /// This machine now has a checkout of a project, at this path. Sent after
    /// a clone, so the workspace shows where the code is without anyone
    /// typing a path into a box.
    ProjectCheckout {
        project_id: Id,
        path: String,
    },
    RuntimeOptions {
        runtime: String,
        #[serde(default)]
        models: Vec<RuntimeOption>,
        #[serde(default)]
        thinking: Vec<RuntimeOption>,
        #[serde(default)]
        modes: Vec<RuntimeOption>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default_model: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default_thinking: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default_mode: Option<String>,
    },
    /// The agent's reply so far, while it is still being written.
    ///
    /// `body` is the whole message up to this point rather than the newest
    /// fragment, so a dropped frame costs nothing: the next one is still
    /// correct. The relay posts the message on the first delta and rewrites it
    /// in place, which is what makes a reply appear as it is composed.
    RunMessageDelta {
        run_id: Id,
        body: String,
    },
    /// A concise, human-readable update authored by the agent.
    RunMessage {
        run_id: Id,
        kind: MessageKind,
        body: String,
    },
    RunQuestion {
        run_id: Id,
        #[serde(default)]
        headline: String,
        items: Vec<QuestionItem>,
        /// Correlation id chosen by the host; the answer comes back with it.
        request_id: String,
    },
    WorktreeReady {
        run_id: Id,
        path: String,
        #[serde(default)]
        branch: String,
        #[serde(default)]
        base_branch: String,
        #[serde(default)]
        is_main_checkout: bool,
    },
    PreviewStatus {
        preview_id: Id,
        status: PreviewStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    PreviewResponse {
        request_id: Id,
        status: u16,
        #[serde(default)]
        headers: Vec<(String, String)>,
        #[serde(default)]
        body: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    PreviewSocketReady {
        socket_id: Id,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    PreviewSocketData {
        socket_id: Id,
        data: String,
        #[serde(default)]
        binary: bool,
    },
    PreviewSocketClose {
        socket_id: Id,
    },
    Pong {
        at: Millis,
    },
}
