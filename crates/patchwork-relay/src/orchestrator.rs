//! Deciding what should happen, and making it happen.
//!
//! Posting a message, creating a task, answering a question and finishing a run
//! all funnel through here so that the conversation, the board, the Inbox and
//! the running agents never disagree with each other.

use anyhow::{anyhow, bail, Context, Result};
use patchwork_agent::worktree::branch_for;
use patchwork_core::events::Event;
use patchwork_core::host::{
    HostToRelay, RelayToHost, RunControlMode, RunControlState, RunFile, RunSpec, WorktreeSpec,
};
use patchwork_core::models::*;
use patchwork_core::wire::{SendMessage, SteerRun};
use patchwork_core::{new_id, now_ms, Id, Millis};
use serde_json::json;

use crate::auth;
use crate::state::Shared;

/// How much conversation an agent gets by default. Deeper history stays
/// retrievable through the CLI rather than being pasted into every prompt.
const CONTEXT_MESSAGES: usize = 30;

/// An agent may answer a human, and may answer an agent that a human prompted.
/// It may not answer that answer — chains stop here.
const MAX_AGENT_CHAIN_DEPTH: i32 = 1;

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub struct PostOptions {
    pub trigger_agents: bool,
    pub run_id: Option<Id>,
}

impl Default for PostOptions {
    fn default() -> Self {
        Self {
            trigger_agents: true,
            run_id: None,
        }
    }
}

/// Boxed because posting can start a run, and starting a run posts a card.
pub fn post_message<'a>(
    state: &'a Shared,
    channel_id: &'a str,
    author_id: &'a str,
    input: SendMessage,
    options: PostOptions,
) -> futures::future::BoxFuture<'a, Result<Message>> {
    Box::pin(post_message_inner(
        state, channel_id, author_id, input, options,
    ))
}

async fn post_message_inner(
    state: &Shared,
    channel_id: &str,
    author_id: &str,
    input: SendMessage,
    options: PostOptions,
) -> Result<Message> {
    let channel = state
        .store
        .channel(channel_id)?
        .ok_or_else(|| anyhow!("channel not found"))?;
    let members = state.store.members()?;
    let mentions = parse_mentions(&input.body, &members);

    let task_id = channel.task_id.clone();
    let mut message = Message {
        id: new_id(),
        channel_id: channel_id.to_string(),
        author_id: author_id.to_string(),
        kind: input.kind.unwrap_or(MessageKind::Text),
        body: input.body.clone(),
        card: input.card.clone(),
        parent_id: input.parent_id.clone(),
        reply_count: 0,
        last_reply_at: 0,
        run_id: options.run_id.clone().or(input.run_id.clone()),
        task_id,
        mentions: mentions.clone(),
        attachments: Vec::new(),
        reactions: Vec::new(),
        created_at: now_ms(),
        edited_at: None,
    };

    // Attach any files that were uploaded ahead of the message.
    for id in &input.attachment_ids {
        if let Some((attachment, _)) = state.store.attachment(id)? {
            message.attachments.push(attachment);
        }
    }

    state.store.insert_message(&message)?;
    let stored = state
        .store
        .message(&message.id)?
        .unwrap_or_else(|| message.clone());
    state.emit(Event::MessageCreated {
        message: stored.clone(),
    });
    if let Some(channel) = state.store.channel(channel_id)? {
        state.emit(Event::ChannelUpdated { channel });
    }

    follow_through(state, &stored, &channel, &members, options.trigger_agents).await?;

    Ok(stored)
}

/// Everything a finished message sets in motion. Split out because a streamed
/// reply lands in the transcript long before it is finished, and must not
/// notify anyone or wake another agent until it actually is.
async fn follow_through(
    state: &Shared,
    stored: &Message,
    channel: &Channel,
    members: &[Member],
    trigger_agents_too: bool,
) -> Result<()> {
    notify_inbox(state, stored, channel, members).await?;

    if trigger_agents_too {
        if let Err(err) = trigger_agents(state, stored, channel, members).await {
            tracing::warn!(?err, "failed to route message to agents");
        }
    }

    // An agent that says "opened <pr url>" links the task without anyone
    // copying the URL by hand.
    if let Some(task_id) = &stored.task_id {
        crate::github::link_pr_from_message(state, task_id, &stored.body).await;
    }

    // A message in a task discussion is also a trigger for automations.
    crate::automations::on_message(state, stored).await;

    Ok(())
}

/// Where an agent's answer belongs: in the thread it was asked in.
///
/// A run started by a message in a thread replies in that thread, and one
/// started by a message at the top of a channel replies at the top. The
/// triggering message already says which, so nothing has to be carried on the
/// run itself.
pub async fn reply_parent(state: &Shared, run: &Run) -> Option<Id> {
    if let Some(known) = state.run_threads.read().await.get(&run.id) {
        return known.clone();
    }
    let message_id = match &run.trigger {
        RunTrigger::Mention { message_id }
        | RunTrigger::DirectMessage { message_id }
        | RunTrigger::Ambient { message_id } => message_id,
        _ => return None,
    };
    state.store.message(message_id).ok().flatten()?.parent_id
}

/// Follow the conversation: whatever message just spoke to this run decides
/// where its next answer goes.
async fn talk_where(state: &Shared, run_id: &str, message: &Message) {
    state
        .run_threads
        .write()
        .await
        .insert(run_id.to_string(), message.parent_id.clone());
}

/// A reply that is still being written: posted on the first delta so the reader
/// watches it arrive, then rewritten in place by every delta after it.
async fn stream_message(state: &Shared, run_id: &str, body: &str) -> Result<()> {
    let existing = state.streaming_messages.read().await.get(run_id).cloned();

    if let Some(message_id) = existing {
        state.store.stream_message_body(&message_id, body)?;
        if let Some(message) = state.store.message(&message_id)? {
            state.emit(Event::MessageUpdated { message });
        }
        return Ok(());
    }

    let Some(run) = state.store.run(run_id)? else {
        return Ok(());
    };
    // Ambient agents are allowed to decide they have nothing to say, and that
    // decision only arrives at the end. Let them finish before taking the floor.
    if matches!(run.trigger, RunTrigger::Ambient { .. }) {
        return Ok(());
    }
    let Some(channel) = state.store.channel(&run.channel_id)? else {
        return Ok(());
    };

    let message = Message {
        id: new_id(),
        channel_id: run.channel_id.clone(),
        author_id: run.agent_id.clone(),
        kind: MessageKind::Text,
        body: body.to_string(),
        card: None,
        parent_id: reply_parent(state, &run).await,
        reply_count: 0,
        last_reply_at: 0,
        run_id: Some(run.id.clone()),
        task_id: channel.task_id.clone(),
        mentions: Vec::new(),
        attachments: Vec::new(),
        reactions: Vec::new(),
        created_at: now_ms(),
        edited_at: None,
    };
    state.store.insert_message(&message)?;
    state
        .streaming_messages
        .write()
        .await
        .insert(run_id.to_string(), message.id.clone());
    state.emit(Event::MessageCreated { message });
    Ok(())
}

/// A streamed reply reaching its final text: it now knows who it mentions, and
/// only now may it notify anyone.
async fn finish_posted_message(state: &Shared, message: &Message) -> Result<()> {
    let Some(channel) = state.store.channel(&message.channel_id)? else {
        return Ok(());
    };
    let members = state.store.members()?;
    let mentions = parse_mentions(&message.body, &members);
    state.store.set_message_mentions(&message.id, &mentions)?;

    let mut settled = message.clone();
    settled.mentions = mentions;
    state.emit(Event::MessageUpdated {
        message: settled.clone(),
    });
    state.emit(Event::ChannelUpdated {
        channel: channel.clone(),
    });

    follow_through(state, &settled, &channel, &members, true).await
}

/// `@handle` mentions, resolved against real members so unknown handles are
/// left as plain text.
pub fn parse_mentions(body: &str, members: &[Member]) -> Vec<Id> {
    let mut found = Vec::new();
    for member in members {
        let needle = format!("@{}", member.handle);
        let mut start = 0;
        while let Some(pos) = body[start..].find(&needle) {
            let at = start + pos;
            let after = at + needle.len();
            let boundary = body[after..]
                .chars()
                .next()
                .map(|c| !c.is_alphanumeric() && c != '-' && c != '_')
                .unwrap_or(true);
            if boundary && !found.contains(&member.id) {
                found.push(member.id.clone());
            }
            start = after;
            if start >= body.len() {
                break;
            }
        }
    }
    found
}

/// The agent a message is plainly a reply to, if any.
///
/// Deliberately narrow. Only the agent that spoke last, only if it spoke
/// recently, only if it was answering *this* person, and only when the new
/// message does not name somebody else instead — say `@other-agent` and you
/// meant that one, not the one still on screen.
fn continuation_target(state: &Shared, message: &Message, author: &Member) -> Result<Option<Id>> {
    if author.kind != MemberKind::Human || !message.mentions.is_empty() {
        return Ok(None);
    }

    let recent = state.store.recent_messages(&message.channel_id, 6)?;
    let Some(previous) = recent
        .iter()
        .rev()
        .find(|candidate| candidate.id != message.id && candidate.kind != MessageKind::System)
    else {
        return Ok(None);
    };
    let Some(run_id) = &previous.run_id else {
        return Ok(None);
    };
    let Some(run) = state.store.run(run_id)? else {
        return Ok(None);
    };

    // Who the previous run was answering. An agent's aside to somebody else is
    // not an invitation to have your next sentence routed into it.
    let spoke_to = match &run.trigger {
        RunTrigger::Mention { message_id }
        | RunTrigger::DirectMessage { message_id }
        | RunTrigger::Ambient { message_id } => {
            state.store.message(message_id)?.map(|m| m.author_id)
        }
        RunTrigger::Manual { by } => Some(by.clone()),
        _ => None,
    };

    Ok(continues_conversation(
        message,
        previous,
        &run,
        spoke_to.as_deref(),
    ))
}

/// Long enough to cover a follow-up question, short enough that returning to a
/// channel tomorrow starts a fresh conversation rather than resuming one nobody
/// remembers.
const CONTINUATION_WINDOW_MS: Millis = 10 * 60 * 1000;

/// The rule itself, with the database left outside so it can be read — and
/// tested — as the single sentence it is.
fn continues_conversation(
    message: &Message,
    previous: &Message,
    previous_run: &Run,
    spoke_to: Option<&str>,
) -> Option<Id> {
    if message.created_at.saturating_sub(previous.created_at) > CONTINUATION_WINDOW_MS {
        return None;
    }
    if spoke_to != Some(message.author_id.as_str()) {
        return None;
    }
    Some(previous_run.agent_id.clone())
}

async fn notify_inbox(
    state: &Shared,
    message: &Message,
    channel: &Channel,
    members: &[Member],
) -> Result<()> {
    let author = members.iter().find(|m| m.id == message.author_id);
    let author_name = author
        .map(|a| a.display_name.clone())
        .unwrap_or_else(|| "Someone".into());
    let preview: String = message.body.chars().take(160).collect();

    let mut notified: Vec<Id> = Vec::new();

    let push = |state: &Shared,
                member_id: &str,
                kind: InboxKind,
                title: String,
                notified: &mut Vec<Id>|
     -> Result<()> {
        if member_id == message.author_id || notified.contains(&member_id.to_string()) {
            return Ok(());
        }
        let member = members.iter().find(|m| m.id == member_id);
        if member.map(|m| m.kind) != Some(MemberKind::Human) {
            return Ok(());
        }
        notified.push(member_id.to_string());
        let item = InboxItem {
            id: new_id(),
            member_id: member_id.to_string(),
            kind,
            title,
            preview: preview.clone(),
            actor_id: Some(message.author_id.clone()),
            channel_id: Some(message.channel_id.clone()),
            message_id: Some(message.id.clone()),
            task_id: message.task_id.clone(),
            run_id: message.run_id.clone(),
            automation_id: None,
            created_at: now_ms(),
            read_at: None,
        };
        state.store.insert_inbox(&item)?;
        state.emit(Event::InboxItemCreated { item });
        Ok(())
    };

    for member_id in &message.mentions {
        push(
            state,
            member_id,
            InboxKind::Mention,
            format!("{author_name} mentioned you in {}", channel_label(channel)),
            &mut notified,
        )?;
    }

    if channel.kind == ChannelKind::Dm {
        for member_id in &channel.member_ids {
            push(
                state,
                member_id,
                InboxKind::DirectMessage,
                format!("{author_name} sent you a message"),
                &mut notified,
            )?;
        }
    }

    if let Some(parent_id) = &message.parent_id {
        if let Some(parent) = state.store.message(parent_id)? {
            push(
                state,
                &parent.author_id,
                InboxKind::Reply,
                format!("{author_name} replied in a thread"),
                &mut notified,
            )?;
        }
    }

    Ok(())
}

pub fn channel_label(channel: &Channel) -> String {
    match channel.kind {
        ChannelKind::Channel => format!("#{}", channel.slug),
        ChannelKind::Dm => "your direct messages".to_string(),
        ChannelKind::Task => channel.name.clone(),
    }
}

// ---------------------------------------------------------------------------
// Routing messages to agents
// ---------------------------------------------------------------------------

async fn trigger_agents(
    state: &Shared,
    message: &Message,
    channel: &Channel,
    members: &[Member],
) -> Result<()> {
    if message.kind == MessageKind::System {
        return Ok(());
    }
    let author = members
        .iter()
        .find(|m| m.id == message.author_id)
        .cloned()
        .ok_or_else(|| anyhow!("unknown author"))?;

    let author_depth = match &message.run_id {
        Some(run_id) => state.store.run_depth(run_id)?,
        None => -1,
    };

    // Who you are plainly still talking to.
    //
    // A person answers the agent that just answered them without saying its
    // name again — that is how conversation works. Without this, the follow-up
    // reaches an ambient agent as ambient chatter, it decides it has nothing to
    // add, and the reply you were waiting for never comes. The reader is left
    // with a working app that simply ignored them.
    let continuing = continuation_target(state, message, &author)?;
    // A task is already addressed: its owner is the recipient. Ordinary room
    // chat keeps the narrower recent-reply heuristic.
    let task_owner = if author.kind == MemberKind::Human
        && message.mentions.is_empty()
        && channel.kind == ChannelKind::Task
    {
        channel
            .task_id
            .as_deref()
            .and_then(|id| state.store.task(id).ok().flatten())
            .and_then(|task| (task.status != TaskStatus::Done).then_some(task.owner_id).flatten())
            .filter(|id| {
                members
                    .iter()
                    .any(|member| member.id == *id && member.kind == MemberKind::Agent)
            })
    } else {
        None
    };

    for agent in members.iter().filter(|m| m.kind == MemberKind::Agent) {
        if agent.id == message.author_id {
            continue;
        }
        let profile = agent.agent.clone().unwrap_or_default();
        let mentioned = message.mentions.contains(&agent.id);
        let in_dm = channel.kind == ChannelKind::Dm && channel.member_ids.contains(&agent.id);
        let participation = profile
            .channel_participation
            .get(&channel.id)
            .copied()
            .unwrap_or(profile.default_participation);

        // Agent-authored messages only ever wake an explicitly mentioned agent,
        // and only while the chain is still shallow. This is what stops two
        // agents from talking to each other forever.
        if author.kind == MemberKind::Agent {
            if !mentioned || author_depth >= MAX_AGENT_CHAIN_DEPTH {
                continue;
            }
        }

        let owns_task = task_owner.as_deref() == Some(agent.id.as_str());
        let addressed = mentioned || owns_task || continuing.as_deref() == Some(agent.id.as_str());

        let should_run = if addressed {
            participation != Participation::Off || in_dm || owns_task
        } else if in_dm {
            profile.dm_enabled
        } else {
            // Ambient means "may chime in", and that is only ever true of a
            // room. A direct message is between the people in it, and a task
            // discussion belongs to whoever is on the task — an uninvited agent
            // wandering into either is not helpfulness, it is eavesdropping.
            participation == Participation::Ambient
                && author.kind == MemberKind::Human
                && channel.kind == ChannelKind::Channel
        };
        if !should_run {
            continue;
        }

        let trigger = if addressed {
            RunTrigger::Mention {
                message_id: message.id.clone(),
            }
        } else if in_dm {
            RunTrigger::DirectMessage {
                message_id: message.id.clone(),
            }
        } else {
            RunTrigger::Ambient {
                message_id: message.id.clone(),
            }
        };

        // If the agent is already working here, this is a follow-up, not a
        // second agent on the same front.
        if let Some(active) = state.store.agent_active_run(&agent.id, &channel.id)? {
            talk_where(state, &active.id, message).await;
            let prompt = format!(
                "{} just said:\n\n{}",
                display_name_of(members, &message.author_id),
                message.body
            );
            let attachment_ids = message
                .attachments
                .iter()
                .map(|attachment| attachment.id.clone())
                .collect::<Vec<_>>();
            if let Err(err) = deliver_control(
                state,
                &active,
                new_id(),
                prompt,
                RunControlMode::Queue,
                run_files(state, &attachment_ids)?,
            )
            .await
            {
                tracing::warn!(?err, run = %active.id, "could not steer active run");
                let _ = post_system(
                    state,
                    &channel.id,
                    &format!("Could not deliver that feedback: {err}"),
                )
                .await;
            }
            continue;
        }

        let params = StartRunParams {
            agent_id: agent.id.clone(),
            channel_id: channel.id.clone(),
            task_id: channel.task_id.clone(),
            prompt: message.body.clone(),
            trigger,
            automation_id: None,
            depth: (author_depth + 1).max(0),
            host_id: None,
            project_id: None,
        };
        if let Err(err) = start_run(state, params).await {
            tracing::warn!(?err, agent = %agent.handle, "could not start agent run");
            let _ = post_system(
                state,
                &channel.id,
                &format!("{} could not start: {err}", agent.display_name),
            )
            .await;
        }
    }
    Ok(())
}

fn display_name_of(members: &[Member], id: &str) -> String {
    members
        .iter()
        .find(|m| m.id == id)
        .map(|m| m.display_name.clone())
        .unwrap_or_else(|| "Someone".into())
}

pub async fn post_system(state: &Shared, channel_id: &str, body: &str) -> Result<Message> {
    let system_id = system_member_id(state)?;
    post_message(
        state,
        channel_id,
        &system_id,
        SendMessage {
            body: body.to_string(),
            kind: Some(MessageKind::System),
            ..Default::default()
        },
        PostOptions {
            trigger_agents: false,
            run_id: None,
        },
    )
    .await
}

fn system_member_id(state: &Shared) -> Result<Id> {
    Ok(state
        .store
        .member_by_handle("patchwork")?
        .map(|m| m.id)
        .unwrap_or_else(|| "patchwork".to_string()))
}

// ---------------------------------------------------------------------------
// Runs
// ---------------------------------------------------------------------------

fn append_run_event(
    state: &Shared,
    run_id: &str,
    kind: RunEventKind,
    text: String,
    data: Option<serde_json::Value>,
) -> Result<()> {
    let event = RunEvent {
        id: new_id(),
        run_id: run_id.to_string(),
        seq: state.store.next_run_event_seq(run_id)?,
        kind,
        text,
        data,
        created_at: now_ms(),
    };
    state.store.append_run_event(&event)?;
    state.emit(Event::RunEventAppended { event });
    Ok(())
}

fn run_files(state: &Shared, attachment_ids: &[Id]) -> Result<Vec<RunFile>> {
    let mut files = Vec::new();
    for id in attachment_ids {
        let (attachment, _) = state
            .store
            .attachment(id)?
            .ok_or_else(|| anyhow!("attachment not found"))?;
        files.push(RunFile {
            file_name: attachment.file_name,
            url: format!("{}{}", state.public_url, attachment.url),
        });
    }
    Ok(files)
}

async fn deliver_control(
    state: &Shared,
    run: &Run,
    control_id: Id,
    prompt: String,
    mode: RunControlMode,
    files: Vec<RunFile>,
) -> Result<()> {
    let host_id = run
        .host_id
        .as_deref()
        .ok_or_else(|| anyhow!("the target run has no execution host"))?;
    if !state
        .send_to_host(
            host_id,
            RelayToHost::FollowUp {
                run_id: run.id.clone(),
                control_id,
                prompt,
                mode,
                files,
            },
        )
        .await
    {
        bail!("the target run's execution host is offline");
    }
    Ok(())
}

/// A durable note that does not recursively wake agents or automations.
fn post_control_note(
    state: &Shared,
    channel_id: &str,
    author_id: &str,
    source_run_id: Option<&str>,
    body: String,
    attachment_ids: &[Id],
) -> Result<Message> {
    let channel = state
        .store
        .channel(channel_id)?
        .ok_or_else(|| anyhow!("channel not found"))?;
    let mut attachments = Vec::new();
    for id in attachment_ids {
        if let Some((attachment, _)) = state.store.attachment(id)? {
            attachments.push(attachment);
        }
    }
    let message = Message {
        id: new_id(),
        channel_id: channel.id.clone(),
        author_id: author_id.to_string(),
        kind: MessageKind::Status,
        body,
        card: None,
        parent_id: None,
        reply_count: 0,
        last_reply_at: 0,
        run_id: source_run_id.map(str::to_string),
        task_id: channel.task_id,
        mentions: Vec::new(),
        attachments,
        reactions: Vec::new(),
        created_at: now_ms(),
        edited_at: None,
    };
    state.store.insert_message(&message)?;
    let stored = state.store.message(&message.id)?.unwrap_or(message);
    state.emit(Event::MessageCreated {
        message: stored.clone(),
    });
    if let Some(channel) = state.store.channel(channel_id)? {
        state.emit(Event::ChannelUpdated { channel });
    }
    Ok(stored)
}

/// Prompt an exact active ACP run, independent of where either run is talking.
pub async fn steer_run(
    state: &Shared,
    author_id: &str,
    source_run_id: Option<&str>,
    target_run_id: &str,
    input: SteerRun,
) -> Result<Id> {
    let prompt = input.prompt.trim();
    if prompt.is_empty() && input.attachment_ids.is_empty() {
        bail!("say what the run should know");
    }
    if prompt.chars().count() > 32_000 {
        bail!("that steering message is too long");
    }
    if input.attachment_ids.len() > 16 {
        bail!("a steering message can attach at most 16 files");
    }
    let target = state
        .store
        .run(target_run_id)?
        .filter(|run| !run.status.is_terminal())
        .ok_or_else(|| anyhow!("the target run is not active"))?;

    let source = match source_run_id {
        Some(id) => {
            if id == target_run_id {
                bail!("a run cannot steer itself");
            }
            let run = state
                .store
                .run(id)?
                .filter(|run| !run.status.is_terminal() && run.agent_id == author_id)
                .ok_or_else(|| anyhow!("the source run is not active"))?;
            let direct: Vec<_> = state
                .store
                .run_events(id, 0)?
                .into_iter()
                .filter(|event| {
                    event
                        .data
                        .as_ref()
                        .and_then(|data| data.get("target_run_id"))
                        .is_some()
                })
                .collect();
            if direct.len() >= 16
                || direct
                    .iter()
                    .filter(|event| {
                        event
                            .data
                            .as_ref()
                            .and_then(|data| data.get("target_run_id"))
                            == Some(&serde_json::Value::String(target_run_id.to_string()))
                    })
                    .count()
                    >= 4
            {
                bail!("this run has reached its cross-session message limit");
            }
            Some(run)
        }
        None => None,
    };

    let members = state.store.members()?;
    let sender = display_name_of(&members, author_id);
    let target_name = display_name_of(&members, &target.agent_id);
    let control_id = new_id();
    let summary = if prompt.is_empty() { "Attached file(s)" } else { prompt };
    let delivered = if prompt.is_empty() {
        "Review the attached file(s).".to_string()
    } else if source.is_some() {
        format!(
            "{sender} sent a message from another active Patchwork run:\n\n{prompt}\n\nUse this information in your current work. Reply only if coordination requires it."
        )
    } else {
        format!("{sender} sent steering feedback:\n\n{prompt}")
    };
    deliver_control(
        state,
        &target,
        control_id.clone(),
        delivered,
        input.mode,
        run_files(state, &input.attachment_ids)?,
    )
    .await?;

    let note = if source.is_some() {
        format!("{sender} → {target_name}: {summary}")
    } else {
        format!("Feedback for {target_name}: {summary}")
    };
    let target_note = post_control_note(
        state,
        &target.channel_id,
        author_id,
        source_run_id,
        note.clone(),
        &input.attachment_ids,
    )?;
    talk_where(state, &target.id, &target_note).await;

    append_run_event(
        state,
        &target.id,
        RunEventKind::Message,
        format!("Steering from {sender}: {summary}"),
        Some(json!({
            "control_id": control_id.clone(),
            "source_run_id": source_run_id,
            "mode": input.mode,
            "direction": "inbound",
        })),
    )?;
    if let Some(source) = &source {
        append_run_event(
            state,
            &source.id,
            RunEventKind::Message,
            format!("Sent to {target_name}: {summary}"),
            Some(json!({
                "control_id": control_id.clone(),
                "target_run_id": target.id.clone(),
                "mode": input.mode,
                "direction": "outbound",
            })),
        )?;
        if source.channel_id != target.channel_id {
            post_control_note(
                state,
                &source.channel_id,
                author_id,
                Some(&source.id),
                note,
                &[],
            )?;
        }
    }
    Ok(control_id)
}

pub struct StartRunParams {
    pub agent_id: Id,
    pub channel_id: Id,
    pub task_id: Option<Id>,
    pub prompt: String,
    pub trigger: RunTrigger,
    pub automation_id: Option<Id>,
    pub depth: i32,
    pub host_id: Option<Id>,
    pub project_id: Option<Id>,
}

pub async fn start_run(state: &Shared, params: StartRunParams) -> Result<Run> {
    let agent = state
        .store
        .member(&params.agent_id)?
        .filter(|m| m.kind == MemberKind::Agent)
        .ok_or_else(|| anyhow!("no such agent"))?;
    let profile = agent.agent.clone().unwrap_or_default();

    let task = match &params.task_id {
        Some(id) => state.store.task(id)?,
        None => None,
    };
    let project_id = params
        .project_id
        .clone()
        .or_else(|| task.as_ref().and_then(|t| t.project_id.clone()))
        .or_else(|| profile.default_project_id.clone());
    let project = match &project_id {
        Some(id) => state.store.project(id)?,
        None => None,
    };

    // A task that already has work on a machine stays on that machine.
    let pinned_host = params
        .host_id
        .clone()
        .or_else(|| task.as_ref().and_then(|t| t.host_id.clone()));
    let host_id = choose_host(state, &profile, pinned_host, project.as_ref()).await?;

    // A project with no repository is one folder that every task shares, so
    // two agents in it would edit the same files at the same time. A git
    // project has a worktree each and needs none of this.
    //
    // ponytail: refuse rather than queue. Queuing means a second dispatch path
    // and a wake-up on every run that ends; add it when someone actually runs
    // into this more than once.
    if let Some(project) = &project {
        if project.repo_url.is_none() {
            if let Some(busy) = state
                .store
                .project_active_run(&project.id, params.task_id.as_deref())?
            {
                let who = state
                    .store
                    .member(&busy.agent_id)?
                    .map(|m| m.display_name)
                    .unwrap_or_else(|| "another agent".into());
                bail!(
                    "{who} is already working in `{}`, and it has no repository to give each task \
a worktree of its own. Wait for that run, or give the project a repository URL.",
                    project.name
                );
            }
        }
    }

    // Where the agent will work.
    let (worktree_spec, existing_worktree) = resolve_worktree(state, &task, &project, &host_id)?;

    let now = now_ms();
    let run = Run {
        id: new_id(),
        agent_id: agent.id.clone(),
        status: RunStatus::Dispatched,
        trigger: params.trigger.clone(),
        channel_id: params.channel_id.clone(),
        task_id: params.task_id.clone(),
        host_id: Some(host_id.clone()),
        project_id: project_id.clone(),
        worktree_id: existing_worktree.as_ref().map(|w| w.id.clone()),
        cwd: existing_worktree.as_ref().map(|w| w.path.clone()),
        automation_id: params.automation_id.clone(),
        session_id: None,
        runtime: profile.runtime.clone(),
        prompt: params.prompt.clone(),
        headline: "Starting".into(),
        error: None,
        token_usage: None,
        created_at: now,
        started_at: Some(now),
        ended_at: None,
    };
    state.store.insert_run(&run, params.depth)?;

    // A token scoped to this run: the agent's native access to Patchwork.
    let token = auth::generate_token();
    state.store.insert_token(
        &auth::hash_token(&token),
        &agent.id,
        "run",
        Some(&run.id),
        Some("run"),
    )?;

    let context = build_context(state, &run, &task).await?;
    let prompt = compose_prompt(&params, &task, &params.trigger);

    let spec = RunSpec {
        run_id: run.id.clone(),
        agent_id: agent.id.clone(),
        agent_handle: agent.handle.clone(),
        agent_name: agent.display_name.clone(),
        agent_description: profile.description.clone(),
        runtime: profile.runtime.clone(),
        provider: profile.provider.clone(),
        model: profile.model.clone(),
        thinking: profile.thinking.clone(),
        custom_command: profile.custom_command.clone(),
        channel_id: run.channel_id.clone(),
        task_id: run.task_id.clone(),
        project_id: project_id.clone(),
        project_name: project.as_ref().map(|p| p.name.clone()),
        automation_id: params.automation_id.clone(),
        worktree: worktree_spec,
        prompt,
        context,
        files: task_files(state, &task),
        api_base: state.public_url.clone(),
        api_token: token,
        resume_session_id: resume_session_for(state, &agent.id, &params.task_id)?,
        env: Vec::new(),
    };

    if !state
        .send_to_host(
            &host_id,
            RelayToHost::StartRun {
                spec: Box::new(spec),
            },
        )
        .await
    {
        let mut failed = run.clone();
        failed.status = RunStatus::Failed;
        failed.error = Some(format!("host {host_id} is not connected"));
        failed.ended_at = Some(now_ms());
        state.store.update_run(&failed)?;
        state.emit(Event::RunUpdated { run: failed });
        bail!("the execution host for this agent is offline");
    }

    state.emit(Event::RunUpdated { run: run.clone() });

    if let Some(task) = &task {
        let mut task = task.clone();
        task.current_run_id = Some(run.id.clone());
        if task.status != TaskStatus::Done {
            task.status = TaskStatus::Running;
        }
        state.store.update_task(&task)?;
        state.emit(Event::TaskUpdated { task });
    }

    // The run card makes concurrent agent work visible in the conversation.
    let _ = post_message(
        state,
        &run.channel_id,
        &agent.id,
        SendMessage {
            kind: Some(MessageKind::Card),
            card: Some(MessageCard::Run {
                run_id: run.id.clone(),
            }),
            run_id: Some(run.id.clone()),
            // Where the work was asked for. A card about a thread's question
            // does not belong at the top of the channel.
            parent_id: reply_parent(state, &run).await,
            ..Default::default()
        },
        PostOptions {
            trigger_agents: false,
            run_id: Some(run.id.clone()),
        },
    )
    .await;

    Ok(run)
}

fn resume_session_for(
    state: &Shared,
    agent_id: &str,
    task_id: &Option<Id>,
) -> Result<Option<String>> {
    let Some(task_id) = task_id else {
        return Ok(None);
    };
    Ok(state
        .store
        .last_run_for(agent_id, task_id)?
        .and_then(|r| r.session_id))
}

async fn choose_host(
    state: &Shared,
    profile: &AgentProfile,
    pinned: Option<Id>,
    project: Option<&Project>,
) -> Result<Id> {
    // A task that already has a worktree is pinned to the machine holding it.
    if let Some(pinned) = pinned.filter(|p| !p.is_empty()) {
        if state.host_online(&pinned).await {
            return Ok(pinned);
        }
        bail!("the machine this task is running on is offline");
    }

    let online = state.online_host_ids().await;
    let candidates: Vec<Id> = match profile.location {
        ExecutionLocation::Relay => vec![state.relay_host_id.clone()],
        ExecutionLocation::Desktop => profile.host_id.clone().into_iter().collect(),
        ExecutionLocation::Auto => {
            let mut ids = vec![state.relay_host_id.clone()];
            ids.extend(
                online
                    .iter()
                    .filter(|id| **id != state.relay_host_id)
                    .cloned(),
            );
            ids
        }
    };

    // Prefer a machine that actually has the project checked out.
    if let Some(project) = project {
        if let Some(id) = candidates
            .iter()
            .find(|id| online.contains(id) && project.paths.contains_key(*id))
        {
            return Ok(id.clone());
        }
        if !project.paths.is_empty() {
            bail!("no connected machine has `{}` checked out", project.name);
        }
    }

    candidates
        .into_iter()
        .find(|id| online.contains(id))
        .ok_or_else(|| anyhow!("no execution host is available for this agent"))
}

fn resolve_worktree(
    state: &Shared,
    task: &Option<Task>,
    project: &Option<Project>,
    host_id: &str,
) -> Result<(WorktreeSpec, Option<Worktree>)> {
    let (Some(task), Some(project)) = (task, project) else {
        return Ok((WorktreeSpec::None, None));
    };

    if let Some(worktree_id) = &task.worktree_id {
        if let Some(worktree) = state.store.worktree(worktree_id)? {
            if worktree.host_id == host_id {
                return Ok((
                    WorktreeSpec::Existing {
                        path: worktree.path.clone(),
                    },
                    Some(worktree),
                ));
            }
        }
    }

    // No path on this machine is not a failure any more: a project with a
    // repository is something the host can fetch for itself, and it reports
    // where it put it.
    Ok((
        WorktreeSpec::New {
            project_path: project.paths.get(host_id).cloned(),
            repo_url: project.repo_url.clone(),
            project_name: project.name.clone(),
            branch: branch_for(&task.key, &task.title),
            base_branch: project.default_branch.clone(),
        },
        None,
    ))
}

/// What has been pinned to this task: screenshots pasted into its
/// description, evidence attached by an earlier run.
fn task_files(state: &Shared, task: &Option<Task>) -> Vec<RunFile> {
    let Some(task) = task else {
        return Vec::new();
    };
    state
        .store
        .task_attachments(&task.id)
        .unwrap_or_default()
        .into_iter()
        .map(|attachment| RunFile {
            file_name: attachment.file_name,
            url: format!("{}{}", state.public_url, attachment.url),
        })
        .collect()
}

fn compose_prompt(params: &StartRunParams, task: &Option<Task>, trigger: &RunTrigger) -> String {
    let mut prompt = String::new();
    if let Some(task) = task {
        prompt.push_str(&format!("You own task {}: {}.\n", task.key, task.title));
        if !task.outcome.trim().is_empty() {
            prompt.push_str(&format!("Expected result: {}\n", task.outcome.trim()));
        }
        prompt.push('\n');
    }
    if matches!(trigger, RunTrigger::Ambient { .. }) {
        prompt.push_str(
            "You are watching this channel rather than being asked directly. \
Contribute only if you have something material to add. If you do not, reply with exactly `NOTHING` \
and say nothing else.\n\n",
        );
    }
    prompt.push_str(params.prompt.trim());
    prompt
}

async fn build_context(state: &Shared, run: &Run, task: &Option<Task>) -> Result<String> {
    let mut out = String::new();
    let members = state.store.members()?;
    let channel = state.store.channel(&run.channel_id)?;

    if let Some(channel) = &channel {
        out.push_str(&format!("Conversation: {}\n", channel_label(channel)));
        if !channel.topic.trim().is_empty() {
            out.push_str(&format!("Topic: {}\n", channel.topic.trim()));
        }
        out.push('\n');
    }

    if let Some(task) = task {
        out.push_str(&format!(
            "Task {} [{}] — {}\n",
            task.key,
            task.status.as_str(),
            task.title
        ));
        if let Some(owner) = &task.owner_id {
            out.push_str(&format!("Owner: {}\n", display_name_of(&members, owner)));
        }
        if let Some(pr) = &task.pr_url {
            out.push_str(&format!("Pull request: {pr}\n"));
        }
        out.push('\n');
    }

    let messages = state
        .store
        .recent_messages(&run.channel_id, CONTEXT_MESSAGES)?;
    if !messages.is_empty() {
        out.push_str("Recent messages (oldest first):\n");
        for message in messages {
            if message.body.trim().is_empty() {
                continue;
            }
            let author = display_name_of(&members, &message.author_id);
            let body: String = message.body.chars().take(2000).collect();
            out.push_str(&format!("- {author}: {body}\n"));
        }
    }

    out.push_str("\nUse `patchwork history` and `patchwork search` if you need more than this.\n");
    Ok(out)
}

// ---------------------------------------------------------------------------
// Host messages
// ---------------------------------------------------------------------------

pub async fn handle_host_message(state: &Shared, host_id: &str, msg: HostToRelay) {
    if let Err(err) = handle_host_message_inner(state, host_id, msg).await {
        tracing::warn!(?err, %host_id, "failed to apply host message");
    }
}

async fn handle_host_message_inner(state: &Shared, host_id: &str, msg: HostToRelay) -> Result<()> {
    match msg {
        HostToRelay::Register { .. } | HostToRelay::Heartbeat { .. } | HostToRelay::Pong { .. } => {
            state.store.touch_host(host_id).ok();
        }

        HostToRelay::RunAccepted { run_id, cwd } => {
            if let Some(mut run) = state.store.run(&run_id)? {
                run.status = RunStatus::Running;
                run.cwd = cwd.or(run.cwd);
                state.store.update_run(&run)?;
                state.emit(Event::RunUpdated { run });
            }
        }

        HostToRelay::RunEvent {
            run_id,
            kind,
            text,
            data,
        } => append_run_event(state, &run_id, kind, text, data)?,

        HostToRelay::RunControlStatus {
            run_id,
            control_id,
            state: control_state,
        } => {
            let label = match control_state {
                RunControlState::Queued => "Steering queued",
                RunControlState::Started => "Steering delivered",
            };
            append_run_event(
                state,
                &run_id,
                RunEventKind::Lifecycle,
                label.to_string(),
                Some(json!({ "control_id": control_id, "state": control_state })),
            )?;
        }

        HostToRelay::RunStatus {
            run_id,
            status,
            headline,
            session_id,
            error,
            token_usage,
        } => {
            let Some(mut run) = state.store.run(&run_id)? else {
                return Ok(());
            };
            // A run waiting on a question stays waiting until it is answered.
            run.status = status;
            if let Some(headline) = headline {
                run.headline = headline;
            }
            if let Some(session_id) = session_id {
                run.session_id = Some(session_id);
            }
            if let Some(error) = error {
                run.error = Some(error);
            }
            if token_usage.is_some() {
                run.token_usage = token_usage;
            }
            if status.is_terminal() {
                run.ended_at = Some(now_ms());
                state.store.revoke_run_tokens(&run_id).ok();
                state.store.cancel_questions_for_run(&run_id).ok();
            }
            state.store.update_run(&run)?;
            state.emit(Event::RunUpdated { run: run.clone() });

            state
                .set_presence(
                    &run.agent_id,
                    match status {
                        RunStatus::Running | RunStatus::Dispatched => Presence::Working,
                        RunStatus::Waiting => Presence::Waiting,
                        _ => Presence::Online,
                    },
                )
                .await;

            if status.is_terminal() {
                finish_run(state, &run).await?;
            }
        }

        HostToRelay::ProjectCheckout { project_id, path } => {
            let Some(mut project) = state.store.project(&project_id)? else {
                return Ok(());
            };
            if project.paths.get(host_id) == Some(&path) {
                return Ok(());
            }
            project.paths.insert(host_id.to_string(), path);
            state.store.upsert_project(&project)?;
            state.emit(Event::ProjectUpdated { project });
        }

        HostToRelay::RuntimeOptions {
            runtime,
            models,
            thinking,
            modes,
            default_model,
            default_thinking,
            default_mode,
        } => {
            // Remember it against the machine that reported it, so the agent
            // editor can offer a real list rather than a free-text box.
            let Some(mut host) = state.store.host(host_id)? else {
                return Ok(());
            };
            let mut changed = false;
            for installation in &mut host.capabilities.runtimes {
                if installation.id != runtime {
                    continue;
                }
                if installation.models != models
                    || installation.thinking != thinking
                    || installation.modes != modes
                    || installation.default_model != default_model
                    || installation.default_thinking != default_thinking
                    || installation.default_mode != default_mode
                {
                    installation.models = models.clone();
                    installation.thinking = thinking.clone();
                    installation.modes = modes.clone();
                    installation.default_model = default_model.clone();
                    installation.default_thinking = default_thinking.clone();
                    installation.default_mode = default_mode.clone();
                    changed = true;
                }
            }
            if changed {
                state.store.upsert_host(&host)?;
                host.online = true;
                state.emit(Event::HostUpdated { host });
            }
        }

        HostToRelay::RunMessageDelta { run_id, body } => {
            stream_message(state, &run_id, &body).await?;
        }

        HostToRelay::RunMessage { run_id, kind, body } => {
            let Some(run) = state.store.run(&run_id)? else {
                return Ok(());
            };
            let draft = state.streaming_messages.write().await.remove(&run_id);

            // An ambient agent that has nothing to add says so, and we stay quiet.
            let quiet = matches!(run.trigger, RunTrigger::Ambient { .. })
                && body
                    .trim()
                    .trim_matches(|c: char| !c.is_alphanumeric())
                    .eq_ignore_ascii_case("NOTHING");
            if quiet {
                // It streamed something before deciding to stay out of it.
                if let Some(message_id) = draft {
                    state.store.delete_message(&message_id)?;
                    state.emit(Event::MessageDeleted {
                        channel_id: run.channel_id.clone(),
                        message_id,
                    });
                }
                return Ok(());
            }

            // The reply is already in the transcript; settle it in place rather
            // than posting the same text twice.
            if let Some(message_id) = draft {
                state.store.stream_message_body(&message_id, &body)?;
                if let Some(message) = state.store.message(&message_id)? {
                    state.emit(Event::MessageUpdated {
                        message: message.clone(),
                    });
                    finish_posted_message(state, &message).await?;
                    return Ok(());
                }
            }

            post_message(
                state,
                &run.channel_id,
                &run.agent_id,
                SendMessage {
                    body,
                    kind: Some(kind),
                    parent_id: reply_parent(state, &run).await,
                    ..Default::default()
                },
                PostOptions {
                    trigger_agents: true,
                    run_id: Some(run_id.clone()),
                },
            )
            .await?;
        }

        HostToRelay::RunQuestion { .. } => {
            // Questions arrive through the CLI's blocking `ask`, which owns the
            // waiting side of the flow.
        }

        HostToRelay::WorktreeReady {
            run_id,
            path,
            branch,
            base_branch,
            is_main_checkout,
        } => {
            let Some(mut run) = state.store.run(&run_id)? else {
                return Ok(());
            };
            let Some(task_id) = run.task_id.clone() else {
                return Ok(());
            };
            let existing = state
                .store
                .task_worktrees(&task_id)?
                .into_iter()
                .find(|w| w.path == path);
            let worktree = Worktree {
                id: existing.map(|w| w.id).unwrap_or_else(new_id),
                task_id: task_id.clone(),
                project_id: run.project_id.clone().unwrap_or_default(),
                host_id: host_id.to_string(),
                path: path.clone(),
                branch,
                base_branch,
                is_main_checkout,
                created_at: now_ms(),
            };
            state.store.upsert_worktree(&worktree)?;
            run.worktree_id = Some(worktree.id.clone());
            run.cwd = Some(path);
            state.store.update_run(&run)?;
            state.emit(Event::RunUpdated { run });

            if let Some(mut task) = state.store.task(&task_id)? {
                task.worktree_id = Some(worktree.id.clone());
                task.host_id = Some(host_id.to_string());
                state.store.update_task(&task)?;
                state.emit(Event::TaskUpdated { task });
            }
            state.emit(Event::WorktreeUpdated { worktree });
        }

        HostToRelay::PreviewStatus {
            preview_id,
            status,
            url,
            error,
        } => {
            let Some(mut preview) = state.store.preview(&preview_id)? else {
                return Ok(());
            };
            preview.status = status;
            if let Some(url) = url {
                // A relay-hosted preview is reachable through the relay; a
                // desktop preview stays on that machine.
                preview.url = if host_id == state.relay_host_id {
                    format!("{}/preview/{}/", state.public_url, preview.id)
                } else {
                    url
                };
            }
            if status == PreviewStatus::Stopped || status == PreviewStatus::Failed {
                preview.stopped_at = Some(now_ms());
            }
            state.store.upsert_preview(&preview)?;
            state.emit(Event::PreviewUpdated {
                preview: preview.clone(),
            });

            if let Some(error) = error {
                let _ = post_system(
                    state,
                    &discussion_channel(state, &preview.task_id)?,
                    &format!("Preview `{}` failed: {error}", preview.label),
                )
                .await;
            } else if status == PreviewStatus::Live {
                let channel_id = discussion_channel(state, &preview.task_id)?;
                let _ = post_message(
                    state,
                    &channel_id,
                    &system_member_id(state)?,
                    SendMessage {
                        kind: Some(MessageKind::Card),
                        card: Some(MessageCard::Preview {
                            preview_id: preview.id.clone(),
                        }),
                        ..Default::default()
                    },
                    PostOptions {
                        trigger_agents: false,
                        run_id: None,
                    },
                )
                .await;
            }
        }
    }
    Ok(())
}

fn discussion_channel(state: &Shared, task_id: &str) -> Result<Id> {
    state
        .store
        .task(task_id)?
        .map(|t| t.discussion_channel_id)
        .ok_or_else(|| anyhow!("task not found"))
}

/// A finished run updates the board and the Inbox so nothing silently stalls.
async fn finish_run(state: &Shared, run: &Run) -> Result<()> {
    // A run that died mid-sentence leaves its half-written reply in place —
    // that is the honest record — but nothing may rewrite it after this.
    if let Some(message_id) = state.streaming_messages.write().await.remove(&run.id) {
        if let Some(message) = state.store.message(&message_id)? {
            finish_posted_message(state, &message).await?;
        }
    }
    state.run_threads.write().await.remove(&run.id);

    if let Some(automation_run) = state.store.automation_run_by_run(&run.id)? {
        let mut automation_run = automation_run;
        automation_run.status = run.status;
        automation_run.error = run.error.clone();
        automation_run.ended_at = Some(now_ms());
        state.store.upsert_automation_run(&automation_run)?;
        state.emit(Event::AutomationRunUpdated {
            run: automation_run.clone(),
        });

        if run.status == RunStatus::Failed {
            crate::automations::report_failure(state, &automation_run, run).await?;
        }
    }

    let Some(task_id) = &run.task_id else {
        return Ok(());
    };
    let Some(mut task) = state.store.task(task_id)? else {
        return Ok(());
    };
    if task.current_run_id.as_deref() != Some(run.id.as_str()) {
        return Ok(());
    }
    task.current_run_id = None;

    match run.status {
        RunStatus::Succeeded => {
            if task.status == TaskStatus::Running {
                task.status = TaskStatus::Review;
                notify_task(
                    state,
                    &task,
                    InboxKind::ReviewReady,
                    format!("{} is ready for review", task.key),
                )?;
            }
        }
        RunStatus::Failed => {
            task.status = TaskStatus::Blocked;
            notify_task(
                state,
                &task,
                InboxKind::TaskBlocked,
                format!("{} is blocked", task.key),
            )?;
        }
        _ => {}
    }

    state.store.update_task(&task)?;
    state.emit(Event::TaskUpdated { task });
    Ok(())
}

pub fn notify_task(state: &Shared, task: &Task, kind: InboxKind, title: String) -> Result<()> {
    let mut targets: Vec<Id> = Vec::new();
    if let Some(owner) = &task.owner_id {
        targets.push(owner.clone());
    }
    targets.push(task.created_by.clone());

    for member_id in targets {
        let Some(member) = state.store.member(&member_id)? else {
            continue;
        };
        if member.kind != MemberKind::Human {
            continue;
        }
        let item = InboxItem {
            id: new_id(),
            member_id: member.id.clone(),
            kind,
            title: title.clone(),
            preview: task.title.clone(),
            actor_id: task.owner_id.clone(),
            channel_id: Some(task.discussion_channel_id.clone()),
            message_id: None,
            task_id: Some(task.id.clone()),
            run_id: task.current_run_id.clone(),
            automation_id: None,
            created_at: now_ms(),
            read_at: None,
        };
        state.store.insert_inbox(&item)?;
        state.emit(Event::InboxItemCreated { item });
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

/// First line of the expected result, trimmed to something a board row can show.
fn title_from(outcome: &str) -> String {
    let line = outcome
        .trim()
        .lines()
        .next()
        .unwrap_or_default()
        .trim()
        .trim_end_matches(['.', ':', ';', ',']);
    if line.is_empty() {
        return "Untitled task".to_string();
    }
    if line.chars().count() <= 60 {
        return line.to_string();
    }
    let head: String = line.chars().take(60).collect();
    let head = match head.rsplit_once(' ') {
        Some((words, _)) if words.chars().count() >= 20 => words,
        _ => head.as_str(),
    };
    format!("{}\u{2026}", head.trim_end())
}

/// Boxed: creating a task can fire an automation that creates a task.
pub fn create_task<'a>(
    state: &'a Shared,
    creator_id: &'a str,
    input: patchwork_core::wire::CreateTask,
) -> futures::future::BoxFuture<'a, Result<Task>> {
    Box::pin(create_task_inner(state, creator_id, input))
}

async fn create_task_inner(
    state: &Shared,
    creator_id: &str,
    input: patchwork_core::wire::CreateTask,
) -> Result<Task> {
    // Asked twice, one task. An agent that reports the same blocker every two
    // hours should leave one thing on the board, not twelve.
    if let Some(once_key) = input.once_key.as_deref().filter(|k| !k.trim().is_empty()) {
        if let Some(existing) = state.store.task_by_once_key(once_key.trim())? {
            return Ok(existing);
        }
    }

    let key = state.store.next_task_key()?;
    let now = now_ms();
    // ponytail: the title is the outcome's first line, not a model call. Swap in
    // a written title if these read badly; the task page already renames in place.
    let title = match input.title.trim() {
        "" => title_from(&input.outcome),
        given => given.to_string(),
    };

    let discussion = Channel {
        id: new_id(),
        kind: ChannelKind::Task,
        section_id: None,
        slug: String::new(),
        name: format!("{key}: {title}"),
        topic: input.outcome.clone(),
        position: 0.0,
        created_at: now,
        member_ids: {
            let mut ids = vec![creator_id.to_string()];
            if let Some(owner) = &input.owner_id {
                if owner != creator_id {
                    ids.push(owner.clone());
                }
            }
            ids
        },
        task_id: None,
        last_message_at: now,
    };
    state.store.insert_channel(&discussion)?;

    let mut task = Task {
        id: new_id(),
        key: key.clone(),
        title,
        outcome: input.outcome.clone(),
        status: input.status.unwrap_or(TaskStatus::Planned),
        owner_id: input.owner_id.clone(),
        source_channel_id: input.source_channel_id.clone(),
        source_message_id: input.source_message_id.clone(),
        discussion_channel_id: discussion.id.clone(),
        project_id: input.project_id.clone(),
        host_id: input.host_id.clone(),
        worktree_id: input.existing_worktree_id.clone(),
        current_run_id: None,
        pr_url: None,
        pr_state: None,
        created_by: creator_id.to_string(),
        due_at: input.due_at.filter(|at| *at > 0),
        once_key: input
            .once_key
            .as_deref()
            .map(str::trim)
            .filter(|k| !k.is_empty())
            .map(str::to_string),
        created_at: now,
        updated_at: now,
        position: now as f64,
    };
    state.store.insert_task(&task)?;

    // Link the discussion back to its task now that the task exists.
    let mut discussion = discussion;
    discussion.task_id = Some(task.id.clone());
    state.store.conn()?.execute(
        "UPDATE channels SET task_id = ?2 WHERE id = ?1",
        rusqlite::params![discussion.id, task.id],
    )?;

    state.emit(Event::ChannelCreated {
        channel: discussion.clone(),
    });
    state.emit(Event::TaskCreated { task: task.clone() });

    // A long voice transcript is source material, not the board title. Keep it
    // as the first human message so later title/outcome cleanup cannot erase it.
    if task.source_message_id.is_none() && !task.outcome.trim().is_empty() {
        let original = post_message(
            state,
            &task.discussion_channel_id,
            creator_id,
            SendMessage {
                body: task.outcome.clone(),
                attachment_ids: input.attachment_ids.clone(),
                ..Default::default()
            },
            PostOptions {
                trigger_agents: false,
                run_id: None,
            },
        )
        .await?;
        task.source_message_id = Some(original.id.clone());
        state
            .store
            .set_task_source_message(&task.id, &original.id)?;
        state.emit(Event::TaskUpdated { task: task.clone() });
    }

    // The task card belongs in the conversation it came from.
    if let Some(channel_id) = &input.source_channel_id {
        let _ = post_message(
            state,
            channel_id,
            creator_id,
            SendMessage {
                kind: Some(MessageKind::Card),
                card: Some(MessageCard::Task {
                    task_id: task.id.clone(),
                }),
                ..Default::default()
            },
            PostOptions {
                trigger_agents: false,
                run_id: None,
            },
        )
        .await;
    }

    if let Some(owner) = &task.owner_id {
        let owner_member = state.store.member(owner)?;
        if owner_member.as_ref().map(|m| m.kind) == Some(MemberKind::Human) {
            notify_task(
                state,
                &task,
                InboxKind::TaskAssigned,
                format!("{} was assigned to you", task.key),
            )?;
        }
    }

    crate::automations::on_task_change(state, &task, None).await;

    if input.start {
        if let Some(owner) = task.owner_id.clone() {
            if state.store.member(&owner)?.map(|m| m.kind) == Some(MemberKind::Agent) {
                let params = StartRunParams {
                    agent_id: owner,
                    channel_id: task.discussion_channel_id.clone(),
                    task_id: Some(task.id.clone()),
                    prompt: format!(
                        "Take this task from Planned to done.\n\n{}",
                        task.outcome.trim()
                    ),
                    trigger: RunTrigger::TaskAssignment {
                        task_id: task.id.clone(),
                    },
                    automation_id: None,
                    depth: 0,
                    host_id: task.host_id.clone(),
                    project_id: task.project_id.clone(),
                };
                if let Err(err) = start_run(state, params).await {
                    let _ = post_system(
                        state,
                        &task.discussion_channel_id,
                        &format!("Could not start the agent: {err}"),
                    )
                    .await;
                }
            }
        }
    }

    Ok(task)
}

pub async fn update_task(
    state: &Shared,
    actor_id: &str,
    task_id: &str,
    input: patchwork_core::wire::UpdateTask,
) -> Result<Task> {
    let mut task = state
        .store
        .task(task_id)?
        .ok_or_else(|| anyhow!("task not found"))?;
    let previous = task.clone();

    if let Some(title) = input.title {
        task.title = title;
    }
    if let Some(outcome) = input.outcome {
        task.outcome = outcome;
    }
    if let Some(status) = input.status {
        task.status = status;
    }
    if let Some(owner_id) = input.owner_id {
        task.owner_id = if owner_id.is_empty() {
            None
        } else {
            Some(owner_id)
        };
    }
    if let Some(project_id) = input.project_id {
        task.project_id = if project_id.is_empty() {
            None
        } else {
            Some(project_id)
        };
    }
    if let Some(host_id) = input.host_id {
        task.host_id = if host_id.is_empty() {
            None
        } else {
            Some(host_id)
        };
    }
    if let Some(pr_url) = input.pr_url {
        task.pr_url = if pr_url.is_empty() {
            None
        } else {
            Some(pr_url)
        };
    }
    // 0 is how a client says "no date": there is no such instant in practice,
    // and `null` cannot be told apart from "not mentioned" in a patch.
    if let Some(due_at) = input.due_at {
        task.due_at = (due_at > 0).then_some(due_at);
    }
    if let Some(position) = input.position {
        task.position = position;
    }

    state.store.update_task(&task)?;
    state.emit(Event::TaskUpdated { task: task.clone() });
    if previous.title != task.title || previous.outcome != task.outcome {
        if let Some(channel) = state.store.channel(&task.discussion_channel_id)? {
            state.emit(Event::ChannelUpdated { channel });
        }
    }

    // A moved date is a new promise, so it gets to be announced again.
    if previous.due_at != task.due_at {
        state.store.clear_inbox(&task.id, InboxKind::TaskDue)?;
    }

    if previous.owner_id != task.owner_id {
        if let Some(owner) = &task.owner_id {
            state
                .store
                .add_channel_member(&task.discussion_channel_id, owner)?;
            if state.store.member(owner)?.map(|m| m.kind) == Some(MemberKind::Human) {
                notify_task(
                    state,
                    &task,
                    InboxKind::TaskAssigned,
                    format!("{} was assigned to you", task.key),
                )?;
            }
        }
    }

    if previous.status != task.status {
        let actor = state
            .store
            .member(actor_id)?
            .map(|m| m.display_name)
            .unwrap_or_else(|| "Someone".into());
        let _ = post_system(
            state,
            &task.discussion_channel_id,
            &format!(
                "{actor} moved this task from {} to {}",
                previous.status.as_str(),
                task.status.as_str()
            ),
        )
        .await;
        if task.status == TaskStatus::Done {
            state.store.resolve_inbox_for(Some(&task.id), None)?;
        }
    }

    if previous.pr_url != task.pr_url {
        if let Some(url) = &task.pr_url {
            let _ = post_message(
                state,
                &task.discussion_channel_id,
                actor_id,
                SendMessage {
                    kind: Some(MessageKind::Card),
                    card: Some(MessageCard::PullRequest {
                        url: url.clone(),
                        task_id: Some(task.id.clone()),
                    }),
                    ..Default::default()
                },
                PostOptions {
                    trigger_agents: false,
                    run_id: None,
                },
            )
            .await;
        }
    }

    crate::automations::on_task_change(state, &task, Some(&previous)).await;
    Ok(task)
}

/// Ask an agent to pick a task up (or continue it).
pub async fn run_task(
    state: &Shared,
    actor_id: &str,
    task_id: &str,
    agent_id: Option<Id>,
    prompt: Option<String>,
) -> Result<Run> {
    let task = state
        .store
        .task(task_id)?
        .ok_or_else(|| anyhow!("task not found"))?;
    let agent_id = agent_id
        .or_else(|| task.owner_id.clone())
        .ok_or_else(|| anyhow!("this task has no agent owner"))?;

    let prompt = prompt.unwrap_or_else(|| {
        if task.outcome.trim().is_empty() {
            format!("Continue task {}: {}", task.key, task.title)
        } else {
            format!(
                "Continue task {} — {}.\nExpected result: {}",
                task.key,
                task.title,
                task.outcome.trim()
            )
        }
    });

    start_run(
        state,
        StartRunParams {
            agent_id,
            channel_id: task.discussion_channel_id.clone(),
            task_id: Some(task.id.clone()),
            prompt,
            trigger: RunTrigger::Manual {
                by: actor_id.to_string(),
            },
            automation_id: None,
            depth: 0,
            host_id: task.host_id.clone(),
            project_id: task.project_id.clone(),
        },
    )
    .await
    .context("could not start the run")
}

/// Answering a question un-blocks the run that asked it.
pub async fn answer_question(
    state: &Shared,
    question_id: &str,
    answers: Vec<QuestionAnswer>,
    by: &str,
) -> Result<Question> {
    let question = state.store.answer_question(question_id, &answers, by)?;
    state.emit(Event::QuestionUpdated {
        question: question.clone(),
    });
    state.resolve_question(&question).await;
    state
        .store
        .resolve_inbox_for(None, Some(&question.run_id))?;

    if let Some(mut run) = state.store.run(&question.run_id)? {
        if run.status == RunStatus::Waiting {
            run.status = RunStatus::Running;
            run.headline = "Working".into();
            state.store.update_run(&run)?;
            state.emit(Event::RunUpdated { run: run.clone() });
        }
        state.set_presence(&run.agent_id, Presence::Working).await;
    }

    Ok(question)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_come_from_the_first_line() {
        assert_eq!(
            title_from("Ship the billing page."),
            "Ship the billing page"
        );
        assert_eq!(title_from("  Fix login\nmore detail here"), "Fix login");
        assert_eq!(title_from(""), "Untitled task");
        let long = title_from(&"alpha beta gamma delta epsilon zeta eta".repeat(3));
        assert!(
            long.ends_with('\u{2026}') && long.chars().count() <= 61,
            "{long}"
        );
    }

    fn member(id: &str, handle: &str, kind: MemberKind) -> Member {
        Member {
            id: id.into(),
            kind,
            handle: handle.into(),
            display_name: handle.into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 0,
            agent: (kind == MemberKind::Agent).then(AgentProfile::default),
            presence: Presence::Offline,
        }
    }

    #[test]
    fn mentions_need_a_word_boundary() {
        let members = vec![
            member("1", "dev", MemberKind::Agent),
            member("2", "dev-ops", MemberKind::Agent),
        ];
        assert_eq!(parse_mentions("hey @dev can you look", &members), vec!["1"]);
        assert_eq!(
            parse_mentions("hey @dev-ops can you look", &members),
            vec!["2"]
        );
        assert!(parse_mentions("email me at a@developer.com", &members).is_empty());
    }

    fn message_at(id: &str, author: &str, at: Millis, run: Option<&str>) -> Message {
        Message {
            id: id.into(),
            channel_id: "c".into(),
            author_id: author.into(),
            kind: MessageKind::Text,
            body: String::new(),
            card: None,
            parent_id: None,
            reply_count: 0,
            last_reply_at: 0,
            run_id: run.map(|r| r.to_string()),
            task_id: None,
            mentions: Vec::new(),
            attachments: Vec::new(),
            reactions: Vec::new(),
            created_at: at,
            edited_at: None,
        }
    }

    fn run_by(agent: &str) -> Run {
        Run {
            id: "r1".into(),
            agent_id: agent.into(),
            status: RunStatus::Succeeded,
            trigger: RunTrigger::Manual { by: "vince".into() },
            channel_id: "c".into(),
            task_id: None,
            host_id: None,
            project_id: None,
            worktree_id: None,
            cwd: None,
            automation_id: None,
            session_id: None,
            runtime: "claude".into(),
            prompt: String::new(),
            headline: String::new(),
            error: None,
            token_usage: None,
            created_at: 0,
            started_at: None,
            ended_at: None,
        }
    }

    #[test]
    fn answering_the_agent_that_just_answered_you_counts_as_talking_to_it() {
        let reply = message_at("m2", "agent", 1_000, Some("r1"));
        let followup = message_at("m3", "vince", 5_000, None);
        assert_eq!(
            continues_conversation(&followup, &reply, &run_by("agent"), Some("vince")),
            Some("agent".to_string()),
            "a follow-up with no @ is still directed at whoever just replied",
        );
    }

    #[test]
    fn continuation_does_not_reach_across_a_long_gap() {
        let reply = message_at("m2", "agent", 0, Some("r1"));
        let much_later = message_at("m3", "vince", CONTINUATION_WINDOW_MS + 1, None);
        assert_eq!(
            continues_conversation(&much_later, &reply, &run_by("agent"), Some("vince")),
            None,
        );
    }

    #[test]
    fn continuation_only_belongs_to_the_person_being_answered() {
        let reply = message_at("m2", "agent", 1_000, Some("r1"));
        let someone_else = message_at("m3", "mallory", 2_000, None);
        assert_eq!(
            continues_conversation(&someone_else, &reply, &run_by("agent"), Some("vince")),
            None,
            "overhearing an answer to somebody else is not a conversation with you",
        );
    }

    #[test]
    fn ambient_runs_are_told_they_may_stay_quiet() {
        let params = StartRunParams {
            agent_id: "a".into(),
            channel_id: "c".into(),
            task_id: None,
            prompt: "deploy is failing".into(),
            trigger: RunTrigger::Ambient {
                message_id: "m".into(),
            },
            automation_id: None,
            depth: 0,
            host_id: None,
            project_id: None,
        };
        let prompt = compose_prompt(&params, &None, &params.trigger);
        assert!(prompt.contains("NOTHING"));
        assert!(prompt.contains("deploy is failing"));
    }
}
