//! Deciding what should happen, and making it happen.
//!
//! Posting a message, creating a task, answering a question and finishing a run
//! all funnel through here so that the conversation, the board, the Inbox and
//! the running agents never disagree with each other.

use anyhow::{anyhow, bail, Context, Result};
use patchwork_core::events::Event;
use patchwork_core::host::{HostToRelay, RelayToHost, RunSpec, WorktreeSpec};
use patchwork_core::models::*;
use patchwork_core::wire::SendMessage;
use patchwork_core::{new_id, now_ms, Id};
use patchwork_agent::worktree::branch_for;

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
    Box::pin(post_message_inner(state, channel_id, author_id, input, options))
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

    notify_inbox(state, &stored, &channel, &members).await?;

    if options.trigger_agents {
        if let Err(err) = trigger_agents(state, &stored, &channel, &members).await {
            tracing::warn!(?err, "failed to route message to agents");
        }
    }

    // An agent that says "opened <pr url>" links the task without anyone
    // copying the URL by hand.
    if let Some(task_id) = &stored.task_id {
        crate::github::link_pr_from_message(state, task_id, &stored.body).await;
    }

    // A message in a task discussion is also a trigger for automations.
    crate::automations::on_message(state, &stored).await;

    Ok(stored)
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

        let should_run = if mentioned {
            participation != Participation::Off || in_dm
        } else if in_dm {
            profile.dm_enabled
        } else {
            participation == Participation::Ambient && author.kind == MemberKind::Human
        };
        if !should_run {
            continue;
        }

        let trigger = if mentioned {
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
            let prompt = format!(
                "{} just said:\n\n{}",
                display_name_of(members, &message.author_id),
                message.body
            );
            state
                .send_to_host(
                    active.host_id.as_deref().unwrap_or(&state.relay_host_id),
                    RelayToHost::FollowUp {
                        run_id: active.id.clone(),
                        prompt,
                    },
                )
                .await;
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

    let host_id = choose_host(
        state,
        &profile,
        params.host_id.clone().or_else(|| {
            task.as_ref()
                .and_then(|t| t.host_id.clone())
                .or_else(|| project.as_ref().map(|_| String::new()).and(None))
        }),
        project.as_ref(),
    )
    .await?;

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
        custom_command: profile.custom_command.clone(),
        channel_id: run.channel_id.clone(),
        task_id: run.task_id.clone(),
        project_id: project_id.clone(),
        automation_id: params.automation_id.clone(),
        worktree: worktree_spec,
        prompt,
        context,
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
        if task.status == TaskStatus::Planned {
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

fn resume_session_for(state: &Shared, agent_id: &str, task_id: &Option<Id>) -> Result<Option<String>> {
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
            ids.extend(online.iter().filter(|id| **id != state.relay_host_id).cloned());
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
            bail!(
                "no connected machine has `{}` checked out",
                project.name
            );
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

    let project_path = project
        .paths
        .get(host_id)
        .cloned()
        .ok_or_else(|| anyhow!("`{}` is not checked out on this machine", project.name))?;

    Ok((
        WorktreeSpec::New {
            project_path,
            branch: branch_for(&task.key, &task.title),
            base_branch: project.default_branch.clone(),
        },
        None,
    ))
}

fn compose_prompt(params: &StartRunParams, task: &Option<Task>, trigger: &RunTrigger) -> String {
    let mut prompt = String::new();
    if let Some(task) = task {
        prompt.push_str(&format!(
            "You own task {} — {}.\n",
            task.key, task.title
        ));
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

    out.push_str(
        "\nUse `patchwork history` and `patchwork search` if you need more than this.\n",
    );
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
        } => {
            let seq = state.store.next_run_event_seq(&run_id)?;
            let event = RunEvent {
                id: new_id(),
                run_id: run_id.clone(),
                seq,
                kind,
                text,
                data,
                created_at: now_ms(),
            };
            state.store.append_run_event(&event)?;
            state.emit(Event::RunEventAppended { event });
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

        HostToRelay::RunMessage { run_id, kind, body } => {
            let Some(run) = state.store.run(&run_id)? else {
                return Ok(());
            };
            // An ambient agent that has nothing to add says so, and we stay quiet.
            let quiet = matches!(run.trigger, RunTrigger::Ambient { .. })
                && body.trim().trim_matches(|c: char| !c.is_alphanumeric())
                    .eq_ignore_ascii_case("NOTHING");
            if quiet {
                return Ok(());
            }
            post_message(
                state,
                &run.channel_id,
                &run.agent_id,
                SendMessage {
                    body,
                    kind: Some(kind),
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

pub fn notify_task(
    state: &Shared,
    task: &Task,
    kind: InboxKind,
    title: String,
) -> Result<()> {
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
    let key = state.store.next_task_key()?;
    let now = now_ms();

    let discussion = Channel {
        id: new_id(),
        kind: ChannelKind::Task,
        section_id: None,
        slug: String::new(),
        name: format!("{key} — {}", input.title),
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

    let task = Task {
        id: new_id(),
        key: key.clone(),
        title: input.title.clone(),
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
        task.pr_url = if pr_url.is_empty() { None } else { Some(pr_url) };
    }
    if let Some(position) = input.position {
        task.position = position;
    }

    state.store.update_task(&task)?;
    state.emit(Event::TaskUpdated { task: task.clone() });

    if previous.owner_id != task.owner_id {
        if let Some(owner) = &task.owner_id {
            state.store.add_channel_member(&task.discussion_channel_id, owner)?;
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
