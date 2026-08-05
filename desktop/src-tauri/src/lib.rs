//! Patchwork Desktop: the collaboration UI plus this machine's local agent
//! execution. The UI talks to the relay directly; this side owns the host
//! connection and the settings that survive a restart.

mod awake;
mod host;
mod settings;

use std::collections::BTreeMap;
use std::sync::Arc;

use host::{HostStatus, LocalHost};
use serde::{Deserialize, Serialize};
use settings::Settings;

struct AppState {
    local_host: Arc<LocalHost>,
    awake: Arc<awake::Keeper>,
}

#[derive(Debug, Serialize)]
struct DesktopInfo {
    settings: Settings,
    host: HostStatus,
    platform: String,
    capabilities: patchwork_core::models::HostCapabilities,
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
}

#[derive(Debug, Deserialize)]
struct JoinInput {
    relay_url: String,
    invite_code: String,
    display_name: String,
}

#[tauri::command]
async fn desktop_boot(state: tauri::State<'_, AppState>) -> Result<DesktopBoot, String> {
    Ok(DesktopBoot {
        settings: settings::load(),
        host: state.local_host.status().await,
        platform: patchwork_agent::detect::platform(),
    })
}

#[tauri::command]
async fn desktop_info(state: tauri::State<'_, AppState>) -> Result<DesktopInfo, String> {
    Ok(DesktopInfo {
        settings: settings::load(),
        host: state.local_host.status().await,
        platform: patchwork_agent::detect::platform(),
        capabilities: patchwork_agent::detect_capabilities().await,
    })
}

/// Redeem an invite, remember the device token, and bring this machine online
/// as an execution host.
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

    let response = reqwest::Client::new()
        .post(format!("{base}/api/auth/join"))
        .json(&serde_json::json!({
            "invite_code": input.invite_code.trim(),
            "display_name": input.display_name.trim(),
            "device_name": host_name,
        }))
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

    let auth: patchwork_core::wire::AuthResponse =
        serde_json::from_str(&text).map_err(|e| e.to_string())?;

    let mut current = settings::load();
    current.relay_url = base;
    current.token = auth.token;
    current.member_id = auth.member.id.clone();
    current.member_name = auth.member.display_name.clone();
    current.host_id = settings::stable_host_id();
    current.host_name = host_name;
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
    Ok(current)
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
    Ok(current)
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

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            local_host: local_host.clone(),
            awake: awake.clone(),
        })
        .setup(move |_app| {
            let local_host = local_host.clone();
            let awake = awake.clone();
            tauri::async_runtime::spawn(async move {
                let mut settings = settings::load();
                // A machine that has joined before keeps its host identity.
                if settings.is_connected() && settings.host_id.is_empty() {
                    settings.host_id = settings::stable_host_id();
                    let _ = settings::save(&settings);
                }
                awake.set_policy(settings.awake);
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
            sign_out,
            set_project_paths,
            set_awake_policy,
            reconnect_host
        ])
        .run(tauri::generate_context!())
        .expect("error while running Patchwork");
}
