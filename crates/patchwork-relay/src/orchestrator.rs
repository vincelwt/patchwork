//! Deciding what should happen, and making it happen.
//!
//! Posting a message, creating a task, answering a question and finishing a run
//! all funnel through here so that the conversation, the board, the Inbox and
//! the running agents never disagree with each other.

use std::collections::BTreeSet;

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
use crate::state::{RunDestination, Shared};
use crate::store::{InsertTaskResult, Store, TaskRunHandoff};

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
    let client_id = input.client_id.as_deref();
    let channel = state
        .store
        .channel(channel_id)?
        .ok_or_else(|| anyhow!("channel not found"))?;
    let members = state.store.members()?;
    let mentions = parse_mentions(&input.body, &members);

    let task_id = channel.task_id.clone();
    let kind = input.kind.unwrap_or(MessageKind::Text);
    let run_id = options.run_id.clone().or(input.run_id.clone());
    let destination =
        if input.reply_to_id.is_none() && input.parent_id.is_none() && kind == MessageKind::Text {
            match options
                .run_id
                .as_deref()
                .and_then(|id| state.store.run(id).ok().flatten())
            {
                Some(run) if run.channel_id == channel_id => reply_destination(state, &run).await,
                _ => RunDestination::default(),
            }
        } else {
            RunDestination::default()
        };
    let mut message = Message {
        id: new_id(),
        channel_id: channel_id.to_string(),
        author_id: author_id.to_string(),
        kind,
        body: input.body.clone(),
        card: input.card.clone(),
        parent_id: input.parent_id.clone().or(destination.parent_id),
        reply_to_id: input.reply_to_id.clone().or(destination.reply_to_id),
        reply_to: None,
        reply_count: 0,
        last_reply_at: 0,
        run_id,
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

    // Two attempts racing here is the unique index's job: the loser fails, and
    // its next retry is answered from the existing message by the API.
    state.store.insert_message_as(&message, client_id)?;
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
    reply_destination(state, run).await.parent_id
}

async fn reply_destination(state: &Shared, run: &Run) -> RunDestination {
    if let Some(known) = state.run_destinations.read().await.get(&run.id) {
        return known.clone();
    }
    let message_id = match &run.trigger {
        RunTrigger::Mention { message_id }
        | RunTrigger::Reply { message_id }
        | RunTrigger::DirectMessage { message_id }
        | RunTrigger::Ambient { message_id } => message_id,
        _ => return RunDestination::default(),
    };
    state
        .store
        .message(message_id)
        .ok()
        .flatten()
        .map(|message| RunDestination {
            reply_to_id: message.parent_id.is_none().then_some(message.id),
            parent_id: message.parent_id,
        })
        .unwrap_or_default()
}

async fn queue_destination(state: &Shared, control_id: &str, message: &Message) {
    state.control_destinations.write().await.insert(
        control_id.to_string(),
        RunDestination {
            parent_id: message.parent_id.clone(),
            reply_to_id: message.parent_id.is_none().then_some(message.id.clone()),
        },
    );
}

/// A reply that is still being written: posted on the first delta so the reader
/// watches it arrive, then rewritten in place by every delta after it.
async fn stream_message(state: &Shared, host_id: &str, run_id: &str, body: &str) -> Result<()> {
    let Some(run) = state.store.run(run_id)? else {
        return Ok(());
    };
    if run.host_id.as_deref() != Some(host_id) || run.status.is_terminal() {
        return Ok(());
    }

    let existing = state.streaming_messages.read().await.get(run_id).cloned();
    if let Some(message_id) = existing {
        state.store.stream_message_body(&message_id, body)?;
        if let Some(message) = state.store.message(&message_id)? {
            state.emit(Event::MessageUpdated { message });
        }
        return Ok(());
    }

    // Ambient agents are allowed to decide they have nothing to say, and that
    // decision only arrives at the end. Let them finish before taking the floor.
    if matches!(run.trigger, RunTrigger::Ambient { .. }) {
        return Ok(());
    }
    let Some(channel) = state.store.channel(&run.channel_id)? else {
        return Ok(());
    };
    let destination = reply_destination(state, &run).await;

    let message = Message {
        id: new_id(),
        channel_id: run.channel_id.clone(),
        author_id: run.agent_id.clone(),
        kind: MessageKind::Text,
        body: body.to_string(),
        card: None,
        parent_id: destination.parent_id,
        reply_to_id: destination.reply_to_id,
        reply_to: None,
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
    let stored = state.store.message(&message.id)?.unwrap_or(message);
    state
        .streaming_messages
        .write()
        .await
        .insert(run_id.to_string(), stored.id.clone());
    state.emit(Event::MessageCreated { message: stored });
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

/// A question is a transcript boundary. Text after the human answers must get
/// a newer message id so it appears below the question card.
pub(crate) async fn finish_streamed_reply(state: &Shared, run_id: &str) -> Result<()> {
    if let Some(message_id) = state.streaming_messages.write().await.remove(run_id) {
        if let Some(message) = state.store.message(&message_id)? {
            finish_posted_message(state, &message).await?;
        }
    }
    Ok(())
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

/// A threaded message sees its root and replies, never unrelated channel chat.
fn conversation_messages(store: &Store, message: &Message, limit: usize) -> Result<Vec<Message>> {
    let mut messages = if let Some(parent_id) = &message.parent_id {
        let Some(parent) = store.message(parent_id)? else {
            return Ok(Vec::new());
        };
        let mut messages = store.thread(parent_id)?;
        let keep = limit.saturating_sub(1);
        if messages.len() > keep {
            messages.drain(..messages.len() - keep);
        }
        if limit > 0 {
            messages.insert(0, parent);
        }
        messages
    } else {
        store.recent_messages(&message.channel_id, limit)?
    };

    // A reply may answer an older message outside the normal context window.
    if let Some(reply_to_id) = &message.reply_to_id {
        if limit > 0 && !messages.iter().any(|item| item.id == *reply_to_id) {
            if let Some(source) = store.message(reply_to_id)? {
                if messages.len() >= limit {
                    messages.remove(0);
                }
                messages.insert(0, source);
            }
        }
    }
    Ok(messages)
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

    if let Some(reply_to_id) = &message.reply_to_id {
        if let Some(parent) = state.store.message(reply_to_id)? {
            push(
                state,
                &parent.author_id,
                InboxKind::Reply,
                format!("{author_name} replied to your message"),
                &mut notified,
            )?;
        }
    } else if let Some(parent_id) = &message.parent_id {
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
    let reply_source = match &message.reply_to_id {
        Some(id) => state.store.message(id)?,
        None => None,
    };
    let reply_agent = reply_source
        .as_ref()
        .and_then(|source| members.iter().find(|member| member.id == source.author_id))
        .filter(|member| member.kind == MemberKind::Agent)
        .map(|member| member.id.clone());

    // Ownership can change while work is running. Feedback belongs to the
    // task's actual writer first, not whoever currently owns the card.
    if author.kind == MemberKind::Human
        && message.mentions.is_empty()
        && message.reply_to_id.is_none()
        && channel.kind == ChannelKind::Task
    {
        let active = channel
            .task_id
            .as_deref()
            .and_then(|id| state.store.task(id).ok().flatten())
            .and_then(|task| task.current_run_id)
            .and_then(|id| state.store.run(&id).ok().flatten())
            .filter(|run| !run.status.is_terminal());
        if let Some(active) = active {
            let control_id = new_id();
            queue_destination(state, &control_id, message).await;
            let attachment_ids = message
                .attachments
                .iter()
                .map(|attachment| attachment.id.clone())
                .collect::<Vec<_>>();
            let prompt = format!(
                "{} just said:\n\n{}",
                display_name_of(members, &message.author_id),
                message.body
            );
            if let Err(err) = deliver_control(
                state,
                &active,
                control_id.clone(),
                prompt,
                RunControlMode::Queue,
                run_files(state, &attachment_ids)?,
            )
            .await
            {
                state.control_destinations.write().await.remove(&control_id);
                let _ = post_system(
                    state,
                    &channel.id,
                    &format!("Could not deliver that feedback: {err}"),
                )
                .await;
            }
            return Ok(());
        }
    }

    // A task is already addressed: its owner is the recipient.
    let task_owner = if author.kind == MemberKind::Human
        && message.mentions.is_empty()
        && message.reply_to_id.is_none()
        && channel.kind == ChannelKind::Task
    {
        channel
            .task_id
            .as_deref()
            .and_then(|id| state.store.task(id).ok().flatten())
            .and_then(|task| {
                (!task.status.is_terminal())
                    .then_some(task.owner_id)
                    .flatten()
            })
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

        let replied_to_agent = reply_agent.as_deref() == Some(agent.id.as_str());
        // Agent-authored messages only ever wake an explicitly mentioned agent,
        // and only while the chain is still shallow. Inline reply references on
        // agent output must not make two active runs answer each other forever.
        if author.kind == MemberKind::Agent {
            if !mentioned || author_depth >= MAX_AGENT_CHAIN_DEPTH {
                continue;
            }
        }

        let owns_task = task_owner.as_deref() == Some(agent.id.as_str());
        let addressed = replied_to_agent || mentioned || owns_task;

        let should_run = if replied_to_agent {
            true
        } else if addressed {
            participation != Participation::Off || in_dm || owns_task
        } else if in_dm {
            profile.dm_enabled
        } else {
            // Ambient means "may chime in", and that is only ever true of a
            // room. A direct message is between the people in it, and a task
            // discussion belongs to whoever is on the task — an uninvited agent
            // wandering into either is not helpfulness, it is eavesdropping.
            message.mentions.is_empty()
                && message.reply_to_id.is_none()
                && participation == Participation::Ambient
                && author.kind == MemberKind::Human
                && channel.kind == ChannelKind::Channel
        };
        if !should_run {
            continue;
        }

        let trigger = if replied_to_agent {
            RunTrigger::Reply {
                message_id: message.id.clone(),
            }
        } else if addressed {
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
            let control_id = new_id();
            queue_destination(state, &control_id, message).await;
            let prompt = if let Some(source) = reply_source.as_ref().filter(|_| replied_to_agent) {
                format!(
                    "{} replied to {}'s message:\n\n{}\n\nReply:\n\n{}",
                    display_name_of(members, &message.author_id),
                    display_name_of(members, &source.author_id),
                    source.body,
                    message.body
                )
            } else {
                format!(
                    "{} just said:\n\n{}",
                    display_name_of(members, &message.author_id),
                    message.body
                )
            };
            let attachment_ids = message
                .attachments
                .iter()
                .map(|attachment| attachment.id.clone())
                .collect::<Vec<_>>();
            if let Err(err) = deliver_control(
                state,
                &active,
                control_id.clone(),
                prompt,
                RunControlMode::Queue,
                run_files(state, &attachment_ids)?,
            )
            .await
            {
                state.control_destinations.write().await.remove(&control_id);
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

        // A second agent on a busy task joins it: same task, same worktree,
        // and each of them is told who else is working there.
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
            required_task_status: None,
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

/// Something meant to be read rather than glanced at. A workspace event is a
/// quiet one-line activity row with no markdown; quoted review feedback needs
/// the ordinary message body, where headings, quotes and code render.
pub async fn post_note(state: &Shared, channel_id: &str, body: &str) -> Result<Message> {
    let system_id = system_member_id(state)?;
    post_message(
        state,
        channel_id,
        &system_id,
        SendMessage {
            body: body.to_string(),
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
// Agents sharing a task
// ---------------------------------------------------------------------------

/// A task takes as many agents at once as somebody starts on it, and they all
/// work in its one worktree. Nothing here arbitrates between them: it makes
/// each of them aware of the others, at the start of a run and whenever the
/// company changes, so they can stay out of each other's way themselves.
const SHARED_WORKTREE_ETIQUETTE: &str = "You share this checkout with them: \
touch only the files your own work needs, stage those paths by name rather than \
`git commit -a`, and do not switch, rebase or reset the branch under someone \
else. Read a file again before you edit it, and use `patchwork tell <run-id>` \
when something you changed affects their work.";

/// Everyone else still working on this task, newest first.
fn task_peers(state: &Shared, task_id: &str, except_run_id: &str) -> Result<Vec<Run>> {
    Ok(state
        .store
        .active_task_runs(task_id)?
        .into_iter()
        .filter(|run| run.id != except_run_id)
        .collect())
}

fn agent_label(members: &[Member], agent_id: &str) -> String {
    match members.iter().find(|member| member.id == agent_id) {
        Some(member) => format!("{} (@{})", member.display_name, member.handle),
        None => "Another agent".to_string(),
    }
}

/// One line per agent in the worktree: who, which run to talk to, and what
/// they said they were doing when they last reported.
fn peer_line(members: &[Member], run: &Run) -> String {
    let doing = run.headline.trim();
    let doing = if doing.is_empty() { "working" } else { doing };
    format!(
        "- {} — run {} [{}] — {doing}\n",
        agent_label(members, &run.agent_id),
        run.id,
        run.status.as_str()
    )
}

/// Tell everyone else on this task that the company changed. It arrives as a
/// queued turn in their existing session, so nobody is interrupted mid-edit.
pub(crate) async fn tell_task_peers(
    state: &Shared,
    task_id: &str,
    except_run_id: &str,
    body: String,
) {
    let peers = match task_peers(state, task_id, except_run_id) {
        Ok(peers) => peers,
        Err(err) => {
            tracing::warn!(?err, task = %task_id, "could not list the task's other runs");
            return;
        }
    };
    for peer in peers {
        let control_id = new_id();
        if let Err(err) = deliver_control(
            state,
            &peer,
            control_id,
            body.clone(),
            RunControlMode::Queue,
            Vec::new(),
        )
        .await
        {
            tracing::warn!(?err, run = %peer.id, "could not tell a task peer");
            continue;
        }
        let _ = append_run_event(
            state,
            &peer.id,
            RunEventKind::Lifecycle,
            body.lines().next().unwrap_or_default().to_string(),
            None,
        );
    }
}

// ---------------------------------------------------------------------------
// Runs
// ---------------------------------------------------------------------------

pub(crate) fn append_run_event(
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
            file_name: attachment.file_name.clone(),
            url: state.grant_file(&attachment),
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
        reply_to_id: None,
        reply_to: None,
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

fn run_conversation(state: &Shared, run: &Run) -> Result<Id> {
    match &run.task_id {
        Some(task_id) => state
            .store
            .task(task_id)?
            .map(|task| task.discussion_channel_id)
            .ok_or_else(|| anyhow!("task not found")),
        None => Ok(run.channel_id.clone()),
    }
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
            Some(run)
        }
        None => None,
    };

    let members = state.store.members()?;
    let sender = display_name_of(&members, author_id);
    let target_name = display_name_of(&members, &target.agent_id);
    let control_id = new_id();
    let summary = if prompt.is_empty() {
        "Attached file(s)"
    } else {
        prompt
    };
    if let Some(source) = &source {
        let mut event = RunEvent {
            id: new_id(),
            run_id: source.id.clone(),
            seq: 0,
            kind: RunEventKind::Message,
            text: format!("Message to {target_name}: {summary}"),
            data: Some(json!({
                "control_id": control_id.clone(),
                "target_run_id": target.id.clone(),
                "mode": input.mode,
                "direction": "outbound",
            })),
            created_at: now_ms(),
        };
        state.store.reserve_direct_control(&mut event, &target.id)?;
        state.emit(Event::RunEventAppended { event });
    }
    let delivered = if prompt.is_empty() {
        "Review the attached file(s).".to_string()
    } else if source.is_some() {
        format!(
            "{sender} sent a message from another active Patchwork run:\n\n{prompt}\n\nUse this information in your current work. Reply only if coordination requires it."
        )
    } else {
        format!("{sender} sent steering feedback:\n\n{prompt}")
    };
    state
        .control_destinations
        .write()
        .await
        .insert(control_id.clone(), RunDestination::default());
    if let Err(err) = deliver_control(
        state,
        &target,
        control_id.clone(),
        delivered,
        input.mode,
        run_files(state, &input.attachment_ids)?,
    )
    .await
    {
        state.control_destinations.write().await.remove(&control_id);
        if let Some(source) = &source {
            append_run_event(
                state,
                &source.id,
                RunEventKind::Error,
                format!("Could not message {target_name}: {err}"),
                Some(json!({ "control_id": control_id.clone() })),
            )?;
        }
        return Err(err);
    }

    let note = if source.is_some() {
        format!("{sender} → {target_name}: {summary}")
    } else {
        format!("Feedback for {target_name}: {summary}")
    };
    let target_channel = run_conversation(state, &target)?;
    post_control_note(
        state,
        &target_channel,
        author_id,
        source_run_id,
        note.clone(),
        &input.attachment_ids,
    )?;

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
        let source_channel = run_conversation(state, source)?;
        if source_channel != target_channel {
            post_control_note(
                state,
                &source_channel,
                author_id,
                Some(&source.id),
                note,
                &[],
            )?;
        }
    }
    Ok(control_id)
}

#[derive(Debug)]
pub struct TaskUnavailable;

impl std::fmt::Display for TaskUnavailable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("the task is no longer available to start")
    }
}

impl std::error::Error for TaskUnavailable {}

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
    pub required_task_status: Option<TaskStatus>,
}

fn ensure_task_accepts_run(task: Option<&Task>) -> Result<()> {
    if let Some(task) = task.filter(|task| task.status.is_terminal()) {
        bail!(
            "{} is {}; reopen it before starting more work",
            task.key,
            task.status.as_str()
        );
    }
    Ok(())
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
    ensure_task_accepts_run(task.as_ref())?;
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
        provider: None,
        model: None,
        thinking: None,
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
        autonomy: state.store.workspace()?.autonomy,
        skills: state.store.workspace_skills()?,
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

    let previous_task_status = if let Some(task_id) = &run.task_id {
        match state
            .store
            .activate_task_run(task_id, &run.id, params.required_task_status)?
        {
            Some(status) => Some(status),
            None => {
                let mut cancelled = run.clone();
                cancelled.status = RunStatus::Cancelled;
                cancelled.error = Some("the task is no longer available to start".into());
                cancelled.ended_at = Some(now_ms());
                state.store.update_run(&cancelled)?;
                state.store.revoke_run_tokens(&run.id).ok();
                state.emit(Event::RunUpdated { run: cancelled });
                return Err(TaskUnavailable.into());
            }
        }
    } else {
        None
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
        state.store.revoke_run_tokens(&run.id).ok();
        if let (Some(task_id), Some(previous_status)) =
            (run.task_id.as_deref(), previous_task_status)
        {
            state
                .store
                .restore_task_after_failed_start(task_id, &run.id, previous_status)?;
            if let Some(task) = state.store.task(task_id)? {
                state.emit(Event::TaskUpdated { task });
            }
        }
        state.emit(Event::RunUpdated { run: failed });
        bail!("the execution host for this agent is offline");
    }

    state.emit(Event::RunUpdated { run: run.clone() });

    if let Some(task_id) = run.task_id.as_deref() {
        state
            .store
            .finalize_task_run_start(task_id, &run.id, run.created_at)?;
        if let Some(task) = state.store.task(task_id)? {
            state.emit(Event::TaskUpdated { task });
        }
    }

    // Whoever is already in this worktree hears that someone joined them,
    // rather than discovering it in a file that moved.
    if let (Some(task_id), Some(task)) = (run.task_id.as_deref(), task.as_ref()) {
        let asked = params.prompt.trim().chars().take(500).collect::<String>();
        let where_ = run
            .cwd
            .as_deref()
            .map(|path| format!(" ({path})"))
            .unwrap_or_default();
        tell_task_peers(
            state,
            task_id,
            &run.id,
            format!(
                "{} just started working on {} alongside you, in the same worktree{where_}. \
They were asked:\n\n{asked}\n\n{SHARED_WORKTREE_ETIQUETTE} Carry on with your own work; \
reply only if this changes it.",
                agent_label(&state.store.members()?, &agent.id),
                task.key,
            ),
        )
        .await;
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

/// Redispatch an interrupted run to the machine that owns it, without creating
/// a second run card or losing its task/worktree identity. The fresh token
/// replaces the unrecoverable plaintext token that was held only by the
/// stopped process.
pub(crate) async fn resume_interrupted_run(state: &Shared, run: &Run) -> Result<()> {
    let host_id = run
        .host_id
        .clone()
        .ok_or_else(|| anyhow!("the run never reached a machine"))?;
    let agent = state
        .store
        .member(&run.agent_id)?
        .filter(|member| member.kind == MemberKind::Agent)
        .ok_or_else(|| anyhow!("the run's agent no longer exists"))?;
    let profile = agent.agent.clone().unwrap_or_default();
    let task = match &run.task_id {
        Some(id) => state.store.task(id)?,
        None => None,
    };
    let project = match &run.project_id {
        Some(id) => state.store.project(id)?,
        None => None,
    };
    let worktree = if let Some(path) = run.cwd.clone() {
        WorktreeSpec::Existing { path }
    } else {
        resolve_worktree(state, &task, &project, &host_id)?.0
    };

    state.store.revoke_run_tokens(&run.id)?;
    let token = auth::generate_token();
    state.store.insert_token(
        &auth::hash_token(&token),
        &agent.id,
        "run",
        Some(&run.id),
        Some("run"),
    )?;

    // An answer routed to the old process cannot be applied to the restored
    // turn. Cancel it so the resumed agent can ask again if it still needs it.
    cancel_questions_for_run(state, &run.id).await?;

    let spec = RunSpec {
        run_id: run.id.clone(),
        agent_id: agent.id.clone(),
        agent_handle: agent.handle.clone(),
        agent_name: agent.display_name.clone(),
        agent_description: profile.description.clone(),
        autonomy: state.store.workspace()?.autonomy,
        skills: state.store.workspace_skills()?,
        runtime: run.runtime.clone(),
        provider: run.provider.clone().or(profile.provider.clone()),
        model: run.model.clone().or(profile.model.clone()),
        thinking: run.thinking.clone().or(profile.thinking.clone()),
        custom_command: profile.custom_command.clone(),
        channel_id: run.channel_id.clone(),
        task_id: run.task_id.clone(),
        project_id: run.project_id.clone(),
        project_name: project.as_ref().map(|project| project.name.clone()),
        automation_id: run.automation_id.clone(),
        worktree,
        prompt: run.prompt.clone(),
        context: build_context(state, run, &task).await?,
        files: task_files(state, &task),
        api_base: state.public_url.clone(),
        api_token: token,
        resume_session_id: run.session_id.clone(),
        env: Vec::new(),
    };

    let mut resumed = run.clone();
    resumed.status = RunStatus::Dispatched;
    resumed.headline = "Restarting".into();
    resumed.error = None;
    resumed.ended_at = None;
    state.store.update_run(&resumed)?;

    if !state
        .send_to_host(
            &host_id,
            RelayToHost::StartRun {
                spec: Box::new(spec),
            },
        )
        .await
    {
        bail!("the machine that was running this is not connected");
    }
    append_run_event(
        state,
        &run.id,
        RunEventKind::Lifecycle,
        "Resumed after an interruption".into(),
        None,
    )?;
    state.emit(Event::RunUpdated { run: resumed });
    Ok(())
}

/// A machine that just registered takes back the runs the relay still has on
/// it. A host stops its agents when its connection drops, so a run still
/// pointing at it is one nobody is executing — including every desktop run
/// left in flight by a relay restart.
pub async fn resume_host_runs(state: &Shared, host_id: &str) {
    let Ok(runs) = state.store.active_runs() else {
        return;
    };
    for run in runs {
        if run.host_id.as_deref() != Some(host_id) {
            continue;
        }
        if let Err(err) = resume_interrupted_run(state, &run).await {
            tracing::warn!(?err, run = %run.id, "could not resume a run on the machine that owns it");
            let _ = fail_run(
                state,
                &run,
                &format!(
                    "it could not be resumed on {}: {err:#}",
                    host_name(state, host_id)
                ),
            )
            .await;
        }
    }
}

/// Three missed heartbeats. Long enough to survive a reconnect, short enough
/// that nobody watches a dead run pretend to work.
const HOST_SILENCE_LIMIT_MS: Millis = 90_000;

/// A run dispatched moments ago is not yet in the machine's own list of what
/// it is running, so only runs old enough to have been picked up are judged.
const RUN_PICKUP_GRACE_MS: Millis = 60_000;

/// A machine that stops answering takes its runs down with it, and nothing
/// else notices: the socket may have gone quietly, and the work it carried
/// would look alive until the next relay restart.
pub async fn watch_hosts(state: Shared) {
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(30));
    loop {
        ticker.tick().await;
        end_runs_on_silent_hosts(&state).await;
    }
}

async fn end_runs_on_silent_hosts(state: &Shared) {
    let Ok(runs) = state.store.active_runs() else {
        return;
    };
    let now = now_ms();
    for run in runs {
        let Some(host_id) = run.host_id.clone() else {
            continue;
        };
        if state.host_online(&host_id).await {
            continue;
        }
        let last_seen = state
            .store
            .host(&host_id)
            .ok()
            .flatten()
            .map(|host| host.last_seen)
            .unwrap_or(0);
        if !host_is_gone(now, last_seen, state.started_at) {
            continue;
        }
        let _ = fail_run(
            state,
            &run,
            &format!(
                "{} stopped answering while this run was in flight",
                host_name(state, &host_id)
            ),
        )
        .await;
    }
}

/// Runs the relay still has on a machine that the machine itself is not
/// running: whatever was executing them died without reporting back.
async fn end_runs_the_host_lost(state: &Shared, host_id: &str, alive: &[Id]) {
    let Ok(runs) = state.store.active_runs() else {
        return;
    };
    let now = now_ms();
    for run in runs {
        if run.host_id.as_deref() != Some(host_id) || alive.contains(&run.id) {
            continue;
        }
        if now.saturating_sub(run.started_at.unwrap_or(run.created_at)) < RUN_PICKUP_GRACE_MS {
            continue;
        }
        let machine = host_name(state, host_id);
        let why = match run.status {
            RunStatus::Queued | RunStatus::Dispatched => {
                format!("{machine} never picked this run up")
            }
            _ => format!("the agent process on {machine} stopped without reporting back"),
        };
        let _ = fail_run(state, &run, &why).await;
    }
}

/// A relay restart is not a dead machine: silence is measured from the moment
/// we came up, so a desktop that reconnects keeps the work it was given.
fn host_is_gone(now: Millis, last_seen: Millis, relay_started_at: Millis) -> bool {
    now.saturating_sub(last_seen.max(relay_started_at)) >= HOST_SILENCE_LIMIT_MS
}

fn host_name(state: &Shared, host_id: &str) -> String {
    state
        .store
        .host(host_id)
        .ok()
        .flatten()
        .map(|host| host.name)
        .unwrap_or_else(|| "the machine running it".into())
}

/// The relay declaring a run dead. The agent cannot report this itself, so the
/// relay says what happened where the run was talking, and the task it was
/// working on reaches somebody who can act on it.
pub(crate) async fn fail_run(state: &Shared, run: &Run, why: &str) -> Result<()> {
    let mut run = run.clone();
    if run.status.is_terminal() {
        return Ok(());
    }
    run.status = RunStatus::Failed;
    run.headline = "Interrupted".into();
    run.error = Some(why.to_string());
    run.ended_at = Some(now_ms());
    state.store.update_run(&run)?;
    state.store.revoke_run_tokens(&run.id).ok();
    append_run_event(state, &run.id, RunEventKind::Error, why.to_string(), None)?;
    if let Err(err) = cancel_questions_for_run(state, &run.id).await {
        tracing::warn!(?err, run = %run.id, "could not cancel the questions of a dead run");
    }
    state.emit(Event::RunUpdated { run: run.clone() });
    state.set_presence(&run.agent_id, Presence::Online).await;

    // Said before `finish_run`, which closes the run's half-written reply and
    // forgets where it was talking.
    let members = state.store.members().unwrap_or_default();
    let body = format!(
        "{} stopped working here: {why}.",
        agent_label(&members, &run.agent_id)
    );
    if let Ok(system_id) = system_member_id(state) {
        if let Err(err) = post_message(
            state,
            &run.channel_id,
            &system_id,
            SendMessage {
                body,
                ..Default::default()
            },
            PostOptions {
                trigger_agents: false,
                run_id: Some(run.id.clone()),
            },
        )
        .await
        {
            tracing::warn!(?err, run = %run.id, "could not report a dead run in its channel");
        }
    }

    finish_run(state, &run).await
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
            file_name: attachment.file_name.clone(),
            url: state.grant_file(&attachment),
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
        prompt.push_str(
            "Leave work in Review when it needs approval. Once the agreed outcome is achieved and no human action remains, mark the task Done.\n",
        );
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

        let peers = task_peers(state, &task.id, &run.id)?;
        if !peers.is_empty() {
            out.push_str("Working on this task right now, in the same worktree:\n");
            for peer in &peers {
                out.push_str(&peer_line(&members, peer));
            }
            out.push_str(&format!("{SHARED_WORKTREE_ETIQUETTE}\n\n"));
        }
    }

    let messages = match &run.trigger {
        RunTrigger::Mention { message_id }
        | RunTrigger::Reply { message_id }
        | RunTrigger::DirectMessage { message_id }
        | RunTrigger::Ambient { message_id } => match state.store.message(message_id)? {
            Some(message) => conversation_messages(&state.store, &message, CONTEXT_MESSAGES)?,
            None => state
                .store
                .recent_messages(&run.channel_id, CONTEXT_MESSAGES)?,
        },
        _ => state
            .store
            .recent_messages(&run.channel_id, CONTEXT_MESSAGES)?,
    };
    if !messages.is_empty() {
        out.push_str("Recent messages (oldest first):\n");
        for message in messages {
            if message.body.trim().is_empty() {
                continue;
            }
            let author = display_name_of(&members, &message.author_id);
            let body: String = message.body.chars().take(2000).collect();
            let replying_to = message
                .reply_to_id
                .as_deref()
                .and_then(|id| state.store.message(id).ok().flatten())
                .map(|source| {
                    format!(
                        " (replying to {})",
                        display_name_of(&members, &source.author_id)
                    )
                })
                .unwrap_or_default();
            out.push_str(&format!("- {author}{replying_to}: {body}\n"));
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

fn run_belongs_to_host(state: &Shared, run_id: &str, host_id: &str) -> Result<bool> {
    Ok(state
        .store
        .run(run_id)?
        .is_some_and(|run| run.host_id.as_deref() == Some(host_id)))
}

async fn handle_host_message_inner(state: &Shared, host_id: &str, msg: HostToRelay) -> Result<()> {
    match msg {
        HostToRelay::Register { .. } | HostToRelay::Pong { .. } => {
            state.store.touch_host(host_id).ok();
        }

        HostToRelay::Heartbeat { runs, .. } => {
            state.store.touch_host(host_id).ok();
            // What the machine says it is running is the truth about what is
            // still alive on it; anything else there died with its process.
            if let Some(alive) = runs {
                end_runs_the_host_lost(state, host_id, &alive).await;
            }
        }

        HostToRelay::RunAccepted { run_id, cwd } => {
            if let Some(mut run) = state.store.run(&run_id)? {
                if run.host_id.as_deref() != Some(host_id) || run.status.is_terminal() {
                    return Ok(());
                }
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
        } => {
            if run_belongs_to_host(state, &run_id, host_id)? {
                append_run_event(state, &run_id, kind, text, data)?;
            }
        }

        HostToRelay::RunControlStatus {
            run_id,
            control_id,
            state: control_state,
        } => {
            if !run_belongs_to_host(state, &run_id, host_id)? {
                return Ok(());
            }
            match control_state {
                RunControlState::Started => {
                    if let Some(destination) =
                        state.control_destinations.write().await.remove(&control_id)
                    {
                        state
                            .run_destinations
                            .write()
                            .await
                            .insert(run_id.clone(), destination);
                    }
                }
                RunControlState::Rejected => {
                    state.control_destinations.write().await.remove(&control_id);
                }
                RunControlState::Queued => {}
            }
            let label = match control_state {
                RunControlState::Queued => "Steering queued",
                RunControlState::Started => "Steering delivered",
                RunControlState::Rejected => "Steering rejected: the ACP run is no longer active",
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
            if run.host_id.as_deref() != Some(host_id) {
                return Ok(());
            }
            // The first terminal state wins. A late host cannot revive a run
            // that was cancelled while it was disconnected.
            if run.status.is_terminal() {
                return Ok(());
            }
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
            }
            // Persist terminal status before settling questions so a concurrent
            // `patchwork ask` cannot recreate waiting work in between.
            state.store.update_run(&run)?;
            if status.is_terminal() {
                if let Err(err) = cancel_questions_for_run(state, &run_id).await {
                    tracing::warn!(?err, run = %run_id, "could not cancel run questions");
                }
            }
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

        HostToRelay::RunConfiguration {
            run_id,
            provider,
            model,
            thinking,
        } => {
            let Some(mut run) = state.store.run(&run_id)? else {
                return Ok(());
            };
            if run.host_id.as_deref() != Some(host_id) || run.status.is_terminal() {
                return Ok(());
            }
            run.provider = provider;
            run.model = model;
            run.thinking = thinking;
            state.store.update_run(&run)?;
            state.emit(Event::RunUpdated { run });
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
            stream_message(state, host_id, &run_id, &body).await?;
        }

        HostToRelay::RunMessage { run_id, kind, body } => {
            let Some(run) = state.store.run(&run_id)? else {
                return Ok(());
            };
            if run.host_id.as_deref() != Some(host_id) || run.status.is_terminal() {
                return Ok(());
            }
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

            let destination = reply_destination(state, &run).await;
            post_message(
                state,
                &run.channel_id,
                &run.agent_id,
                SendMessage {
                    body,
                    kind: Some(kind),
                    parent_id: destination.parent_id,
                    reply_to_id: destination.reply_to_id,
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
            if run.host_id.as_deref() != Some(host_id) || run.status.is_terminal() {
                return Ok(());
            }
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
            url: _,
            error,
        } => {
            let Some(mut preview) = state.store.preview(&preview_id)? else {
                return Ok(());
            };
            if preview.host_id != host_id {
                return Ok(());
            }
            preview.status = status;
            // Every host is reached through the workspace relay. Desktops stay
            // outbound-only and no longer create machine-local previews.
            preview.url = format!("{}/preview/{}/", state.public_url, preview.id);
            preview.local_only = false;
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
        HostToRelay::SystemSkillUpdated {
            request_id,
            path,
            skills,
            error,
        } => {
            let pending = match state.system_skill_waiters.write().await.remove(&request_id) {
                Some(waiter) if waiter.host_id != host_id => {
                    state
                        .system_skill_waiters
                        .write()
                        .await
                        .insert(request_id, waiter);
                    return Ok(());
                }
                pending => pending,
            };

            let result = if let Some(error) = error {
                Err(error)
            } else if let Some(skill) = skills.iter().find(|skill| skill.path == path).cloned() {
                if let Some(mut host) = state.store.host(host_id)? {
                    host.capabilities.system_skills = skills;
                    state.store.upsert_host(&host)?;
                    host.online = true;
                    state.emit(Event::HostUpdated { host });
                }
                Ok(skill)
            } else {
                Err("the updated skill was no longer detected".into())
            };
            if let Some(waiter) = pending {
                let _ = waiter.reply.send(result);
            }
        }
        HostToRelay::PreviewResponse {
            request_id,
            status,
            headers,
            body,
            error,
        } => {
            if let Some(waiter) = state.preview_waiters.write().await.remove(&request_id) {
                let _ = waiter.send(crate::state::PreviewReply {
                    status,
                    headers,
                    body,
                    error,
                });
            }
        }
        HostToRelay::PreviewSocketReady { socket_id, error } => {
            if let Some(socket) = state.preview_sockets.read().await.get(&socket_id) {
                let _ = socket.send(crate::state::PreviewSocketEvent::Ready(error));
            }
        }
        HostToRelay::PreviewSocketData {
            socket_id,
            data,
            binary,
        } => {
            if let Some(socket) = state.preview_sockets.read().await.get(&socket_id) {
                let _ = socket.send(crate::state::PreviewSocketEvent::Data { data, binary });
            }
        }
        HostToRelay::PreviewSocketClose { socket_id } => {
            if let Some(socket) = state.preview_sockets.write().await.remove(&socket_id) {
                let _ = socket.send(crate::state::PreviewSocketEvent::Close);
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

/// The run that just ended plus everyone who was working on the task at the
/// same time. Evidence from any of them belongs to this stretch of work, and
/// which agent attached it is not the reviewer's problem.
fn concurrent_run_ids(state: &Shared, task: &Task, run: &Run) -> Vec<Id> {
    let started = run.started_at.unwrap_or(run.created_at);
    let mut ids = vec![run.id.clone()];
    ids.extend(
        state
            .store
            .task_runs(&task.id)
            .unwrap_or_default()
            .into_iter()
            .filter(|other| other.id != run.id && other.ended_at.unwrap_or_else(now_ms) >= started)
            .map(|other| other.id),
    );
    ids
}

/// Whose artifacts count as this task's current evidence: the caller's own run
/// and everyone working alongside it right now.
pub(crate) fn evidence_run_ids(
    state: &Shared,
    task: &Task,
    run_id: Option<&str>,
) -> Result<Vec<Id>> {
    let mut ids: Vec<Id> = run_id.into_iter().map(str::to_string).collect();
    for peer in state.store.active_task_runs(&task.id)? {
        if !ids.contains(&peer.id) {
            ids.push(peer.id);
        }
    }
    Ok(ids)
}

pub(crate) fn has_review_evidence(
    state: &Shared,
    task: &Task,
    run_ids: &[Id],
    pending_pr_url: Option<&str>,
) -> Result<bool> {
    let produced_by = |id: Option<&str>| id.is_some_and(|id| run_ids.iter().any(|run| run == id));
    let artifact = pending_pr_url.is_some_and(|url| !url.is_empty())
        || task.pr_url.as_deref().is_some_and(|url| !url.is_empty())
        || state
            .store
            .task_attachments(&task.id)?
            .iter()
            .any(|attachment| produced_by(attachment.run_id.as_deref()))
        || state.store.task_previews(&task.id)?.iter().any(|preview| {
            produced_by(preview.run_id.as_deref()) && preview.status == PreviewStatus::Live
        });
    if artifact {
        return Ok(true);
    }

    // A recommendation or answer is itself the thing a person reviews. The
    // immutable original request tells us that this is an inquiry even when
    // the agent later distils the task title/outcome into its conclusion.
    if run_ids.is_empty() || !task_expects_written_answer(state, task)? {
        return Ok(false);
    }
    for run_id in run_ids {
        let answered = state.store.run_events(run_id, 0)?.iter().any(|event| {
            event.kind == RunEventKind::Message
                && event.data.is_none()
                && !event.text.trim().is_empty()
        });
        if answered {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(crate) fn task_expects_written_answer(state: &Shared, task: &Task) -> Result<bool> {
    let original = task
        .source_message_id
        .as_deref()
        .map(|id| state.store.message(id))
        .transpose()?
        .flatten();
    Ok(asks_for_written_answer(
        original
            .as_ref()
            .map(|message| message.body.as_str())
            .unwrap_or(task.outcome.as_str()),
    ))
}

fn asks_for_written_answer(request: &str) -> bool {
    // Only classify the opening line. Implementation requests often contain a
    // later checklist item phrased as a question, but their expected result is
    // still a changed product rather than a written answer.
    let opening = request
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or_default()
        .trim();
    if opening.contains('?') {
        return true;
    }

    let normalized = opening
        .trim_start_matches(|character: char| !character.is_alphanumeric())
        .to_lowercase();
    let first = normalized.split_whitespace().next().unwrap_or_default();
    matches!(
        first,
        "who"
            | "what"
            | "when"
            | "where"
            | "why"
            | "how"
            | "which"
            | "can"
            | "could"
            | "should"
            | "would"
            | "is"
            | "are"
            | "do"
            | "does"
            | "did"
            | "will"
            | "has"
            | "have"
    ) || [
        "decide whether",
        "find out whether",
        "help me decide",
        "i am unsure",
        "i'm unsure",
        "i am not sure",
        "i'm not sure",
        "recommend whether",
        "tell me whether",
        "unsure whether",
    ]
    .iter()
    .any(|prefix| normalized.starts_with(prefix))
}

/// A finished run updates the board and the Inbox so nothing silently stalls.
pub(crate) async fn finish_run(state: &Shared, run: &Run) -> Result<()> {
    // A run that died mid-sentence leaves its half-written reply in place —
    // that is the honest record — but nothing may rewrite it after this.
    finish_streamed_reply(state, &run.id).await?;
    state.run_destinations.write().await.remove(&run.id);

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
    let Some(task) = state.store.task(task_id)? else {
        return Ok(());
    };

    // Several agents can be working here at once. Whoever is left keeps the
    // task running, and only the last one out decides what it became.
    let peers = task_peers(state, task_id, &run.id)?;
    if !peers.is_empty() {
        let members = state.store.members()?;
        let outcome = match run.status {
            RunStatus::Succeeded => "finished",
            RunStatus::Failed => "stopped with an error",
            _ => "stopped",
        };
        let headline = run.headline.trim();
        let headline = if headline.is_empty() {
            String::new()
        } else {
            format!(": {headline}")
        };
        tell_task_peers(
            state,
            task_id,
            &run.id,
            format!(
                "{} {outcome} on {}{headline}. You are still working here; \
the task stays yours until you stop. Reply only if this changes your work.",
                agent_label(&members, &run.agent_id),
                task.key,
            ),
        )
        .await;
    }

    match state.store.hand_off_finished_task_run(task_id, &run.id)? {
        TaskRunHandoff::Peer(task) => {
            state.emit(Event::TaskUpdated { task });
            return Ok(());
        }
        TaskRunHandoff::Moved => return Ok(()),
        TaskRunHandoff::Last => {}
    }

    // The last agent out reports for the whole group, and a failure inside it
    // is not erased by whoever happened to finish afterwards.
    let group = concurrent_run_ids(state, &task, run);
    let outcome = if state
        .store
        .task_runs(task_id)?
        .iter()
        .any(|other| other.status == RunStatus::Failed && group.contains(&other.id))
    {
        RunStatus::Failed
    } else {
        run.status
    };

    // A person may move the task while this run is settling. Re-read and use
    // the existing optimistic task write so an old snapshot cannot undo them.
    for _ in 0..8 {
        let Some(mut task) = state.store.task(task_id)? else {
            return Ok(());
        };
        if task.current_run_id.as_deref() != Some(run.id.as_str()) {
            return Ok(());
        }
        let expected_updated_at = task.updated_at;
        let mut notification = None;
        task.current_run_id = None;

        if let Some(continuation) = &task.active_continuation {
            task.status = match continuation.status {
                ContinuationStatus::Waiting | ContinuationStatus::Ready => TaskStatus::Running,
                ContinuationStatus::ActionRequired | ContinuationStatus::Failed => {
                    TaskStatus::Blocked
                }
            };
        } else {
            match outcome {
                RunStatus::Succeeded => {
                    if task.status == TaskStatus::Running {
                        if has_review_evidence(state, &task, &group, None)? {
                            task.status = TaskStatus::Review;
                            notification = Some((
                                InboxKind::ReviewReady,
                                format!("{} is ready for review", task.key),
                            ));
                        } else {
                            task.status = TaskStatus::Planned;
                        }
                    }
                }
                RunStatus::Failed => {
                    if task.status == TaskStatus::Running {
                        task.status = TaskStatus::Blocked;
                        notification =
                            Some((InboxKind::TaskBlocked, format!("{} is blocked", task.key)));
                    }
                }
                RunStatus::Cancelled => {
                    if task.status == TaskStatus::Running {
                        task.status = TaskStatus::Planned;
                    }
                }
                _ => {}
            }
        }

        if task.status != TaskStatus::Review {
            task.review_action = None;
        }
        if !state
            .store
            .update_task_if_unchanged(&task, expected_updated_at, false)?
        {
            continue;
        }
        if let Some((kind, title)) = notification {
            notify_task(state, &task, kind, title)?;
        }
        let task = state.store.task(task_id)?.unwrap_or(task);
        state.emit(Event::TaskUpdated { task });
        return Ok(());
    }
    bail!("task kept changing while its run was finishing")
}

pub fn notify_task(state: &Shared, task: &Task, kind: InboxKind, title: String) -> Result<()> {
    for member_id in task_recipients(state, task)? {
        let item = InboxItem {
            id: new_id(),
            member_id: member_id.clone(),
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

/// Who hears about a task. Agents own tasks and create them for each other, so
/// an Inbox item addressed only to them would reach nobody at all: fall back to
/// the people who run the workspace, and then to everybody in it.
fn task_recipients(state: &Shared, task: &Task) -> Result<Vec<Id>> {
    let members = state.store.members()?;
    let system = system_member_id(state)?;
    let people: Vec<&Member> = members
        .iter()
        .filter(|member| member.kind == MemberKind::Human && member.id != system)
        .collect();

    let mut targets: Vec<Id> = [task.owner_id.clone(), Some(task.created_by.clone())]
        .into_iter()
        .flatten()
        .filter(|id| people.iter().any(|member| &member.id == id))
        .collect();
    targets.dedup();
    if !targets.is_empty() {
        return Ok(targets);
    }

    let admins: Vec<Id> = people
        .iter()
        .filter(|member| member.is_admin)
        .map(|member| member.id.clone())
        .collect();
    Ok(if admins.is_empty() {
        people.iter().map(|member| member.id.clone()).collect()
    } else {
        admins
    })
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

/// First line of the expected result, trimmed to something a board row can show.
pub(crate) fn title_from(outcome: &str) -> String {
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

const RECENT_TASK_WINDOW_MS: Millis = 14 * 24 * 60 * 60 * 1_000;

fn task_words(text: &str) -> BTreeSet<String> {
    const NOISE: &[&str] = &[
        "add",
        "after",
        "alert",
        "and",
        "are",
        "before",
        "create",
        "created",
        "duplicate",
        "ensure",
        "failed",
        "failing",
        "failure",
        "fix",
        "fixed",
        "follow",
        "following",
        "for",
        "from",
        "had",
        "has",
        "have",
        "implement",
        "incident",
        "into",
        "issue",
        "make",
        "new",
        "not",
        "problem",
        "production",
        "report",
        "reported",
        "restore",
        "safe",
        "should",
        "spike",
        "task",
        "that",
        "the",
        "their",
        "this",
        "update",
        "use",
        "used",
        "using",
        "was",
        "were",
        "what",
        "when",
        "where",
        "which",
        "will",
        "with",
        "work",
        "would",
        "your",
    ];

    text.split(|c: char| !c.is_alphanumeric())
        .filter_map(|word| {
            let mut word = word.to_lowercase();
            if NOISE.contains(&word.as_str()) {
                return None;
            }
            if word.len() > 5 && word.ends_with("ing") {
                word.truncate(word.len() - 3);
            } else if word.len() > 4 && word.ends_with("ed") {
                word.truncate(word.len() - 2);
            } else if word.len() > 4 && word.ends_with("ies") {
                word.truncate(word.len() - 3);
                word.push('y');
            } else if word.len() > 4
                && ["sses", "xes", "zes", "ches", "shes"]
                    .iter()
                    .any(|suffix| word.ends_with(suffix))
            {
                word.truncate(word.len() - 2);
            } else if word.len() > 3 && word.ends_with('s') && !word.ends_with("ss") {
                word.pop();
            }
            (word.len() >= 3 && !NOISE.contains(&word.as_str())).then_some(word)
        })
        .collect()
}

fn task_similarity(left: &str, right: &str) -> f32 {
    let left = task_words(left);
    let right = task_words(right);
    if left.len() < 3 || right.len() < 3 {
        return 0.0;
    }
    let shared: Vec<&String> = left.intersection(&right).collect();
    if shared.len() < 2 {
        return 0.0;
    }
    let overlap = shared.len() as f32 / left.len().min(right.len()) as f32;
    let union = left.union(&right).count();
    let jaccard = shared.len() as f32 / union as f32;
    let stable_identifier = shared
        .iter()
        .any(|word| word.len() >= 7 || word.chars().any(|c| c.is_ascii_digit()));
    0.6 * overlap + 0.4 * jaccard + if stable_identifier { 0.1 } else { 0.0 }
}

/// Best open or recently completed task whose wording looks related. This is
/// only a warning signal: callers can confirm that distinct work should exist.
pub(crate) fn similar_task(
    state: &Shared,
    title: &str,
    outcome: &str,
    project_id: Option<&str>,
) -> Result<Option<Task>> {
    let title = if title.trim().is_empty() {
        title_from(outcome)
    } else {
        title.trim().to_string()
    };
    let incoming = format!("{title} {outcome}");
    let recent_after = now_ms() - RECENT_TASK_WINDOW_MS;
    Ok(state
        .store
        .tasks()?
        .into_iter()
        .filter(|task| !task.status.is_terminal() || task.updated_at >= recent_after)
        .filter(|task| {
            project_id
                .map(|project| task.project_id.as_deref() == Some(project))
                .unwrap_or(true)
        })
        .filter_map(|task| {
            let score = task_similarity(&title, &task.title).max(task_similarity(
                &incoming,
                &format!("{} {}", task.title, task.outcome),
            ));
            (score >= 0.42).then_some((task, score))
        })
        .max_by(|(left_task, left), (right_task, right)| {
            left.total_cmp(right)
                .then_with(|| left_task.updated_at.cmp(&right_task.updated_at))
        })
        .map(|(task, _)| task))
}

pub struct TaskCreation {
    pub task: Task,
    pub created: bool,
}

fn should_start_task(start: bool, status: Option<TaskStatus>, owner_is_agent: bool) -> bool {
    start || (status.is_none() && owner_is_agent)
}

/// Boxed: creating a task can fire an automation that creates a task.
pub fn create_task<'a>(
    state: &'a Shared,
    creator_id: &'a str,
    input: patchwork_core::wire::CreateTask,
) -> futures::future::BoxFuture<'a, Result<Task>> {
    Box::pin(async move { Ok(create_task_inner(state, creator_id, input).await?.task) })
}

pub fn create_task_with_result<'a>(
    state: &'a Shared,
    creator_id: &'a str,
    input: patchwork_core::wire::CreateTask,
) -> futures::future::BoxFuture<'a, Result<TaskCreation>> {
    Box::pin(create_task_inner(state, creator_id, input))
}

async fn create_task_inner(
    state: &Shared,
    creator_id: &str,
    input: patchwork_core::wire::CreateTask,
) -> Result<TaskCreation> {
    // Asked twice, one task. An agent that reports the same blocker every two
    // hours should leave one thing on the board, not twelve.
    if let Some(once_key) = input.once_key.as_deref().filter(|k| !k.trim().is_empty()) {
        if let Some(existing) = state.store.task_by_once_key(once_key.trim())? {
            return Ok(TaskCreation {
                task: existing,
                created: false,
            });
        }
    }

    let owner_is_agent = match input.owner_id.as_deref() {
        Some(owner_id) => state
            .store
            .member(owner_id)?
            .is_some_and(|member| member.kind == MemberKind::Agent),
        None => false,
    };
    let start = should_start_task(input.start, input.status, owner_is_agent);

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
        active_continuation: None,
        pr_url: None,
        pr_state: None,
        review_action: None,
        created_by: creator_id.to_string(),
        due_at: input.due_at.filter(|at| *at > 0),
        once_key: input
            .once_key
            .as_deref()
            .map(str::trim)
            .filter(|k| !k.is_empty())
            .map(str::to_lowercase),
        created_at: now,
        updated_at: now,
        position: now as f64,
    };
    match state.store.insert_task_with_channel(&task, &discussion)? {
        InsertTaskResult::Existing(existing) => {
            return Ok(TaskCreation {
                task: existing,
                created: false,
            })
        }
        InsertTaskResult::Inserted => {}
    }

    let mut discussion = discussion;
    discussion.task_id = Some(task.id.clone());

    state.emit(Event::ChannelCreated {
        channel: discussion.clone(),
    });
    state.emit(Event::TaskCreated { task: task.clone() });

    // Source material belongs in the discussion, separate from the stable
    // result that defines the task as done.
    if task.source_message_id.is_none() {
        let original_request = input.initial_message.clone().unwrap_or_else(|| {
            if task.outcome.trim().is_empty() {
                task.title.clone()
            } else {
                task.outcome.clone()
            }
        });
        let original = post_message(
            state,
            &task.discussion_channel_id,
            creator_id,
            SendMessage {
                body: original_request,
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

    if start {
        if let Some(owner) = task.owner_id.clone() {
            if state.store.member(&owner)?.map(|m| m.kind) == Some(MemberKind::Agent) {
                let params = StartRunParams {
                    agent_id: owner,
                    channel_id: task.discussion_channel_id.clone(),
                    task_id: Some(task.id.clone()),
                    prompt: format!("Work on this task.\n\n{}", task.outcome.trim()),
                    trigger: RunTrigger::TaskAssignment {
                        task_id: task.id.clone(),
                    },
                    automation_id: None,
                    depth: 0,
                    host_id: task.host_id.clone(),
                    project_id: task.project_id.clone(),
                    required_task_status: Some(TaskStatus::Planned),
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

    Ok(TaskCreation {
        task,
        created: true,
    })
}

pub async fn update_task(
    state: &Shared,
    actor_id: &str,
    actor_is_agent: bool,
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
    let has_explicit_status = input.status.is_some();
    if let Some(status) = input.status {
        task.status = status;
    }
    if let Some(review_action) = input.review_action {
        task.review_action = match review_action.trim() {
            "" => None,
            action => Some(action.to_string()),
        };
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
        let pr_url = (!pr_url.is_empty()).then_some(pr_url);
        if task.pr_url != pr_url {
            task.pr_url = pr_url;
            task.pr_state = None;
        }
    }
    // 0 is how a client says "no date": there is no such instant in practice,
    // and `null` cannot be told apart from "not mentioned" in a patch.
    if let Some(due_at) = input.due_at {
        task.due_at = (due_at > 0).then_some(due_at);
    }
    if let Some(position) = input.position {
        task.position = position;
    }
    if task.status != TaskStatus::Review {
        task.review_action = None;
    }

    if actor_is_agent && previous.status.is_terminal() && !task.status.is_terminal() {
        bail!("only a person can reopen a completed or canceled task");
    }
    if actor_is_agent {
        if !state
            .store
            .update_task_if_unchanged(&task, previous.updated_at, has_explicit_status)?
        {
            bail!("the task changed while the agent was updating it; reload it and try again");
        }
    } else if has_explicit_status {
        state.store.update_task_with_explicit_status(&task)?;
    } else {
        state.store.update_task(&task)?;
    }
    task = state
        .store
        .task(task_id)?
        .ok_or_else(|| anyhow!("task was deleted while it was being updated"))?;
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
        if task.status.is_terminal() {
            resolve_inbox(state, Some(&task.id), None, None)?;
        } else if task.status == TaskStatus::Review {
            notify_task(
                state,
                &task,
                InboxKind::ReviewReady,
                format!("{} is ready for review", task.key),
            )?;
        } else if previous.status == TaskStatus::Review {
            resolve_inbox(state, Some(&task.id), None, None)?;
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
            required_task_status: None,
        },
    )
    .await
    .context("could not start the run")
}

/// Execute the action an agent put behind the review gate. Claiming the task
/// before dispatch makes the approval single-use; a failed dispatch restores
/// the exact gate so the person can try again after the host recovers.
pub async fn approve_task(state: &Shared, actor_id: &str, task_id: &str) -> Result<Option<Run>> {
    let task = state
        .store
        .task(task_id)?
        .ok_or_else(|| anyhow!("task not found"))?;
    let Some(action) = task.review_action.clone() else {
        return Ok(None);
    };
    if task.status != TaskStatus::Review || !state.store.claim_review_action(&task.id, &action)? {
        return Ok(None);
    }

    let actor = state
        .store
        .member(actor_id)?
        .map(|member| member.display_name)
        .unwrap_or_else(|| "A workspace member".into());
    let prompt = format!(
        "{actor} approved the requested review action:\n\n{action}\n\nCarry out the approved action now. Ask again only if its scope or risk has materially changed."
    );

    match run_task(state, actor_id, &task.id, None, Some(prompt)).await {
        Ok(run) => {
            resolve_inbox(state, Some(&task.id), None, None)?;
            let _ = post_system(
                state,
                &task.discussion_channel_id,
                &format!("{actor} approved: {action}"),
            )
            .await;
            Ok(Some(run))
        }
        Err(err) => {
            if state.store.restore_review_action(&task.id, &action)? {
                if let Some(task) = state.store.task(&task.id)? {
                    state.emit(Event::TaskUpdated { task });
                }
            }
            Err(err)
        }
    }
}

/// Answering a question un-blocks the run that asked it.
pub async fn answer_question(
    state: &Shared,
    question_id: &str,
    answers: Vec<QuestionAnswer>,
    by: &str,
) -> Result<Question> {
    let (question, resumed_task) = state.store.answer_question(question_id, &answers, by)?;
    state.emit(Event::QuestionUpdated {
        question: question.clone(),
    });
    if let Some(task) = resumed_task {
        state.emit(Event::TaskUpdated { task });
    }

    let run = state.store.run(&question.run_id)?;
    if let Some(run) = &run {
        if let Some(host_id) = &run.host_id {
            state
                .send_to_host(
                    host_id,
                    RelayToHost::AnswerQuestion {
                        run_id: run.id.clone(),
                        question_id: question.id.clone(),
                        answers: answers.clone(),
                    },
                )
                .await;
        }
    }
    // Reset the transcript boundary before the long-poll lets the CLI return.
    state.resolve_question(&question).await;
    resolve_inbox(state, None, None, question.message_id.as_deref())?;

    // The host send above yields, so cancellation may have won meanwhile.
    if let Some(mut run) = state.store.run(&question.run_id)? {
        let has_open = state
            .store
            .run_questions(&run.id)?
            .iter()
            .any(|question| question.status == QuestionStatus::Open);
        let mut changed = false;
        if has_open && !run.status.is_terminal() && run.status != RunStatus::Waiting {
            run.status = RunStatus::Waiting;
            run.headline = "Waiting for an answer".into();
            changed = true;
        } else if !has_open && run.status == RunStatus::Waiting {
            run.status = RunStatus::Running;
            run.headline = "Working".into();
            changed = true;
        }
        if changed {
            state.store.update_run(&run)?;
            state.emit(Event::RunUpdated { run: run.clone() });
        }
        state
            .set_presence(
                &run.agent_id,
                if run.status.is_terminal() {
                    Presence::Online
                } else if has_open {
                    Presence::Waiting
                } else {
                    Presence::Working
                },
            )
            .await;
    }

    Ok(question)
}

fn resolve_inbox(
    state: &Shared,
    task_id: Option<&str>,
    question_run_id: Option<&str>,
    question_message_id: Option<&str>,
) -> Result<()> {
    for item in state
        .store
        .resolve_inbox_for(task_id, question_run_id, question_message_id)?
    {
        state.emit(Event::InboxItemUpdated { item });
    }
    Ok(())
}

/// Retire the questions a re-asking run left open: the card stops inviting an
/// answer nobody is waiting for, the Inbox badge clears, and a `patchwork ask`
/// still long-polling learns it lost the floor instead of hanging.
pub async fn settle_superseded_questions(state: &Shared, questions: Vec<Question>) -> Result<()> {
    for question in questions {
        state.emit(Event::QuestionUpdated {
            question: question.clone(),
        });
        state.resolve_question(&question).await;
        resolve_inbox(state, None, None, question.message_id.as_deref())?;
    }
    Ok(())
}

/// Settle every outstanding question when its run ends, including the card,
/// Inbox badge and any long-polling `patchwork ask` process.
pub async fn cancel_questions_for_run(state: &Shared, run_id: &str) -> Result<()> {
    for question in state.store.cancel_questions_for_run(run_id)? {
        state.emit(Event::QuestionUpdated {
            question: question.clone(),
        });
        state.resolve_question(&question).await;
    }
    resolve_inbox(state, None, Some(run_id), None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn interrupted_relay_run_is_redispatched_with_its_session_and_identity() {
        let path = std::env::temp_dir().join(format!("patchwork-resume-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        store.create_workspace("ws", "Test").unwrap();
        store
            .update_workspace(None, None, None, None, Some("Merge after checks pass."))
            .unwrap();
        let mut agent = member("agent", "developer", MemberKind::Agent);
        let current_profile = agent.agent.as_mut().unwrap();
        current_profile.runtime = "claude".into();
        current_profile.provider = Some("wrong-provider".into());
        current_profile.model = Some("wrong/model".into());
        current_profile.thinking = Some("low".into());
        store.insert_member(&agent).unwrap();
        store
            .save_workspace_skill(
                WorkspaceSkill {
                    id: "skill".into(),
                    name: "Release checks".into(),
                    description: String::new(),
                    instructions: "Run the release smoke test.".into(),
                    created_at: 1,
                    updated_at: 1,
                },
                false,
                usize::MAX,
            )
            .unwrap();
        let run = Run {
            id: "run".into(),
            agent_id: agent.id.clone(),
            status: RunStatus::Running,
            trigger: RunTrigger::Manual { by: "human".into() },
            channel_id: "channel".into(),
            task_id: None,
            host_id: Some("relay".into()),
            project_id: None,
            worktree_id: None,
            cwd: Some("/tmp/existing-worktree".into()),
            automation_id: None,
            session_id: Some("session".into()),
            runtime: "pi".into(),
            provider: Some("openai".into()),
            model: Some("openai/gpt-5.5".into()),
            thinking: Some("high".into()),
            prompt: "Finish the interrupted work".into(),
            headline: "Working".into(),
            error: None,
            token_usage: None,
            created_at: 1,
            started_at: Some(1),
            ended_at: None,
        };
        store.insert_run(&run, 0).unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "relay".into(),
        ));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        state
            .hosts
            .write()
            .await
            .insert("relay".into(), crate::state::HostConn { tx });
        handle_host_message(
            &state,
            "relay",
            HostToRelay::RunConfiguration {
                run_id: run.id.clone(),
                provider: Some("openai-codex".into()),
                model: Some("openai-codex/gpt-5.6-sol".into()),
                thinking: Some("xhigh".into()),
            },
        )
        .await;
        let configured = store.run(&run.id).unwrap().unwrap();

        resume_interrupted_run(&state, &configured).await.unwrap();

        let RelayToHost::StartRun { spec } = rx.recv().await.unwrap() else {
            panic!("expected the interrupted run to be dispatched");
        };
        assert_eq!(spec.run_id, "run");
        assert_eq!(spec.resume_session_id.as_deref(), Some("session"));
        assert_eq!(spec.runtime, "pi");
        assert_eq!(spec.provider.as_deref(), Some("openai-codex"));
        assert_eq!(spec.model.as_deref(), Some("openai-codex/gpt-5.6-sol"));
        assert_eq!(spec.thinking.as_deref(), Some("xhigh"));
        assert_eq!(spec.prompt, "Finish the interrupted work");
        assert_eq!(spec.autonomy, "Merge after checks pass.");
        assert_eq!(spec.skills, store.workspace_skills().unwrap());
        assert!(matches!(
            spec.worktree,
            WorktreeSpec::Existing { ref path } if path == "/tmp/existing-worktree"
        ));
        let stored = store.run("run").unwrap().unwrap();
        assert_eq!(stored.status, RunStatus::Dispatched);
        assert_eq!(stored.headline, "Restarting");

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_machine_is_only_gone_after_its_silence_outlasts_the_relays_own_start() {
        let now = 10_000_000;
        assert!(host_is_gone(now, now - HOST_SILENCE_LIMIT_MS, 0));
        assert!(!host_is_gone(now, now - 1_000, 0));
        // Restarted a moment ago: nobody has had a chance to reconnect yet.
        assert!(!host_is_gone(now, now - 10 * HOST_SILENCE_LIMIT_MS, now));
        assert!(host_is_gone(now, 0, now - HOST_SILENCE_LIMIT_MS - 1));
    }

    /// A desktop that stops running a run without saying so: the relay hears
    /// it in the heartbeat, ends the run, says why where the run was talking,
    /// and reaches a person even though no human is anywhere near the task.
    #[tokio::test]
    async fn a_run_the_machine_no_longer_has_is_ended_reported_and_escalated() {
        let path = std::env::temp_dir().join(format!("patchwork-dead-{}.sqlite", new_id()));
        let store = Store::open(&path).unwrap();
        store.create_workspace("workspace", "Test").unwrap();
        for member in [
            member("system", "patchwork", MemberKind::Human),
            member("agent", "developer", MemberKind::Agent),
            member("manager", "manager", MemberKind::Agent),
            {
                let mut human = member("human", "vince", MemberKind::Human);
                human.is_admin = true;
                human
            },
        ] {
            store.insert_member(&member).unwrap();
        }
        let channel = Channel {
            id: "channel".into(),
            kind: ChannelKind::Channel,
            section_id: None,
            slug: "dev".into(),
            name: "dev".into(),
            topic: String::new(),
            position: 0.0,
            created_at: 1,
            member_ids: Vec::new(),
            task_id: None,
            last_message_at: 0,
        };
        store.insert_channel(&channel).unwrap();
        let host = Host {
            id: "desktop".into(),
            name: "Vince's MacBook".into(),
            kind: HostKind::Desktop,
            platform: "macos".into(),
            owner_id: None,
            online: true,
            last_seen: now_ms(),
            capabilities: HostCapabilities::default(),
            created_at: 1,
        };
        store.upsert_host(&host).unwrap();
        let task = Task {
            id: "task".into(),
            key: "PW-1".into(),
            title: "Ship it".into(),
            outcome: "Shipped".into(),
            status: TaskStatus::Running,
            owner_id: Some("agent".into()),
            source_channel_id: None,
            source_message_id: None,
            discussion_channel_id: channel.id.clone(),
            project_id: None,
            host_id: None,
            worktree_id: None,
            current_run_id: Some("run".into()),
            active_continuation: None,
            pr_url: None,
            pr_state: None,
            review_action: None,
            created_by: "manager".into(),
            due_at: None,
            once_key: None,
            created_at: 1,
            updated_at: 1,
            position: 0.0,
        };
        store.insert_task(&task).unwrap();
        let run = Run {
            id: "run".into(),
            agent_id: "agent".into(),
            status: RunStatus::Running,
            trigger: RunTrigger::Manual {
                by: "manager".into(),
            },
            channel_id: channel.id.clone(),
            task_id: Some(task.id.clone()),
            host_id: Some("desktop".into()),
            project_id: None,
            worktree_id: None,
            cwd: None,
            automation_id: None,
            session_id: None,
            runtime: "codex".into(),
            provider: None,
            model: None,
            thinking: None,
            prompt: "Ship it".into(),
            headline: "Working".into(),
            error: None,
            token_usage: None,
            created_at: 1,
            started_at: Some(1),
            ended_at: None,
        };
        store.insert_run(&run, 0).unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "relay".into(),
        ));

        handle_host_message(
            &state,
            "desktop",
            HostToRelay::Heartbeat {
                capabilities: None,
                runs: Some(Vec::new()),
            },
        )
        .await;

        let ended = store.run("run").unwrap().unwrap();
        assert_eq!(ended.status, RunStatus::Failed);
        assert!(
            ended.error.as_deref().unwrap().contains("Vince's MacBook"),
            "{:?}",
            ended.error
        );
        let said = store
            .messages(&channel.id, None, 10)
            .unwrap()
            .0
            .into_iter()
            .any(|message| message.body.contains("stopped working here"));
        assert!(said, "the channel it was talking in must be told why");
        assert_eq!(
            store.task("task").unwrap().unwrap().status,
            TaskStatus::Blocked
        );
        assert_eq!(
            store.inbox("human", true).unwrap().len(),
            1,
            "a task owned and created by agents must still reach a person"
        );

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

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

    #[test]
    fn written_answer_requests_are_distinct_from_implementation_questions() {
        assert!(asks_for_written_answer(
            "Should we add QMD for CLI search? or not"
        ));
        assert!(asks_for_written_answer(
            "Decide whether relay search needs semantic retrieval"
        ));
        assert!(asks_for_written_answer(
            "I'm unsure whether this belongs in the relay"
        ));
        assert!(!asks_for_written_answer(
            "Fix the Expo app\n- should the sheet use a native modal?"
        ));
        assert!(!asks_for_written_answer(
            "Ensure every task view renders its pull request"
        ));
    }

    #[test]
    fn differently_worded_incidents_trigger_a_similarity_warning() {
        assert!(
            task_similarity(
                "PostHog image proxy invalid-content spike",
                "PostHog: headless images fetch 403 spike",
            ) >= 0.42
        );
        assert!(
            task_similarity(
                "Fund production-safe Hyperbrowser fallback capacity",
                "Restore headless-image fallback capacity",
            ) >= 0.42
        );
    }

    #[test]
    fn unrelated_incidents_do_not_trigger_a_similarity_warning() {
        assert!(
            task_similarity(
                "PostHog image proxy invalid-content spike",
                "Throttle scheduled database maintenance IO",
            ) < 0.42
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

    #[tokio::test]
    async fn replies_and_mentions_only_invoke_the_target_agent() {
        let path = std::env::temp_dir().join(format!("patchwork-reply-{}.sqlite", new_id()));
        let store = Store::open(&path).unwrap();
        store.create_workspace("workspace", "Test").unwrap();
        let human = member("human", "vince", MemberKind::Human);
        let mut target = member("target", "target", MemberKind::Agent);
        target.agent.as_mut().unwrap().default_participation = Participation::Off;
        let mut ambient = member("ambient", "ambient", MemberKind::Agent);
        ambient.agent.as_mut().unwrap().default_participation = Participation::Ambient;
        for member in [&human, &target, &ambient] {
            store.insert_member(member).unwrap();
        }
        let mut members = [human, target, ambient];
        let channel = Channel {
            id: "channel".into(),
            kind: ChannelKind::Channel,
            section_id: None,
            slug: "general".into(),
            name: "General".into(),
            topic: String::new(),
            position: 0.0,
            created_at: 1,
            member_ids: Vec::new(),
            task_id: None,
            last_message_at: 0,
        };
        store.insert_channel(&channel).unwrap();
        let mut source = message_at("source", "target", 1, None);
        source.channel_id = channel.id.clone();
        source.body = "Original answer".into();
        let mut reply = message_at("reply", "human", 2, None);
        reply.channel_id = channel.id.clone();
        reply.reply_to_id = Some(source.id.clone());
        store.insert_message(&source).unwrap();
        store.insert_message(&reply).unwrap();

        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "relay".into(),
        ));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        state
            .hosts
            .write()
            .await
            .insert("relay".into(), crate::state::HostConn { tx });

        trigger_agents(&state, &reply, &channel, &members)
            .await
            .unwrap();

        let RelayToHost::StartRun { spec } = rx.recv().await.unwrap() else {
            panic!("expected a run to start");
        };
        assert_eq!(spec.agent_id, "target");
        let run = store.run(&spec.run_id).unwrap().unwrap();
        assert!(matches!(run.trigger, RunTrigger::Reply { .. }));
        assert!(
            rx.try_recv().is_err(),
            "ambient agents must not join a direct reply"
        );

        let mut followup = message_at("followup", "human", 3, None);
        followup.channel_id = channel.id.clone();
        followup.body = "That makes sense".into();
        followup.reply_to_id = Some(source.id.clone());
        store.insert_message(&followup).unwrap();
        trigger_agents(&state, &followup, &channel, &members)
            .await
            .unwrap();

        let RelayToHost::FollowUp {
            control_id, prompt, ..
        } = rx.recv().await.unwrap()
        else {
            panic!("expected a follow-up");
        };
        assert_eq!(
            prompt,
            "vince replied to target's message:\n\nOriginal answer\n\nReply:\n\nThat makes sense"
        );
        assert_eq!(
            reply_destination(&state, &run).await.reply_to_id.as_deref(),
            Some("reply"),
            "queued feedback must not move the answer still being written"
        );
        handle_host_message_inner(
            &state,
            "relay",
            HostToRelay::RunControlStatus {
                run_id: run.id.clone(),
                control_id,
                state: RunControlState::Started,
            },
        )
        .await
        .unwrap();
        assert_eq!(
            reply_destination(&state, &run).await.reply_to_id.as_deref(),
            Some("followup")
        );

        members[1].agent.as_mut().unwrap().default_participation = Participation::Mention;
        let mut mention = message_at("mention", "human", 4, None);
        mention.channel_id = channel.id.clone();
        mention.body = "@target can you check?".into();
        mention.mentions = vec!["target".into()];
        store.insert_message(&mention).unwrap();
        trigger_agents(&state, &mention, &channel, &members)
            .await
            .unwrap();

        let RelayToHost::FollowUp { prompt, .. } = rx.recv().await.unwrap() else {
            panic!("expected a follow-up for the mentioned agent");
        };
        assert_eq!(prompt, "vince just said:\n\n@target can you check?");
        assert!(
            rx.try_recv().is_err(),
            "unmentioned ambient agents must not join an explicit mention"
        );

        let mut answer = message_at("answer", "target", 5, Some(&run.id));
        answer.channel_id = channel.id.clone();
        answer.body = "Original answer".into();
        store.insert_message(&answer).unwrap();
        let mut plain_followup = message_at("plain-followup", "human", 6, None);
        plain_followup.channel_id = channel.id.clone();
        plain_followup.body = "One more thing".into();
        store.insert_message(&plain_followup).unwrap();
        trigger_agents(&state, &plain_followup, &channel, &members)
            .await
            .unwrap();

        let RelayToHost::StartRun { spec } = rx.recv().await.unwrap() else {
            panic!("expected the ambient agent to start");
        };
        assert_eq!(spec.agent_id, "ambient");
        assert!(
            rx.try_recv().is_err(),
            "a plain follow-up must not invoke an only-when-mentioned agent"
        );

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn agent_owned_tasks_start_unless_explicitly_planned() {
        assert!(should_start_task(false, None, true));
        assert!(should_start_task(true, Some(TaskStatus::Planned), true));
        assert!(!should_start_task(false, Some(TaskStatus::Planned), true));
        assert!(!should_start_task(false, None, false));
    }

    #[test]
    fn terminal_tasks_must_be_reopened_before_another_run() {
        let mut task = Task {
            id: "t".into(),
            key: "PW-1".into(),
            title: "Ship it".into(),
            outcome: "It is shipped".into(),
            status: TaskStatus::Done,
            owner_id: None,
            source_channel_id: None,
            source_message_id: None,
            discussion_channel_id: "c".into(),
            project_id: None,
            host_id: None,
            worktree_id: None,
            current_run_id: None,
            active_continuation: None,
            pr_url: None,
            pr_state: None,
            review_action: None,
            created_by: "human".into(),
            due_at: None,
            once_key: None,
            created_at: 0,
            updated_at: 0,
            position: 0.0,
        };
        assert!(ensure_task_accepts_run(Some(&task)).is_err());
        task.status = TaskStatus::Canceled;
        assert!(ensure_task_accepts_run(Some(&task)).is_err());
        task.status = TaskStatus::Planned;
        assert!(ensure_task_accepts_run(Some(&task)).is_ok());
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
            reply_to_id: None,
            reply_to: None,
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

    #[test]
    fn an_old_inline_reply_target_stays_in_agent_context() {
        let path =
            std::env::temp_dir().join(format!("patchwork-reply-context-{}.sqlite", new_id()));
        let store = Store::open(&path).unwrap();
        store
            .insert_channel(&Channel {
                id: "c".into(),
                kind: ChannelKind::Channel,
                section_id: None,
                slug: "general".into(),
                name: "General".into(),
                topic: String::new(),
                position: 0.0,
                created_at: 0,
                member_ids: Vec::new(),
                task_id: None,
                last_message_at: 0,
            })
            .unwrap();
        let source = message_at("m1", "agent", 1, Some("r1"));
        let middle = message_at("m2", "other", 2, None);
        let mut reply = message_at("m3", "vince", 3, None);
        reply.reply_to_id = Some(source.id.clone());
        for message in [&source, &middle, &reply] {
            store.insert_message(message).unwrap();
        }

        let messages = conversation_messages(&store, &reply, 2).unwrap();
        assert_eq!(
            messages
                .iter()
                .map(|message| message.id.as_str())
                .collect::<Vec<_>>(),
            ["m1", "m3"]
        );

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn thread_context_excludes_other_channel_messages() {
        let path = std::env::temp_dir().join(format!("patchwork-thread-{}.sqlite", new_id()));
        let store = Store::open(&path).unwrap();
        store
            .insert_channel(&Channel {
                id: "c".into(),
                kind: ChannelKind::Channel,
                section_id: None,
                slug: "general".into(),
                name: "General".into(),
                topic: String::new(),
                position: 0.0,
                created_at: 0,
                member_ids: Vec::new(),
                task_id: None,
                last_message_at: 0,
            })
            .unwrap();

        let root = message_at("m1", "agent", 1, Some("r1"));
        let unrelated = message_at("m2", "agent", 2, Some("r2"));
        let mut reply = message_at("m3", "vince", 3, None);
        reply.parent_id = Some(root.id.clone());
        for message in [&root, &unrelated, &reply] {
            store.insert_message(message).unwrap();
        }

        let messages = conversation_messages(&store, &reply, CONTEXT_MESSAGES).unwrap();
        assert_eq!(
            messages
                .iter()
                .map(|message| message.id.as_str())
                .collect::<Vec<_>>(),
            ["m1", "m3"]
        );

        drop(store);
        let _ = std::fs::remove_file(path);
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
            required_task_status: None,
        };
        let prompt = compose_prompt(&params, &None, &params.trigger);
        assert!(prompt.contains("NOTHING"));
        assert!(prompt.contains("deploy is failing"));
    }

    #[test]
    fn task_runs_explain_review_and_completion() {
        let task = Task {
            id: "task".into(),
            key: "PW-1".into(),
            title: "Answer it".into(),
            outcome: "What is the answer?".into(),
            status: TaskStatus::Planned,
            owner_id: None,
            source_channel_id: None,
            source_message_id: None,
            discussion_channel_id: "c".into(),
            project_id: None,
            host_id: None,
            worktree_id: None,
            current_run_id: None,
            active_continuation: None,
            pr_url: None,
            pr_state: None,
            review_action: None,
            created_by: "vince".into(),
            due_at: None,
            once_key: None,
            created_at: 0,
            updated_at: 0,
            position: 0.0,
        };
        let params = StartRunParams {
            agent_id: "a".into(),
            channel_id: "c".into(),
            task_id: Some(task.id.clone()),
            prompt: "Work on it".into(),
            trigger: RunTrigger::Manual { by: "vince".into() },
            automation_id: None,
            depth: 0,
            host_id: None,
            project_id: None,
            required_task_status: None,
        };
        let prompt = compose_prompt(&params, &Some(task), &params.trigger);
        assert!(prompt.contains("Leave work in Review when it needs approval"));
        assert!(prompt.contains("mark the task Done"));
        assert!(!prompt.contains("do not mark the task Done yourself"));
    }
}
