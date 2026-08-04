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
        project_path: String,
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
    /// `codex`, `claude`, `pi`, `custom`.
    pub runtime: String,
    /// The model this agent should think with, named as the runtime names it.
    /// Unset leaves the machine's own runtime configuration alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The runtime's permission mode, e.g. `read-only`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_command: Option<Vec<String>>,
    pub channel_id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation_id: Option<Id>,
    pub worktree: WorktreeSpec,
    /// The instruction for this turn.
    pub prompt: String,
    /// Compact, human-readable context: who is talking, recent messages, task
    /// outcome. Deep history stays retrievable through the Patchwork CLI.
    #[serde(default)]
    pub context: String,
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
    /// A user answered the agent's question; resume the waiting turn.
    AnswerQuestion {
        run_id: Id,
        question_id: Id,
        answers: Vec<QuestionAnswer>,
    },
    /// The user said something else while the run was still active.
    FollowUp {
        run_id: Id,
        prompt: String,
    },
    StartPreview {
        preview_id: Id,
        task_id: Id,
        cwd: String,
        command: String,
        port: u16,
        label: String,
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
    RuntimeOptions {
        runtime: String,
        #[serde(default)]
        models: Vec<RuntimeOption>,
        #[serde(default)]
        modes: Vec<RuntimeOption>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default_model: Option<String>,
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
    Pong {
        at: Millis,
    },
}
