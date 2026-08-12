// Mirrors patchwork-core. Kept hand-written and small on purpose: the wire
// shape is the contract, and it is easier to read here than in generated code.

export type Id = string;
export type Millis = number;

export const REALTIME_HEARTBEAT = '{"t":"heartbeat"}';
export const REALTIME_HEARTBEAT_MS = 20_000;

export type MemberKind = "human" | "agent";
export type Presence =
  | "offline"
  | "online"
  | "away"
  | "thinking"
  | "working"
  | "waiting";
export type Participation = "off" | "mention" | "ambient";
export type ExecutionLocation = "auto" | "relay" | "desktop";

export interface AgentProfile {
  description: string;
  runtime: string;
  custom_command?: string[];
  location: ExecutionLocation;
  host_id?: Id;
  /// Named as the runtime names it. For Codex the reasoning effort is part of
  /// the id — `gpt-5.6-sol[high]` — so this is both "which model" and "how hard
  /// should it think".
  model?: string;
  /// Only the built-in `patchwork` runtime asks for one: it brings the agent
  /// but not the model, so a provider has to be named and keyed per machine.
  provider?: string;
  /// How hard it thinks, in the runtime's own words. Permissions are not a
  /// setting: a run takes the widest mode its runtime offers.
  thinking?: string;
  dm_enabled: boolean;
  default_participation: Participation;
  channel_participation: Record<Id, Participation>;
  default_project_id?: Id;
}

export interface Member {
  id: Id;
  kind: MemberKind;
  handle: string;
  display_name: string;
  email?: string;
  avatar?: string;
  is_admin: boolean;
  created_at: Millis;
  agent?: AgentProfile;
  presence: Presence;
}

export interface Section {
  id: Id;
  name: string;
  position: number;
}

export type ChannelKind = "channel" | "dm" | "task";

export interface Channel {
  id: Id;
  kind: ChannelKind;
  section_id?: Id;
  slug: string;
  name: string;
  topic: string;
  position: number;
  created_at: Millis;
  member_ids: Id[];
  task_id?: Id;
  last_message_at: Millis;
}

export type MessageKind = "text" | "status" | "system" | "card";

export type MessageCard =
  | { type: "task"; task_id: Id }
  | { type: "run"; run_id: Id }
  | { type: "question"; question_id: Id }
  | { type: "artifact"; attachment_id: Id; caption?: string }
  | { type: "preview"; preview_id: Id }
  | { type: "pull_request"; url: string; task_id?: Id }
  /// A Flint `ChartAssemblyInput`. Left `unknown` because the shape belongs to
  /// flint-chart, and re-declaring it here would only rot against it.
  | { type: "chart"; spec: unknown; caption?: string };

export interface Attachment {
  id: Id;
  file_name: string;
  mime: string;
  size: number;
  caption?: string;
  url: string;
  message_id?: Id;
  task_id?: Id;
  run_id?: Id;
  created_at: Millis;
}

export interface Reaction {
  emoji: string;
  member_ids: Id[];
}

export interface ReplyPreview {
  id: Id;
  author_id: Id;
  body: string;
  card?: MessageCard;
}

export interface Message {
  id: Id;
  channel_id: Id;
  author_id: Id;
  kind: MessageKind;
  body: string;
  card?: MessageCard;
  parent_id?: Id;
  reply_to_id?: Id;
  reply_to?: ReplyPreview;
  reply_count: number;
  last_reply_at: Millis;
  run_id?: Id;
  task_id?: Id;
  mentions: Id[];
  attachments: Attachment[];
  reactions: Reaction[];
  created_at: Millis;
  edited_at?: Millis;
}

export type TaskStatus =
  | "planned"
  | "running"
  | "blocked"
  | "review"
  | "done"
  | "canceled";

export const TASK_STATUSES: TaskStatus[] = [
  "planned",
  "running",
  "blocked",
  "review",
  "done",
  "canceled",
];

export function isTerminalTaskStatus(status: TaskStatus): boolean {
  return status === "done" || status === "canceled";
}

export interface PullRequestState {
  number: number;
  title: string;
  state: string;
  checks: string;
  review: string;
  /// Newest comment or review already reported into the task (ISO 8601).
  last_feedback_at?: string;
  updated_at: Millis;
}

export interface Task {
  id: Id;
  key: string;
  title: string;
  outcome: string;
  status: TaskStatus;
  owner_id?: Id;
  source_channel_id?: Id;
  source_message_id?: Id;
  discussion_channel_id: Id;
  project_id?: Id;
  host_id?: Id;
  worktree_id?: Id;
  current_run_id?: Id;
  pr_url?: string;
  pr_state?: PullRequestState;
  /// Exact action the owning agent will take if a person approves this review.
  review_action?: string;
  created_by: Id;
  /// When this is meant to be done. The Inbox says so on the day.
  due_at?: Millis;
  created_at: Millis;
  updated_at: Millis;
  position: number;
}

export interface Project {
  id: Id;
  name: string;
  description: string;
  /// With a URL, every machine clones it for itself. Without one this is a
  /// folder that already exists, and `paths` says where.
  repo_url?: string;
  default_branch: string;
  paths: Record<Id, string>;
  created_at: Millis;
}

export interface RuntimeOption {
  id: string;
  name: string;
  description: string;
}

export interface RuntimeInstallation {
  id: string;
  label: string;
  available: boolean;
  command: string[];
  version?: string;
  problem?: string;
  /// Learned the first time a session was opened on this machine — the runtime
  /// is the only thing that knows what it can run.
  models: RuntimeOption[];
  /// Empty for runtimes that fold reasoning effort into the model id.
  thinking: RuntimeOption[];
  modes: RuntimeOption[];
  default_model?: string;
  default_thinking?: string;
  default_mode?: string;
}

export interface SystemSkill {
  name: string;
  description: string;
  path: string;
  content?: string;
}

export interface HostCapabilities {
  runtimes: RuntimeInstallation[];
  system_skills: SystemSkill[];
  has_git: boolean;
  has_gh: boolean;
  gh_authenticated: boolean;
  has_node: boolean;
  browser_automation: boolean;
  home_dir: string;
  /// `user@hostname`. The relay and a desktop app on the same box are two hosts
  /// but one machine.
  machine_key: string;
  notes: string[];
}

export interface Host {
  id: Id;
  name: string;
  kind: "relay" | "desktop";
  platform: string;
  owner_id?: Id;
  online: boolean;
  last_seen: Millis;
  capabilities: HostCapabilities;
  created_at: Millis;
}

export interface Worktree {
  id: Id;
  task_id: Id;
  project_id: Id;
  host_id: Id;
  path: string;
  branch: string;
  base_branch: string;
  is_main_checkout: boolean;
  created_at: Millis;
}

export type RunStatus =
  | "queued"
  | "dispatched"
  | "running"
  | "waiting"
  | "succeeded"
  | "failed"
  | "cancelled";

export type RunTrigger =
  | { type: "mention"; message_id: Id }
  | { type: "reply"; message_id: Id }
  | { type: "direct_message"; message_id: Id }
  | { type: "task_assignment"; task_id: Id }
  | { type: "manual"; by: Id }
  | { type: "automation"; automation_id: Id }
  | { type: "ambient"; message_id: Id }
  | { type: "pull_request_feedback"; task_id: Id };

export interface Run {
  id: Id;
  agent_id: Id;
  status: RunStatus;
  trigger: RunTrigger;
  channel_id: Id;
  task_id?: Id;
  host_id?: Id;
  project_id?: Id;
  worktree_id?: Id;
  cwd?: string;
  automation_id?: Id;
  session_id?: string;
  runtime: string;
  provider?: string;
  model?: string;
  thinking?: string;
  prompt: string;
  headline: string;
  error?: string;
  token_usage?: { input: number; output: number };
  created_at: Millis;
  started_at?: Millis;
  ended_at?: Millis;
}

export type RunEventKind =
  | "lifecycle"
  | "thought"
  | "message"
  | "tool_call"
  | "tool_result"
  | "file_change"
  | "command"
  | "permission"
  | "question"
  | "error"
  | "plan";

export interface RunEvent {
  id: Id;
  run_id: Id;
  seq: number;
  kind: RunEventKind;
  text: string;
  data?: unknown;
  created_at: Millis;
}

export interface QuestionOption {
  label: string;
  description: string;
}

export interface QuestionItem {
  id: string;
  header: string;
  question: string;
  options: QuestionOption[];
  allow_free_text: boolean;
  multi_select: boolean;
}

export interface QuestionAnswer {
  item_id: string;
  values: string[];
  note: string;
}

export interface Question {
  id: Id;
  run_id: Id;
  agent_id: Id;
  channel_id: Id;
  task_id?: Id;
  message_id?: Id;
  headline: string;
  items: QuestionItem[];
  status: "open" | "answered" | "cancelled";
  answers?: QuestionAnswer[];
  answered_by?: Id;
  created_at: Millis;
  answered_at?: Millis;
}

export type InboxKind =
  | "mention"
  | "reply"
  | "direct_message"
  | "question"
  | "task_assigned"
  | "task_blocked"
  | "task_due"
  | "review_ready"
  | "automation_failed";

export interface InboxItem {
  id: Id;
  member_id: Id;
  kind: InboxKind;
  title: string;
  preview: string;
  actor_id?: Id;
  channel_id?: Id;
  message_id?: Id;
  task_id?: Id;
  run_id?: Id;
  automation_id?: Id;
  created_at: Millis;
  read_at?: Millis;
}

export type AutomationTrigger =
  | { type: "schedule"; every_seconds: number; start_at?: Millis }
  | { type: "cron"; expression: string }
  | {
      type: "message";
      channel_id: Id;
      pattern: string;
      include_agents: boolean;
    }
  | { type: "task_status"; status: TaskStatus; project_id?: Id; task_id?: Id }
  | { type: "task_assigned" }
  | { type: "pull_request"; on_review_comment: boolean; on_checks_failed: boolean }
  | { type: "webhook"; token: string }
  | { type: "watch"; command: string; every_seconds: number }
  | { type: "manual" };

export type AutomationAction = "post_in_chat" | "create_task" | "continue_task";

export interface Automation {
  id: Id;
  name: string;
  description: string;
  enabled: boolean;
  trigger: AutomationTrigger;
  agent_id: Id;
  action: AutomationAction;
  instructions: string;
  context_channel_id?: Id;
  report_channel_id?: Id;
  project_id?: Id;
  location: ExecutionLocation;
  host_id?: Id;
  created_by: Id;
  created_at: Millis;
  last_run_at?: Millis;
  next_run_at?: Millis;
  failure_count: number;
}

export interface AutomationRun {
  id: Id;
  automation_id: Id;
  run_id?: Id;
  trigger_summary: string;
  trigger_payload?: unknown;
  selection?: unknown;
  context_preview: string;
  status: RunStatus;
  error?: string;
  task_id?: Id;
  created_at: Millis;
  ended_at?: Millis;
}

export interface Preview {
  id: Id;
  task_id: Id;
  host_id: Id;
  run_id?: Id;
  label: string;
  port: number;
  url: string;
  status: "starting" | "live" | "stopped" | "failed";
  local_only: boolean;
  created_at: Millis;
  stopped_at?: Millis;
}

export interface WorkspaceSkill {
  id: Id;
  name: string;
  description: string;
  instructions: string;
  created_at: Millis;
  updated_at: Millis;
}

export interface Workspace {
  id: Id;
  name: string;
  /** Emoji shown when no custom image is set. */
  icon?: string;
  /** Relay-relative URL of the current PNG or JPEG icon. */
  icon_image?: string;
  /// What task keys start with: "PW" gives PW-14.
  task_prefix: string;
  created_at: Millis;
  task_seq: number;
}

/// The relay's own vital signs. `system` is only filled in for an
/// authenticated caller: a bare probe gets liveness and nothing about the box.
export interface Health {
  ok: boolean;
  version: string;
  api: number;
  started_at: Millis;
  hosts_online: number;
  runs_active: number;
  system?: SystemHealth;
}

export interface SystemHealth {
  cpu_percent: number;
  cpu_count: number;
  memory_used: number;
  memory_total: number;
  process_memory: number;
}

export interface Device {
  id: Id;
  label: string;
  created_at: Millis;
  last_used?: Millis;
  current: boolean;
}

export interface PairingResponse {
  secret: string;
  expires_at: Millis;
  workspace_url: string;
}

export interface Bootstrap {
  workspace: Workspace;
  me: Member;
  members: Member[];
  sections: Section[];
  channels: Channel[];
  skills: WorkspaceSkill[];
  projects: Project[];
  hosts: Host[];
  tasks: Task[];
  inbox: InboxItem[];
  automations: Automation[];
  open_questions: Question[];
  active_runs: Run[];
  previews: Preview[];
  seq: number;
}

export interface TaskDetail {
  task: Task;
  worktree?: Worktree;
  runs: Run[];
  attachments: Attachment[];
  previews: Preview[];
  questions: Question[];
}

export interface RunDetail {
  run: Run;
  events: RunEvent[];
  questions: Question[];
}

export interface AutomationDebug {
  automation: Automation;
  runs: AutomationRun[];
}

export interface SearchHit {
  message: Message;
  channel_name: string;
  author_name: string;
  snippet: string;
}

export interface SearchResults {
  messages: SearchHit[];
  tasks: Task[];
}

export interface MessagePage {
  messages: Message[];
  before?: Id;
  has_more: boolean;
}

export type Event =
  | { kind: "message_created"; message: Message }
  | { kind: "message_updated"; message: Message }
  | { kind: "message_deleted"; channel_id: Id; message_id: Id }
  | { kind: "channel_created"; channel: Channel }
  | { kind: "channel_updated"; channel: Channel }
  | { kind: "channel_deleted"; channel_id: Id }
  | { kind: "sections_updated"; sections: Section[] }
  | { kind: "workspace_skills_updated"; skills: WorkspaceSkill[] }
  | { kind: "member_updated"; member: Member }
  | { kind: "member_removed"; member_id: Id }
  | { kind: "presence_changed"; member_id: Id; presence: Presence }
  | { kind: "typing"; channel_id: Id; member_id: Id }
  | { kind: "task_created"; task: Task }
  | { kind: "task_updated"; task: Task }
  | { kind: "task_deleted"; task_id: Id }
  | { kind: "run_updated"; run: Run }
  | { kind: "run_event_appended"; event: RunEvent }
  | { kind: "question_updated"; question: Question }
  | { kind: "inbox_item_created"; item: InboxItem }
  | { kind: "inbox_item_updated"; item: InboxItem }
  | { kind: "host_updated"; host: Host }
  | { kind: "project_updated"; project: Project }
  | { kind: "project_deleted"; project_id: Id }
  | { kind: "automation_updated"; automation: Automation }
  | { kind: "automation_deleted"; automation_id: Id }
  | { kind: "automation_run_updated"; run: AutomationRun }
  | { kind: "preview_updated"; preview: Preview }
  | { kind: "worktree_updated"; worktree: Worktree }
  | { kind: "workspace_updated"; workspace: Workspace };

export interface Envelope {
  seq: number;
  at: Millis;
  kind: Event["kind"];
  [key: string]: unknown;
}
