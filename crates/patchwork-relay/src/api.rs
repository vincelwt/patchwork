//! The HTTP API. Desktop, the agent CLI, and any future mobile client all
//! speak exactly this.

use std::collections::BTreeMap;
use std::sync::Arc;

use axum::extract::{DefaultBodyLimit, Multipart, Path, Query, Request, State};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use tower::ServiceExt;
use patchwork_core::events::Event;
use patchwork_core::host::RelayToHost;
use patchwork_core::models::*;
use patchwork_core::wire::*;
use patchwork_core::{new_id, now_ms, Id};
use serde::Deserialize;

use crate::auth::{self, Caller};
use crate::error::{ApiError, ApiResult};
use crate::orchestrator::{self, PostOptions, StartRunParams};
use crate::relay::Relay;
use crate::state::Shared;
use crate::{automations, preview_proxy};

/// The relay itself: what is true before you have picked a workspace.
/// Everything else lives under `/w/{workspace_id}/` and is served by that
/// workspace's own router.
pub fn relay_router(relay: Arc<Relay>) -> Router {
    Router::new()
        .route("/api/health", get(relay_health))
        .route("/api/workspaces", get(list_workspaces).post(create_workspace))
        .route("/api/auth/join", post(join))
        .fallback(dispatch)
        .with_state(relay)
}

/// `/w/{workspace_id}/api/thing` -> the workspace, and `/api/thing`.
fn split_workspace(path: &str) -> Option<(&str, &str)> {
    let rest = path.strip_prefix("/w/")?;
    let (workspace_id, tail) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, "/"),
    };
    (!workspace_id.is_empty()).then_some((workspace_id, tail))
}

/// Hand the request to the workspace named in its path.
async fn dispatch(State(relay): State<Arc<Relay>>, mut request: Request) -> Response {
    let path = request.uri().path().to_string();
    let Some((workspace_id, tail)) = split_workspace(&path) else {
        return ApiError::not_found("no such endpoint").into_response();
    };
    let Some(router) = relay.router(workspace_id).await else {
        return ApiError::not_found("no such workspace").into_response();
    };

    let query = request
        .uri()
        .query()
        .map(|q| format!("?{q}"))
        .unwrap_or_default();
    let Ok(uri) = format!("{tail}{query}").parse() else {
        return ApiError::bad_request("bad path").into_response();
    };
    *request.uri_mut() = uri;
    router.oneshot(request).await.into_response()
}

async fn relay_health(State(relay): State<Arc<Relay>>) -> ApiResult<Json<Health>> {
    let states = relay.states().await;
    let mut hosts_online = 0;
    let mut runs_active = 0;
    let mut started_at = now_ms();
    for state in &states {
        hosts_online += state.online_host_ids().await.len();
        runs_active += state.store.active_runs().map(|r| r.len()).unwrap_or(0);
        started_at = started_at.min(state.started_at);
    }
    Ok(Json(Health {
        ok: true,
        version: env!("CARGO_PKG_VERSION").to_string(),
        api: 1,
        started_at,
        hosts_online,
        runs_active,
    }))
}

/// Every workspace on this relay, for a caller who already belongs to one of
/// them. Names only: the contents stay behind each workspace's own token.
async fn list_workspaces(
    State(relay): State<Arc<Relay>>,
    headers: axum::http::HeaderMap,
) -> ApiResult<Json<Vec<Workspace>>> {
    relay
        .workspace_for_token(&bearer(&headers)?)
        .await
        .ok_or_else(|| ApiError::unauthorized("invalid token"))?;
    Ok(Json(relay.workspaces().await))
}

/// A second workspace on the same relay, created by someone who is already in
/// one. They own it: they are its first admin, with a token of its own.
async fn create_workspace(
    State(relay): State<Arc<Relay>>,
    headers: axum::http::HeaderMap,
    Json(input): Json<NameInput>,
) -> ApiResult<Json<AuthResponse>> {
    let name = input.name.trim();
    if name.is_empty() {
        return Err(ApiError::bad_request("a workspace needs a name"));
    }
    let (_, caller) = relay
        .workspace_for_token(&bearer(&headers)?)
        .await
        .ok_or_else(|| ApiError::unauthorized("invalid token"))?;

    let (state, code) = relay
        .create(name)
        .await
        .map_err(|e| ApiError::bad_request(e.to_string()))?;
    let response = join_workspace(
        &state,
        JoinRequest {
            invite_code: code,
            display_name: caller.member.display_name.clone(),
            email: caller.member.email.clone(),
            device_name: None,
        },
    )
    .await?;
    Ok(Json(response))
}

fn bearer(headers: &axum::http::HeaderMap) -> Result<String, ApiError> {
    headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
        .ok_or_else(|| ApiError::unauthorized("missing token"))
}

async fn join(
    State(relay): State<Arc<Relay>>,
    Json(input): Json<JoinRequest>,
) -> ApiResult<Json<AuthResponse>> {
    let state = relay
        .workspace_for_invite(input.invite_code.trim())
        .await
        .ok_or_else(|| {
            ApiError::new(
                axum::http::StatusCode::FORBIDDEN,
                "invalid_invite",
                "that invite code is not valid",
            )
        })?;
    Ok(Json(join_workspace(&state, input).await?))
}

/// One workspace's API. Mounted under `/w/{workspace_id}/`.
pub fn router(state: Shared) -> Router {
    let public = Router::new()
        .route("/api/health", get(health))
        .route("/api/webhooks/{token}", post(webhook));

    let api = Router::new()
        .route("/api/bootstrap", get(bootstrap))
        .route("/api/events", get(events_since))
        // channels and messages
        .route("/api/sections", get(list_sections).post(create_section))
        .route("/api/channels", get(list_channels).post(create_channel))
        .route(
            "/api/channels/{id}",
            patch(update_channel).delete(archive_channel),
        )
        .route("/api/channels/dm", post(open_dm))
        .route(
            "/api/channels/{id}/messages",
            get(list_messages).post(send_message),
        )
        .route("/api/messages/{id}", patch(edit_message).delete(delete_message))
        .route("/api/messages/{id}/thread", get(thread))
        .route("/api/messages/{id}/reactions", post(react))
        // tasks
        .route("/api/tasks", get(list_tasks).post(create_task))
        .route(
            "/api/tasks/{id}",
            get(task_detail).patch(update_task).delete(delete_task),
        )
        .route("/api/tasks/{id}/run", post(run_task))
        // runs
        .route("/api/runs", post(start_run))
        .route("/api/runs/{id}", get(run_detail))
        .route("/api/runs/{id}/cancel", post(cancel_run))
        .route("/api/runs/{id}/events", get(run_events))
        // questions
        .route("/api/questions", get(list_questions).post(ask_question))
        .route("/api/questions/{id}", get(get_question))
        .route("/api/questions/{id}/answer", post(answer_question))
        .route("/api/questions/{id}/wait", get(wait_for_answer))
        // inbox
        .route("/api/inbox", get(list_inbox))
        .route("/api/inbox/{id}/read", post(mark_read))
        .route("/api/inbox/read-all", post(mark_all_read))
        // members and agents
        .route("/api/members", get(list_members))
        .route("/api/members/me", patch(update_me))
        .route("/api/members/{id}", delete(remove_member))
        .route("/api/agents", post(create_agent))
        .route("/api/agents/{id}", patch(update_agent))
        // projects and hosts
        .route("/api/projects", get(list_projects).post(create_project))
        .route(
            "/api/projects/{id}",
            patch(update_project).delete(delete_project),
        )
        .route("/api/hosts", get(list_hosts))
        // automations
        .route(
            "/api/automations",
            get(list_automations).post(create_automation),
        )
        .route(
            "/api/automations/{id}",
            patch(update_automation).delete(delete_automation),
        )
        .route("/api/automations/{id}/run", post(run_automation))
        .route("/api/automations/{id}/debug", get(automation_debug))
        // previews
        .route("/api/previews", get(list_previews).post(start_preview))
        .route("/api/previews/{id}/stop", post(stop_preview))
        // files
        .route("/api/files", post(upload_file))
        .route("/api/files/{id}", get(download_file))
        // workspace admin
        .route("/api/workspace", patch(rename_workspace))
        .route("/api/invites", get(list_invites).post(create_invite))
        .route("/api/search", get(search))
        .layer(DefaultBodyLimit::max(64 * 1024 * 1024));

    Router::new()
        .merge(public)
        .merge(api)
        .route("/ws", get(crate::ws::handler))
        .route("/preview/{id}/", get(preview_proxy::proxy_root))
        .route("/preview/{id}/{*path}", get(preview_proxy::proxy))
        .with_state(state)
}

// ---------------------------------------------------------------------------
// health and auth
// ---------------------------------------------------------------------------

async fn health(State(state): State<Shared>) -> ApiResult<Json<Health>> {
    Ok(Json(Health {
        ok: true,
        version: env!("CARGO_PKG_VERSION").to_string(),
        api: 1,
        started_at: state.started_at,
        hosts_online: state.online_host_ids().await.len(),
        runs_active: state.store.active_runs().map(|r| r.len()).unwrap_or(0),
    }))
}

async fn join_workspace(state: &Shared, input: JoinRequest) -> ApiResult<AuthResponse> {
    let display_name = input.display_name.trim();
    if display_name.is_empty() {
        return Err(ApiError::bad_request("a display name is required"));
    }

    let invite = state
        .store
        .claim_invite(input.invite_code.trim(), "pending")
        .map_err(|e| ApiError::new(axum::http::StatusCode::FORBIDDEN, "invalid_invite", e.to_string()))?;

    let member = Member {
        id: new_id(),
        kind: MemberKind::Human,
        handle: state.store.unique_handle(display_name)?,
        display_name: display_name.to_string(),
        email: input.email.clone().or(invite.email.clone()),
        avatar: None,
        is_admin: invite.is_admin,
        created_at: now_ms(),
        agent: None,
        presence: Presence::Online,
    };
    state.store.insert_member(&member)?;
    state.store.conn()?.execute(
        "UPDATE invites SET used_by = ?2 WHERE code = ?1",
        rusqlite::params![invite.code, member.id],
    )?;

    let token = auth::generate_token();
    state.store.insert_token(
        &auth::hash_token(&token),
        &member.id,
        "device",
        None,
        input.device_name.as_deref(),
    )?;

    state.emit(Event::MemberUpdated {
        member: member.clone(),
    });

    Ok(AuthResponse {
        token,
        member,
        workspace: state.store.workspace()?,
    })
}

// ---------------------------------------------------------------------------
// bootstrap
// ---------------------------------------------------------------------------

async fn bootstrap(State(state): State<Shared>, caller: Caller) -> ApiResult<Json<Bootstrap>> {
    let members = state.members_with_presence().await?;
    let me = members
        .iter()
        .find(|m| m.id == caller.member.id)
        .cloned()
        .unwrap_or(caller.member.clone());

    Ok(Json(Bootstrap {
        workspace: state.store.workspace()?,
        me,
        members,
        sections: state.store.sections()?,
        channels: visible_channels(&state, &caller)?,
        projects: state.store.projects()?,
        hosts: state.hosts_with_presence().await?,
        tasks: state.store.tasks()?,
        inbox: state.store.inbox(&caller.member.id, false)?,
        automations: state.store.automations()?,
        open_questions: state.store.open_questions()?,
        active_runs: state.store.active_runs()?,
        previews: state.store.previews(true)?,
        seq: state.store.latest_seq()?,
    }))
}

/// Channels and task discussions belong to the workspace — a board everyone can
/// see would be useless if its conversations were private. Only DMs are.
fn visible_channels(state: &Shared, caller: &Caller) -> ApiResult<Vec<Channel>> {
    let channels = state.store.channels()?;
    Ok(channels
        .into_iter()
        .filter(|c| match c.kind {
            ChannelKind::Channel | ChannelKind::Task => true,
            ChannelKind::Dm => c.member_ids.contains(&caller.member.id) || caller.is_agent(),
        })
        .collect())
}

#[derive(Deserialize)]
struct SinceQuery {
    #[serde(default)]
    since: i64,
}

async fn events_since(
    State(state): State<Shared>,
    _caller: Caller,
    Query(query): Query<SinceQuery>,
) -> ApiResult<Json<Vec<patchwork_core::events::Envelope>>> {
    Ok(Json(state.store.events_since(query.since, 500)?))
}

// ---------------------------------------------------------------------------
// sections and channels
// ---------------------------------------------------------------------------

async fn list_sections(State(state): State<Shared>, _c: Caller) -> ApiResult<Json<Vec<Section>>> {
    Ok(Json(state.store.sections()?))
}

#[derive(Deserialize)]
struct NameInput {
    name: String,
}

async fn create_section(
    State(state): State<Shared>,
    _c: Caller,
    Json(input): Json<NameInput>,
) -> ApiResult<Json<Section>> {
    let section = Section {
        id: new_id(),
        name: input.name.trim().to_uppercase(),
        position: state.store.sections()?.len() as f64,
    };
    state.store.upsert_section(&section)?;
    state.emit(Event::SectionsUpdated {
        sections: state.store.sections()?,
    });
    Ok(Json(section))
}

async fn list_channels(State(state): State<Shared>, caller: Caller) -> ApiResult<Json<Vec<Channel>>> {
    Ok(Json(visible_channels(&state, &caller)?))
}

async fn create_channel(
    State(state): State<Shared>,
    _c: Caller,
    Json(input): Json<CreateChannel>,
) -> ApiResult<Json<Channel>> {
    let name = input.name.trim().trim_start_matches('#');
    if name.is_empty() {
        return Err(ApiError::bad_request("a channel needs a name"));
    }
    let slug = patchwork_core::ids::slugify(name);
    if state.store.channel_by_slug(&slug)?.is_some() {
        return Err(ApiError::conflict("a channel with that name already exists"));
    }

    let section_id = match (&input.section_id, &input.section_name) {
        (Some(id), _) => Some(id.clone()),
        (None, Some(name)) if !name.trim().is_empty() => {
            match state.store.section_by_name(name)? {
                Some(section) => Some(section.id),
                None => {
                    let section = Section {
                        id: new_id(),
                        name: name.trim().to_uppercase(),
                        position: state.store.sections()?.len() as f64,
                    };
                    state.store.upsert_section(&section)?;
                    state.emit(Event::SectionsUpdated {
                        sections: state.store.sections()?,
                    });
                    Some(section.id)
                }
            }
        }
        _ => None,
    };

    let channel = Channel {
        id: new_id(),
        kind: ChannelKind::Channel,
        section_id,
        slug: slug.clone(),
        name: slug,
        topic: input.topic.clone(),
        position: now_ms() as f64,
        created_at: now_ms(),
        member_ids: Vec::new(),
        task_id: None,
        last_message_at: 0,
    };
    state.store.insert_channel(&channel)?;
    state.emit(Event::ChannelCreated {
        channel: channel.clone(),
    });
    Ok(Json(channel))
}

async fn update_channel(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
    Json(input): Json<UpdateChannel>,
) -> ApiResult<Json<Channel>> {
    let mut channel = state
        .store
        .channel(&id)?
        .ok_or_else(|| ApiError::not_found("channel not found"))?;
    if let Some(name) = input.name {
        let slug = patchwork_core::ids::slugify(name.trim_start_matches('#'));
        channel.name = slug.clone();
        channel.slug = slug;
    }
    if let Some(topic) = input.topic {
        channel.topic = topic;
    }
    if let Some(section_id) = input.section_id {
        channel.section_id = if section_id.is_empty() {
            None
        } else {
            Some(section_id)
        };
    }
    if let Some(position) = input.position {
        channel.position = position;
    }
    state.store.update_channel(&channel)?;
    state.emit(Event::ChannelUpdated {
        channel: channel.clone(),
    });
    Ok(Json(channel))
}

async fn archive_channel(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    state.store.archive_channel(&id)?;
    state.emit(Event::ChannelDeleted { channel_id: id });
    Ok(Json(Ok::default()))
}

async fn open_dm(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<OpenDm>,
) -> ApiResult<Json<Channel>> {
    if input.member_id == caller.member.id {
        return Err(ApiError::bad_request("pick someone other than yourself"));
    }
    let other = state
        .store
        .member(&input.member_id)?
        .ok_or_else(|| ApiError::not_found("no such member"))?;

    if let Some(existing) = state.store.find_dm(&caller.member.id, &other.id)? {
        return Ok(Json(existing));
    }

    let channel = Channel {
        id: new_id(),
        kind: ChannelKind::Dm,
        section_id: None,
        slug: String::new(),
        name: other.display_name.clone(),
        topic: String::new(),
        position: now_ms() as f64,
        created_at: now_ms(),
        member_ids: vec![caller.member.id.clone(), other.id.clone()],
        task_id: None,
        last_message_at: 0,
    };
    state.store.insert_channel(&channel)?;
    state.emit(Event::ChannelCreated {
        channel: channel.clone(),
    });
    Ok(Json(channel))
}

#[derive(Deserialize)]
struct MessageQuery {
    #[serde(default)]
    before: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
}

async fn list_messages(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
    Query(query): Query<MessageQuery>,
) -> ApiResult<Json<MessagePage>> {
    let (messages, has_more) =
        state
            .store
            .messages(&id, query.before.as_deref(), query.limit.unwrap_or(50))?;
    Ok(Json(MessagePage {
        before: messages.first().map(|m| m.id.clone()),
        messages,
        has_more,
    }))
}

async fn send_message(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<SendMessage>,
) -> ApiResult<Json<Message>> {
    if input.body.trim().is_empty() && input.card.is_none() && input.attachment_ids.is_empty() {
        return Err(ApiError::bad_request("nothing to post"));
    }
    let message = orchestrator::post_message(
        &state,
        &id,
        &caller.member.id,
        input,
        PostOptions {
            trigger_agents: true,
            run_id: caller.run_id.clone(),
        },
    )
    .await?;
    Ok(Json(message))
}

#[derive(Deserialize)]
struct EditInput {
    body: String,
}

async fn edit_message(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<EditInput>,
) -> ApiResult<Json<Message>> {
    let message = state
        .store
        .message(&id)?
        .ok_or_else(|| ApiError::not_found("message not found"))?;
    if message.author_id != caller.member.id {
        return Err(ApiError::forbidden("you can only edit your own messages"));
    }
    state.store.update_message_body(&id, &input.body)?;
    let message = state.store.message(&id)?.unwrap();
    state.emit(Event::MessageUpdated {
        message: message.clone(),
    });
    Ok(Json(message))
}

async fn delete_message(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    let message = state
        .store
        .message(&id)?
        .ok_or_else(|| ApiError::not_found("message not found"))?;
    if message.author_id != caller.member.id && !caller.member.is_admin {
        return Err(ApiError::forbidden("you can only delete your own messages"));
    }
    state.store.delete_message(&id)?;
    state.emit(Event::MessageDeleted {
        channel_id: message.channel_id,
        message_id: id,
    });
    Ok(Json(Ok::default()))
}

async fn thread(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Vec<Message>>> {
    Ok(Json(state.store.thread(&id)?))
}

async fn react(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<ReactionRequest>,
) -> ApiResult<Json<Message>> {
    state
        .store
        .toggle_reaction(&id, &caller.member.id, &input.emoji)?;
    let message = state
        .store
        .message(&id)?
        .ok_or_else(|| ApiError::not_found("message not found"))?;
    state.emit(Event::MessageUpdated {
        message: message.clone(),
    });
    Ok(Json(message))
}

// ---------------------------------------------------------------------------
// tasks
// ---------------------------------------------------------------------------

async fn list_tasks(State(state): State<Shared>, _c: Caller) -> ApiResult<Json<Vec<Task>>> {
    Ok(Json(state.store.tasks()?))
}

async fn create_task(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<CreateTask>,
) -> ApiResult<Json<Task>> {
    if input.title.trim().is_empty() && input.outcome.trim().is_empty() {
        return Err(ApiError::bad_request("a task needs an expected result"));
    }
    Ok(Json(
        orchestrator::create_task(&state, &caller.member.id, input).await?,
    ))
}

async fn task_detail(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<TaskDetail>> {
    let task = state
        .store
        .task_by_ref(&id)?
        .ok_or_else(|| ApiError::not_found("task not found"))?;
    let worktree = match &task.worktree_id {
        Some(id) => state.store.worktree(id)?,
        None => None,
    };
    Ok(Json(TaskDetail {
        runs: state.store.task_runs(&task.id)?,
        attachments: state.store.task_attachments(&task.id)?,
        previews: state.store.task_previews(&task.id)?,
        questions: state.store.task_questions(&task.id)?,
        worktree,
        task,
    }))
}

async fn update_task(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<UpdateTask>,
) -> ApiResult<Json<Task>> {
    let task = state
        .store
        .task_by_ref(&id)?
        .ok_or_else(|| ApiError::not_found("task not found"))?;
    Ok(Json(
        orchestrator::update_task(&state, &caller.member.id, &task.id, input).await?,
    ))
}

async fn delete_task(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    caller.require_admin()?;
    state.store.delete_task(&id)?;
    state.emit(Event::TaskDeleted { task_id: id });
    Ok(Json(Ok::default()))
}

#[derive(Deserialize, Default)]
struct RunTaskInput {
    #[serde(default)]
    agent_id: Option<Id>,
    #[serde(default)]
    prompt: Option<String>,
}

async fn run_task(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    body: Option<Json<RunTaskInput>>,
) -> ApiResult<Json<Run>> {
    let task = state
        .store
        .task_by_ref(&id)?
        .ok_or_else(|| ApiError::not_found("task not found"))?;
    let input = body.map(|Json(b)| b).unwrap_or_default();
    Ok(Json(
        orchestrator::run_task(
            &state,
            &caller.member.id,
            &task.id,
            input.agent_id,
            input.prompt,
        )
        .await?,
    ))
}

// ---------------------------------------------------------------------------
// runs
// ---------------------------------------------------------------------------

async fn start_run(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<StartRun>,
) -> ApiResult<Json<Run>> {
    let agent_id = input
        .agent_id
        .ok_or_else(|| ApiError::bad_request("which agent should run?"))?;
    let channel_id = match (&input.channel_id, &input.task_id) {
        (Some(channel_id), _) => channel_id.clone(),
        (None, Some(task_id)) => state
            .store
            .task_by_ref(task_id)?
            .map(|t| t.discussion_channel_id)
            .ok_or_else(|| ApiError::not_found("task not found"))?,
        _ => return Err(ApiError::bad_request("a channel or task is required")),
    };

    let run = orchestrator::start_run(
        &state,
        StartRunParams {
            agent_id,
            channel_id,
            task_id: input.task_id.clone(),
            prompt: input.prompt.clone(),
            trigger: RunTrigger::Manual {
                by: caller.member.id.clone(),
            },
            automation_id: None,
            depth: 0,
            host_id: input.host_id.clone(),
            project_id: None,
        },
    )
    .await?;
    Ok(Json(run))
}

#[derive(Deserialize)]
struct AfterQuery {
    #[serde(default)]
    after: i64,
}

async fn run_detail(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<RunDetail>> {
    let run = state
        .store
        .run(&id)?
        .ok_or_else(|| ApiError::not_found("run not found"))?;
    Ok(Json(RunDetail {
        events: state.store.run_events(&id, 0)?,
        questions: state.store.run_questions(&id)?,
        run,
    }))
}

async fn run_events(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
    Query(query): Query<AfterQuery>,
) -> ApiResult<Json<Vec<RunEvent>>> {
    Ok(Json(state.store.run_events(&id, query.after)?))
}

async fn cancel_run(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    let run = state
        .store
        .run(&id)?
        .ok_or_else(|| ApiError::not_found("run not found"))?;
    if let Some(host_id) = &run.host_id {
        state
            .send_to_host(host_id, RelayToHost::CancelRun { run_id: id.clone() })
            .await;
    }
    Ok(Json(Ok::default()))
}

// ---------------------------------------------------------------------------
// questions
// ---------------------------------------------------------------------------

async fn list_questions(
    State(state): State<Shared>,
    _c: Caller,
) -> ApiResult<Json<Vec<Question>>> {
    Ok(Json(state.store.open_questions()?))
}

async fn get_question(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Question>> {
    state
        .store
        .question(&id)?
        .map(Json)
        .ok_or_else(|| ApiError::not_found("question not found"))
}

/// An agent asks. The card lands in the conversation and the right Inboxes.
async fn ask_question(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<AskQuestion>,
) -> ApiResult<Json<Question>> {
    if input.items.is_empty() {
        return Err(ApiError::bad_request("ask at least one question"));
    }
    let run = state
        .store
        .run(&input.run_id)?
        .ok_or_else(|| ApiError::not_found("run not found"))?;
    if caller.is_agent() && run.agent_id != caller.member.id {
        return Err(ApiError::forbidden("that is not your run"));
    }

    let question = Question {
        id: new_id(),
        run_id: run.id.clone(),
        agent_id: run.agent_id.clone(),
        channel_id: run.channel_id.clone(),
        task_id: run.task_id.clone(),
        message_id: None,
        headline: input.headline.clone(),
        items: input.items.clone(),
        status: QuestionStatus::Open,
        answers: None,
        answered_by: None,
        created_at: now_ms(),
        answered_at: None,
    };
    state.store.insert_question(&question)?;

    let message = orchestrator::post_message(
        &state,
        &run.channel_id,
        &run.agent_id,
        SendMessage {
            kind: Some(MessageKind::Card),
            card: Some(MessageCard::Question {
                question_id: question.id.clone(),
            }),
            run_id: Some(run.id.clone()),
            // Asked where the work was asked for.
            parent_id: orchestrator::reply_parent(&state, &run).await,
            ..Default::default()
        },
        PostOptions {
            trigger_agents: false,
            run_id: Some(run.id.clone()),
        },
    )
    .await?;
    state.store.set_question_message(&question.id, &message.id)?;

    // The run is visibly waiting, and the people who can answer are told.
    let mut run = run;
    run.status = RunStatus::Waiting;
    run.headline = if question.headline.is_empty() {
        "Waiting for an answer".into()
    } else {
        question.headline.clone()
    };
    state.store.update_run(&run)?;
    state.emit(Event::RunUpdated { run: run.clone() });
    state.set_presence(&run.agent_id, Presence::Waiting).await;

    let agent_name = state
        .store
        .member(&run.agent_id)?
        .map(|m| m.display_name)
        .unwrap_or_else(|| "An agent".into());
    for member_id in state.store.channel_audience(&run.channel_id)? {
        let Some(member) = state.store.member(&member_id)? else {
            continue;
        };
        if member.kind != MemberKind::Human {
            continue;
        }
        let item = InboxItem {
            id: new_id(),
            member_id: member.id.clone(),
            kind: InboxKind::Question,
            title: format!("{agent_name} has a question"),
            preview: question
                .items
                .first()
                .map(|i| i.question.clone())
                .unwrap_or_default(),
            actor_id: Some(run.agent_id.clone()),
            channel_id: Some(run.channel_id.clone()),
            message_id: Some(message.id.clone()),
            task_id: run.task_id.clone(),
            run_id: Some(run.id.clone()),
            automation_id: None,
            created_at: now_ms(),
            read_at: None,
        };
        state.store.insert_inbox(&item)?;
        state.emit(Event::InboxItemCreated { item });
    }

    let question = state.store.question(&question.id)?.unwrap();
    state.emit(Event::QuestionUpdated {
        question: question.clone(),
    });
    Ok(Json(question))
}

async fn answer_question(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<AnswerQuestion>,
) -> ApiResult<Json<Question>> {
    Ok(Json(
        orchestrator::answer_question(&state, &id, input.answers, &caller.member.id).await?,
    ))
}

/// The agent side of `patchwork ask`: hold the connection until a human
/// answers, so the run genuinely continues in context.
async fn wait_for_answer(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Question>> {
    let question = state
        .store
        .question(&id)?
        .ok_or_else(|| ApiError::not_found("question not found"))?;
    if question.status != QuestionStatus::Open {
        return Ok(Json(question));
    }

    let rx = state.wait_for_answer(&id).await;
    // Re-read after registering: an answer that landed in between would
    // otherwise make the agent wait out the whole long-poll for nothing.
    if let Some(answered) = state.store.question(&id)? {
        if answered.status != QuestionStatus::Open {
            return Ok(Json(answered));
        }
    }
    match tokio::time::timeout(std::time::Duration::from_secs(90), rx).await {
        Ok(Result::Ok(answered)) => Ok(Json(answered)),
        // A timeout is not an error: the caller polls again.
        _ => Ok(Json(
            state
                .store
                .question(&id)?
                .ok_or_else(|| ApiError::not_found("question not found"))?,
        )),
    }
}

// ---------------------------------------------------------------------------
// inbox
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct InboxQuery {
    #[serde(default)]
    all: bool,
}

async fn list_inbox(
    State(state): State<Shared>,
    caller: Caller,
    Query(query): Query<InboxQuery>,
) -> ApiResult<Json<Vec<InboxItem>>> {
    Ok(Json(state.store.inbox(&caller.member.id, query.all)?))
}

async fn mark_read(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    state.store.mark_inbox_read(&id)?;
    if let Some(item) = state.store.inbox_item(&id)? {
        if item.member_id == caller.member.id {
            state.emit(Event::InboxItemUpdated { item });
        }
    }
    Ok(Json(Ok::default()))
}

async fn mark_all_read(State(state): State<Shared>, caller: Caller) -> ApiResult<Json<Ok>> {
    state.store.mark_all_inbox_read(&caller.member.id)?;
    for item in state.store.inbox(&caller.member.id, true)? {
        state.emit(Event::InboxItemUpdated { item });
    }
    Ok(Json(Ok::default()))
}

// ---------------------------------------------------------------------------
// members and agents
// ---------------------------------------------------------------------------

async fn list_members(State(state): State<Shared>, _c: Caller) -> ApiResult<Json<Vec<Member>>> {
    Ok(Json(state.members_with_presence().await?))
}

#[derive(Deserialize)]
struct UpdateMe {
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    avatar: Option<String>,
}

async fn update_me(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<UpdateMe>,
) -> ApiResult<Json<Member>> {
    let mut member = caller.member.clone();
    if let Some(name) = input.display_name {
        if !name.trim().is_empty() {
            member.display_name = name.trim().to_string();
        }
    }
    if let Some(avatar) = input.avatar {
        member.avatar = Some(avatar).filter(|a| !a.is_empty());
    }
    state.store.update_member(&member)?;
    state.emit(Event::MemberUpdated {
        member: member.clone(),
    });
    Ok(Json(member))
}

async fn remove_member(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    caller.require_admin()?;
    state.store.deactivate_member(&id)?;
    state.emit(Event::MemberRemoved { member_id: id });
    Ok(Json(Ok::default()))
}

async fn create_agent(
    State(state): State<Shared>,
    _c: Caller,
    Json(input): Json<CreateAgent>,
) -> ApiResult<Json<Member>> {
    if input.display_name.trim().is_empty() {
        return Err(ApiError::bad_request("an agent needs a name"));
    }
    let handle = state.store.unique_handle(
        input
            .handle
            .as_deref()
            .unwrap_or(input.display_name.as_str()),
    )?;
    let member = Member {
        id: new_id(),
        kind: MemberKind::Agent,
        handle,
        display_name: input.display_name.trim().to_string(),
        email: None,
        avatar: input.avatar.clone(),
        is_admin: false,
        created_at: now_ms(),
        agent: Some(input.profile.clone()),
        presence: Presence::Offline,
    };
    state.store.insert_member(&member)?;
    state.emit(Event::MemberUpdated {
        member: member.clone(),
    });
    Ok(Json(member))
}

async fn update_agent(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
    Json(input): Json<UpdateAgent>,
) -> ApiResult<Json<Member>> {
    let mut member = state
        .store
        .member(&id)?
        .filter(|m| m.kind == MemberKind::Agent)
        .ok_or_else(|| ApiError::not_found("no such agent"))?;
    if let Some(name) = input.display_name {
        if !name.trim().is_empty() {
            member.display_name = name.trim().to_string();
        }
    }
    if let Some(avatar) = input.avatar {
        member.avatar = Some(avatar).filter(|a| !a.is_empty());
    }
    if let Some(profile) = input.profile {
        member.agent = Some(profile);
    }
    state.store.update_member(&member)?;
    state.emit(Event::MemberUpdated {
        member: member.clone(),
    });
    Ok(Json(member))
}

// ---------------------------------------------------------------------------
// projects and hosts
// ---------------------------------------------------------------------------

async fn list_projects(State(state): State<Shared>, _c: Caller) -> ApiResult<Json<Vec<Project>>> {
    Ok(Json(state.store.projects()?))
}

async fn create_project(
    State(state): State<Shared>,
    _c: Caller,
    Json(input): Json<CreateProject>,
) -> ApiResult<Json<Project>> {
    if input.name.trim().is_empty() {
        return Err(ApiError::bad_request("a project needs a name"));
    }
    let project = Project {
        id: new_id(),
        name: input.name.trim().to_string(),
        description: input.description.clone(),
        kind: input.kind.unwrap_or(ProjectKind::Git),
        repo_url: input.repo_url.clone(),
        default_branch: input.default_branch.clone().unwrap_or_else(|| "main".into()),
        paths: input.paths.clone(),
        created_at: now_ms(),
    };
    state.store.upsert_project(&project)?;
    state.emit(Event::ProjectUpdated {
        project: project.clone(),
    });
    Ok(Json(project))
}

async fn update_project(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
    Json(input): Json<CreateProject>,
) -> ApiResult<Json<Project>> {
    let mut project = state
        .store
        .project(&id)?
        .ok_or_else(|| ApiError::not_found("project not found"))?;
    if !input.name.trim().is_empty() {
        project.name = input.name.trim().to_string();
    }
    project.description = input.description.clone();
    if let Some(kind) = input.kind {
        project.kind = kind;
    }
    project.repo_url = input.repo_url.clone();
    if let Some(branch) = input.default_branch {
        project.default_branch = branch;
    }
    if !input.paths.is_empty() {
        project.paths = input.paths.clone();
    }
    state.store.upsert_project(&project)?;
    state.emit(Event::ProjectUpdated {
        project: project.clone(),
    });
    Ok(Json(project))
}

async fn delete_project(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    caller.require_admin()?;
    state.store.delete_project(&id)?;
    state.emit(Event::ProjectDeleted { project_id: id });
    Ok(Json(Ok::default()))
}

async fn list_hosts(State(state): State<Shared>, _c: Caller) -> ApiResult<Json<Vec<Host>>> {
    Ok(Json(state.hosts_with_presence().await?))
}

// ---------------------------------------------------------------------------
// automations
// ---------------------------------------------------------------------------

async fn list_automations(
    State(state): State<Shared>,
    _c: Caller,
) -> ApiResult<Json<Vec<Automation>>> {
    Ok(Json(state.store.automations()?))
}

async fn create_automation(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<CreateAutomation>,
) -> ApiResult<Json<Automation>> {
    let automation = Automation {
        id: new_id(),
        name: input.name.trim().to_string(),
        description: input.description.clone(),
        enabled: input.enabled,
        trigger: input.trigger.clone(),
        agent_id: input.agent_id.clone(),
        action: input.action,
        instructions: input.instructions.clone(),
        context_channel_id: input.context_channel_id.clone(),
        report_channel_id: input.report_channel_id.clone(),
        project_id: input.project_id.clone(),
        location: input.location,
        host_id: input.host_id.clone(),
        created_by: caller.member.id.clone(),
        created_at: now_ms(),
        last_run_at: None,
        next_run_at: match &input.trigger {
            AutomationTrigger::Schedule {
                every_seconds,
                start_at,
            } => Some(start_at.unwrap_or_else(|| now_ms() + every_seconds * 1000)),
            _ => None,
        },
        failure_count: 0,
    };
    state.store.upsert_automation(&automation)?;
    state.emit(Event::AutomationUpdated {
        automation: automation.clone(),
    });
    Ok(Json(automation))
}

async fn update_automation(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
    Json(input): Json<CreateAutomation>,
) -> ApiResult<Json<Automation>> {
    let mut automation = state
        .store
        .automation(&id)?
        .ok_or_else(|| ApiError::not_found("automation not found"))?;
    automation.name = input.name.trim().to_string();
    automation.description = input.description.clone();
    automation.enabled = input.enabled;
    automation.trigger = input.trigger.clone();
    automation.agent_id = input.agent_id.clone();
    automation.action = input.action;
    automation.instructions = input.instructions.clone();
    automation.context_channel_id = input.context_channel_id.clone();
    automation.report_channel_id = input.report_channel_id.clone();
    automation.project_id = input.project_id.clone();
    automation.location = input.location;
    automation.host_id = input.host_id.clone();
    if let AutomationTrigger::Schedule { every_seconds, .. } = &automation.trigger {
        automation.next_run_at = Some(now_ms() + every_seconds * 1000);
    }
    state.store.upsert_automation(&automation)?;
    state.emit(Event::AutomationUpdated {
        automation: automation.clone(),
    });
    Ok(Json(automation))
}

async fn delete_automation(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    state.store.delete_automation(&id)?;
    state.emit(Event::AutomationDeleted { automation_id: id });
    Ok(Json(Ok::default()))
}

async fn run_automation(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<AutomationRun>> {
    let automation = state
        .store
        .automation(&id)?
        .ok_or_else(|| ApiError::not_found("automation not found"))?;
    Ok(Json(
        automations::run_now(&state, &automation, &caller.member.display_name).await?,
    ))
}

async fn automation_debug(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<AutomationDebug>> {
    let automation = state
        .store
        .automation(&id)?
        .ok_or_else(|| ApiError::not_found("automation not found"))?;
    Ok(Json(AutomationDebug {
        runs: state.store.automation_runs(&id, 50)?,
        automation,
    }))
}

async fn webhook(
    State(state): State<Shared>,
    Path(token): Path<String>,
    body: Option<Json<serde_json::Value>>,
) -> ApiResult<Json<Ok>> {
    let payload = body.map(|Json(v)| v).unwrap_or(serde_json::json!({}));
    let fired = automations::on_webhook(&state, &token, payload).await?;
    if !fired {
        return Err(ApiError::not_found("no automation listens on that webhook"));
    }
    Ok(Json(Ok::default()))
}

// ---------------------------------------------------------------------------
// previews
// ---------------------------------------------------------------------------

async fn list_previews(State(state): State<Shared>, _c: Caller) -> ApiResult<Json<Vec<Preview>>> {
    Ok(Json(state.store.previews(false)?))
}

async fn start_preview(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<StartPreview>,
) -> ApiResult<Json<Preview>> {
    let task = state
        .store
        .task_by_ref(&input.task_id)?
        .ok_or_else(|| ApiError::not_found("task not found"))?;
    let project = match &task.project_id {
        Some(id) => state.store.project(id)?,
        None => None,
    };
    let command = input
        .command
        .clone()
        .ok_or_else(|| ApiError::bad_request("what should I run? pass --command"))?;
    let host_id = task
        .host_id
        .clone()
        .unwrap_or_else(|| state.relay_host_id.clone());
    let worktree = match &task.worktree_id {
        Some(id) => state.store.worktree(id)?,
        None => None,
    };
    let cwd = worktree
        .map(|w| w.path)
        .or_else(|| {
            project
                .as_ref()
                .and_then(|p| p.paths.get(&host_id).cloned())
        })
        .ok_or_else(|| ApiError::bad_request("this task has no folder to run in"))?;

    let port = input.port.unwrap_or(4321);

    let preview = Preview {
        id: new_id(),
        task_id: task.id.clone(),
        host_id: host_id.clone(),
        run_id: caller.run_id.clone(),
        label: input.label.clone().unwrap_or_else(|| task.title.clone()),
        port,
        url: String::new(),
        status: PreviewStatus::Starting,
        local_only: host_id != state.relay_host_id,
        created_at: now_ms(),
        stopped_at: None,
    };
    state.store.upsert_preview(&preview)?;
    state.emit(Event::PreviewUpdated {
        preview: preview.clone(),
    });

    let sent = state
        .send_to_host(
            &host_id,
            RelayToHost::StartPreview {
                preview_id: preview.id.clone(),
                task_id: task.id.clone(),
                cwd,
                command,
                port,
                label: preview.label.clone(),
            },
        )
        .await;
    if !sent {
        return Err(ApiError::bad_request(
            "the machine that owns this task is offline",
        ));
    }
    Ok(Json(preview))
}

async fn stop_preview(
    State(state): State<Shared>,
    _c: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    let preview = state
        .store
        .preview(&id)?
        .ok_or_else(|| ApiError::not_found("preview not found"))?;
    state
        .send_to_host(
            &preview.host_id,
            RelayToHost::StopPreview {
                preview_id: preview.id.clone(),
            },
        )
        .await;
    Ok(Json(Ok::default()))
}

// ---------------------------------------------------------------------------
// files
// ---------------------------------------------------------------------------

async fn upload_file(
    State(state): State<Shared>,
    caller: Caller,
    mut multipart: Multipart,
) -> ApiResult<Json<Attachment>> {
    let mut task_id: Option<Id> = None;
    let mut stored: Option<Attachment> = None;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::bad_request(e.to_string()))?
    {
        match field.name().unwrap_or_default() {
            "task_id" => {
                task_id = field.text().await.ok().filter(|t| !t.is_empty());
            }
            _ => {
                let file_name = field
                    .file_name()
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "file".into());
                let mime = field
                    .content_type()
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| {
                        mime_guess::from_path(&file_name)
                            .first_or_octet_stream()
                            .to_string()
                    });
                let bytes = field
                    .bytes()
                    .await
                    .map_err(|e| ApiError::bad_request(e.to_string()))?;

                let id = new_id();
                let path = state.files_dir.join(&id);
                tokio::fs::create_dir_all(&state.files_dir)
                    .await
                    .map_err(|e| ApiError::bad_request(e.to_string()))?;
                tokio::fs::write(&path, &bytes)
                    .await
                    .map_err(|e| ApiError::bad_request(e.to_string()))?;

                stored = Some(Attachment {
                    id: id.clone(),
                    file_name,
                    mime,
                    size: bytes.len() as i64,
                    url: format!("/api/files/{id}"),
                    message_id: None,
                    task_id: None,
                    run_id: caller.run_id.clone(),
                    created_at: now_ms(),
                });
            }
        }
    }

    let mut attachment = stored.ok_or_else(|| ApiError::bad_request("no file in that upload"))?;
    attachment.task_id = task_id;
    let path = state.files_dir.join(&attachment.id);
    state
        .store
        .insert_attachment(&attachment, &path.to_string_lossy())?;
    Ok(Json(attachment))
}

async fn download_file(
    State(state): State<Shared>,
    Path(id): Path<Id>,
) -> ApiResult<axum::response::Response> {
    use axum::response::IntoResponse;
    let (attachment, path) = state
        .store
        .attachment(&id)?
        .ok_or_else(|| ApiError::not_found("file not found"))?;
    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|_| ApiError::not_found("file is no longer on disk"))?;
    Ok((
        [
            (axum::http::header::CONTENT_TYPE, attachment.mime),
            (
                axum::http::header::CONTENT_DISPOSITION,
                format!("inline; filename=\"{}\"", attachment.file_name),
            ),
        ],
        bytes,
    )
        .into_response())
}

// ---------------------------------------------------------------------------
// workspace admin and search
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct WorkspaceInput {
    #[serde(default)]
    name: Option<String>,
    /// What task keys start with. Letters and digits, upper-cased.
    #[serde(default)]
    task_prefix: Option<String>,
}

async fn rename_workspace(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<WorkspaceInput>,
) -> ApiResult<Json<Workspace>> {
    caller.require_admin()?;
    let name = input.name.as_deref().map(str::trim).filter(|n| !n.is_empty());
    let prefix = match input.task_prefix.as_deref() {
        Some(raw) => {
            let cleaned: String = raw
                .chars()
                .filter(|c| c.is_ascii_alphanumeric())
                .take(6)
                .collect::<String>()
                .to_uppercase();
            if cleaned.is_empty() {
                return Err(ApiError::bad_request("a task prefix needs a letter or two"));
            }
            Some(cleaned)
        }
        None => None,
    };
    let workspace = state.store.update_workspace(name, prefix.as_deref())?;
    state.emit(Event::WorkspaceUpdated {
        workspace: workspace.clone(),
    });
    Ok(Json(workspace))
}

async fn list_invites(State(state): State<Shared>, caller: Caller) -> ApiResult<Json<Vec<Invite>>> {
    caller.require_admin()?;
    Ok(Json(state.store.invites()?))
}

async fn create_invite(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<CreateInvite>,
) -> ApiResult<Json<Invite>> {
    caller.require_admin()?;
    let invite = Invite {
        code: auth::generate_invite_code(),
        created_by: caller.member.id.clone(),
        created_at: now_ms(),
        email: input.email.clone(),
        is_admin: input.is_admin,
        used_at: None,
        used_by: None,
    };
    state.store.insert_invite(&invite)?;
    Ok(Json(invite))
}

#[derive(Deserialize)]
struct SearchQuery {
    q: String,
    #[serde(default)]
    limit: Option<usize>,
}

async fn search(
    State(state): State<Shared>,
    _c: Caller,
    Query(query): Query<SearchQuery>,
) -> ApiResult<Json<SearchResults>> {
    let needle = query.q.trim();
    if needle.is_empty() {
        return Err(ApiError::bad_request("what should I search for?"));
    }
    let limit = query.limit.unwrap_or(30);

    // FTS5 rejects some raw user input; fall back to a quoted phrase.
    let messages = state
        .store
        .search_messages(needle, limit)
        .or_else(|_| state.store.search_messages(&format!("\"{needle}\""), limit))
        .unwrap_or_default();

    let members: BTreeMap<Id, String> = state.store.member_names()?;
    let channels: BTreeMap<Id, String> = state.store.channel_names()?;
    let hits = messages
        .into_iter()
        .map(|message| SearchHit {
            snippet: snippet(&message.body, needle),
            channel_name: channels
                .get(&message.channel_id)
                .cloned()
                .unwrap_or_default(),
            author_name: members.get(&message.author_id).cloned().unwrap_or_default(),
            message,
        })
        .collect();

    let lowered = needle.to_lowercase();
    let tasks = state
        .store
        .tasks()?
        .into_iter()
        .filter(|t| {
            t.title.to_lowercase().contains(&lowered)
                || t.outcome.to_lowercase().contains(&lowered)
                || t.key.eq_ignore_ascii_case(needle)
        })
        .take(limit)
        .collect();

    Ok(Json(SearchResults {
        messages: hits,
        tasks,
    }))
}

fn snippet(body: &str, needle: &str) -> String {
    let lowered = body.to_lowercase();
    let position = lowered.find(&needle.to_lowercase()).unwrap_or(0);
    let start = body[..position]
        .char_indices()
        .rev()
        .nth(60)
        .map(|(i, _)| i)
        .unwrap_or(0);
    let text: String = body[start..].chars().take(200).collect();
    if start > 0 {
        format!("…{text}")
    } else {
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_is_split_into_a_workspace_and_the_api_it_calls() {
        assert_eq!(
            split_workspace("/w/ws1/api/bootstrap"),
            Some(("ws1", "/api/bootstrap"))
        );
        assert_eq!(split_workspace("/w/ws1/ws"), Some(("ws1", "/ws")));
        assert_eq!(split_workspace("/w/ws1"), Some(("ws1", "/")));
        assert_eq!(split_workspace("/w/"), None);
        assert_eq!(split_workspace("/api/health"), None);
    }

    #[test]
    fn snippets_centre_on_the_match() {
        let body = format!("{}NEEDLE{}", "a".repeat(200), "b".repeat(200));
        let s = snippet(&body, "needle");
        assert!(s.starts_with('…'));
        assert!(s.contains("NEEDLE"));
        assert!(s.len() < 260);
    }
}
