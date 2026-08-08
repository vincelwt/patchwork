//! Patchwork Desktop: the collaboration UI plus this machine's local agent
//! execution. The UI talks to the relay directly; this side owns the host
//! connection and the settings that survive a restart.

mod awake;
mod dictation;
mod host;
mod relay;
mod settings;

use std::collections::BTreeMap;
use std::sync::Arc;

use host::{HostStatus, LocalHost};
use serde::{Deserialize, Serialize};
use settings::{Settings, WorkspaceSettings};
use tauri::Emitter;

struct AppState {
    local_host: Arc<LocalHost>,
    awake: Arc<awake::Keeper>,
    hosted_relay: Arc<relay::Hosted>,
}

#[derive(Debug, Serialize)]
struct DesktopInfo {
    settings: Settings,
    host: HostStatus,
    platform: String,
    capabilities: patchwork_core::models::HostCapabilities,
    hosting_relay: bool,
}

/// Everything the app needs before it can draw anything, and nothing else.
///
/// Kept apart from [`desktop_info`] because the window opens behind this call:
/// asking the machine what agents it has installed means a subprocess per
/// runtime and a round trip to GitHub, and none of that decides what the first
/// frame looks like.
#[derive(Debug, Serialize)]
struct DesktopBoot {
    settings: Settings,
    host: HostStatus,
    platform: String,
    /// Whether this machine is the relay, and is serving right now.
    hosting_relay: bool,
}

#[derive(Debug, Deserialize)]
struct JoinInput {
    relay_url: String,
    invite_code: String,
    display_name: String,
}

/// The providers the Patchwork agent can be pointed at.
#[tauri::command]
fn patchwork_providers() -> &'static [patchwork_agent::ProviderInfo] {
    patchwork_agent::PROVIDERS
}

/// Remember an API key for a provider, or forget it when the key is empty.
/// The host is restarted because a run picks its environment up at launch.
#[tauri::command]
async fn set_provider_key(
    state: tauri::State<'_, AppState>,
    provider: String,
    key: String,
) -> Result<Settings, String> {
    let mut current = settings::load();
    let key = key.trim().to_string();
    if key.is_empty() {
        current.provider_keys.remove(&provider);
    } else {
        current.provider_keys.insert(provider, key);
    }
    settings::save(&current).map_err(|e| e.to_string())?;
    state.local_host.restart(current.clone()).await;
    Ok(current.redacted())
}

/// Sign the Patchwork agent into a subscription. The flow is a browser login
/// and a pasted code, so it belongs in a terminal: we open one where we can,
/// and hand back the command either way.
#[tauri::command]
fn pi_login(provider: String) -> Result<String, String> {
    let command = patchwork_agent::providers::login_command(&provider);
    #[cfg(target_os = "macos")]
    {
        let script = format!(
            "tell application \"Terminal\" to do script \"{}\"\ntell application \"Terminal\" to activate",
            command.replace('\\', "\\\\").replace('"', "\\\"")
        );
        let _ = std::process::Command::new("osascript")
            .arg("-e")
            .arg(script)
            .spawn();
    }
    Ok(command)
}

#[derive(Debug, Deserialize)]
struct HostInput {
    workspace_name: String,
    display_name: String,
}

/// POST some JSON at a relay and read the error message it sends back, which
/// is written for a person rather than for a log.
async fn post_json(
    url: String,
    token: Option<&str>,
    body: serde_json::Value,
) -> Result<patchwork_core::wire::AuthResponse, String> {
    let mut request = reqwest::Client::new().post(url).json(&body);
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request
        .send()
        .await
        .map_err(|e| format!("could not reach the relay: {e}"))?;

    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    if !status.is_success() {
        let message = serde_json::from_str::<serde_json::Value>(&text)
            .ok()
            .and_then(|v| {
                v.pointer("/error/message")
                    .and_then(|m| m.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or(text);
        return Err(message);
    }
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

#[tauri::command]
async fn desktop_boot(state: tauri::State<'_, AppState>) -> Result<DesktopBoot, String> {
    let mut current = settings::load();
    // The window asks for this before it connects to anything, which is
    // exactly when a relay living in this app has to be listening.
    if current.hosts_relay {
        match state.hosted_relay.ensure_started().await {
            Ok(url) => {
                remember_hosted_url(&mut current, &url);
                let _ = settings::save(&current);
                state.local_host.restart(current.clone()).await;
            }
            Err(err) => tracing::error!(?err, "could not start the relay on this device"),
        }
    }
    // A machine that has joined before keeps its host identity.
    if current.is_connected() && current.host_id.is_empty() {
        current.host_id = settings::stable_host_id();
        let _ = settings::save(&current);
    }
    Ok(DesktopBoot {
        settings: current.redacted(),
        host: state.local_host.status().await,
        platform: patchwork_agent::detect::platform(),
        hosting_relay: state.hosted_relay.is_running().await,
    })
}

#[tauri::command]
async fn desktop_info(state: tauri::State<'_, AppState>) -> Result<DesktopInfo, String> {
    Ok(DesktopInfo {
        settings: settings::load().redacted(),
        host: state.local_host.status().await,
        platform: patchwork_agent::detect::platform(),
        capabilities: patchwork_agent::detect_capabilities().await,
        hosting_relay: state.hosted_relay.is_running().await,
    })
}

/// Use this machine as the relay: start one inside the app, give it a
/// workspace, and join it. Nothing to install, nothing to keep running in a
/// terminal — and it is the same relay, so a VPS can take over later.
#[tauri::command]
async fn use_this_device_as_relay(
    state: tauri::State<'_, AppState>,
    input: HostInput,
) -> Result<Settings, String> {
    let url = state
        .hosted_relay
        .ensure_started()
        .await
        .map_err(|e| format!("{e:#}"))?;

    let name = input.workspace_name.trim();
    let code = state
        .hosted_relay
        .adopt(if name.is_empty() { "Patchwork" } else { name })
        .await
        .map_err(|e| format!("{e:#}"))?;

    let mut current = settings::load();
    current.hosts_relay = true;
    settings::save(&current).map_err(|e| e.to_string())?;

    join_workspace(
        state,
        JoinInput {
            relay_url: url,
            invite_code: code,
            display_name: input.display_name,
        },
    )
    .await
}

/// Redeem an invite, remember the device token, and bring this machine online
/// as an execution host in that workspace. Workspaces already joined keep
/// running.
#[tauri::command]
async fn join_workspace(
    state: tauri::State<'_, AppState>,
    input: JoinInput,
) -> Result<Settings, String> {
    let base = input.relay_url.trim().trim_end_matches('/').to_string();
    let host_name = format!(
        "{}'s {}",
        input.display_name.trim(),
        friendly_machine_name()
    );

    let auth = post_json(
        format!("{base}/api/auth/join"),
        None,
        serde_json::json!({
            "invite_code": input.invite_code.trim(),
            "display_name": input.display_name.trim(),
            "device_name": host_name,
        }),
    )
    .await?;

    remember(&state, base, host_name, auth).await
}

/// A new workspace on the relay this desktop is already in. The caller
/// becomes its first admin.
#[tauri::command]
async fn create_workspace(
    state: tauri::State<'_, AppState>,
    name: String,
) -> Result<Settings, String> {
    let current = settings::load();
    let active = current
        .active_workspace()
        .cloned()
        .ok_or_else(|| "join a workspace first".to_string())?;

    let auth = post_json(
        format!("{}/api/workspaces", active.relay_url),
        Some(&active.token),
        serde_json::json!({ "name": name.trim() }),
    )
    .await?;

    let host_name = if current.host_name.is_empty() {
        format!("{}'s {}", auth.member.display_name, friendly_machine_name())
    } else {
        current.host_name.clone()
    };
    remember(&state, active.relay_url.clone(), host_name, auth).await
}

async fn remember(
    state: &tauri::State<'_, AppState>,
    relay_url: String,
    host_name: String,
    auth: patchwork_core::wire::AuthResponse,
) -> Result<Settings, String> {
    let mut current = settings::load();
    current.upsert(WorkspaceSettings {
        id: auth.workspace.id.clone(),
        name: auth.workspace.name.clone(),
        relay_url,
        token: auth.token,
        member_id: auth.member.id.clone(),
        member_name: auth.member.display_name.clone(),
    });
    current.host_id = settings::stable_host_id();
    current.host_name = host_name;
    settings::save(&current).map_err(|e| e.to_string())?;

    state.local_host.restart(current.clone()).await;
    Ok(current.redacted())
}

/// Which workspace the window is showing. Nothing disconnects: the others
/// keep their agents, their runs and their unread counts.
#[tauri::command]
async fn switch_workspace(id: String) -> Result<Settings, String> {
    let mut current = settings::load();
    if current.workspace(&id).is_none() {
        return Err("no such workspace on this machine".into());
    }
    current.active = id;
    settings::save(&current).map_err(|e| e.to_string())?;
    Ok(current)
}

#[tauri::command]
async fn leave_workspace(
    state: tauri::State<'_, AppState>,
    id: String,
) -> Result<Settings, String> {
    let mut current = settings::load();
    current.workspaces.retain(|workspace| workspace.id != id);
    if current.active == id {
        current.active = current
            .workspaces
            .first()
            .map(|workspace| workspace.id.clone())
            .unwrap_or_default();
    }
    settings::save(&current).map_err(|e| e.to_string())?;
    state.local_host.restart(current.clone()).await;
    Ok(current)
}

#[tauri::command]
async fn sign_out(state: tauri::State<'_, AppState>) -> Result<(), String> {
    let settings = Settings::default();
    settings::save(&settings).map_err(|e| e.to_string())?;
    state.local_host.restart(settings).await;
    Ok(())
}

/// Tell the relay where a project lives on this machine, so tasks for it can
/// run here.
#[tauri::command]
async fn set_project_paths(
    state: tauri::State<'_, AppState>,
    paths: BTreeMap<String, String>,
) -> Result<Settings, String> {
    let mut current = settings::load();
    current.project_paths = paths;
    settings::save(&current).map_err(|e| e.to_string())?;
    state.local_host.restart(current.clone()).await;
    Ok(current.redacted())
}

/// Keep this machine awake — never, only while it is running an agent, or for
/// as long as the app is open.
#[tauri::command]
async fn set_awake_policy(
    state: tauri::State<'_, AppState>,
    policy: awake::AwakePolicy,
) -> Result<Settings, String> {
    let mut current = settings::load();
    current.awake = policy;
    settings::save(&current).map_err(|e| e.to_string())?;
    state.awake.set_policy(policy);
    Ok(current.redacted())
}

/// Speaking instead of typing. On this machine, with the system's own
/// recogniser: no key, no upload, no model of ours to download.
#[tauri::command]
fn dictation_supported() -> bool {
    dictation::supported()
}

#[tauri::command]
fn dictation_start(app: tauri::AppHandle, locale: Option<String>) -> Result<(), String> {
    dictation::start(app, locale.as_deref().unwrap_or(""))
}

#[tauri::command]
fn dictation_stop() {
    dictation::stop();
}

#[tauri::command]
async fn reconnect_host(state: tauri::State<'_, AppState>) -> Result<HostStatus, String> {
    // An explicit "try again" is also the moment to look at this machine
    // afresh, since the usual reason for pressing it is having just installed
    // something that was missing.
    patchwork_agent::refresh_capabilities().await;
    let settings = settings::load();
    state.local_host.restart(settings).await;
    Ok(state.local_host.status().await)
}

fn friendly_machine_name() -> String {
    let host = patchwork_agent::detect::hostname();
    host.trim_end_matches(".local").to_string()
}

/// Workspaces created before managed ingress existed pointed at loopback.
/// Once this app's relay has a stable public URL, move only those local entries
/// to it; workspaces joined on somebody else's relay are untouched.
fn remember_hosted_url(settings: &mut Settings, url: &str) {
    if !url.starts_with("https://") {
        return;
    }
    for workspace in &mut settings.workspaces {
        if workspace.relay_url.starts_with("http://127.0.0.1:")
            || workspace.relay_url.starts_with("http://localhost:")
        {
            workspace.relay_url = url.to_string();
        }
    }
}

#[cfg(test)]
mod managed_relay_tests {
    use super::*;

    #[test]
    fn managed_url_migrates_only_the_relay_hosted_here() {
        let mut settings = Settings {
            workspaces: vec![
                WorkspaceSettings {
                    id: "local".into(),
                    relay_url: "http://127.0.0.1:7727".into(),
                    ..Default::default()
                },
                WorkspaceSettings {
                    id: "other".into(),
                    relay_url: "https://team.example".into(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        remember_hosted_url(&mut settings, "https://relay.patchwork.sh/r/abc");
        assert_eq!(
            settings.workspaces[0].relay_url,
            "https://relay.patchwork.sh/r/abc"
        );
        assert_eq!(settings.workspaces[1].relay_url, "https://team.example");
    }
}

/// System-wide, so it has to be a chord nothing else is likely to want. ⌘D on
/// its own stays the in-window one.
#[cfg(desktop)]
const DICTATE_CHORD: &str = "CmdOrCtrl+Shift+D";

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "patchwork_desktop=info,patchwork_agent=info,warn".into()),
        )
        .init();

    let awake = Arc::new(awake::Keeper::default());
    let local_host = Arc::new(LocalHost::new(awake.clone()));
    let hosted_relay = Arc::new(relay::Hosted::default());
    let on_exit = (hosted_relay.clone(), awake.clone());

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            local_host: local_host.clone(),
            awake: awake.clone(),
            hosted_relay: hosted_relay.clone(),
        })
        .setup(move |app| {
            // Dictation you can reach from whatever you were doing. A thought
            // worth capturing rarely arrives while you are already looking at
            // the right box, and the in-app chord needs the app in front.
            #[cfg(desktop)]
            {
                use tauri::Manager;
                use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

                app.handle().plugin(
                    tauri_plugin_global_shortcut::Builder::new()
                        .with_handler(|app, _shortcut, event| {
                            // Pressed only: a hotkey reports its release too,
                            // and toggling twice per press starts and stops
                            // the recogniser in the same breath.
                            if event.state() != ShortcutState::Pressed {
                                return;
                            }
                            if let Some(window) = app.get_webview_window("main") {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                            let _ = app.emit("dictate", ());
                        })
                        .build(),
                )?;
                // A chord another app already owns is not worth refusing to
                // start over. Everything else still works, and ⌘D still does
                // this from inside the window.
                if let Err(err) = app.global_shortcut().register(DICTATE_CHORD) {
                    tracing::warn!(
                        ?err,
                        chord = DICTATE_CHORD,
                        "the global dictation chord is taken"
                    );
                }
            }

            let local_host = local_host.clone();
            let awake = awake.clone();
            let hosted_relay = hosted_relay.clone();
            tauri::async_runtime::spawn(async move {
                let mut settings = settings::load();
                // A machine that has joined before keeps its host identity.
                if settings.is_connected() && settings.host_id.is_empty() {
                    settings.host_id = settings::stable_host_id();
                    let _ = settings::save(&settings);
                }
                awake.set_policy(settings.awake);
                // Before the host connections, or they spend their first
                // seconds failing to reach a relay that is about to exist.
                if settings.hosts_relay {
                    match hosted_relay.ensure_started().await {
                        Ok(url) => {
                            remember_hosted_url(&mut settings, &url);
                            let _ = settings::save(&settings);
                        }
                        Err(err) => {
                            tracing::error!(?err, "could not start the relay on this device")
                        }
                    }
                }
                local_host.restart(settings).await;
            });
            // Warm the capability answer off the critical path, so that host
            // registration and the settings page both find it already there.
            tauri::async_runtime::spawn(async {
                patchwork_agent::detect_capabilities().await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            desktop_boot,
            desktop_info,
            join_workspace,
            use_this_device_as_relay,
            create_workspace,
            switch_workspace,
            leave_workspace,
            sign_out,
            set_project_paths,
            set_awake_policy,
            reconnect_host,
            dictation_supported,
            dictation_start,
            dictation_stop,
            patchwork_providers,
            set_provider_key,
            pi_login
        ])
        .build(tauri::generate_context!())
        .expect("error while running Patchwork");

    // Quitting stops the relay's hosted agents deliberately, rather than
    // leaving their runtimes behind with nobody to talk to.
    app.run(move |_handle, event| {
        if matches!(event, tauri::RunEvent::Exit) {
            let (hosted_relay, awake) = &on_exit;
            tauri::async_runtime::block_on(hosted_relay.shutdown());
            awake.shutdown();
        }
    });
}
