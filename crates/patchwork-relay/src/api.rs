//! The HTTP API. Desktop, the agent CLI, and any future mobile client all
//! speak exactly this.

use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;

use axum::extract::{DefaultBodyLimit, Multipart, Path, Query, Request, State};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, delete, get, patch, post, put};
use axum::{Json, Router};
use patchwork_core::events::Event;
use patchwork_core::host::RelayToHost;
use patchwork_core::models::*;
use patchwork_core::wire::*;
use patchwork_core::{new_id, now_ms, Id};
use serde::{Deserialize, Serialize};
use tower::ServiceExt;

use crate::auth::{self, Caller};
use crate::error::{ApiError, ApiResult};
use crate::orchestrator::{self, PostOptions, StartRunParams};
use crate::relay::Relay;
use crate::state::Shared;
use crate::store::SaveWorkspaceSkillResult;
use crate::{automations, preview_proxy};

/// The relay itself: what is true before you have picked a workspace.
/// Everything else lives under `/w/{workspace_id}/` and is served by that
/// workspace's own router.
pub fn relay_router(relay: Arc<Relay>) -> Router {
    Router::new()
        .route("/api/health", get(relay_health))
        .route(
            "/api/workspaces",
            get(list_workspaces).post(create_workspace),
        )
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

fn split_preview(path: &str) -> Option<(&str, &str)> {
    let rest = path.strip_prefix("/preview/")?;
    let (preview_id, tail) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, "/"),
    };
    (!preview_id.is_empty()).then_some((preview_id, tail))
}

/// Hand the request to the workspace named in its path. Isolated preview
/// origins carry only relay + preview ids, so those resolve by preview id.
async fn dispatch(State(relay): State<Arc<Relay>>, mut request: Request) -> Response {
    let path = request.uri().path().to_string();
    let (router, tail) = if let Some((workspace_id, tail)) = split_workspace(&path) {
        let Some(router) = relay.router(workspace_id).await else {
            return ApiError::not_found("no such workspace").into_response();
        };
        (router, tail.to_string())
    } else if let Some((preview_id, rest)) = split_preview(&path) {
        let Some(router) = relay.router_for_preview(preview_id).await else {
            return ApiError::not_found("no such preview").into_response();
        };
        (router, format!("/preview/{preview_id}{rest}"))
    } else {
        return ApiError::not_found("no such endpoint").into_response();
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

async fn relay_health(
    State(relay): State<Arc<Relay>>,
    headers: axum::http::HeaderMap,
) -> ApiResult<Json<Health>> {
    let states = relay.states().await;
    let mut hosts_online = 0;
    let mut runs_active = 0;
    let mut started_at = now_ms();
    for state in &states {
        hosts_online += state.online_host_ids().await.len();
        runs_active += state.store.active_runs().map(|r| r.len()).unwrap_or(0);
        started_at = started_at.min(state.started_at);
    }
    let known = match bearer(&headers) {
        Ok(token) => relay.workspace_for_token(&token).await.is_some(),
        Err(_) => false,
    };
    Ok(Json(Health {
        ok: true,
        version: env!("CARGO_PKG_VERSION").to_string(),
        api: 1,
        started_at,
        hosts_online,
        runs_active,
        system: if known { Some(system_health().await) } else { None },
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
        .route("/api/auth/pair", post(claim_pairing))
        .route("/api/workspace/icon/{id}", get(workspace_icon))
        .route("/api/webhooks/{token}", post(webhook));

    let api = Router::new()
        .route("/api/bootstrap", get(bootstrap))
        .route("/api/events", get(events_since))
        .route("/api/pairings", post(create_pairing))
        .route("/api/devices", get(list_devices))
        .route("/api/devices/current", delete(revoke_current_device))
        .route("/api/devices/{id}", delete(revoke_device))
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
        .route(
            "/api/messages/{id}",
            patch(edit_message).delete(delete_message),
        )
        .route("/api/messages/{id}/thread", get(thread))
        .route("/api/messages/{id}/reactions", post(react))
        // tasks
        .route("/api/tasks", get(list_tasks).post(create_task))
        .route(
            "/api/tasks/{id}",
            get(task_detail).patch(update_task).delete(delete_task),
        )
        .route("/api/tasks/{id}/run", post(run_task))
        .route("/api/tasks/{id}/approve", post(approve_task))
        // runs
        .route("/api/runs", post(start_run))
        .route("/api/runs/{id}", get(run_detail))
        .route("/api/runs/{id}/cancel", post(cancel_run))
        .route("/api/runs/{id}/steer", post(steer_run))
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
        // workspace skills
        .route("/api/skills", get(list_skills).post(create_skill))
        .route("/api/skills/{id}", patch(update_skill).delete(delete_skill))
        // projects and hosts
        .route("/api/projects", get(list_projects).post(create_project))
        .route(
            "/api/projects/{id}",
            patch(update_project).delete(delete_project),
        )
        .route("/api/hosts", get(list_hosts))
        .route("/api/hosts/{id}/skills", patch(update_system_skill))
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
        .route("/api/previews/{id}/grant", post(grant_preview))
        // files
        .route("/api/uploads", post(create_upload))
        .route("/api/uploads/{id}", put(upload_chunk))
        .route("/api/uploads/{id}/complete", post(complete_upload))
        .route("/api/files", post(upload_file))
        .route("/api/files/{id}", get(download_file))
        .route("/api/files/{id}/grant", post(grant_file))
        .route("/api/files/{id}/evidence", delete(remove_file_evidence))
        // workspace admin
        .route("/api/workspace", patch(update_workspace))
        .route("/api/invites", get(list_invites).post(create_invite))
        .route("/api/search", get(search))
        .layer(DefaultBodyLimit::max(64 * 1024 * 1024));

    Router::new()
        .merge(public)
        .merge(api)
        .route("/ws", get(crate::ws::handler))
        .route("/preview/{id}/", any(preview_proxy::proxy_root))
        .route("/preview/{id}/{*path}", any(preview_proxy::proxy))
        .with_state(state)
}

// ---------------------------------------------------------------------------
// health and auth
// ---------------------------------------------------------------------------

async fn health(
    State(state): State<Shared>,
    headers: axum::http::HeaderMap,
) -> ApiResult<Json<Health>> {
    let known = bearer(&headers)
        .ok()
        .and_then(|token| auth::authenticate(&state, &token))
        .is_some();
    Ok(Json(Health {
        ok: true,
        version: env!("CARGO_PKG_VERSION").to_string(),
        api: 1,
        started_at: state.started_at,
        hosts_online: state.online_host_ids().await.len(),
        runs_active: state.store.active_runs().map(|r| r.len()).unwrap_or(0),
        system: if known { Some(system_health().await) } else { None },
    }))
}

/// What the relay's machine is doing right now. CPU usage is a rate, so it
/// needs two samples: the reader is built per call and thrown away, which
/// costs one 200ms wait and buys no shared state to keep correct.
async fn system_health() -> SystemHealth {
    use sysinfo::{
        get_current_pid, ProcessRefreshKind, ProcessesToUpdate, System,
        MINIMUM_CPU_UPDATE_INTERVAL,
    };

    let mut system = System::new();
    system.refresh_cpu_usage();
    tokio::time::sleep(MINIMUM_CPU_UPDATE_INTERVAL).await;
    system.refresh_cpu_usage();
    system.refresh_memory();

    let pid = get_current_pid().ok();
    if let Some(pid) = pid {
        system.refresh_processes_specifics(
            ProcessesToUpdate::Some(&[pid]),
            true,
            ProcessRefreshKind::nothing().with_memory(),
        );
    }

    SystemHealth {
        cpu_percent: system.global_cpu_usage(),
        cpu_count: system.cpus().len(),
        memory_used: system.used_memory(),
        memory_total: system.total_memory(),
        process_memory: pid
            .and_then(|pid| system.process(pid))
            .map(|process| process.memory())
            .unwrap_or(0),
    }
}

async fn join_workspace(state: &Shared, input: JoinRequest) -> ApiResult<AuthResponse> {
    let display_name = input.display_name.trim();
    if display_name.is_empty() {
        return Err(ApiError::bad_request("a display name is required"));
    }

    let invite = state
        .store
        .claim_invite(input.invite_code.trim(), "pending")
        .map_err(|e| {
            ApiError::new(
                axum::http::StatusCode::FORBIDDEN,
                "invalid_invite",
                e.to_string(),
            )
        })?;

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

const PAIRING_LIFETIME_MS: i64 = 5 * 60 * 1000;

async fn create_pairing(
    State(state): State<Shared>,
    caller: Caller,
    _input: Option<Json<CreatePairing>>,
) -> ApiResult<Json<PairingResponse>> {
    caller.require_device()?;
    let secret = auth::generate_token();
    let expires_at = now_ms() + PAIRING_LIFETIME_MS;
    state
        .store
        .insert_pairing(&auth::hash_token(&secret), &caller.member.id, expires_at)?;
    Ok(Json(PairingResponse {
        secret,
        expires_at,
        workspace_url: state.public_url.clone(),
    }))
}

async fn claim_pairing(
    State(state): State<Shared>,
    Json(input): Json<ClaimPairing>,
) -> ApiResult<Json<ClaimPairingResponse>> {
    let secret = input.secret.trim();
    if secret.is_empty() || secret.len() > 256 {
        return Err(ApiError::bad_request("invalid pairing secret"));
    }
    let label = input
        .device_name
        .as_deref()
        .map(str::trim)
        .filter(|label| !label.is_empty());
    if label.is_some_and(|label| label.chars().count() > 100) {
        return Err(ApiError::bad_request("device name is too long"));
    }

    let token = auth::generate_token();
    let member_id = state
        .store
        .claim_pairing(
            &auth::hash_token(secret),
            &auth::hash_token(&token),
            label,
            now_ms(),
        )?
        .ok_or_else(|| {
            ApiError::new(
                axum::http::StatusCode::FORBIDDEN,
                "invalid_pairing",
                "that pairing has expired or was already used",
            )
        })?;
    let member = state
        .store
        .member(&member_id)?
        .ok_or_else(|| ApiError::unauthorized("member is no longer active"))?;
    Ok(Json(ClaimPairingResponse {
        token,
        member,
        workspace: state.store.workspace()?,
    }))
}

async fn list_devices(State(state): State<Shared>, caller: Caller) -> ApiResult<Json<Vec<Device>>> {
    caller.require_device()?;
    Ok(Json(
        state.store.devices(&caller.member.id, &caller.token_hash)?,
    ))
}

async fn revoke_device(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    caller.require_device()?;
    if id == caller.token_hash {
        return Err(ApiError::conflict(
            "use /api/devices/current to sign out this device",
        ));
    }
    if !state.store.revoke_device(&caller.member.id, &id)? {
        return Err(ApiError::not_found("device not found"));
    }
    Ok(Json(Ok::default()))
}

async fn revoke_current_device(State(state): State<Shared>, caller: Caller) -> ApiResult<Json<Ok>> {
    caller.require_device()?;
    state
        .store
        .revoke_device(&caller.member.id, &caller.token_hash)?;
    Ok(Json(Ok::default()))
}

// ---------------------------------------------------------------------------
// bootstrap
// ---------------------------------------------------------------------------

async fn bootstrap(State(state): State<Shared>, caller: Caller) -> ApiResult<Json<Bootstrap>> {
    // This is the snapshot boundary. Every durable mutation after it has a
    // larger sequence number and will be replayed over the socket, including a
    // mutation that lands between two of the reads below. Reading the sequence
    // at the end can claim an event is already represented by an earlier read
    // (tasks in particular) and make the client discard that event.
    let seq = state.store.latest_seq()?;
    let members = state.members_with_presence().await?;
    let channels = visible_channels(&state, &caller)?;
    let visible_ids = channels
        .iter()
        .map(|channel| channel.id.clone())
        .collect::<HashSet<_>>();
    let active_runs = state
        .store
        .active_runs()?
        .into_iter()
        .filter(|run| visible_ids.contains(&run.channel_id))
        .collect();
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
        channels,
        skills: state.store.workspace_skills()?,
        projects: state.store.projects()?,
        hosts: state.hosts_with_presence().await?,
        tasks: state.store.tasks()?,
        inbox: state.store.inbox(&caller.member.id, false)?,
        automations: state
            .store
            .automations()?
            .into_iter()
            .filter(|automation| {
                crate::visibility::automation(&state.store, &caller.member.id, automation)
                    .unwrap_or(false)
            })
            .collect(),
        open_questions: state
            .store
            .open_questions()?
            .into_iter()
            .filter(|question| visible_ids.contains(&question.channel_id))
            .collect(),
        active_runs,
        previews: state.store.previews(true)?,
        seq,
    }))
}

/// Channels and task discussions belong to the workspace — a board everyone can
/// see would be useless if its conversations were private. Only DMs are.
fn require_channel_access(state: &Shared, caller: &Caller, channel_id: &str) -> ApiResult<()> {
    if crate::visibility::channel(&state.store, &caller.member.id, channel_id)? {
        Ok(())
    } else {
        Err(ApiError::forbidden(
            "that belongs to a private conversation",
        ))
    }
}

fn require_run_access(state: &Shared, caller: &Caller, run: &Run) -> ApiResult<()> {
    require_channel_access(state, caller, &run.channel_id)
}

fn require_automation_access(
    state: &Shared,
    caller: &Caller,
    automation: &Automation,
) -> ApiResult<()> {
    if crate::visibility::automation(&state.store, &caller.member.id, automation)? {
        Ok(())
    } else {
        Err(ApiError::forbidden(
            "that automation belongs to a private conversation",
        ))
    }
}

fn require_attachment_access(
    state: &Shared,
    caller: &Caller,
    attachment: &Attachment,
) -> ApiResult<()> {
    if let Some(message_id) = &attachment.message_id {
        let message = state
            .store
            .message(message_id)?
            .ok_or_else(|| ApiError::not_found("message not found"))?;
        return require_channel_access(state, caller, &message.channel_id);
    }
    if let Some(run_id) = &attachment.run_id {
        let run = state
            .store
            .run(run_id)?
            .ok_or_else(|| ApiError::not_found("run not found"))?;
        return require_run_access(state, caller, &run);
    }
    Ok(())
}

fn visible_channels(state: &Shared, caller: &Caller) -> ApiResult<Vec<Channel>> {
    let channels = state.store.channels()?;
    Ok(channels
        .into_iter()
        .filter(|c| match c.kind {
            ChannelKind::Channel | ChannelKind::Task => true,
            ChannelKind::Dm => c.member_ids.contains(&caller.member.id),
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
    caller: Caller,
    Query(query): Query<SinceQuery>,
) -> ApiResult<Json<Vec<patchwork_core::events::Envelope>>> {
    Ok(Json(
        state
            .store
            .events_since(query.since, 500)?
            .into_iter()
            .filter(|envelope| crate::visibility::event(&state.store, &caller.member.id, envelope))
            .collect(),
    ))
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
        // A section keeps the name it was given; shouting is not our decision.
        name: input.name.trim().to_string(),
        position: state.store.sections()?.len() as f64,
    };
    state.store.upsert_section(&section)?;
    state.emit(Event::SectionsUpdated {
        sections: state.store.sections()?,
    });
    Ok(Json(section))
}

async fn list_channels(
    State(state): State<Shared>,
    caller: Caller,
) -> ApiResult<Json<Vec<Channel>>> {
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
        return Err(ApiError::conflict(
            "a channel with that name already exists",
        ));
    }

    let section_id = match (&input.section_id, &input.section_name) {
        (Some(id), _) => Some(id.clone()),
        (None, Some(name)) if !name.trim().is_empty() => {
            match state.store.section_by_name(name)? {
                Some(section) => Some(section.id),
                None => {
                    let section = Section {
                        id: new_id(),
                        name: name.trim().to_string(),
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
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<UpdateChannel>,
) -> ApiResult<Json<Channel>> {
    require_channel_access(&state, &caller, &id)?;
    let mut channel = state
        .store
        .channel(&id)?
        .ok_or_else(|| ApiError::not_found("channel not found"))?;
    if channel.kind != ChannelKind::Channel {
        return Err(ApiError::forbidden("only workspace channels can be edited"));
    }
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
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    require_channel_access(&state, &caller, &id)?;
    let channel = state
        .store
        .channel(&id)?
        .ok_or_else(|| ApiError::not_found("channel not found"))?;
    if channel.kind != ChannelKind::Channel {
        return Err(ApiError::forbidden(
            "only workspace channels can be archived",
        ));
    }
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
        .members()?
        .into_iter()
        .find(|member| member.id == input.member_id)
        .ok_or_else(|| ApiError::not_found("no such active member"))?;

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
    caller: Caller,
    Path(id): Path<Id>,
    Query(query): Query<MessageQuery>,
) -> ApiResult<Json<MessagePage>> {
    require_channel_access(&state, &caller, &id)?;
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
    require_channel_access(&state, &caller, &id)?;
    if input.parent_id.is_some() && input.reply_to_id.is_some() {
        return Err(ApiError::bad_request(
            "a message cannot be both an inline reply and a thread reply",
        ));
    }
    if let Some(reply_to_id) = &input.reply_to_id {
        let source = state
            .store
            .message(reply_to_id)?
            .ok_or_else(|| ApiError::bad_request("reply target not found"))?;
        if source.channel_id != id {
            return Err(ApiError::bad_request(
                "reply target belongs to another conversation",
            ));
        }
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
    require_channel_access(&state, &caller, &message.channel_id)?;
    if state.store.task_by_source_message(&id)?.is_some() {
        return Err(ApiError::forbidden(
            "the original task request is preserved",
        ));
    }
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
    require_channel_access(&state, &caller, &message.channel_id)?;
    if state.store.task_by_source_message(&id)?.is_some() {
        return Err(ApiError::forbidden(
            "the original task request is preserved",
        ));
    }
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
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Vec<Message>>> {
    let root = state
        .store
        .message(&id)?
        .ok_or_else(|| ApiError::not_found("message not found"))?;
    require_channel_access(&state, &caller, &root.channel_id)?;
    Ok(Json(state.store.thread(&id)?))
}

async fn react(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<ReactionRequest>,
) -> ApiResult<Json<Message>> {
    let existing = state
        .store
        .message(&id)?
        .ok_or_else(|| ApiError::not_found("message not found"))?;
    require_channel_access(&state, &caller, &existing.channel_id)?;
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
    if caller.is_agent() && input.status == Some(TaskStatus::Review) {
        return Err(ApiError::bad_request(
            "an agent cannot create a task in review without review evidence",
        ));
    }
    if let Some(channel_id) = &input.source_channel_id {
        require_channel_access(&state, &caller, channel_id)?;
    }
    if let Some(message_id) = &input.source_message_id {
        let message = state
            .store
            .message(message_id)?
            .ok_or_else(|| ApiError::not_found("source message not found"))?;
        require_channel_access(&state, &caller, &message.channel_id)?;
    }
    let exact_once_match = input
        .once_key
        .as_deref()
        .filter(|key| !key.trim().is_empty())
        .map(|key| state.store.task_by_once_key(key.trim()))
        .transpose()?
        .flatten()
        .is_some();
    if caller.is_agent() && !input.allow_similar && !exact_once_match {
        if let Some(existing) = orchestrator::similar_task(
            &state,
            &input.title,
            &input.outcome,
            input.project_id.as_deref(),
        )? {
            return Err(ApiError::new(
                axum::http::StatusCode::CONFLICT,
                "similar_task",
                format!(
                    "possible duplicate {}: \"{}\". Continue that task if this is the same incident; otherwise rerun with --allow-similar",
                    existing.key, existing.title
                ),
            ));
        }
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

fn reopens_terminal(from: TaskStatus, to: Option<TaskStatus>) -> bool {
    from.is_terminal() && to.is_some_and(|status| !status.is_terminal())
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
    if let Some(action) = input.review_action.as_deref() {
        let action = action.trim();
        if action.chars().any(char::is_control) || action.chars().count() > 80 {
            return Err(ApiError::bad_request(
                "a review action must be one line of at most 80 characters",
            ));
        }
        let resulting_status = input.status.unwrap_or(task.status);
        if !action.is_empty() && resulting_status != TaskStatus::Review {
            return Err(ApiError::bad_request(
                "a review action can only be set while the task is in review",
            ));
        }
    }
    if caller.is_agent() && reopens_terminal(task.status, input.status) {
        return Err(ApiError::bad_request(
            "only a person can reopen a completed or canceled task",
        ));
    }
    if caller.is_agent() && input.status == Some(TaskStatus::Review) {
        if !orchestrator::has_review_evidence(
            &state,
            &task,
            &orchestrator::evidence_run_ids(&state, &task, caller.run_id.as_deref())?,
            input.pr_url.as_deref(),
        )? {
            return Err(ApiError::bad_request(
                "review needs evidence from this run: answer the original question, attach a file, expose a preview, or link a pull request; otherwise leave the task planned or blocked",
            ));
        }
    }
    Ok(Json(
        orchestrator::update_task(
            &state,
            &caller.member.id,
            caller.is_agent(),
            &task.id,
            input,
        )
        .await?,
    ))
}

async fn delete_task(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    caller.require_admin()?;
    let task = state
        .store
        .task_by_ref(&id)?
        .ok_or_else(|| ApiError::not_found("task not found"))?;
    for preview in state.store.task_previews(&task.id)? {
        if matches!(
            preview.status,
            PreviewStatus::Starting | PreviewStatus::Live
        ) {
            state
                .send_to_host(
                    &preview.host_id,
                    RelayToHost::StopPreview {
                        preview_id: preview.id,
                    },
                )
                .await;
        }
    }
    let pending_files = {
        let mut uploads = state.uploads.lock().await;
        let mut files = Vec::new();
        uploads.retain(|_, upload| {
            let keep = upload.task_id.as_deref() != Some(&task.id);
            if !keep {
                files.push(upload.path.clone());
            }
            keep
        });
        files
    };
    let files = state.store.delete_task(&task.id)?;
    for path in files
        .into_iter()
        .map(std::path::PathBuf::from)
        .chain(pending_files)
    {
        let _ = tokio::fs::remove_file(path).await;
    }
    state.emit(Event::TaskDeleted { task_id: task.id });
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

async fn approve_task(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Run>> {
    caller.require_device()?;
    let task = state
        .store
        .task_by_ref(&id)?
        .ok_or_else(|| ApiError::not_found("task not found"))?;
    if task.status != TaskStatus::Review || task.review_action.is_none() {
        return Err(ApiError::conflict(
            "this task no longer has an action awaiting approval",
        ));
    }
    // Approving starts another run in the task's worktree. While an agent is
    // still working in there, waiting is the honest answer.
    if task.current_run_id.is_some() {
        return Err(ApiError::conflict(
            "an agent is still working on this task; approve once it stops",
        ));
    }
    let run = orchestrator::approve_task(&state, &caller.member.id, &task.id)
        .await?
        .ok_or_else(|| ApiError::conflict("this review action was already handled"))?;
    Ok(Json(run))
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
    require_channel_access(&state, &caller, &channel_id)?;

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
            required_task_status: None,
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
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<RunDetail>> {
    let run = state
        .store
        .run(&id)?
        .ok_or_else(|| ApiError::not_found("run not found"))?;
    require_run_access(&state, &caller, &run)?;
    Ok(Json(RunDetail {
        events: state.store.run_events(&id, 0)?,
        questions: state.store.run_questions(&id)?,
        run,
    }))
}

async fn run_events(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Query(query): Query<AfterQuery>,
) -> ApiResult<Json<Vec<RunEvent>>> {
    let run = state
        .store
        .run(&id)?
        .ok_or_else(|| ApiError::not_found("run not found"))?;
    require_run_access(&state, &caller, &run)?;
    Ok(Json(state.store.run_events(&id, query.after)?))
}

async fn steer_run(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<SteerRun>,
) -> ApiResult<Json<SteerRunResponse>> {
    let target = state
        .store
        .run(&id)?
        .ok_or_else(|| ApiError::not_found("run not found"))?;
    require_run_access(&state, &caller, &target)?;
    for attachment_id in &input.attachment_ids {
        let attachment = state
            .store
            .attachment(attachment_id)?
            .map(|(attachment, _)| attachment)
            .ok_or_else(|| ApiError::not_found("attachment not found"))?;
        require_attachment_access(&state, &caller, &attachment)?;
        if attachment.message_id.is_some() {
            return Err(ApiError::conflict("that attachment was already sent"));
        }
    }
    if caller.is_agent() && input.mode == patchwork_core::host::RunControlMode::Interrupt {
        return Err(ApiError::forbidden(
            "agents may queue messages, not interrupt another run",
        ));
    }
    let control_id = orchestrator::steer_run(
        &state,
        &caller.member.id,
        caller.run_id.as_deref(),
        &id,
        input,
    )
    .await?;
    Ok(Json(SteerRunResponse { control_id }))
}

async fn cancel_run(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    caller.require_device()?;
    let run = state
        .store
        .run(&id)?
        .ok_or_else(|| ApiError::not_found("run not found"))?;
    require_run_access(&state, &caller, &run)?;
    if run.status.is_terminal() {
        return Ok(Json(Ok::default()));
    }
    if let Some(host_id) = &run.host_id {
        state
            .send_to_host(host_id, RelayToHost::CancelRun { run_id: id.clone() })
            .await;
    }

    // Stop is durable immediately. A host acknowledgement may never arrive.
    let mut run = run;
    run.status = RunStatus::Cancelled;
    run.headline = "Cancelled".into();
    run.ended_at = Some(now_ms());
    state.store.revoke_run_tokens(&run.id).ok();
    state.store.update_run(&run)?;
    state.emit(Event::RunUpdated { run: run.clone() });
    orchestrator::cancel_questions_for_run(&state, &run.id).await?;
    state.set_presence(&run.agent_id, Presence::Online).await;
    orchestrator::finish_run(&state, &run).await?;
    Ok(Json(Ok::default()))
}

// ---------------------------------------------------------------------------
// questions
// ---------------------------------------------------------------------------

async fn list_questions(
    State(state): State<Shared>,
    caller: Caller,
) -> ApiResult<Json<Vec<Question>>> {
    Ok(Json(
        state
            .store
            .open_questions()?
            .into_iter()
            .filter(|question| {
                crate::visibility::channel(&state.store, &caller.member.id, &question.channel_id)
                    .unwrap_or(false)
            })
            .collect(),
    ))
}

async fn get_question(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Question>> {
    let question = state
        .store
        .question(&id)?
        .ok_or_else(|| ApiError::not_found("question not found"))?;
    require_channel_access(&state, &caller, &question.channel_id)?;
    Ok(Json(question))
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
    require_run_access(&state, &caller, &run)?;
    if !caller.is_agent()
        || caller.member.id != run.agent_id
        || caller.run_id.as_deref() != Some(run.id.as_str())
    {
        return Err(ApiError::forbidden("only this run's agent can ask"));
    }
    if run.status.is_terminal() {
        return Err(ApiError::conflict("that run has already ended"));
    }

    let mut question = Question {
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
    orchestrator::finish_streamed_reply(&state, &run.id).await?;

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
    question.message_id = Some(message.id.clone());

    // The run is visibly waiting, and the people who can answer are told.
    let mut run = run;
    run.status = RunStatus::Waiting;
    run.headline = if question.headline.is_empty() {
        "Waiting for an answer".into()
    } else {
        question.headline.clone()
    };

    let agent_name = state
        .store
        .member(&run.agent_id)?
        .map(|m| m.display_name)
        .unwrap_or_else(|| "An agent".into());
    let mut inbox_items = Vec::new();
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
        inbox_items.push(item);
    }

    // Nothing is answerable until the card, waiting run and every Inbox row
    // are durable. A concurrent Stop wins without leaving an open question.
    let (committed, blocked_task) =
        state
            .store
            .commit_question_waiting(&question, &run, &inbox_items)?;
    if !committed {
        state.store.delete_message(&message.id)?;
        state.emit(Event::MessageDeleted {
            channel_id: run.channel_id.clone(),
            message_id: message.id,
        });
        return Err(ApiError::conflict("that run has already ended"));
    }
    state.emit(Event::RunUpdated { run: run.clone() });
    if let Some(task) = blocked_task {
        state.emit(Event::TaskUpdated { task });
    }
    state.set_presence(&run.agent_id, Presence::Waiting).await;
    for item in inbox_items {
        state.emit(Event::InboxItemCreated { item });
    }
    if let Some(host_id) = &run.host_id {
        state
            .send_to_host(
                host_id,
                RelayToHost::QuestionAsked {
                    run_id: run.id.clone(),
                },
            )
            .await;
    }
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
    caller.require_device()?;
    let question = state
        .store
        .question(&id)?
        .ok_or_else(|| ApiError::not_found("question not found"))?;
    require_channel_access(&state, &caller, &question.channel_id)?;
    if question.status != QuestionStatus::Open {
        return Err(ApiError::conflict(
            "that question is no longer waiting for an answer",
        ));
    }
    Ok(Json(
        orchestrator::answer_question(&state, &id, input.answers, &caller.member.id).await?,
    ))
}

/// The agent side of `patchwork ask`: hold the connection until a human
/// answers, so the run genuinely continues in context.
async fn wait_for_answer(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Question>> {
    let question = state
        .store
        .question(&id)?
        .ok_or_else(|| ApiError::not_found("question not found"))?;
    require_channel_access(&state, &caller, &question.channel_id)?;
    if !caller.is_agent()
        || caller.member.id != question.agent_id
        || caller.run_id.as_deref() != Some(question.run_id.as_str())
    {
        return Err(ApiError::forbidden(
            "only the asking run can wait for this answer",
        ));
    }
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
        _ => {
            Ok(Json(state.store.question(&id)?.ok_or_else(|| {
                ApiError::not_found("question not found")
            })?))
        }
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
    let item = state
        .store
        .inbox_item(&id)?
        .filter(|item| item.member_id == caller.member.id)
        .ok_or_else(|| ApiError::not_found("inbox item not found"))?;
    state.store.mark_inbox_read(&id, &caller.member.id)?;
    let item = state.store.inbox_item(&id)?.unwrap_or(item);
    state.emit(Event::InboxItemUpdated { item });
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
    caller: Caller,
    Json(input): Json<CreateAgent>,
) -> ApiResult<Json<Member>> {
    if input.display_name.trim().is_empty() {
        return Err(ApiError::bad_request("an agent needs a name"));
    }
    if input.is_admin {
        caller.require_admin()?;
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
        is_admin: input.is_admin,
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
    caller: Caller,
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
    if let Some(is_admin) = input.is_admin {
        if is_admin != member.is_admin {
            caller.require_admin()?;
            member.is_admin = is_admin;
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
// workspace skills
// ---------------------------------------------------------------------------

const MAX_SKILL_NAME_BYTES: usize = 100;
const MAX_SKILL_DESCRIPTION_BYTES: usize = 500;
const MAX_SKILL_INSTRUCTIONS_BYTES: usize = 32 * 1024;
const MAX_WORKSPACE_SKILLS_BYTES: usize = 64 * 1024;

fn validated_skill(input: UpsertWorkspaceSkill) -> ApiResult<(String, String, String)> {
    let name = input.name.trim().to_string();
    let description = input.description.trim().to_string();
    let instructions = input.instructions.trim().to_string();
    if name.is_empty() {
        return Err(ApiError::bad_request("a skill needs a name"));
    }
    if name.contains('\n') || name.contains('\r') {
        return Err(ApiError::bad_request("the skill name must be one line"));
    }
    if instructions.is_empty() {
        return Err(ApiError::bad_request("a skill needs instructions"));
    }
    if name.len() > MAX_SKILL_NAME_BYTES {
        return Err(ApiError::bad_request("the skill name is too long"));
    }
    if description.len() > MAX_SKILL_DESCRIPTION_BYTES {
        return Err(ApiError::bad_request("the skill description is too long"));
    }
    if instructions.len() > MAX_SKILL_INSTRUCTIONS_BYTES {
        return Err(ApiError::bad_request("the skill instructions are too long"));
    }
    Ok((name, description, instructions))
}

fn save_skill(
    state: &Shared,
    skill: WorkspaceSkill,
    must_exist: bool,
) -> ApiResult<WorkspaceSkill> {
    match state
        .store
        .save_workspace_skill(skill, must_exist, MAX_WORKSPACE_SKILLS_BYTES)?
    {
        SaveWorkspaceSkillResult::Saved(skill) => Ok(skill),
        SaveWorkspaceSkillResult::Missing => Err(ApiError::not_found("no such skill")),
        SaveWorkspaceSkillResult::TooLarge => Err(ApiError::bad_request(
            "workspace skills are limited to 64 KB in total",
        )),
    }
}

fn emit_skills(state: &Shared) -> ApiResult<()> {
    state.emit(Event::WorkspaceSkillsUpdated {
        skills: state.store.workspace_skills()?,
    });
    Ok(())
}

async fn list_skills(
    State(state): State<Shared>,
    _caller: Caller,
) -> ApiResult<Json<Vec<WorkspaceSkill>>> {
    Ok(Json(state.store.workspace_skills()?))
}

async fn create_skill(
    State(state): State<Shared>,
    _caller: Caller,
    Json(input): Json<UpsertWorkspaceSkill>,
) -> ApiResult<Json<WorkspaceSkill>> {
    let (name, description, instructions) = validated_skill(input)?;
    let now = now_ms();
    let skill = save_skill(
        &state,
        WorkspaceSkill {
            id: new_id(),
            name,
            description,
            instructions,
            created_at: now,
            updated_at: now,
        },
        false,
    )?;
    emit_skills(&state)?;
    Ok(Json(skill))
}

async fn update_skill(
    State(state): State<Shared>,
    _caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<UpsertWorkspaceSkill>,
) -> ApiResult<Json<WorkspaceSkill>> {
    let (name, description, instructions) = validated_skill(input)?;
    let now = now_ms();
    let skill = save_skill(
        &state,
        WorkspaceSkill {
            id,
            name,
            description,
            instructions,
            created_at: now,
            updated_at: now,
        },
        true,
    )?;
    emit_skills(&state)?;
    Ok(Json(skill))
}

async fn delete_skill(
    State(state): State<Shared>,
    _caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    if !state.store.delete_workspace_skill(&id)? {
        return Err(ApiError::not_found("no such skill"));
    }
    emit_skills(&state)?;
    Ok(Json(Ok::default()))
}

// ---------------------------------------------------------------------------
// projects and hosts
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct UpdateSystemSkillInput {
    path: String,
    previous_content: String,
    content: String,
}

async fn update_system_skill(
    State(state): State<Shared>,
    caller: Caller,
    Path(host_id): Path<Id>,
    Json(input): Json<UpdateSystemSkillInput>,
) -> ApiResult<Json<SystemSkill>> {
    const MAX_SYSTEM_SKILL_BYTES: usize = 256 * 1024;
    caller.require_device()?;
    caller.require_admin()?;
    if input.content.len() > MAX_SYSTEM_SKILL_BYTES {
        return Err(ApiError::bad_request("system skills are limited to 256 KB"));
    }
    if input.content.trim().is_empty() {
        return Err(ApiError::bad_request("a system skill cannot be empty"));
    }
    let host = state
        .store
        .host(&host_id)?
        .ok_or_else(|| ApiError::not_found("no such execution machine"))?;
    if !host
        .capabilities
        .system_skills
        .iter()
        .any(|skill| skill.path == input.path)
    {
        return Err(ApiError::not_found("no such system skill on that machine"));
    }

    let request_id = new_id();
    let (reply, wait) = tokio::sync::oneshot::channel();
    state.system_skill_waiters.write().await.insert(
        request_id.clone(),
        crate::state::SystemSkillWaiter {
            host_id: host_id.clone(),
            reply,
        },
    );
    if !state
        .send_to_host(
            &host_id,
            RelayToHost::UpdateSystemSkill {
                request_id: request_id.clone(),
                path: input.path,
                previous_content: input.previous_content,
                content: input.content,
            },
        )
        .await
    {
        state.system_skill_waiters.write().await.remove(&request_id);
        return Err(ApiError::conflict("that execution machine is offline"));
    }

    match tokio::time::timeout(std::time::Duration::from_secs(15), wait).await {
        Ok(Ok(Ok(skill))) => Ok(Json(skill)),
        Ok(Ok(Err(error))) => Err(ApiError::conflict(error)),
        Ok(Err(_)) => Err(ApiError::conflict("the execution machine disconnected")),
        Err(_) => {
            state.system_skill_waiters.write().await.remove(&request_id);
            Err(ApiError::conflict("the execution machine did not answer"))
        }
    }
}

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
        repo_url: input.repo_url.clone(),
        default_branch: input
            .default_branch
            .clone()
            .unwrap_or_else(|| "main".into()),
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
    caller: Caller,
) -> ApiResult<Json<Vec<Automation>>> {
    Ok(Json(
        state
            .store
            .automations()?
            .into_iter()
            .filter(|automation| {
                crate::visibility::automation(&state.store, &caller.member.id, automation)
                    .unwrap_or(false)
            })
            .collect(),
    ))
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
    require_automation_access(&state, &caller, &automation)?;
    state.store.upsert_automation(&automation)?;
    state.emit(Event::AutomationUpdated {
        automation: automation.clone(),
    });
    Ok(Json(automation))
}

async fn update_automation(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<CreateAutomation>,
) -> ApiResult<Json<Automation>> {
    let mut automation = state
        .store
        .automation(&id)?
        .ok_or_else(|| ApiError::not_found("automation not found"))?;
    require_automation_access(&state, &caller, &automation)?;
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
    require_automation_access(&state, &caller, &automation)?;
    state.store.upsert_automation(&automation)?;
    state.emit(Event::AutomationUpdated {
        automation: automation.clone(),
    });
    Ok(Json(automation))
}

async fn delete_automation(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    let automation = state
        .store
        .automation(&id)?
        .ok_or_else(|| ApiError::not_found("automation not found"))?;
    require_automation_access(&state, &caller, &automation)?;
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
    require_automation_access(&state, &caller, &automation)?;
    Ok(Json(
        automations::run_now(&state, &automation, &caller.member.display_name).await?,
    ))
}

async fn automation_debug(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<AutomationDebug>> {
    let automation = state
        .store
        .automation(&id)?
        .ok_or_else(|| ApiError::not_found("automation not found"))?;
    require_automation_access(&state, &caller, &automation)?;
    Ok(Json(AutomationDebug {
        runs: state.store.automation_runs(&id, 50)?,
        automation,
    }))
}

/// `?once=` is the sender's own name for the event. Deliveries are retried by
/// everything that sends them, and a retry should not buy a second task.
#[derive(Deserialize)]
struct WebhookQuery {
    #[serde(default)]
    once: Option<String>,
}

async fn webhook(
    State(state): State<Shared>,
    Path(token): Path<String>,
    Query(query): Query<WebhookQuery>,
    body: Option<Json<serde_json::Value>>,
) -> ApiResult<Json<Ok>> {
    let payload = body.map(|Json(v)| v).unwrap_or(serde_json::json!({}));
    let fired = automations::on_webhook(&state, &token, payload, query.once).await?;
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
    if input.command.is_none() && input.port.is_none() {
        return Err(ApiError::bad_request(
            "pass --port for a server that is already running, or --command to start one",
        ));
    }
    let command = input.command.clone();
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
        .or_else(|| input.command.is_none().then(String::new))
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
        local_only: false,
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
        let mut failed = preview;
        failed.status = PreviewStatus::Failed;
        failed.stopped_at = Some(now_ms());
        state.store.upsert_preview(&failed)?;
        state.emit(Event::PreviewUpdated { preview: failed });
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
    if !state
        .send_to_host(
            &preview.host_id,
            RelayToHost::StopPreview {
                preview_id: preview.id.clone(),
            },
        )
        .await
    {
        let mut stopped = preview;
        stopped.status = PreviewStatus::Stopped;
        stopped.stopped_at = Some(now_ms());
        state.store.upsert_preview(&stopped)?;
        state.emit(Event::PreviewUpdated { preview: stopped });
    }
    Ok(Json(Ok::default()))
}

#[derive(Serialize)]
struct GrantedUrl {
    url: String,
}

async fn grant_preview(
    State(state): State<Shared>,
    _caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<GrantedUrl>> {
    let preview = state
        .store
        .preview(&id)?
        .ok_or_else(|| ApiError::not_found("preview not found"))?;
    if preview.status != PreviewStatus::Live {
        return Err(ApiError::bad_request("preview is not live"));
    }
    let grant = state.grant_preview(&preview.id);
    Ok(Json(GrantedUrl {
        url: state.preview_url(&preview.id, &grant),
    }))
}

// ---------------------------------------------------------------------------
// files
// ---------------------------------------------------------------------------

const UPLOAD_CHUNK_SIZE: usize = 8 * 1024 * 1024;
const MAX_UPLOAD_SIZE: i64 = 512 * 1024 * 1024;
const UPLOAD_TTL: i64 = 24 * 60 * 60 * 1000;
const MAX_PENDING_UPLOADS: usize = 4;

async fn create_upload(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<CreateUpload>,
) -> ApiResult<Json<UploadSession>> {
    if input.file_name.trim().is_empty() || input.size < 0 || input.size > MAX_UPLOAD_SIZE {
        return Err(ApiError::bad_request(
            "a file needs a name and must be no larger than 512 MB",
        ));
    }
    let task_id = match input.task_id {
        Some(reference) => Some(
            state
                .store
                .task_by_ref(&reference)?
                .ok_or_else(|| ApiError::not_found("task not found"))?
                .id,
        ),
        None => None,
    };
    let now = now_ms();
    let mut stale = Vec::new();
    let too_many = {
        let mut uploads = state.uploads.lock().await;
        uploads.retain(|_, upload| {
            let keep = upload.created_at + UPLOAD_TTL > now;
            if !keep {
                stale.push(upload.path.clone());
            }
            keep
        });
        uploads
            .values()
            .filter(|upload| upload.member_id == caller.member.id)
            .count()
            >= MAX_PENDING_UPLOADS
    };
    for path in stale {
        let _ = tokio::fs::remove_file(path).await;
    }
    if too_many {
        return Err(ApiError::conflict("finish or wait for an existing upload"));
    }

    let id = new_id();
    let upload_dir = state.files_dir.join(".uploads");
    tokio::fs::create_dir_all(&upload_dir)
        .await
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let path = upload_dir.join(&id);
    tokio::fs::File::create(&path)
        .await
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let mime = if input.mime.trim().is_empty() {
        mime_guess::from_path(&input.file_name)
            .first_or_octet_stream()
            .to_string()
    } else {
        input.mime
    };
    let pending = crate::state::PendingUpload {
        id: id.clone(),
        member_id: caller.member.id,
        run_id: caller.run_id,
        task_id,
        file_name: input.file_name,
        mime,
        caption: input.caption,
        size: input.size,
        received: 0,
        created_at: now_ms(),
        path: path.clone(),
    };
    let mut uploads = state.uploads.lock().await;
    if uploads
        .values()
        .filter(|upload| upload.member_id == pending.member_id)
        .count()
        >= MAX_PENDING_UPLOADS
    {
        drop(uploads);
        let _ = tokio::fs::remove_file(path).await;
        return Err(ApiError::conflict("finish or wait for an existing upload"));
    }
    uploads.insert(id.clone(), pending);
    Ok(Json(UploadSession {
        id,
        chunk_size: UPLOAD_CHUNK_SIZE,
    }))
}

#[derive(Deserialize, Default)]
struct UploadQuery {
    #[serde(default)]
    offset: i64,
}

async fn upload_chunk(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Query(query): Query<UploadQuery>,
    body: axum::body::Bytes,
) -> ApiResult<Json<Ok>> {
    use tokio::io::AsyncWriteExt;

    if body.len() > UPLOAD_CHUNK_SIZE {
        return Err(ApiError::bad_request("upload chunk exceeds 8 MB"));
    }
    let mut uploads = state.uploads.lock().await;
    let upload = uploads
        .get_mut(&id)
        .ok_or_else(|| ApiError::not_found("upload not found"))?;
    if upload.member_id != caller.member.id {
        return Err(ApiError::forbidden("this upload belongs to another member"));
    }
    if query.offset != upload.received {
        return Err(ApiError::conflict(format!(
            "expected upload offset {}, not {}",
            upload.received, query.offset
        )));
    }
    if upload.received + body.len() as i64 > upload.size {
        return Err(ApiError::bad_request("upload exceeds its declared size"));
    }
    let mut file = tokio::fs::OpenOptions::new()
        .append(true)
        .open(&upload.path)
        .await
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    file.write_all(&body)
        .await
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    upload.received += body.len() as i64;
    Ok(Json(Ok::default()))
}

async fn complete_upload(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Attachment>> {
    let mut uploads = state.uploads.lock().await;
    let upload = uploads
        .get(&id)
        .ok_or_else(|| ApiError::not_found("upload not found"))?;
    if upload.member_id != caller.member.id {
        return Err(ApiError::forbidden("this upload belongs to another member"));
    }
    if upload.received != upload.size {
        return Err(ApiError::conflict(format!(
            "upload has {} of {} bytes",
            upload.received, upload.size
        )));
    }
    let upload = uploads.remove(&id).unwrap();
    drop(uploads);

    let path = state.files_dir.join(&upload.id);
    tokio::fs::rename(&upload.path, &path)
        .await
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let attachment = Attachment {
        id: upload.id,
        file_name: upload.file_name,
        mime: upload.mime,
        size: upload.size,
        caption: upload.caption,
        url: format!("/api/files/{id}"),
        message_id: None,
        task_id: upload.task_id,
        run_id: upload.run_id,
        created_at: upload.created_at,
    };
    state
        .store
        .insert_attachment(&attachment, &path.to_string_lossy())?;
    Ok(Json(attachment))
}

async fn upload_file(
    State(state): State<Shared>,
    caller: Caller,
    mut multipart: Multipart,
) -> ApiResult<Json<Attachment>> {
    let mut task_id: Option<Id> = None;
    let mut caption = String::new();
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
            "caption" => caption = field.text().await.unwrap_or_default(),
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
                    caption: String::new(),
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
    attachment.caption = caption;
    let path = state.files_dir.join(&attachment.id);
    state
        .store
        .insert_attachment(&attachment, &path.to_string_lossy())?;
    Ok(Json(attachment))
}

async fn grant_file(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<GrantedUrl>> {
    let (attachment, _) = state
        .store
        .attachment(&id)?
        .ok_or_else(|| ApiError::not_found("file not found"))?;
    require_attachment_access(&state, &caller, &attachment)?;
    Ok(Json(GrantedUrl {
        url: state.grant_file(&attachment),
    }))
}

async fn remove_file_evidence(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Attachment>> {
    let (attachment, _) = state
        .store
        .attachment(&id)?
        .ok_or_else(|| ApiError::not_found("file not found"))?;
    require_attachment_access(&state, &caller, &attachment)?;
    let task_id = attachment
        .task_id
        .as_deref()
        .ok_or_else(|| ApiError::conflict("that file is not task evidence"))?;
    if caller.is_agent() {
        let run_id = caller
            .run_id
            .as_deref()
            .ok_or_else(|| ApiError::forbidden("evidence can only be changed from a task run"))?;
        let run = state
            .store
            .run(run_id)?
            .ok_or_else(|| ApiError::forbidden("evidence can only be changed from a task run"))?;
        if run.task_id.as_deref() != Some(task_id) {
            return Err(ApiError::forbidden(
                "an agent can only change evidence on its current task",
            ));
        }
    }
    if !state.store.remove_task_attachment(&id, task_id)? {
        return Err(ApiError::conflict("that file is no longer task evidence"));
    }
    Ok(Json(attachment))
}

#[derive(Deserialize, Default)]
struct FileQuery {
    #[serde(default)]
    grant: Option<String>,
}

async fn download_file(
    State(state): State<Shared>,
    Path(id): Path<Id>,
    Query(query): Query<FileQuery>,
    headers: axum::http::HeaderMap,
) -> ApiResult<axum::response::Response> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let member = bearer(&headers)
        .ok()
        .and_then(|token| auth::authenticate(&state, &token));
    let granted = query
        .grant
        .as_deref()
        .is_some_and(|token| state.valid_file_grant(&id, token));
    if member.is_none() && !granted {
        return Err(ApiError::unauthorized(
            "a valid file grant or workspace token is required",
        ));
    }
    let (attachment, path) = state
        .store
        .attachment(&id)?
        .ok_or_else(|| ApiError::not_found("file not found"))?;
    if let Some(caller) = &member {
        require_attachment_access(&state, caller, &attachment)?;
    }
    let size = attachment.size.max(0) as u64;
    let requested_range = headers
        .get(axum::http::header::RANGE)
        .and_then(|value| value.to_str().ok());
    let range = requested_range.and_then(|value| byte_range(value, size));
    if requested_range.is_some() && range.is_none() {
        return Ok(axum::response::Response::builder()
            .status(axum::http::StatusCode::RANGE_NOT_SATISFIABLE)
            .header(axum::http::header::CONTENT_RANGE, format!("bytes */{size}"))
            .body(axum::body::Body::empty())
            .map_err(|error| ApiError::bad_request(error.to_string()))?);
    }
    let (start, end, status) = range
        .map(|(start, end)| (start, end, axum::http::StatusCode::PARTIAL_CONTENT))
        .unwrap_or((0, size.saturating_sub(1), axum::http::StatusCode::OK));
    let length = if size == 0 { 0 } else { end - start + 1 };
    let mut file = tokio::fs::File::open(&path)
        .await
        .map_err(|_| ApiError::not_found("file is no longer on disk"))?;
    file.seek(std::io::SeekFrom::Start(start))
        .await
        .map_err(|_| ApiError::not_found("file is no longer on disk"))?;
    let mut bytes = vec![0; length as usize];
    file.read_exact(&mut bytes)
        .await
        .map_err(|_| ApiError::not_found("file is no longer on disk"))?;

    let mut response = axum::response::Response::builder()
        .status(status)
        .header(axum::http::header::CONTENT_TYPE, attachment.mime)
        .header(axum::http::header::ACCEPT_RANGES, "bytes")
        .header(axum::http::header::CONTENT_LENGTH, length)
        .header(
            axum::http::header::CONTENT_DISPOSITION,
            format!(
                "inline; filename=\"{}\"",
                attachment.file_name.replace('"', "")
            ),
        );
    if status == axum::http::StatusCode::PARTIAL_CONTENT {
        response = response.header(
            axum::http::header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{size}"),
        );
    }
    Ok(response
        .body(axum::body::Body::from(bytes))
        .map_err(|error| ApiError::bad_request(error.to_string()))?)
}

const DOWNLOAD_CHUNK_SIZE: u64 = 8 * 1024 * 1024;

fn byte_range(value: &str, size: u64) -> Option<(u64, u64)> {
    let value = value.strip_prefix("bytes=")?;
    let (start, end) = value.split_once('-')?;
    if size == 0 || value.contains(',') {
        return None;
    }
    if start.is_empty() {
        let suffix = end.parse::<u64>().ok()?.min(size).min(DOWNLOAD_CHUNK_SIZE);
        return Some((size - suffix, size - 1));
    }
    let start = start.parse::<u64>().ok()?;
    if start >= size {
        return None;
    }
    let requested_end = if end.is_empty() {
        size - 1
    } else {
        end.parse::<u64>().ok()?.min(size - 1)
    };
    let end = requested_end.min(start.saturating_add(DOWNLOAD_CHUNK_SIZE - 1));
    (start <= end).then_some((start, end))
}

// ---------------------------------------------------------------------------
// workspace admin and search
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct WorkspaceInput {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    icon: Option<String>,
    #[serde(default)]
    icon_file_id: Option<Id>,
    /// What task keys start with. Letters and digits, upper-cased.
    #[serde(default)]
    task_prefix: Option<String>,
}

const MAX_WORKSPACE_ICON_SIZE: i64 = 2 * 1024 * 1024;

fn workspace_icon_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        Some("image/jpeg")
    } else {
        None
    }
}

async fn workspace_icon(State(state): State<Shared>, Path(id): Path<Id>) -> ApiResult<Response> {
    let workspace = state.store.workspace()?;
    let icon_path = format!("/api/workspace/icon/{id}");
    if workspace.icon_image.as_deref() != Some(icon_path.as_str()) {
        return Err(ApiError::not_found("workspace icon not found"));
    }
    let (attachment, path) = state
        .store
        .attachment(&id)?
        .ok_or_else(|| ApiError::not_found("workspace icon not found"))?;
    if attachment.size > MAX_WORKSPACE_ICON_SIZE {
        return Err(ApiError::not_found("workspace icon not found"));
    }
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|_| ApiError::not_found("workspace icon not found"))?;
    let mime = workspace_icon_mime(&bytes)
        .ok_or_else(|| ApiError::not_found("workspace icon not found"))?;
    Ok((
        [
            (axum::http::header::CONTENT_TYPE, mime),
            (
                axum::http::header::CACHE_CONTROL,
                "public, max-age=31536000, immutable",
            ),
        ],
        bytes,
    )
        .into_response())
}

async fn update_workspace(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<WorkspaceInput>,
) -> ApiResult<Json<Workspace>> {
    caller.require_admin()?;
    if input.icon.is_some() && input.icon_file_id.is_some() {
        return Err(ApiError::bad_request(
            "choose an emoji or an image, not both",
        ));
    }
    let name = input
        .name
        .as_deref()
        .map(str::trim)
        .filter(|n| !n.is_empty());
    let icon = input
        .icon
        .as_deref()
        .map(str::trim)
        .map(|value| value.chars().take(8).collect::<String>());
    if let Some(id) = input.icon_file_id.as_deref() {
        let (attachment, path) = state
            .store
            .attachment(id)?
            .ok_or_else(|| ApiError::not_found("icon image not found"))?;
        require_attachment_access(&state, &caller, &attachment)?;
        if attachment.size > MAX_WORKSPACE_ICON_SIZE {
            return Err(ApiError::bad_request(
                "a workspace icon must be no larger than 2 MB",
            ));
        }
        let bytes = tokio::fs::read(path)
            .await
            .map_err(|_| ApiError::not_found("icon image not found"))?;
        if workspace_icon_mime(&bytes).is_none() {
            return Err(ApiError::bad_request(
                "a workspace icon must be a PNG or JPEG",
            ));
        }
    }
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
    let workspace = state.store.update_workspace(
        name,
        icon.as_deref(),
        input.icon_file_id.as_deref(),
        prefix.as_deref(),
    )?;
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
    caller: Caller,
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
        .filter(|message| {
            crate::visibility::channel(&state.store, &caller.member.id, &message.channel_id)
                .unwrap_or(false)
        })
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

    #[tokio::test]
    async fn the_machine_reads_back_plausible_cpu_and_memory() {
        let system = system_health().await;
        assert!(system.cpu_count >= 1);
        assert!((0.0..=100.0).contains(&system.cpu_percent));
        assert!(system.memory_total > 0);
        assert!(system.memory_used <= system.memory_total);
        assert!(system.process_memory > 0);
    }

    #[test]
    fn snippets_centre_on_the_match() {
        let body = format!("{}NEEDLE{}", "a".repeat(200), "b".repeat(200));
        let s = snippet(&body, "needle");
        assert!(s.starts_with('…'));
        assert!(s.contains("NEEDLE"));
        assert!(s.len() < 260);
    }

    #[tokio::test]
    async fn an_admin_agent_can_set_an_image_or_emoji_workspace_icon() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let files = path.with_extension("files");
        let store = crate::store::Store::open(&path).unwrap();
        store.create_workspace("ws", "Test").unwrap();
        tokio::fs::create_dir_all(&files).await.unwrap();
        let image_path = files.join("icon");
        tokio::fs::write(&image_path, b"\x89PNG\r\n\x1a\n")
            .await
            .unwrap();
        store
            .insert_attachment(
                &Attachment {
                    id: "icon".into(),
                    file_name: "icon.png".into(),
                    mime: "image/png".into(),
                    size: 8,
                    caption: String::new(),
                    url: "/api/files/icon".into(),
                    message_id: None,
                    task_id: None,
                    run_id: None,
                    created_at: 1,
                },
                &image_path.to_string_lossy(),
            )
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            files.clone(),
            "http://workspace".into(),
            "host".into(),
        ));
        let caller = Caller {
            member: Member {
                id: "agent".into(),
                kind: MemberKind::Agent,
                handle: "agent".into(),
                display_name: "Agent".into(),
                email: None,
                avatar: None,
                is_admin: true,
                created_at: 1,
                agent: Some(AgentProfile::default()),
                presence: Presence::Offline,
            },
            run_id: Some("run".into()),
            token_hash: "hash".into(),
            token_kind: "run".into(),
        };

        let Json(updated) = update_workspace(
            State(state.clone()),
            caller.clone(),
            Json(WorkspaceInput {
                name: None,
                icon: None,
                icon_file_id: Some("icon".into()),
                task_prefix: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            updated.icon_image.as_deref(),
            Some("/api/workspace/icon/icon")
        );
        assert_eq!(
            axum::body::to_bytes(
                workspace_icon(State(state.clone()), Path("icon".into()))
                    .await
                    .unwrap()
                    .into_body(),
                32,
            )
            .await
            .unwrap(),
            b"\x89PNG\r\n\x1a\n".as_slice()
        );

        let Json(updated) = update_workspace(
            State(state.clone()),
            caller,
            Json(WorkspaceInput {
                name: None,
                icon: Some("🚀".into()),
                icon_file_id: None,
                task_prefix: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(updated.icon, "🚀");
        assert!(updated.icon_image.is_none());

        drop(state);
        drop(store);
        let _ = std::fs::remove_dir_all(files);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn only_a_deliberate_reopen_leaves_a_terminal_state() {
        assert!(reopens_terminal(
            TaskStatus::Done,
            Some(TaskStatus::Planned)
        ));
        assert!(reopens_terminal(
            TaskStatus::Canceled,
            Some(TaskStatus::Running)
        ));
        assert!(!reopens_terminal(TaskStatus::Done, Some(TaskStatus::Done)));
        assert!(!reopens_terminal(
            TaskStatus::Review,
            Some(TaskStatus::Planned)
        ));
        assert!(!reopens_terminal(TaskStatus::Done, None));
    }

    #[test]
    fn file_ranges_are_bounded_and_suffixes_work() {
        assert_eq!(byte_range("bytes=10-19", 100), Some((10, 19)));
        assert_eq!(byte_range("bytes=90-", 100), Some((90, 99)));
        assert_eq!(byte_range("bytes=-10", 100), Some((90, 99)));
        assert_eq!(byte_range("bytes=100-", 100), None);
        assert_eq!(byte_range("bytes=0-1,4-5", 100), None);
        assert_eq!(
            byte_range("bytes=0-", DOWNLOAD_CHUNK_SIZE * 2),
            Some((0, DOWNLOAD_CHUNK_SIZE - 1))
        );
    }

    #[tokio::test]
    async fn inline_replies_reject_threads_and_other_conversations() {
        let path = std::env::temp_dir().join(format!("patchwork-api-reply-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        let human = Member {
            id: "human".into(),
            kind: MemberKind::Human,
            handle: "human".into(),
            display_name: "Human".into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: None,
            presence: Presence::Online,
        };
        store.insert_member(&human).unwrap();
        for id in ["one", "two"] {
            store
                .insert_channel(&Channel {
                    id: id.into(),
                    kind: ChannelKind::Channel,
                    section_id: None,
                    slug: id.into(),
                    name: id.into(),
                    topic: String::new(),
                    position: 0.0,
                    created_at: 1,
                    member_ids: Vec::new(),
                    task_id: None,
                    last_message_at: 0,
                })
                .unwrap();
        }
        store
            .insert_message(&Message {
                id: "source".into(),
                channel_id: "two".into(),
                author_id: human.id.clone(),
                kind: MessageKind::Text,
                body: "Source".into(),
                card: None,
                parent_id: None,
                reply_to_id: None,
                reply_to: None,
                reply_count: 0,
                last_reply_at: 0,
                run_id: None,
                task_id: None,
                mentions: Vec::new(),
                attachments: Vec::new(),
                reactions: Vec::new(),
                created_at: 1,
                edited_at: None,
            })
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "relay".into(),
        ));
        let caller = || Caller {
            member: human.clone(),
            run_id: None,
            token_hash: "token".into(),
            token_kind: "device".into(),
        };

        let both = send_message(
            State(state.clone()),
            caller(),
            Path("one".into()),
            Json(SendMessage {
                body: "Both".into(),
                parent_id: Some("source".into()),
                reply_to_id: Some("source".into()),
                ..Default::default()
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(both.status, axum::http::StatusCode::BAD_REQUEST);

        let cross_channel = send_message(
            State(state),
            caller(),
            Path("one".into()),
            Json(SendMessage {
                body: "Cross channel".into(),
                reply_to_id: Some("source".into()),
                ..Default::default()
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(cross_channel.status, axum::http::StatusCode::BAD_REQUEST);

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn workspace_skills_are_shared_without_per_member_access() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        let member = Member {
            id: "human".into(),
            kind: MemberKind::Human,
            handle: "human".into(),
            display_name: "Human".into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: None,
            presence: Presence::Online,
        };
        store.insert_member(&member).unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));
        let caller = Caller {
            member,
            run_id: None,
            token_hash: "token".into(),
            token_kind: "device".into(),
        };

        let skill = create_skill(
            State(state.clone()),
            caller.clone(),
            Json(UpsertWorkspaceSkill {
                name: "Release checks".into(),
                description: "Before shipping".into(),
                instructions: "Run the smoke test.".into(),
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(
            list_skills(State(state.clone()), caller.clone())
                .await
                .unwrap()
                .0,
            [skill]
        );

        let too_large = create_skill(
            State(state.clone()),
            caller,
            Json(UpsertWorkspaceSkill {
                name: "Too large".into(),
                description: String::new(),
                instructions: "x".repeat(MAX_SKILL_INSTRUCTIONS_BYTES + 1),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(too_large.status, axum::http::StatusCode::BAD_REQUEST);

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn agents_must_confirm_similar_tasks_but_exact_keys_are_reused() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        store.create_workspace("workspace", "Test").unwrap();
        let agent = Member {
            id: "agent".into(),
            kind: MemberKind::Agent,
            handle: "agent".into(),
            display_name: "Agent".into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: Some(AgentProfile::default()),
            presence: Presence::Working,
        };
        store.insert_member(&agent).unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));
        let caller = || Caller {
            member: agent.clone(),
            run_id: None,
            token_hash: "agent-token".into(),
            token_kind: "run".into(),
        };

        let first = create_task(
            State(state.clone()),
            caller(),
            Json(CreateTask {
                title: "PostHog image proxy invalid-content spike".into(),
                outcome: "Image proxy requests complete safely".into(),
                initial_message: Some("The upstream returned invalid content".into()),
                once_key: Some("posthog:image-proxy:403".into()),
                allow_similar: true,
                ..Default::default()
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(first.outcome, "Image proxy requests complete safely");
        assert_eq!(
            store
                .message(first.source_message_id.as_deref().unwrap())
                .unwrap()
                .unwrap()
                .body,
            "The upstream returned invalid content"
        );

        let warning = create_task(
            State(state.clone()),
            caller(),
            Json(CreateTask {
                title: "PostHog headless images fetch 403 spike".into(),
                outcome: "Headless image fetches now return forbidden".into(),
                once_key: Some("posthog:headless-fetch:403".into()),
                ..Default::default()
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(warning.status, axum::http::StatusCode::CONFLICT);
        assert_eq!(warning.code, "similar_task");
        assert!(warning.message.contains(&first.key));

        let repeated = create_task(
            State(state.clone()),
            caller(),
            Json(CreateTask {
                title: "Another wording for the same delivery".into(),
                outcome: "This exact source event was delivered again".into(),
                once_key: Some("POSTHOG:IMAGE-PROXY:403".into()),
                ..Default::default()
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(repeated.id, first.id);

        let distinct = create_task(
            State(state.clone()),
            caller(),
            Json(CreateTask {
                title: "PostHog headless images fetch 403 spike".into(),
                outcome: "A separate environment is returning forbidden".into(),
                once_key: Some("posthog:staging-headless-fetch:403".into()),
                allow_similar: true,
                ..Default::default()
            }),
        )
        .await
        .unwrap()
        .0;
        assert_ne!(distinct.id, first.id);
        assert_eq!(store.tasks().unwrap().len(), 2);

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn only_the_scoped_agent_asks_and_only_a_human_answers() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        let human = Member {
            id: "human".into(),
            kind: MemberKind::Human,
            handle: "human".into(),
            display_name: "Human".into(),
            email: None,
            avatar: None,
            is_admin: true,
            created_at: 1,
            agent: None,
            presence: Presence::Online,
        };
        let agent = Member {
            id: "agent".into(),
            kind: MemberKind::Agent,
            handle: "agent".into(),
            display_name: "Agent".into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: Some(AgentProfile::default()),
            presence: Presence::Working,
        };
        store.insert_member(&human).unwrap();
        store.insert_member(&agent).unwrap();
        store
            .insert_channel(&Channel {
                id: "channel".into(),
                kind: ChannelKind::Channel,
                section_id: None,
                slug: "channel".into(),
                name: "Channel".into(),
                topic: String::new(),
                position: 0.0,
                created_at: 1,
                member_ids: Vec::new(),
                task_id: None,
                last_message_at: 0,
            })
            .unwrap();
        let make_run = |id: &str| Run {
            id: id.into(),
            agent_id: agent.id.clone(),
            status: RunStatus::Running,
            trigger: RunTrigger::Manual {
                by: human.id.clone(),
            },
            channel_id: "channel".into(),
            task_id: None,
            host_id: Some("host-one".into()),
            project_id: None,
            worktree_id: None,
            cwd: None,
            automation_id: None,
            session_id: None,
            runtime: "test".into(),
            prompt: String::new(),
            headline: "Working".into(),
            error: None,
            token_usage: None,
            created_at: 1,
            started_at: Some(1),
            ended_at: None,
        };
        let task = Task {
            id: "task".into(),
            key: "PW-1".into(),
            title: "Needs a decision".into(),
            outcome: "Continue after the human decides".into(),
            status: TaskStatus::Running,
            owner_id: Some(agent.id.clone()),
            source_channel_id: Some("channel".into()),
            source_message_id: None,
            discussion_channel_id: "channel".into(),
            project_id: None,
            host_id: Some("host-one".into()),
            worktree_id: None,
            current_run_id: Some("run-one".into()),
            pr_url: None,
            pr_state: None,
            review_action: None,
            created_by: human.id.clone(),
            due_at: None,
            once_key: None,
            created_at: 1,
            updated_at: 1,
            position: 1.0,
        };
        store.insert_task(&task).unwrap();
        let mut first_run = make_run("run-one");
        first_run.task_id = Some(task.id.clone());
        store.insert_run(&first_run, 0).unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));
        let human_caller = || Caller {
            member: human.clone(),
            run_id: None,
            token_hash: "human-token".into(),
            token_kind: "device".into(),
        };
        let agent_caller = |run_id: &str| Caller {
            member: agent.clone(),
            run_id: Some(run_id.into()),
            token_hash: "agent-token".into(),
            token_kind: "run".into(),
        };
        let ask = |run_id: &str| AskQuestion {
            run_id: run_id.into(),
            headline: "Approval".into(),
            items: vec![QuestionItem {
                id: "choice".into(),
                header: String::new(),
                question: "Continue?".into(),
                options: Vec::new(),
                allow_free_text: true,
                multi_select: false,
            }],
        };

        orchestrator::handle_host_message(
            &state,
            "host-two",
            patchwork_core::host::HostToRelay::RunStatus {
                run_id: "run-one".into(),
                status: RunStatus::Failed,
                headline: Some("Spoofed".into()),
                session_id: None,
                error: None,
                token_usage: None,
            },
        )
        .await;
        assert_eq!(
            store.run("run-one").unwrap().unwrap().status,
            RunStatus::Running
        );

        assert_eq!(
            ask_question(State(state.clone()), human_caller(), Json(ask("run-one")),)
                .await
                .unwrap_err()
                .status,
            axum::http::StatusCode::FORBIDDEN
        );
        assert_eq!(
            ask_question(
                State(state.clone()),
                agent_caller("another-run"),
                Json(ask("run-one")),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::FORBIDDEN
        );

        let question = ask_question(
            State(state.clone()),
            agent_caller("run-one"),
            Json(ask("run-one")),
        )
        .await
        .unwrap()
        .0;
        assert!(question.message_id.is_some());
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Blocked
        );
        assert!(store
            .inbox(&human.id, false)
            .unwrap()
            .iter()
            .any(|item| item.run_id.as_deref() == Some("run-one")));
        assert_eq!(
            answer_question(
                State(state.clone()),
                agent_caller("run-one"),
                Path(question.id.clone()),
                Json(AnswerQuestion {
                    answers: Vec::new()
                }),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::FORBIDDEN
        );
        assert_eq!(
            wait_for_answer(
                State(state.clone()),
                agent_caller("another-run"),
                Path(question.id.clone()),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::FORBIDDEN
        );
        let second = ask_question(
            State(state.clone()),
            agent_caller("run-one"),
            Json(ask("run-one")),
        )
        .await
        .unwrap()
        .0;
        let _ = answer_question(
            State(state.clone()),
            human_caller(),
            Path(question.id),
            Json(AnswerQuestion {
                answers: Vec::new(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            store.run("run-one").unwrap().unwrap().status,
            RunStatus::Waiting
        );
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Blocked,
            "one answer cannot unblock a task with another open question",
        );
        assert_eq!(
            store.question(&second.id).unwrap().unwrap().status,
            QuestionStatus::Open
        );
        assert_eq!(
            store
                .inbox(&human.id, false)
                .unwrap()
                .iter()
                .filter(|item| item.run_id.as_deref() == Some("run-one"))
                .count(),
            1
        );
        let _ = answer_question(
            State(state.clone()),
            human_caller(),
            Path(second.id),
            Json(AnswerQuestion {
                answers: Vec::new(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            store.run("run-one").unwrap().unwrap().status,
            RunStatus::Running
        );
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Running
        );

        let explicit_block = ask_question(
            State(state.clone()),
            agent_caller("run-one"),
            Json(ask("run-one")),
        )
        .await
        .unwrap()
        .0;
        let _ = orchestrator::update_task(
            &state,
            &human.id,
            false,
            &task.id,
            UpdateTask {
                status: Some(TaskStatus::Blocked),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let _ = answer_question(
            State(state.clone()),
            human_caller(),
            Path(explicit_block.id),
            Json(AnswerQuestion {
                answers: Vec::new(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Blocked,
            "an explicit Blocked status must outlive the question that first blocked it",
        );

        store.insert_run(&make_run("run-two"), 0).unwrap();
        store
            .insert_token("run-two-token", &agent.id, "run", Some("run-two"), None)
            .unwrap();
        let waiting = ask_question(
            State(state.clone()),
            agent_caller("run-two"),
            Json(ask("run-two")),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(
            cancel_run(
                State(state.clone()),
                agent_caller("run-two"),
                Path("run-two".into()),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::FORBIDDEN
        );
        let _ = cancel_run(State(state.clone()), human_caller(), Path("run-two".into()))
            .await
            .unwrap();
        assert_eq!(
            store.run("run-two").unwrap().unwrap().status,
            RunStatus::Cancelled
        );
        assert!(store.lookup_token("run-two-token").unwrap().is_none());
        assert_eq!(
            store.question(&waiting.id).unwrap().unwrap().status,
            QuestionStatus::Cancelled
        );
        assert_eq!(
            ask_question(
                State(state.clone()),
                agent_caller("run-two"),
                Json(ask("run-two")),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::CONFLICT
        );
        assert!(store
            .inbox(&human.id, false)
            .unwrap()
            .iter()
            .all(|item| item.run_id.as_deref() != Some("run-two")));

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    /// Two agents in one task and one worktree: the task belongs to both of
    /// them until the last one stops, and either one's evidence is the task's.
    #[tokio::test]
    async fn a_task_waits_for_its_last_agent_to_stop() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        store.create_workspace("ws", "Test").unwrap();
        let agent = Member {
            id: "agent".into(),
            kind: MemberKind::Agent,
            handle: "agent".into(),
            display_name: "Agent".into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: Some(AgentProfile::default()),
            presence: Presence::Online,
        };
        store.insert_member(&agent).unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));
        let task = orchestrator::create_task(
            &state,
            &agent.id,
            CreateTask {
                title: "Ship the partner hub".into(),
                outcome: "The hub is live".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();

        let working = |id: &str| Run {
            id: id.into(),
            agent_id: agent.id.clone(),
            status: RunStatus::Running,
            trigger: RunTrigger::Manual {
                by: "person".into(),
            },
            channel_id: task.discussion_channel_id.clone(),
            task_id: Some(task.id.clone()),
            host_id: None,
            project_id: None,
            worktree_id: None,
            cwd: None,
            automation_id: None,
            session_id: None,
            runtime: "test".into(),
            prompt: String::new(),
            headline: "Working".into(),
            error: None,
            token_usage: None,
            created_at: 1,
            started_at: Some(1),
            ended_at: None,
        };
        let mut builder = working("run-builder");
        let mut writer = working("run-writer");
        store.insert_run(&builder, 0).unwrap();
        store.insert_run(&writer, 0).unwrap();
        assert!(store
            .activate_task_run(&task.id, &builder.id, None)
            .unwrap()
            .is_some());
        assert!(
            store
                .activate_task_run(&task.id, &writer.id, None)
                .unwrap()
                .is_some(),
            "a second agent joins a task that is already running"
        );

        // Evidence from either of them belongs to the task.
        store
            .upsert_preview(&Preview {
                id: "preview".into(),
                task_id: task.id.clone(),
                host_id: "host".into(),
                run_id: Some(builder.id.clone()),
                label: "Partner hub".into(),
                port: 5173,
                url: "http://preview".into(),
                status: PreviewStatus::Live,
                local_only: false,
                created_at: 2,
                stopped_at: None,
            })
            .unwrap();

        builder.status = RunStatus::Succeeded;
        builder.ended_at = Some(3);
        store.update_run(&builder).unwrap();
        orchestrator::finish_run(&state, &builder).await.unwrap();
        let mid = store.task(&task.id).unwrap().unwrap();
        assert_eq!(
            mid.status,
            TaskStatus::Running,
            "the task is still being worked on by the other agent"
        );
        assert_eq!(mid.current_run_id.as_deref(), Some(writer.id.as_str()));

        writer.status = RunStatus::Succeeded;
        writer.ended_at = Some(4);
        store.update_run(&writer).unwrap();
        orchestrator::finish_run(&state, &writer).await.unwrap();
        let done = store.task(&task.id).unwrap().unwrap();
        assert_eq!(done.status, TaskStatus::Review);
        assert!(done.current_run_id.is_none());

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn an_agent_needs_evidence_before_review() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        store.create_workspace("ws", "Test").unwrap();
        let agent = Member {
            id: "agent".into(),
            kind: MemberKind::Agent,
            handle: "agent".into(),
            display_name: "Agent".into(),
            email: None,
            avatar: None,
            is_admin: true,
            created_at: 1,
            agent: Some(AgentProfile::default()),
            presence: Presence::Offline,
        };
        let human = Member {
            id: "human".into(),
            kind: MemberKind::Human,
            handle: "human".into(),
            display_name: "Human".into(),
            email: None,
            avatar: None,
            is_admin: true,
            created_at: 1,
            agent: None,
            presence: Presence::Online,
        };
        store.insert_member(&agent).unwrap();
        store.insert_member(&human).unwrap();
        let token = auth::generate_token();
        store
            .insert_token(
                &auth::hash_token(&token),
                &agent.id,
                "run",
                Some("run"),
                None,
            )
            .unwrap();
        let human_token = auth::generate_token();
        store
            .insert_token(
                &auth::hash_token(&human_token),
                &human.id,
                "device",
                None,
                None,
            )
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));
        let task = orchestrator::create_task(
            &state,
            &agent.id,
            CreateTask {
                title: "Do it".into(),
                outcome: "A result exists".into(),
                owner_id: Some(agent.id.clone()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        store
            .upsert_preview(&Preview {
                id: "stopped-preview".into(),
                task_id: task.id.clone(),
                host_id: "host".into(),
                run_id: Some("run".into()),
                label: "Old preview".into(),
                port: 4321,
                url: String::new(),
                status: PreviewStatus::Stopped,
                local_only: false,
                created_at: 1,
                stopped_at: Some(2),
            })
            .unwrap();

        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("PATCH")
                    .uri(format!("/api/tasks/{}", task.id))
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(r#"{"status":"review"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::BAD_REQUEST);
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Planned
        );

        let mut running = store.task(&task.id).unwrap().unwrap();
        running.status = TaskStatus::Running;
        running.current_run_id = Some("run".into());
        store.update_task(&running).unwrap();
        orchestrator::finish_run(
            &state,
            &Run {
                id: "run".into(),
                agent_id: agent.id.clone(),
                status: RunStatus::Succeeded,
                trigger: RunTrigger::Manual {
                    by: "person".into(),
                },
                channel_id: task.discussion_channel_id.clone(),
                task_id: Some(task.id.clone()),
                host_id: None,
                project_id: None,
                worktree_id: None,
                cwd: None,
                automation_id: None,
                session_id: None,
                runtime: "test".into(),
                prompt: String::new(),
                headline: "Done".into(),
                error: None,
                token_usage: None,
                created_at: 1,
                started_at: Some(1),
                ended_at: Some(2),
            },
        )
        .await
        .unwrap();
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Planned,
            "a successful run without evidence must not auto-promote itself",
        );

        let answered = orchestrator::create_task(
            &state,
            &agent.id,
            CreateTask {
                title: "Should search use QMD?".into(),
                outcome: "Should we add QMD for powering CLI search? or not".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        store
            .append_run_event(&RunEvent {
                id: "answer-event".into(),
                run_id: "run".into(),
                seq: 1,
                kind: RunEventKind::Message,
                text: "Recommendation: keep search in the relay.".into(),
                data: None,
                created_at: 2,
            })
            .unwrap();

        // Explicit completion wins even for an inquiry. Successful runs still
        // auto-promote written answers to Review when the agent does not set a
        // terminal status itself.
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("PATCH")
                    .uri(format!("/api/tasks/{}", answered.id))
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(
                        r#"{"title":"Keep relay search","outcome":"Decision: keep FTS5","status":"done"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        let answered = store.task(&answered.id).unwrap().unwrap();
        assert_eq!(answered.status, TaskStatus::Done);
        assert_eq!(answered.outcome, "Decision: keep FTS5");

        let auto_reviewed = orchestrator::create_task(
            &state,
            &agent.id,
            CreateTask {
                title: "What does search index?".into(),
                outcome: "What does CLI search index?".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        store
            .append_run_event(&RunEvent {
                id: "automatic-answer-event".into(),
                run_id: "answer-run".into(),
                seq: 1,
                kind: RunEventKind::Message,
                text: "It indexes task titles and outcomes.".into(),
                data: None,
                created_at: 3,
            })
            .unwrap();
        let mut running = auto_reviewed.clone();
        running.status = TaskStatus::Running;
        running.current_run_id = Some("answer-run".into());
        store.update_task(&running).unwrap();
        orchestrator::finish_run(
            &state,
            &Run {
                id: "answer-run".into(),
                agent_id: agent.id.clone(),
                status: RunStatus::Succeeded,
                trigger: RunTrigger::Manual {
                    by: "person".into(),
                },
                channel_id: auto_reviewed.discussion_channel_id.clone(),
                task_id: Some(auto_reviewed.id.clone()),
                host_id: None,
                project_id: None,
                worktree_id: None,
                cwd: None,
                automation_id: None,
                session_id: None,
                runtime: "test".into(),
                prompt: String::new(),
                headline: "Done".into(),
                error: None,
                token_usage: None,
                created_at: 1,
                started_at: Some(1),
                ended_at: Some(3),
            },
        )
        .await
        .unwrap();
        assert_eq!(
            store.task(&auto_reviewed.id).unwrap().unwrap().status,
            TaskStatus::Review,
            "a successful written answer should wait for human review",
        );

        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/uploads")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(format!(
                        r#"{{"file_name":"proof.mp4","size":6,"caption":"Demo","task_id":"{}"}}"#,
                        task.id
                    )))
                    .unwrap(),
            )
            .await
            .unwrap();
        let upload: UploadSession = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap(),
        )
        .unwrap();
        for (offset, bytes) in [(0, "abc"), (3, "def")] {
            let response = router(state.clone())
                .oneshot(
                    Request::builder()
                        .method("PUT")
                        .uri(format!("/api/uploads/{}?offset={offset}", upload.id))
                        .header("authorization", format!("Bearer {token}"))
                        .body(axum::body::Body::from(bytes))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), axum::http::StatusCode::OK);
        }
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/uploads/{}/complete", upload.id))
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        let attachment: Attachment = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(attachment.caption, "Demo");
        assert_eq!(attachment.run_id.as_deref(), Some("run"));
        assert_eq!(
            tokio::fs::read(state.files_dir.join(&attachment.id))
                .await
                .unwrap(),
            b"abcdef"
        );

        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("PATCH")
                    .uri(format!("/api/tasks/{}", task.id))
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(
                        r#"{"status":"review","review_action":"Approve and deploy app"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        assert_eq!(
            store
                .task(&task.id)
                .unwrap()
                .unwrap()
                .review_action
                .as_deref(),
            Some("Approve and deploy app")
        );

        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/tasks/{}/approve", task.id))
                    .header("authorization", format!("Bearer {token}"))
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::FORBIDDEN);

        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/tasks/{}/approve", task.id))
                    .header("authorization", format!("Bearer {human_token}"))
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            axum::http::StatusCode::INTERNAL_SERVER_ERROR
        );
        let restored = store.task(&task.id).unwrap().unwrap();
        assert_eq!(restored.status, TaskStatus::Review);
        assert_eq!(
            restored.review_action.as_deref(),
            Some("Approve and deploy app")
        );

        let (host_tx, mut host_rx) = tokio::sync::mpsc::unbounded_channel();
        state
            .hosts
            .write()
            .await
            .insert("host".into(), crate::state::HostConn { tx: host_tx });
        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/tasks/{}/approve", task.id))
                    .header("authorization", format!("Bearer {human_token}"))
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        let approved: Run = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap(),
        )
        .unwrap();
        let dispatched = host_rx.recv().await.unwrap();
        let RelayToHost::StartRun { spec } = dispatched else {
            panic!("approval did not dispatch a run")
        };
        assert_eq!(spec.run_id, approved.id);
        assert!(spec.prompt.contains("Human approved"));
        assert!(spec.prompt.contains("Approve and deploy app"));
        let approved_task = store.task(&task.id).unwrap().unwrap();
        assert_eq!(approved_task.status, TaskStatus::Running);
        assert!(approved_task.review_action.is_none());
        assert_eq!(
            approved_task.current_run_id.as_deref(),
            Some(approved.id.as_str())
        );

        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/tasks/{}/approve", task.id))
                    .header("authorization", format!("Bearer {human_token}"))
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::CONFLICT);

        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri(format!("/api/tasks/{}", task.key))
                    .header("authorization", format!("Bearer {token}"))
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        assert!(store.task(&task.id).unwrap().is_none());
        assert!(store.attachment(&attachment.id).unwrap().is_none());
        assert!(!state.files_dir.join(&attachment.id).exists());
        let files = state.files_dir.clone();
        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_dir_all(files);
    }

    #[tokio::test]
    async fn a_non_admin_cannot_promote_an_agent() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        let human = Member {
            id: "human".into(),
            kind: MemberKind::Human,
            handle: "human".into(),
            display_name: "Human".into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: None,
            presence: Presence::Offline,
        };
        let agent = Member {
            id: "agent".into(),
            kind: MemberKind::Agent,
            handle: "agent".into(),
            display_name: "Agent".into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: Some(AgentProfile::default()),
            presence: Presence::Offline,
        };
        store.insert_member(&human).unwrap();
        store.insert_member(&agent).unwrap();
        let token = auth::generate_token();
        store
            .insert_token(&auth::hash_token(&token), &human.id, "device", None, None)
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));

        let response = router(state.clone())
            .oneshot(
                Request::builder()
                    .method("PATCH")
                    .uri("/api/agents/agent")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(r#"{"is_admin":true}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::FORBIDDEN);
        assert!(!store.member("agent").unwrap().unwrap().is_admin);
        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn current_device_only_logs_out_through_the_current_route() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        let member = Member {
            id: "human".into(),
            kind: MemberKind::Human,
            handle: "human".into(),
            display_name: "Human".into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: None,
            presence: Presence::Offline,
        };
        store.insert_member(&member).unwrap();
        let token = auth::generate_token();
        let token_hash = auth::hash_token(&token);
        store
            .insert_token(&token_hash, &member.id, "device", None, None)
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));

        let request = |uri: String| {
            Request::builder()
                .method("DELETE")
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .body(axum::body::Body::empty())
                .unwrap()
        };
        let response = router(state.clone())
            .oneshot(request(format!("/api/devices/{token_hash}")))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::CONFLICT);
        assert!(auth::authenticate(&state, &token).is_some());

        let response = router(state.clone())
            .oneshot(request("/api/devices/current".into()))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        assert!(auth::authenticate(&state, &token).is_none());
        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }
}
