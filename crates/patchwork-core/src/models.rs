use serde::{Deserialize, Serialize};
use serde_json::Value as Json;

use crate::ids::{Id, Millis};

// ---------------------------------------------------------------------------
// Members: humans and agents share one identity space so that authorship,
// mentions, DMs, ownership and reactions have exactly one shape.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemberKind {
    Human,
    Agent,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Member {
    pub id: Id,
    pub kind: MemberKind,
    /// `@handle`, unique in the workspace.
    pub handle: String,
    pub display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    /// Emoji or a `/files/...` path. Kept tiny on purpose.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
    #[serde(default)]
    pub is_admin: bool,
    pub created_at: Millis,
    /// Present only for `MemberKind::Agent`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<AgentProfile>,
    /// Live presence, filled in by the relay; never stored.
    #[serde(default)]
    pub presence: Presence,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Presence {
    #[default]
    Offline,
    Online,
    Away,
    /// Agent-only states.
    Thinking,
    Working,
    Waiting,
}

/// Where an agent identity prefers to run. The identity is deliberately
/// separate from the runtime that powers it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionLocation {
    /// Wherever the required project is available; prefer relay.
    #[default]
    Auto,
    Relay,
    /// A specific desktop host (see `AgentProfile::host_id`).
    Desktop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Participation {
    /// Never speaks unless explicitly invoked elsewhere (task, automation).
    Off,
    /// Replies when @-mentioned or DM'd. The default.
    #[default]
    Mention,
    /// May contribute to any human message in the channel when it has
    /// something material to add.
    Ambient,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentProfile {
    /// Public description / system prompt: personality, voice, expertise,
    /// responsibilities, working style, and what it will decline.
    #[serde(default)]
    pub description: String,
    /// Id of a runtime in the host's catalog: `codex`, `claude`, `gemini`,
    /// `grok`, `opencode`, `pi`, `patchwork`, `custom`.
    #[serde(default = "default_runtime")]
    pub runtime: String,
    /// For `runtime == "custom"`: the ACP command line to launch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_command: Option<Vec<String>>,
    /// For `runtime == "patchwork"`: whose models it thinks with. The key or
    /// login itself belongs to the machine that runs it, never to the
    /// workspace, so only the choice is stored here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default)]
    pub location: ExecutionLocation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_id: Option<Id>,
    #[serde(default = "default_true")]
    pub dm_enabled: bool,
    #[serde(default)]
    pub default_participation: Participation,
    /// Optional per-channel overrides: channel id -> participation.
    #[serde(default)]
    pub channel_participation: std::collections::BTreeMap<Id, Participation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_project_id: Option<Id>,
    /// Which model this agent thinks with, as the runtime names it. For Codex
    /// the reasoning effort is part of the id — `gpt-5.6-sol[high]` — so this
    /// one field is both "which model" and "how hard should it think".
    /// Unset means whatever the machine's own runtime config says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The runtime's permission mode: `read-only`, `agent`, and so on. Named
    /// by the runtime, not by us, because the meanings are the runtime's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
}

fn default_runtime() -> String {
    "codex".to_string()
}
fn default_true() -> bool {
    true
}

impl Default for AgentProfile {
    fn default() -> Self {
        Self {
            description: String::new(),
            runtime: default_runtime(),
            custom_command: None,
            provider: None,
            location: ExecutionLocation::default(),
            host_id: None,
            dm_enabled: true,
            default_participation: Participation::default(),
            channel_participation: Default::default(),
            default_project_id: None,
            model: None,
            permission_mode: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Sections and channels
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Section {
    pub id: Id,
    pub name: String,
    pub position: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelKind {
    Channel,
    Dm,
    /// The discussion attached to a task. Never shown in the sidebar.
    Task,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Channel {
    pub id: Id,
    pub kind: ChannelKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub section_id: Option<Id>,
    /// `infra` for `# infra`; empty for DMs and task discussions.
    pub slug: String,
    pub name: String,
    #[serde(default)]
    pub topic: String,
    pub position: f64,
    pub created_at: Millis,
    /// DM participants / explicit channel membership. Empty means "everyone".
    #[serde(default)]
    pub member_ids: Vec<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    /// Denormalised for the sidebar.
    #[serde(default)]
    pub last_message_at: Millis,
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageKind {
    /// Ordinary prose from a human or agent.
    Text,
    /// Concise agent progress note. Rendered quieter than `Text`.
    Status,
    /// Workspace bookkeeping ("Alice created this task").
    System,
    /// A card: see `MessageCard`.
    Card,
}

/// Structured cards that live inline in a conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MessageCard {
    Task {
        task_id: Id,
    },
    Run {
        run_id: Id,
    },
    Question {
        question_id: Id,
    },
    Artifact {
        attachment_id: Id,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        caption: Option<String>,
    },
    Preview {
        preview_id: Id,
    },
    PullRequest {
        url: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        task_id: Option<Id>,
    },
    /// A chart, as a Flint chart spec: data, what the fields mean, and how to
    /// draw them. Kept as the spec rather than an image so it stays readable,
    /// re-renderable and small.
    Chart {
        spec: Json,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        caption: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: Id,
    pub channel_id: Id,
    pub author_id: Id,
    pub kind: MessageKind,
    #[serde(default)]
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub card: Option<MessageCard>,
    /// Root message of the thread this reply belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<Id>,
    #[serde(default)]
    pub reply_count: u32,
    #[serde(default)]
    pub last_reply_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    #[serde(default)]
    pub mentions: Vec<Id>,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
    #[serde(default)]
    pub reactions: Vec<Reaction>,
    pub created_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<Millis>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reaction {
    pub emoji: String,
    pub member_ids: Vec<Id>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Attachment {
    pub id: Id,
    pub file_name: String,
    pub mime: String,
    pub size: i64,
    /// Relay-relative download path.
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<Id>,
    pub created_at: Millis,
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Planned,
    Running,
    Blocked,
    Review,
    Done,
}

impl TaskStatus {
    pub const ALL: [TaskStatus; 5] = [
        TaskStatus::Planned,
        TaskStatus::Running,
        TaskStatus::Blocked,
        TaskStatus::Review,
        TaskStatus::Done,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            TaskStatus::Planned => "planned",
            TaskStatus::Running => "running",
            TaskStatus::Blocked => "blocked",
            TaskStatus::Review => "review",
            TaskStatus::Done => "done",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "planned" => TaskStatus::Planned,
            "running" => TaskStatus::Running,
            "blocked" => TaskStatus::Blocked,
            "review" => TaskStatus::Review,
            "done" => TaskStatus::Done,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: Id,
    /// Short human key, e.g. `PW-14`.
    pub key: String,
    pub title: String,
    /// The expected result, in the requester's words.
    #[serde(default)]
    pub outcome: String,
    pub status: TaskStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_id: Option<Id>,
    /// Channel or DM the task came from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_channel_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_message_id: Option<Id>,
    /// Its own discussion (a channel of kind `task`).
    pub discussion_channel_id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_run_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_state: Option<PullRequestState>,
    pub created_by: Id,
    /// When this is meant to be done. The Inbox says so on the day.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_at: Option<Millis>,
    pub created_at: Millis,
    pub updated_at: Millis,
    /// Ordering within its board column.
    #[serde(default)]
    pub position: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullRequestState {
    pub number: i64,
    pub title: String,
    /// `open`, `merged`, `closed`, `draft`.
    pub state: String,
    #[serde(default)]
    pub checks: String,
    #[serde(default)]
    pub review: String,
    pub updated_at: Millis,
}

// ---------------------------------------------------------------------------
// Projects, hosts, worktrees
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProjectKind {
    Git,
    Folder,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub id: Id,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub kind: ProjectKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_url: Option<String>,
    #[serde(default = "default_branch")]
    pub default_branch: String,
    /// Where this project lives on each host: host id -> absolute path.
    #[serde(default)]
    pub paths: std::collections::BTreeMap<Id, String>,
    pub created_at: Millis,
}

fn default_branch() -> String {
    "main".into()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostKind {
    Relay,
    Desktop,
}

/// A machine that can execute agent runs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Host {
    pub id: Id,
    pub name: String,
    pub kind: HostKind,
    /// `macos-aarch64`, `linux-x86_64`, ...
    #[serde(default)]
    pub platform: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_id: Option<Id>,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub last_seen: Millis,
    #[serde(default)]
    pub capabilities: HostCapabilities,
    pub created_at: Millis,
}

/// What a machine can actually do — surfaced in the UI so setup failures are
/// understandable rather than mysterious.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HostCapabilities {
    /// ACP agent installations detected on this machine.
    #[serde(default)]
    pub runtimes: Vec<RuntimeInstallation>,
    #[serde(default)]
    pub has_git: bool,
    #[serde(default)]
    pub has_gh: bool,
    #[serde(default)]
    pub gh_authenticated: bool,
    #[serde(default)]
    pub has_node: bool,
    #[serde(default)]
    pub browser_automation: bool,
    #[serde(default)]
    pub home_dir: String,
    /// `user@hostname`. The relay and a desktop app on the same box are two
    /// hosts but one machine, and only this can tell you so.
    #[serde(default)]
    pub machine_key: String,
    #[serde(default)]
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeInstallation {
    /// `codex`, `claude`, `pi`, `custom`.
    pub id: String,
    pub label: String,
    pub available: bool,
    #[serde(default)]
    pub command: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
    /// What this installation offered the last time a session was opened.
    /// Learned rather than declared: only the runtime knows what it can run,
    /// and asking costs a process launch, so we remember the answer.
    #[serde(default)]
    pub models: Vec<RuntimeOption>,
    #[serde(default)]
    pub modes: Vec<RuntimeOption>,
    /// What it picks on its own when nothing is configured — usually whatever
    /// the machine's own config file says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_mode: Option<String>,
}

/// A model or a permission mode, as the runtime describes itself.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuntimeOption {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Worktree {
    pub id: Id,
    pub task_id: Id,
    pub project_id: Id,
    pub host_id: Id,
    pub path: String,
    #[serde(default)]
    pub branch: String,
    #[serde(default)]
    pub base_branch: String,
    /// `main_checkout` when the user deliberately used the primary checkout.
    #[serde(default)]
    pub is_main_checkout: bool,
    pub created_at: Millis,
}

// ---------------------------------------------------------------------------
// Runs
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Queued,
    /// Waiting for a host to pick it up.
    Dispatched,
    Running,
    /// Blocked on a question or a permission request.
    Waiting,
    Succeeded,
    Failed,
    Cancelled,
}

impl RunStatus {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            RunStatus::Succeeded | RunStatus::Failed | RunStatus::Cancelled
        )
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            RunStatus::Queued => "queued",
            RunStatus::Dispatched => "dispatched",
            RunStatus::Running => "running",
            RunStatus::Waiting => "waiting",
            RunStatus::Succeeded => "succeeded",
            RunStatus::Failed => "failed",
            RunStatus::Cancelled => "cancelled",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "queued" => RunStatus::Queued,
            "dispatched" => RunStatus::Dispatched,
            "running" => RunStatus::Running,
            "waiting" => RunStatus::Waiting,
            "succeeded" => RunStatus::Succeeded,
            "failed" => RunStatus::Failed,
            "cancelled" => RunStatus::Cancelled,
            _ => return None,
        })
    }
}

/// Why a run was started. Shown in the run header and the automation debugger.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RunTrigger {
    Mention { message_id: Id },
    DirectMessage { message_id: Id },
    TaskAssignment { task_id: Id },
    Manual { by: Id },
    Automation { automation_id: Id },
    Ambient { message_id: Id },
    PullRequestFeedback { task_id: Id },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Run {
    pub id: Id,
    pub agent_id: Id,
    pub status: RunStatus,
    pub trigger: RunTrigger,
    /// Where concise updates are posted.
    pub channel_id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation_id: Option<Id>,
    /// ACP session id, once the runtime has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default)]
    pub runtime: String,
    /// The prompt actually delivered to the agent.
    #[serde(default)]
    pub prompt: String,
    /// One-line summary of what is happening right now.
    #[serde(default)]
    pub headline: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default)]
    pub token_usage: Option<TokenUsage>,
    pub created_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<Millis>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<Millis>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TokenUsage {
    #[serde(default)]
    pub input: i64,
    #[serde(default)]
    pub output: i64,
}

/// The detailed activity inside a run. Users never have to read this to
/// understand what happened, but it is always there when debugging.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunEvent {
    pub id: Id,
    pub run_id: Id,
    pub seq: i64,
    pub kind: RunEventKind,
    #[serde(default)]
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Json>,
    pub created_at: Millis,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunEventKind {
    Lifecycle,
    Thought,
    Message,
    ToolCall,
    ToolResult,
    FileChange,
    Command,
    Permission,
    Question,
    Error,
    Plan,
}

// ---------------------------------------------------------------------------
// Agent questions — a first-class clarification flow.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Question {
    pub id: Id,
    pub run_id: Id,
    pub agent_id: Id,
    pub channel_id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<Id>,
    #[serde(default)]
    pub headline: String,
    pub items: Vec<QuestionItem>,
    pub status: QuestionStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answers: Option<Vec<QuestionAnswer>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answered_by: Option<Id>,
    pub created_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answered_at: Option<Millis>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QuestionStatus {
    Open,
    Answered,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionItem {
    pub id: String,
    /// Short chip label, e.g. `Auth method`.
    #[serde(default)]
    pub header: String,
    pub question: String,
    #[serde(default)]
    pub options: Vec<QuestionOption>,
    #[serde(default = "default_true")]
    pub allow_free_text: bool,
    #[serde(default)]
    pub multi_select: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionOption {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestionAnswer {
    pub item_id: String,
    pub values: Vec<String>,
    #[serde(default)]
    pub note: String,
}

// ---------------------------------------------------------------------------
// Inbox
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxKind {
    Mention,
    Reply,
    DirectMessage,
    Question,
    TaskAssigned,
    TaskBlocked,
    TaskDue,
    ReviewReady,
    AutomationFailed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InboxItem {
    pub id: Id,
    pub member_id: Id,
    pub kind: InboxKind,
    pub title: String,
    #[serde(default)]
    pub preview: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation_id: Option<Id>,
    pub created_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_at: Option<Millis>,
}

// ---------------------------------------------------------------------------
// Automations
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AutomationTrigger {
    /// Every N seconds from whenever it last ran. Fine for "poll this often";
    /// wrong for "every morning", which is what `Cron` is for.
    Schedule {
        /// Seconds between runs.
        every_seconds: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        start_at: Option<Millis>,
    },
    /// A wall-clock schedule in the relay's local time. "Daily at 09:00" has to
    /// mean 09:00 tomorrow, not "24 hours after I set this up".
    Cron {
        /// Standard five-field cron (`min hour day month weekday`).
        expression: String,
    },
    /// A new message in a channel, optionally matching a pattern.
    Message {
        channel_id: Id,
        #[serde(default)]
        pattern: String,
        #[serde(default)]
        include_agents: bool,
    },
    /// A task entering a status.
    TaskStatus {
        status: TaskStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        project_id: Option<Id>,
    },
    /// A task being assigned to the automation's agent.
    TaskAssigned,
    /// Pull request activity on a task.
    PullRequest {
        #[serde(default)]
        on_review_comment: bool,
        #[serde(default)]
        on_checks_failed: bool,
    },
    /// `POST /api/webhooks/{token}`.
    Webhook { token: String },
    Manual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AutomationAction {
    /// Post in the target channel.
    PostInChat,
    /// Create a new task and work in it.
    CreateTask,
    /// Continue the task carried by the trigger.
    ContinueTask,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Automation {
    pub id: Id,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub trigger: AutomationTrigger,
    pub agent_id: Id,
    pub action: AutomationAction,
    /// Instructions for the agent. Context is carried by reference, not by
    /// copying an oversized prompt in here.
    #[serde(default)]
    pub instructions: String,
    /// Conversation whose history provides the context, and where results are
    /// reported by default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_channel_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report_channel_id: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Id>,
    #[serde(default)]
    pub location: ExecutionLocation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_id: Option<Id>,
    pub created_by: Id,
    pub created_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run_at: Option<Millis>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run_at: Option<Millis>,
    #[serde(default)]
    pub failure_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationRun {
    pub id: Id,
    pub automation_id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<Id>,
    /// What actually fired it.
    pub trigger_summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trigger_payload: Option<Json>,
    /// The resolved selection: agent, host, project, task, channel.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<Json>,
    /// The context the agent actually received.
    #[serde(default)]
    pub context_preview: String,
    pub status: RunStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_id: Option<Id>,
    pub created_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<Millis>,
}

// ---------------------------------------------------------------------------
// Previews
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Preview {
    pub id: Id,
    pub task_id: Id,
    pub host_id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<Id>,
    pub label: String,
    pub port: u16,
    /// Where a workspace member can open it. Relay-hosted previews are proxied
    /// through the relay; local previews open on the owning desktop.
    pub url: String,
    pub status: PreviewStatus,
    #[serde(default)]
    pub local_only: bool,
    pub created_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stopped_at: Option<Millis>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PreviewStatus {
    Starting,
    Live,
    Stopped,
    Failed,
}

// ---------------------------------------------------------------------------
// Workspace
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workspace {
    pub id: Id,
    pub name: String,
    pub created_at: Millis,
    /// Next task number for `PW-<n>` keys.
    #[serde(default)]
    pub task_seq: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Invite {
    pub code: String,
    pub created_by: Id,
    pub created_at: Millis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(default)]
    pub is_admin: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_at: Option<Millis>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_by: Option<Id>,
}
