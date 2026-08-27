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
        system: if known {
            Some(system_health().await)
        } else {
            None
        },
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
        .route(
            "/api/sections/{id}",
            patch(update_section).delete(delete_section),
        )
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
        .route(
            "/api/tasks/{id}/continuation",
            post(create_task_continuation),
        )
        // runs
        .route("/api/runs", post(start_run))
        .route("/api/runs/{id}", get(run_detail))
        .route("/api/runs/{id}/cancel", post(cancel_run))
        .route("/api/runs/{id}/steer", post(steer_run))
        .route("/api/runs/{id}/events", get(run_events))
        // asks
        .route("/api/asks", get(list_asks).post(open_ask))
        .route("/api/asks/{id}", get(get_ask))
        .route("/api/asks/{id}/answer", post(answer_ask))
        .route("/api/asks/{id}/wait", get(wait_for_answer))
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
        .route("/api/automations/{id}/test", post(test_automation))
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
        system: if known {
            Some(system_health().await)
        } else {
            None
        },
    }))
}

/// What the relay's machine is doing right now. CPU usage is a rate, so it
/// needs two samples: the reader is built per call and thrown away, which
/// costs one 200ms wait and buys no shared state to keep correct.
async fn system_health() -> SystemHealth {
    use sysinfo::{
        get_current_pid, ProcessRefreshKind, ProcessesToUpdate, System, MINIMUM_CPU_UPDATE_INTERVAL,
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
        open_asks: state
            .store
            .open_asks()?
            .into_iter()
            .filter(|ask| visible_ids.contains(&ask.channel_id))
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

async fn update_section(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<NameInput>,
) -> ApiResult<Json<Section>> {
    caller.require_admin()?;
    let name = input.name.trim();
    if name.is_empty() {
        return Err(ApiError::bad_request("a section needs a name"));
    }
    if !state.store.rename_section(&id, name)? {
        return Err(ApiError::not_found("section not found"));
    }
    let sections = state.store.sections()?;
    let section = sections
        .iter()
        .find(|section| section.id == id)
        .cloned()
        .ok_or_else(|| ApiError::not_found("section not found"))?;
    state.emit(Event::SectionsUpdated { sections });
    Ok(Json(section))
}

async fn delete_section(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ok>> {
    caller.require_admin()?;
    let affected: HashSet<_> = state
        .store
        .channels()?
        .into_iter()
        .filter(|channel| channel.section_id.as_deref() == Some(id.as_str()))
        .map(|channel| channel.id)
        .collect();
    if !state.store.delete_section(&id)? {
        return Err(ApiError::not_found("section not found"));
    }
    for channel in state
        .store
        .channels()?
        .into_iter()
        .filter(|channel| affected.contains(&channel.id))
    {
        state.emit(Event::ChannelUpdated { channel });
    }
    state.emit(Event::SectionsUpdated {
        sections: state.store.sections()?,
    });
    Ok(Json(Ok::default()))
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

fn dm_between(state: &Shared, owner: &Member, other: &Member) -> ApiResult<Channel> {
    if let Some(existing) = state.store.find_dm(&owner.id, &other.id)? {
        return Ok(existing);
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
        member_ids: vec![owner.id.clone(), other.id.clone()],
        task_id: None,
        last_message_at: 0,
    };
    state.store.insert_channel(&channel)?;
    state.emit(Event::ChannelCreated {
        channel: channel.clone(),
    });
    Ok(channel)
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
    Ok(Json(dm_between(&state, &caller.member, &other)?))
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
    if input
        .client_id
        .as_deref()
        .is_some_and(|id| uuid::Uuid::parse_str(id).is_err())
    {
        return Err(ApiError::bad_request("client_id must be a UUID"));
    }
    require_channel_access(&state, &caller, &id)?;
    if let Some(client_id) = &input.client_id {
        if let Some(existing) =
            state
                .store
                .message_by_client_id(&caller.member.id, &id, client_id)?
        {
            return Ok(Json(existing));
        }
    }
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
    let client_id = input.client_id.clone();
    let posted = orchestrator::post_message(
        &state,
        &id,
        &caller.member.id,
        input,
        PostOptions {
            trigger_agents: true,
            run_id: caller.run_id.clone(),
        },
    )
    .await;
    match posted {
        Ok(message) => Ok(Json(message)),
        Err(error) => {
            if let Some(client_id) = client_id {
                if let Some(existing) =
                    state
                        .store
                        .message_by_client_id(&caller.member.id, &id, &client_id)?
                {
                    return Ok(Json(existing));
                }
            }
            Err(error.into())
        }
    }
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
    Json(mut input): Json<CreateTask>,
) -> ApiResult<Json<Task>> {
    if input.title.trim().is_empty() && input.outcome.trim().is_empty() {
        return Err(ApiError::bad_request("a task needs an expected result"));
    }
    if caller.is_agent() && input.status == Some(TaskStatus::Review) {
        return Err(ApiError::bad_request(
            "an agent cannot create a task in review without review evidence",
        ));
    }
    if input.status == Some(TaskStatus::Running) {
        return Err(ApiError::bad_request(
            "create the task as planned and start it; running requires an active run or continuation",
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
    // Every task reports back where it came from, so an agent's task inherits
    // the conversation its parent came from rather than vanishing into its own
    // discussion.
    if input.source_channel_id.is_none() {
        if let Some(run_id) = caller.run_id.as_deref() {
            if let Some(parent) = state
                .store
                .run(run_id)?
                .and_then(|run| run.task_id)
                .map(|task_id| state.store.task(&task_id))
                .transpose()?
                .flatten()
            {
                input.source_channel_id = parent.source_channel_id;
            }
        }
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
        asks: state.store.task_asks(&task.id)?,
        worktree,
        task,
    }))
}

fn reopens_terminal(from: TaskStatus, to: Option<TaskStatus>) -> bool {
    from.is_terminal() && to.is_some_and(|status| !status.is_terminal())
}

fn pull_request_blocks_completion(task: &Task, input: &UpdateTask) -> bool {
    if input.status != Some(TaskStatus::Done) {
        return false;
    }
    let requested_url = input.pr_url.as_deref().filter(|url| !url.is_empty());
    if requested_url.is_none() && task.pr_url.is_none() {
        return false;
    }
    let state_matches_link = requested_url.is_none() || requested_url == task.pr_url.as_deref();
    !state_matches_link
        || !task.pr_state.as_ref().is_some_and(|pr| {
            pr.state.eq_ignore_ascii_case("merged") || pr.state.eq_ignore_ascii_case("closed")
        })
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
    if let Some(brief) = input.brief.as_deref() {
        if brief.chars().count() > TASK_BRIEF_LIMIT {
            return Err(ApiError::bad_request(format!(
                "a brief is at most {TASK_BRIEF_LIMIT} characters: two sentences of where this stands"
            )));
        }
    }
    // Only closing is a choice, and reopening is a person's. Everything else
    // follows from runs and the open ask, so accepting it here would be
    // accepting a lie the next refresh would silently overwrite.
    if let Some(status) = input.status {
        if !status.is_terminal() && status != TaskStatus::Planned {
            return Err(ApiError::bad_request(
                "status is derived from the runs and the open ask: use done, cancel, or open an ask",
            ));
        }
        if caller.is_agent() && reopens_terminal(task.status, Some(status)) {
            return Err(ApiError::bad_request(
                "only a person can reopen a completed or canceled task",
            ));
        }
    }
    if pull_request_blocks_completion(&task, &input) {
        return Err(ApiError::conflict(
            "the linked pull request must be closed or merged before this task can be marked done",
        ));
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

async fn create_task_continuation(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<CreateTaskContinuation>,
) -> ApiResult<Json<Task>> {
    let run_id = caller
        .run_id
        .as_deref()
        .filter(|_| caller.is_agent() && caller.token_kind == "run")
        .ok_or_else(|| {
            ApiError::forbidden("only the agent run owning this task can wait for it")
        })?;
    let task = state
        .store
        .task_by_ref(&id)?
        .ok_or_else(|| ApiError::not_found("task not found"))?;
    let run = state
        .store
        .run(run_id)?
        .filter(|run| {
            run.agent_id == caller.member.id
                && run.task_id.as_deref() == Some(task.id.as_str())
                && !run.status.is_terminal()
        })
        .ok_or_else(|| ApiError::forbidden("this run does not own that task"))?;

    let command = input.command.trim();
    let wake_prompt = input.wake_prompt.trim();
    let summary = input.summary.trim();
    if command.is_empty() || command.chars().count() > 8_192 {
        return Err(ApiError::bad_request(
            "a checker command must be between 1 and 8192 characters",
        ));
    }
    if !(20..=86_400).contains(&input.every_seconds) {
        return Err(ApiError::bad_request(
            "the checker interval must be between 20 and 86400 seconds",
        ));
    }
    if wake_prompt.is_empty() || wake_prompt.chars().count() > 8_000 {
        return Err(ApiError::bad_request(
            "a wake prompt must be between 1 and 8000 characters",
        ));
    }
    if summary.is_empty() || summary.chars().count() > 500 {
        return Err(ApiError::bad_request(
            "an obligation summary must be between 1 and 500 characters",
        ));
    }
    let now = now_ms();
    if input.deadline_at <= now || input.deadline_at > now + 365 * 24 * 60 * 60 * 1000 {
        return Err(ApiError::bad_request(
            "the deadline must be in the future and within one year",
        ));
    }

    let continuation = TaskContinuation {
        id: new_id(),
        task_id: task.id.clone(),
        run_id: run.id,
        agent_id: caller.member.id.clone(),
        command: command.to_string(),
        every_seconds: input.every_seconds,
        deadline_at: input.deadline_at,
        wake_prompt: wake_prompt.to_string(),
        status: ContinuationStatus::Waiting,
        summary: summary.to_string(),
        next_check_at: now + input.every_seconds * 1000,
        created_at: now,
        updated_at: now,
        ended_at: None,
    };
    let updated = state
        .store
        .register_task_continuation(&continuation)?
        .ok_or_else(|| {
            ApiError::conflict(
                "the run ended, the task moved, or this task already has an active obligation",
            )
        })?;
    state.emit(Event::TaskUpdated {
        task: updated.clone(),
    });
    let _ = orchestrator::post_system(
        &state,
        &updated.discussion_channel_id,
        &format!("Patchwork will keep checking: {summary}"),
    )
    .await;
    Ok(Json(updated))
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
            automation_run_id: None,
            automation_run_attempt: None,
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
        asks: state.store.run_asks(&id)?,
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
    orchestrator::cancel_asks_for_run(&state, &run.id).await?;
    state.set_presence(&run.agent_id, Presence::Online).await;
    orchestrator::finish_run(&state, &run).await?;
    Ok(Json(Ok::default()))
}

// ---------------------------------------------------------------------------
// asks
// ---------------------------------------------------------------------------

async fn list_asks(State(state): State<Shared>, caller: Caller) -> ApiResult<Json<Vec<Ask>>> {
    Ok(Json(
        state
            .store
            .open_asks()?
            .into_iter()
            .filter(|ask| {
                crate::visibility::channel(&state.store, &caller.member.id, &ask.channel_id)
                    .unwrap_or(false)
            })
            .collect(),
    ))
}

async fn get_ask(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ask>> {
    let ask = state
        .store
        .ask(&id)?
        .ok_or_else(|| ApiError::not_found("ask not found"))?;
    require_channel_access(&state, &caller, &ask.channel_id)?;
    Ok(Json(ask))
}

/// Every rule about what an ask may be lives here, as a rejection rather than
/// as advice in a document an agent has to remember.
fn check_ask(input: &OpenAsk, kind: AskKind) -> ApiResult<String> {
    let text = input.text.trim();
    if text.is_empty() {
        return Err(ApiError::bad_request("say what you need"));
    }
    if text.chars().count() > ASK_TEXT_LIMIT {
        return Err(ApiError::bad_request(format!(
            "an ask is at most {ASK_TEXT_LIMIT} characters; put the detail in the conversation"
        )));
    }
    if let Some(action) = input.action.as_deref().map(str::trim).filter(|a| !a.is_empty()) {
        if action.chars().any(char::is_control) || action.chars().count() > ASK_ACTION_LIMIT {
            return Err(ApiError::bad_request(format!(
                "an action must be one line of at most {ASK_ACTION_LIMIT} characters"
            )));
        }
    }
    if input.summary.len() > ASK_SUMMARY_LIMIT {
        return Err(ApiError::bad_request(format!(
            "a summary is at most {ASK_SUMMARY_LIMIT} bullets"
        )));
    }
    if kind == AskKind::Review && input.summary.iter().all(|line| line.trim().is_empty()) {
        return Err(ApiError::bad_request(
            "a review needs a summary: up to three bullets saying what changed",
        ));
    }
    Ok(text.to_string())
}

async fn open_ask(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<OpenAsk>,
) -> ApiResult<Json<Ask>> {
    let kind = input.kind.unwrap_or(AskKind::Answer);
    let text = check_ask(&input, kind)?;

    let run = match &input.run_id {
        Some(run_id) => {
            let run = state
                .store
                .run(run_id)?
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
            Some(run)
        }
        None => None,
    };
    let reference = input
        .task_id
        .clone()
        .or_else(|| run.as_ref().and_then(|run| run.task_id.clone()));
    let task = match &reference {
        Some(id) => Some(
            state
                .store
                .task_by_ref(id)?
                .ok_or_else(|| ApiError::not_found("task not found"))?,
        ),
        None => None,
    };
    // Callers name a task however they read it — "PW-102" as often as its id —
    // so the ask hangs off what the reference resolved to. Stored raw, the ask
    // belongs to no task: no card, no status, and nothing to answer it from.
    let task_id = task.as_ref().map(|task| task.id.clone());
    if let Some(task) = &task {
        if task.status.is_terminal() {
            return Err(ApiError::conflict("that task is already closed"));
        }
    }
    let channel_id = match (&run, &task) {
        (Some(run), _) => run.channel_id.clone(),
        (None, Some(task)) => task.discussion_channel_id.clone(),
        _ => return Err(ApiError::bad_request("an ask needs a run or a task")),
    };
    require_channel_access(&state, &caller, &channel_id)?;

    // Review is mechanical: without something concrete to look at, "have a
    // look" is the whole of what a person would be handed.
    if kind == AskKind::Review {
        let task = task
            .as_ref()
            .ok_or_else(|| ApiError::bad_request("a review belongs to a task"))?;
        if !orchestrator::has_review_evidence(
            &state,
            task,
            &orchestrator::evidence_run_ids(&state, task, caller.run_id.as_deref())?,
            None,
        )? && input.evidence_ids.is_empty()
        {
            return Err(ApiError::bad_request(
                "a review needs something to inspect: attach a file, expose a preview, or link a pull request",
            ));
        }
    }

    let agent_id = run
        .as_ref()
        .map(|run| run.agent_id.clone())
        .unwrap_or_else(|| caller.member.id.clone());
    let (_, ask) = orchestrator::open_ask(
        &state,
        orchestrator::NewAsk {
            kind,
            agent_id,
            channel_id,
            task_id,
            run,
            text,
            action: input
                .action
                .as_deref()
                .map(str::trim)
                .filter(|action| !action.is_empty())
                .map(str::to_string),
            summary: input
                .summary
                .iter()
                .map(|line| line.trim().to_string())
                .filter(|line| !line.is_empty())
                .collect(),
            evidence_ids: input.evidence_ids.clone(),
            options: input.options.clone(),
            allow_free_text: !input.require_option,
            multi_select: input.multi_select,
            replace: input.replace,
        },
    )
    .await
    .map_err(|err| match err.downcast::<orchestrator::AlreadyAsking>() {
        Ok(already) => ApiError::conflict(already.to_string()),
        Err(err) => ApiError::from(err),
    })?;
    Ok(Json(ask))
}

async fn answer_ask(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
    Json(input): Json<AnswerAsk>,
) -> ApiResult<Json<Ask>> {
    caller.require_device()?;
    let ask = state
        .store
        .ask(&id)?
        .ok_or_else(|| ApiError::not_found("ask not found"))?;
    require_channel_access(&state, &caller, &ask.channel_id)?;
    if ask.status != AskStatus::Open {
        return Err(ApiError::conflict("that ask is no longer waiting"));
    }
    Ok(Json(
        orchestrator::answer_ask(&state, &id, input.answer, input.note, &caller.member.id).await?,
    ))
}

/// The agent side of `patchwork ask`: hold the connection until a person
/// answers, so the run genuinely continues in context.
async fn wait_for_answer(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<Ask>> {
    let ask = state
        .store
        .ask(&id)?
        .ok_or_else(|| ApiError::not_found("ask not found"))?;
    require_channel_access(&state, &caller, &ask.channel_id)?;
    if !caller.is_agent()
        || caller.member.id != ask.agent_id
        || caller.run_id.as_deref() != ask.run_id.as_deref()
    {
        return Err(ApiError::forbidden(
            "only the asking run can wait for this answer",
        ));
    }
    if ask.status != AskStatus::Open {
        return Ok(Json(ask));
    }

    let rx = state.wait_for_answer(&id).await;
    // Re-read after registering: an answer that landed in between would
    // otherwise make the agent wait out the whole long-poll for nothing.
    if let Some(answered) = state.store.ask(&id)? {
        if answered.status != AskStatus::Open {
            return Ok(Json(answered));
        }
    }
    match tokio::time::timeout(std::time::Duration::from_secs(90), rx).await {
        Ok(Result::Ok(answered)) => Ok(Json(answered)),
        // A timeout is not an error: the caller polls again.
        _ => Ok(Json(
            state
                .store
                .ask(&id)?
                .ok_or_else(|| ApiError::not_found("ask not found"))?,
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

const DAILY_SWEEP_NAME: &str = "Daily sweep";
const DAILY_SWEEP_INSTRUCTIONS: &str = "Review recent workspace conversations, open and running tasks, inbox items, and automation health. DM the user a concise daily sweep based on that state, ending with 2-3 concrete proposals they can tap as structured suggestions.";

fn ensure_daily_sweep(state: &Shared, owner: &Member, agent: &Member) -> ApiResult<()> {
    if owner.kind != MemberKind::Human
        || state.store.automations()?.iter().any(|automation| {
            automation.created_by == owner.id && automation.name == DAILY_SWEEP_NAME
        })
    {
        return Ok(());
    }
    let channel = dm_between(state, owner, agent)?;
    let now = now_ms();
    let automation = Automation {
        id: new_id(),
        name: DAILY_SWEEP_NAME.into(),
        description: "A daily workspace scan with proposed next actions.".into(),
        enabled: true,
        trigger: AutomationTrigger::Cron {
            expression: "0 9 * * *".into(),
        },
        agent_id: agent.id.clone(),
        action: AutomationAction::PostInChat,
        instructions: DAILY_SWEEP_INSTRUCTIONS.into(),
        context_channel_id: Some(channel.id.clone()),
        report_channel_id: Some(channel.id),
        project_id: None,
        location: ExecutionLocation::Auto,
        host_id: None,
        created_by: owner.id.clone(),
        created_at: now,
        last_run_at: None,
        next_run_at: automations::next_cron_after("0 9 * * *", now),
        last_success_at: None,
        last_error_at: None,
        last_error: None,
        last_validated_at: None,
        failure_count: 0,
        overdue_since: None,
        blocked_reason: None,
        retry_at: None,
    };
    state.store.upsert_automation(&automation)?;
    state.emit(Event::AutomationUpdated { automation });
    Ok(())
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
    ensure_daily_sweep(&state, &caller.member, &member)?;
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

fn watch_schedule_changed(old: &AutomationTrigger, new: &AutomationTrigger) -> bool {
    matches!(
        (old, new),
        (
            AutomationTrigger::Watch { every_seconds: old, .. },
            AutomationTrigger::Watch { every_seconds: new, .. },
        ) if old != new
    )
}

fn validate_automation_config(input: &CreateAutomation) -> ApiResult<()> {
    match &input.trigger {
        AutomationTrigger::Watch {
            command,
            every_seconds,
        } => {
            if command.trim().is_empty() {
                return Err(ApiError::bad_request("a watch command is required"));
            }
            if *every_seconds <= 0 {
                return Err(ApiError::bad_request("a watch interval must be positive"));
            }
        }
        AutomationTrigger::Schedule { every_seconds, .. } if *every_seconds <= 0 => {
            return Err(ApiError::bad_request(
                "a schedule interval must be positive",
            ));
        }
        AutomationTrigger::Cron { expression }
            if automations::next_cron_after(expression, now_ms()).is_none() =>
        {
            return Err(ApiError::bad_request("a valid cron expression is required"));
        }
        _ => {}
    }
    Ok(())
}

async fn create_automation(
    State(state): State<Shared>,
    caller: Caller,
    Json(input): Json<CreateAutomation>,
) -> ApiResult<Json<Automation>> {
    validate_automation_config(&input)?;
    let created_at = now_ms();
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
        created_at,
        last_run_at: None,
        next_run_at: if input.enabled {
            match &input.trigger {
                AutomationTrigger::Schedule {
                    every_seconds,
                    start_at,
                } => Some(
                    start_at
                        .unwrap_or(created_at.saturating_add(every_seconds.saturating_mul(1000))),
                ),
                AutomationTrigger::Cron { expression } => {
                    automations::next_cron_after(expression, created_at)
                }
                AutomationTrigger::Watch { every_seconds, .. } => {
                    Some(created_at.saturating_add(every_seconds.saturating_mul(1000)))
                }
                _ => None,
            }
        } else {
            None
        },
        last_success_at: None,
        last_error_at: None,
        last_error: None,
        last_validated_at: None,
        failure_count: 0,
        overdue_since: None,
        blocked_reason: None,
        retry_at: None,
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
    validate_automation_config(&input)?;
    let previous_trigger = automation.trigger.clone();
    let watch_command_changed = match (&automation.trigger, &input.trigger) {
        (
            AutomationTrigger::Watch { command: old, .. },
            AutomationTrigger::Watch { command: new, .. },
        ) => old != new,
        (AutomationTrigger::Watch { .. }, _) | (_, AutomationTrigger::Watch { .. }) => true,
        _ => false,
    };
    let watch_interval_changed = watch_schedule_changed(&automation.trigger, &input.trigger);
    let was_enabled = automation.enabled;
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
    automation.next_run_at = match &automation.trigger {
        AutomationTrigger::Schedule { every_seconds, .. } if automation.enabled => {
            Some(now_ms().saturating_add(every_seconds.saturating_mul(1000)))
        }
        AutomationTrigger::Cron { expression } if automation.enabled => {
            automations::next_cron_after(expression, now_ms())
        }
        AutomationTrigger::Watch { every_seconds, .. }
            if automation.enabled
                && (!was_enabled || watch_command_changed || watch_interval_changed) =>
        {
            Some(now_ms().saturating_add(every_seconds.saturating_mul(1000)))
        }
        AutomationTrigger::Watch { .. } if automation.enabled => automation.next_run_at,
        _ => None,
    };
    require_automation_access(&state, &caller, &automation)?;
    let automation = state
        .store
        .update_automation_config(
            &automation,
            &previous_trigger,
            was_enabled,
            watch_command_changed,
        )?
        .ok_or_else(|| ApiError::conflict("automation changed; retry your update"))?;
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
    if !automation.enabled {
        return Err(ApiError::conflict(
            "resume this automation before running it",
        ));
    }
    Ok(Json(
        automations::run_now(&state, &automation, &caller.member.display_name).await?,
    ))
}

async fn test_automation(
    State(state): State<Shared>,
    caller: Caller,
    Path(id): Path<Id>,
) -> ApiResult<Json<WatchTestResult>> {
    let automation = state
        .store
        .automation(&id)?
        .ok_or_else(|| ApiError::not_found("automation not found"))?;
    require_automation_access(&state, &caller, &automation)?;
    if !matches!(automation.trigger, AutomationTrigger::Watch { .. }) {
        return Err(ApiError::bad_request(
            "only watch automations can be tested",
        ));
    }
    Ok(Json(automations::test_watch(&state, &automation).await?))
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
    /// Contents of the workspace's AUTONOMY.md policy.
    #[serde(default)]
    autonomy: Option<String>,
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
    if input.autonomy.is_some() {
        caller.require_device()?;
    }
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
    let autonomy = input.autonomy.as_deref().map(str::trim);
    if autonomy.is_some_and(|policy| policy.len() > MAX_SKILL_INSTRUCTIONS_BYTES) {
        return Err(ApiError::bad_request("AUTONOMY.md is limited to 32 KB"));
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
        autonomy,
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

    fn watch_input(enabled: bool, command: &str) -> CreateAutomation {
        CreateAutomation {
            name: "Watch".into(),
            description: String::new(),
            trigger: AutomationTrigger::Watch {
                command: command.into(),
                every_seconds: 60,
            },
            agent_id: "agent".into(),
            action: AutomationAction::CreateTask,
            instructions: String::new(),
            context_channel_id: None,
            report_channel_id: None,
            project_id: None,
            location: ExecutionLocation::Auto,
            host_id: None,
            enabled,
        }
    }

    #[test]
    fn watch_validation_is_health_not_enabled_state() {
        assert!(validate_automation_config(&watch_input(false, "scan")).is_ok());
        assert!(validate_automation_config(&watch_input(true, "scan")).is_ok());
        assert!(validate_automation_config(&watch_input(true, "  ")).is_err());

        let current = AutomationTrigger::Watch {
            command: "scan".into(),
            every_seconds: 60,
        };
        assert!(watch_schedule_changed(
            &current,
            &AutomationTrigger::Watch {
                command: "scan".into(),
                every_seconds: 300,
            }
        ));
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
    async fn workspace_policy_is_human_admin_controlled_and_bounded() {
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
        let agent = Caller {
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
            agent.clone(),
            Json(WorkspaceInput {
                name: None,
                icon: None,
                icon_file_id: Some("icon".into()),
                task_prefix: None,
                autonomy: None,
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
        assert!(update_workspace(
            State(state.clone()),
            agent,
            Json(WorkspaceInput {
                name: None,
                icon: None,
                icon_file_id: None,
                task_prefix: None,
                autonomy: Some("Agents may change this policy.".into()),
            }),
        )
        .await
        .is_err());

        let human_admin = Caller {
            member: Member {
                id: "human".into(),
                kind: MemberKind::Human,
                handle: "human".into(),
                display_name: "Human".into(),
                email: None,
                avatar: None,
                is_admin: true,
                created_at: 1,
                agent: None,
                presence: Presence::Offline,
            },
            run_id: None,
            token_hash: "human-hash".into(),
            token_kind: "device".into(),
        };
        let Json(updated) = update_workspace(
            State(state.clone()),
            human_admin.clone(),
            Json(WorkspaceInput {
                name: None,
                icon: Some("🚀".into()),
                icon_file_id: None,
                task_prefix: None,
                autonomy: Some("  Merge after checks pass.  ".into()),
            }),
        )
        .await
        .unwrap();
        assert_eq!(updated.icon, "🚀");
        assert_eq!(updated.autonomy, "Merge after checks pass.");

        assert!(update_workspace(
            State(state.clone()),
            human_admin,
            Json(WorkspaceInput {
                name: None,
                icon: None,
                icon_file_id: None,
                task_prefix: None,
                autonomy: Some("x".repeat(MAX_SKILL_INSTRUCTIONS_BYTES + 1)),
            }),
        )
        .await
        .is_err());
        assert_eq!(state.store.workspace().unwrap().autonomy, updated.autonomy);

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
    fn an_unfinished_pull_request_blocks_completion() {
        let mut task: Task = serde_json::from_value(serde_json::json!({
            "id": "task",
            "key": "PW-1",
            "title": "Ship it",
            "outcome": "The change is live",
            "status": "review",
            "discussion_channel_id": "channel",
            "created_by": "human",
            "created_at": 1,
            "updated_at": 1,
            "position": 1
        }))
        .unwrap();
        let mut input = UpdateTask {
            status: Some(TaskStatus::Done),
            ..Default::default()
        };
        assert!(!pull_request_blocks_completion(&task, &input));

        task.pr_url = Some("https://github.com/acme/app/pull/42".into());
        assert!(pull_request_blocks_completion(&task, &input));
        for state in ["OPEN", "DRAFT", "MERGED", "CLOSED", "merged", "closed"] {
            task.pr_state = Some(PullRequestState {
                number: 42,
                title: "Ship it".into(),
                state: state.into(),
                checks: String::new(),
                review: String::new(),
                last_feedback_at: String::new(),
                updated_at: 1,
            });
            assert_eq!(
                pull_request_blocks_completion(&task, &input),
                matches!(state, "OPEN" | "DRAFT")
            );
        }

        input.pr_url = Some("https://github.com/acme/app/pull/43".into());
        assert!(pull_request_blocks_completion(&task, &input));
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
    async fn message_sends_validate_replies_and_dedupe_client_retries() {
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
                digest: String::new(),
                card: None,
                suggestions: Vec::new(),
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
            State(state.clone()),
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

        let client_id = new_id();
        let Json(first) = send_message(
            State(state.clone()),
            caller(),
            Path("one".into()),
            Json(SendMessage {
                body: "Retry me".into(),
                suggestions: vec![
                    " First ".into(),
                    String::new(),
                    "Second".into(),
                    "Third".into(),
                    "Fourth".into(),
                ],
                client_id: Some(client_id.clone()),
                ..Default::default()
            }),
        )
        .await
        .unwrap();
        let Json(retried) = send_message(
            State(state.clone()),
            caller(),
            Path("one".into()),
            Json(SendMessage {
                body: "Retry me".into(),
                suggestions: vec!["First".into(), "Second".into(), "Third".into()],
                client_id: Some(client_id),
                ..Default::default()
            }),
        )
        .await
        .unwrap();
        assert_eq!(retried.id, first.id);
        assert_eq!(first.suggestions, ["First", "Second", "Third"]);
        assert_eq!(store.messages("one", None, 50).unwrap().0.len(), 1);

        let client_id = new_id();
        let input = SendMessage {
            body: "Race me".into(),
            client_id: Some(client_id),
            ..Default::default()
        };
        let first_send = send_message(
            State(state.clone()),
            caller(),
            Path("one".into()),
            Json(input.clone()),
        );
        let second_send = send_message(State(state), caller(), Path("one".into()), Json(input));
        let (first_race, second_race) = tokio::join!(first_send, second_send);
        assert_eq!(first_race.unwrap().0.id, second_race.unwrap().0.id);
        assert_eq!(store.messages("one", None, 50).unwrap().0.len(), 2);

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
            provider: None,
            model: None,
            thinking: None,
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
            brief: String::new(),
            status: TaskStatus::Running,
            owner_id: Some(agent.id.clone()),
            source_channel_id: Some("channel".into()),
            source_message_id: None,
            discussion_channel_id: "channel".into(),
            project_id: None,
            host_id: Some("host-one".into()),
            worktree_id: None,
            current_run_id: Some("run-one".into()),
            active_continuation: None,
            pr_url: None,
            pr_state: None,
            ask: None,
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
        let asking = |run_id: &str| OpenAsk {
            run_id: Some(run_id.into()),
            text: "Continue?".into(),
            ..Default::default()
        };
        let replace = |run_id: &str| OpenAsk {
            replace: true,
            ..asking(run_id)
        };
        let nothing = || AnswerAsk::default();

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
            open_ask(State(state.clone()), human_caller(), Json(asking("run-one")),)
                .await
                .unwrap_err()
                .status,
            axum::http::StatusCode::FORBIDDEN
        );
        assert_eq!(
            open_ask(
                State(state.clone()),
                agent_caller("another-run"),
                Json(asking("run-one")),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::FORBIDDEN
        );

        let first = open_ask(
            State(state.clone()),
            agent_caller("run-one"),
            Json(asking("run-one")),
        )
        .await
        .unwrap()
        .0;
        assert!(first.message_id.is_some());
        // An open ask of any kind other than review reads as blocked, and the
        // task never had to be told so.
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
            answer_ask(
                State(state.clone()),
                agent_caller("run-one"),
                Path(first.id.clone()),
                Json(nothing()),
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
                Path(first.id.clone()),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::FORBIDDEN
        );
        // A run asks one thing at a time, and the messages it would have
        // posted do not survive the refusal.
        let count = || store.messages("channel", None, 200).unwrap().0.len();
        let before = count();
        assert_eq!(
            open_ask(
                State(state.clone()),
                agent_caller("run-one"),
                Json(asking("run-one")),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::CONFLICT
        );
        assert_eq!(count(), before, "a refused ask posts no card");
        // Replacing is how a run whose ask died gets to ask again. The
        // abandoned card stops holding the task in Blocked.
        let second = open_ask(
            State(state.clone()),
            agent_caller("run-one"),
            Json(replace("run-one")),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(
            store.ask(&first.id).unwrap().unwrap().status,
            AskStatus::Cancelled,
        );
        assert_eq!(
            answer_ask(
                State(state.clone()),
                human_caller(),
                Path(first.id),
                Json(nothing()),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::CONFLICT
        );
        assert_eq!(
            store.run("run-one").unwrap().unwrap().status,
            RunStatus::Waiting
        );
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Blocked
        );
        assert_eq!(
            store.ask(&second.id).unwrap().unwrap().status,
            AskStatus::Open
        );
        assert_eq!(
            store
                .inbox(&human.id, false)
                .unwrap()
                .iter()
                .filter(|item| item.run_id.as_deref() == Some("run-one"))
                .count(),
            1,
            "the superseded ask's Inbox row is resolved with its card",
        );
        let answered = answer_ask(
            State(state.clone()),
            human_caller(),
            Path(second.id),
            Json(AnswerAsk {
                answer: vec!["Continue".into()],
                note: "ship it".into(),
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(answered.answer, ["Continue"]);
        assert_eq!(answered.answer_text(), "Continue, ship it");
        // Answering releases the run that was waiting on it, and the task
        // follows the run again because nothing is open any more.
        assert_eq!(
            store.run("run-one").unwrap().unwrap().status,
            RunStatus::Running
        );
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Running
        );

        store.insert_run(&make_run("run-two"), 0).unwrap();
        store
            .insert_token("run-two-token", &agent.id, "run", Some("run-two"), None)
            .unwrap();
        let waiting = open_ask(
            State(state.clone()),
            agent_caller("run-two"),
            Json(asking("run-two")),
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
            store.ask(&waiting.id).unwrap().unwrap().status,
            AskStatus::Cancelled
        );
        assert_eq!(
            open_ask(
                State(state.clone()),
                agent_caller("run-two"),
                Json(asking("run-two")),
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

    #[tokio::test]
    async fn a_delegated_task_reports_to_the_conversation_its_parent_came_from() {
        let path = std::env::temp_dir().join(format!("patchwork-delegated-{}.sqlite", new_id()));
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
        store
            .insert_channel(&Channel {
                id: "origin".into(),
                kind: ChannelKind::Channel,
                section_id: None,
                slug: "origin".into(),
                name: "Origin".into(),
                topic: String::new(),
                position: 0.0,
                created_at: 1,
                member_ids: Vec::new(),
                task_id: None,
                last_message_at: 0,
            })
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));
        let parent = orchestrator::create_task(
            &state,
            &agent.id,
            CreateTask {
                title: "Parent".into(),
                outcome: "Delegate work".into(),
                status: Some(TaskStatus::Planned),
                source_channel_id: Some("origin".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let run = |id: &str, task: &Task, trigger: RunTrigger| Run {
            id: id.into(),
            agent_id: agent.id.clone(),
            status: RunStatus::Running,
            trigger,
            channel_id: task.discussion_channel_id.clone(),
            task_id: Some(task.id.clone()),
            host_id: None,
            project_id: None,
            worktree_id: None,
            cwd: None,
            automation_id: None,
            session_id: None,
            runtime: "test".into(),
            provider: None,
            model: None,
            thinking: None,
            prompt: String::new(),
            headline: "Working".into(),
            error: None,
            token_usage: None,
            created_at: 1,
            started_at: Some(1),
            ended_at: None,
        };
        let parent_run = run(
            "parent-run",
            &parent,
            RunTrigger::TaskAssignment {
                task_id: parent.id.clone(),
            },
        );
        store.insert_run(&parent_run, 0).unwrap();

        let child = create_task(
            State(state.clone()),
            Caller {
                member: agent.clone(),
                run_id: Some(parent_run.id.clone()),
                token_hash: "hash".into(),
                token_kind: "run".into(),
            },
            Json(CreateTask {
                title: "Delegated child".into(),
                outcome: "The delegated result is ready".into(),
                status: Some(TaskStatus::Planned),
                allow_similar: true,
                ..Default::default()
            }),
        )
        .await
        .unwrap()
        .0;
        // Every task reports back where the work was asked for, so a task an
        // agent creates mid-run inherits its parent's conversation rather than
        // disappearing into its own discussion.
        assert_eq!(child.source_channel_id.as_deref(), Some("origin"));

        let mut continuation_run = run(
            "continuation-run",
            &child,
            RunTrigger::Continuation {
                continuation_id: "wait".into(),
            },
        );
        store.insert_run(&continuation_run, 0).unwrap();
        store
            .activate_task_run(&child.id, &continuation_run.id, None)
            .unwrap()
            .unwrap();
        let mut completed = store.task(&child.id).unwrap().unwrap();
        completed.status = TaskStatus::Done;
        store.update_task(&completed).unwrap();
        store
            .insert_message(&Message {
                id: "summary".into(),
                channel_id: child.discussion_channel_id.clone(),
                author_id: agent.id.clone(),
                kind: MessageKind::Text,
                body: "The delegated result is ready.".into(),
                digest: String::new(),
                card: None,
                suggestions: Vec::new(),
                parent_id: None,
                reply_to_id: None,
                reply_to: None,
                reply_count: 0,
                last_reply_at: 0,
                run_id: Some(continuation_run.id.clone()),
                task_id: Some(child.id.clone()),
                mentions: Vec::new(),
                attachments: Vec::new(),
                reactions: Vec::new(),
                created_at: 2,
                edited_at: None,
            })
            .unwrap();
        continuation_run.status = RunStatus::Succeeded;
        continuation_run.ended_at = Some(3);
        store.update_run(&continuation_run).unwrap();
        orchestrator::finish_run(&state, &continuation_run)
            .await
            .unwrap();

        let reports: Vec<_> = store
            .messages("origin", None, 20)
            .unwrap()
            .0
            .into_iter()
            .filter(|message| message.body == "The delegated result is ready.")
            .collect();
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].author_id, agent.id);
        assert_eq!(reports[0].run_id.as_deref(), Some("continuation-run"));
        assert_eq!(
            store.task(&child.id).unwrap().unwrap().status,
            TaskStatus::Done
        );

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    /// Two agents in one task and one worktree: the task belongs to both of
    /// them until the last one stops, and either one's evidence is the task's.
    #[tokio::test]
    async fn only_the_live_task_run_can_register_its_continuation() {
        let path = std::env::temp_dir().join(format!("patchwork-continuation-{}.sqlite", new_id()));
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
                title: "Ship build".into(),
                outcome: "Build reaches testers".into(),
                owner_id: Some(agent.id.clone()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let run = Run {
            id: "run".into(),
            agent_id: agent.id.clone(),
            status: RunStatus::Running,
            trigger: RunTrigger::Manual { by: "human".into() },
            channel_id: task.discussion_channel_id.clone(),
            task_id: Some(task.id.clone()),
            host_id: Some("host".into()),
            project_id: None,
            worktree_id: None,
            cwd: None,
            automation_id: None,
            session_id: None,
            runtime: "test".into(),
            provider: None,
            model: None,
            thinking: None,
            prompt: String::new(),
            headline: "Working".into(),
            error: None,
            token_usage: None,
            created_at: 1,
            started_at: Some(1),
            ended_at: None,
        };
        store.insert_run(&run, 0).unwrap();
        store
            .activate_task_run(&task.id, &run.id, None)
            .unwrap()
            .unwrap();
        let input = CreateTaskContinuation {
            command: "check-build".into(),
            every_seconds: 60,
            deadline_at: now_ms() + 60_000,
            wake_prompt: "Finish the release".into(),
            summary: "Build is processing".into(),
        };
        let mut caller = Caller {
            member: agent,
            run_id: Some("someone-elses-run".into()),
            token_hash: "hash".into(),
            token_kind: "run".into(),
        };
        assert_eq!(
            create_task_continuation(
                State(state.clone()),
                caller.clone(),
                Path(task.id.clone()),
                Json(input.clone()),
            )
            .await
            .unwrap_err()
            .status,
            axum::http::StatusCode::FORBIDDEN
        );

        caller.run_id = Some(run.id.clone());
        let Json(updated) = create_task_continuation(
            State(state.clone()),
            caller,
            Path(task.id.clone()),
            Json(input),
        )
        .await
        .unwrap();
        assert_eq!(updated.status, TaskStatus::Running);
        assert_eq!(
            updated
                .active_continuation
                .as_ref()
                .map(|continuation| continuation.summary.as_str()),
            Some("Build is processing")
        );

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

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
            provider: None,
            model: None,
            thinking: None,
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
        // The last one out gives the task back, and gives it back to nobody in
        // particular: a finished run promotes nothing, so a task that wants a
        // person has to say so with an ask.
        assert_eq!(done.status, TaskStatus::Planned);
        assert!(done.ask.is_none());
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

        // Handing work to a person is opening a review ask, and a review ask is
        // mechanical: it needs bullets saying what changed and something
        // concrete to inspect, so "have a look" can never be all somebody gets.
        let ask_as = |bearer: &str, body: String| {
            Request::builder()
                .method("POST")
                .uri("/api/asks")
                .header("authorization", format!("Bearer {bearer}"))
                .header("content-type", "application/json")
                .body(axum::body::Body::from(body))
                .unwrap()
        };
        let response = router(state.clone())
            .oneshot(ask_as(
                &token,
                format!(
                    r#"{{"kind":"review","task_id":"{}","text":"Ready for you"}}"#,
                    task.id
                ),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            axum::http::StatusCode::BAD_REQUEST,
            "a review without a summary is refused"
        );
        let response = router(state.clone())
            .oneshot(ask_as(
                &token,
                format!(
                    r#"{{"kind":"review","task_id":"{}","text":"Ready for you","summary":["Rewrote the proxy"]}}"#,
                    task.id
                ),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            axum::http::StatusCode::BAD_REQUEST,
            "a stopped preview is not something to inspect"
        );
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().status,
            TaskStatus::Planned
        );

        let mut running = store.task(&task.id).unwrap().unwrap();
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
                provider: None,
                model: None,
                thinking: None,
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
                provider: None,
                model: None,
                thinking: None,
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
            TaskStatus::Planned,
            "a finished run promotes nothing; only an ask makes a task wait",
        );

        // For an inquiry, the written answer is itself the thing a person
        // reviews, so the review ask is accepted with no file or preview.
        let answer_run_token = auth::generate_token();
        store
            .insert_token(
                &auth::hash_token(&answer_run_token),
                &agent.id,
                "run",
                Some("answer-run"),
                None,
            )
            .unwrap();
        // Named by its key, the way a person or an agent reads it back. The
        // ask must hang off the task that resolved to, or it belongs to no
        // task at all: no card, no status, and nothing to answer it from.
        let response = router(state.clone())
            .oneshot(ask_as(
                &answer_run_token,
                format!(
                    r#"{{"kind":"review","task_id":"{}","text":"Is this the answer you needed?","summary":["It indexes task titles and outcomes"]}}"#,
                    auto_reviewed.key
                ),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        let reviewing = store.task(&auto_reviewed.id).unwrap().unwrap();
        assert_eq!(reviewing.status, TaskStatus::Review);
        assert_eq!(
            reviewing.ask.as_ref().map(|ask| ask.kind),
            Some(AskKind::Review)
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

        // The uploaded file is something to inspect, so the same review ask is
        // now accepted. Its `action` is the approval button.
        let response = router(state.clone())
            .oneshot(ask_as(
                &token,
                format!(
                    r#"{{"kind":"review","task_id":"{}","text":"Ready for you","action":"Approve and deploy app","summary":["Rewrote the proxy","Recorded a demo"]}}"#,
                    task.id
                ),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        let review: Ask = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap(),
        )
        .unwrap();
        let reviewing = store.task(&task.id).unwrap().unwrap();
        assert_eq!(reviewing.status, TaskStatus::Review);
        assert_eq!(
            reviewing.ask.as_ref().and_then(|ask| ask.action.as_deref()),
            Some("Approve and deploy app")
        );

        // Approval is answering that ask with its action label, and only a
        // person on a device may do it.
        let answer = |bearer: &str, id: &str, body: &str| {
            Request::builder()
                .method("POST")
                .uri(format!("/api/asks/{id}/answer"))
                .header("authorization", format!("Bearer {bearer}"))
                .header("content-type", "application/json")
                .body(axum::body::Body::from(body.to_string()))
                .unwrap()
        };
        let response = router(state.clone())
            .oneshot(answer(
                &token,
                &review.id,
                r#"{"answer":["Approve and deploy app"]}"#,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::FORBIDDEN);

        let response = router(state.clone())
            .oneshot(answer(
                &human_token,
                &review.id,
                r#"{"answer":["Approve and deploy app"],"note":"ship it"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        let approved: Ask = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(approved.status, AskStatus::Answered);
        assert_eq!(approved.answer, ["Approve and deploy app"]);
        assert_eq!(approved.answered_by.as_deref(), Some(human.id.as_str()));
        let approved_task = store.task(&task.id).unwrap().unwrap();
        assert!(
            approved_task.ask.is_none(),
            "an answered ask stops the task waiting on anybody"
        );
        assert_ne!(approved_task.status, TaskStatus::Review);

        // Answering is once: the second attempt has nothing left to answer.
        let response = router(state.clone())
            .oneshot(answer(
                &human_token,
                &review.id,
                r#"{"answer":["Approve and deploy app"]}"#,
            ))
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
    async fn only_admins_manage_sections_and_deleting_one_keeps_its_channels() {
        let path = std::env::temp_dir().join(format!("patchwork-api-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        let add_member = |id: &str, kind: MemberKind, is_admin: bool| {
            store
                .insert_member(&Member {
                    id: id.into(),
                    kind,
                    handle: id.into(),
                    display_name: id.into(),
                    email: None,
                    avatar: None,
                    is_admin,
                    created_at: 1,
                    agent: (kind == MemberKind::Agent).then(AgentProfile::default),
                    presence: Presence::Offline,
                })
                .unwrap();
            let token = auth::generate_token();
            store
                .insert_token(
                    &auth::hash_token(&token),
                    id,
                    if kind == MemberKind::Agent {
                        "run"
                    } else {
                        "device"
                    },
                    None,
                    None,
                )
                .unwrap();
            token
        };
        let human_member = add_member("human-member", MemberKind::Human, false);
        let agent_member = add_member("agent-member", MemberKind::Agent, false);
        let human_admin = add_member("human-admin", MemberKind::Human, true);
        let agent_admin = add_member("agent-admin", MemberKind::Agent, true);

        for (position, id) in ["agent-section", "human-section"].into_iter().enumerate() {
            store
                .upsert_section(&Section {
                    id: id.into(),
                    name: id.into(),
                    position: position as f64,
                })
                .unwrap();
            store
                .insert_channel(&Channel {
                    id: format!("{id}-channel"),
                    kind: ChannelKind::Channel,
                    section_id: Some(id.into()),
                    slug: format!("{id}-channel"),
                    name: format!("{id}-channel"),
                    topic: String::new(),
                    position: position as f64,
                    created_at: 1,
                    member_ids: Vec::new(),
                    task_id: None,
                    last_message_at: 0,
                })
                .unwrap();
        }
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));
        let request = |method: &str, path: &str, token: &str, body: &str| {
            Request::builder()
                .method(method)
                .uri(path)
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(axum::body::Body::from(body.to_string()))
                .unwrap()
        };

        for token in [&human_member, &agent_member] {
            let response = router(state.clone())
                .oneshot(request(
                    "PATCH",
                    "/api/sections/agent-section",
                    token,
                    r#"{"name":"Nope"}"#,
                ))
                .await
                .unwrap();
            assert_eq!(response.status(), axum::http::StatusCode::FORBIDDEN);
            let response = router(state.clone())
                .oneshot(request("DELETE", "/api/sections/agent-section", token, ""))
                .await
                .unwrap();
            assert_eq!(response.status(), axum::http::StatusCode::FORBIDDEN);
        }

        let response = router(state.clone())
            .oneshot(request(
                "PATCH",
                "/api/sections/agent-section",
                &agent_admin,
                r#"{"name":"   "}"#,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::BAD_REQUEST);

        for (token, id, name) in [
            (&agent_admin, "agent-section", "Agent renamed"),
            (&human_admin, "human-section", "Human renamed"),
        ] {
            let response = router(state.clone())
                .oneshot(request(
                    "PATCH",
                    &format!("/api/sections/{id}"),
                    token,
                    &format!(r#"{{"name":"{name}"}}"#),
                ))
                .await
                .unwrap();
            assert_eq!(response.status(), axum::http::StatusCode::OK);
            assert_eq!(
                store
                    .sections()
                    .unwrap()
                    .into_iter()
                    .find(|section| section.id == id)
                    .unwrap()
                    .name,
                name
            );

            let response = router(state.clone())
                .oneshot(request("DELETE", &format!("/api/sections/{id}"), token, ""))
                .await
                .unwrap();
            assert_eq!(response.status(), axum::http::StatusCode::OK);
            assert!(store
                .sections()
                .unwrap()
                .into_iter()
                .all(|section| section.id != id));
        }

        for id in ["agent-section-channel", "human-section-channel"] {
            assert_eq!(store.channel(id).unwrap().unwrap().section_id, None);
        }
        let events = store.events_since(0, 20).unwrap();
        for id in ["agent-section-channel", "human-section-channel"] {
            assert!(events.iter().any(|envelope| matches!(
                &envelope.event,
                Event::ChannelUpdated { channel }
                    if channel.id == id && channel.section_id.is_none()
            )));
        }
        assert_eq!(
            events
                .iter()
                .filter(|envelope| matches!(envelope.event, Event::SectionsUpdated { .. }))
                .count(),
            4
        );

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn the_first_agent_gets_one_daily_sweep_to_its_creator() {
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
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));

        ensure_daily_sweep(&state, &human, &agent).unwrap();
        ensure_daily_sweep(&state, &human, &agent).unwrap();

        let automations = store.automations().unwrap();
        assert_eq!(automations.len(), 1);
        let sweep = &automations[0];
        assert_eq!(sweep.name, DAILY_SWEEP_NAME);
        assert_eq!(sweep.agent_id, agent.id);
        assert!(sweep.enabled);
        assert!(sweep.next_run_at.is_some());
        let channel = store
            .channel(sweep.report_channel_id.as_deref().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(channel.kind, ChannelKind::Dm);
        assert_eq!(channel.member_ids.len(), 2);
        assert!(channel.member_ids.contains(&human.id));
        assert!(channel.member_ids.contains(&agent.id));

        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
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
