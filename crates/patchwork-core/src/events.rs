use serde::{Deserialize, Serialize};

use crate::ids::{Id, Millis};
use crate::models::*;

/// Everything the relay broadcasts to connected clients. Each event carries a
/// monotonic `seq` so a reconnecting client can ask for everything it missed
/// instead of refetching the world.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    pub seq: i64,
    pub at: Millis,
    #[serde(flatten)]
    pub event: Event,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Event {
    MessageCreated { message: Message },
    MessageUpdated { message: Message },
    MessageDeleted { channel_id: Id, message_id: Id },
    ChannelCreated { channel: Channel },
    ChannelUpdated { channel: Channel },
    ChannelDeleted { channel_id: Id },
    SectionsUpdated { sections: Vec<Section> },
    WorkspaceSkillsUpdated { skills: Vec<WorkspaceSkill> },
    MemberUpdated { member: Member },
    MemberRemoved { member_id: Id },
    PresenceChanged { member_id: Id, presence: Presence },
    Typing { channel_id: Id, member_id: Id },
    TaskCreated { task: Task },
    TaskUpdated { task: Task },
    TaskDeleted { task_id: Id },
    RunUpdated { run: Run },
    RunEventAppended { event: RunEvent },
    AskUpdated { ask: Ask },
    InboxItemCreated { item: InboxItem },
    InboxItemUpdated { item: InboxItem },
    HostUpdated { host: Host },
    ProjectUpdated { project: Project },
    ProjectDeleted { project_id: Id },
    AutomationUpdated { automation: Automation },
    AutomationDeleted { automation_id: Id },
    AutomationRunUpdated { run: AutomationRun },
    PreviewUpdated { preview: Preview },
    WorktreeUpdated { worktree: Worktree },
    WorkspaceUpdated { workspace: Workspace },
}
