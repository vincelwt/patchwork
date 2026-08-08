//! Asking each runtime what it can run, before anyone asks it to run.
//!
//! Detection can tell us a runtime is installed; only the runtime itself can
//! say which models it has, and it only says so when a session opens. Waiting
//! for the first real run to find out means the agent editor offers an empty
//! list exactly when someone is choosing a model. So this opens one throwaway
//! session per runtime at startup and reports what comes back.

use std::time::Duration;

use patchwork_core::host::HostToRelay;
use serde_json::json;

use crate::acp::AcpConnection;
use crate::{detect, Sink};

/// A session that only says hello is cheap, but not free: they are opened one
/// at a time, and one that will not answer is dropped rather than waited on.
const PROBE_TIMEOUT: Duration = Duration::from_secs(60);

pub async fn report_runtime_options(out: Sink, env: Vec<(String, String)>) {
    // A dropped connection re-registers, and spawning every runtime again each
    // time the network hiccups is not a thing worth doing twice.
    static ASKED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if ASKED.swap(true, std::sync::atomic::Ordering::AcqRel) {
        return;
    }

    let capabilities = detect::detect_capabilities().await;
    let cwd = crate::worktree::work_root().join("probe");
    if tokio::fs::create_dir_all(&cwd).await.is_err() {
        return;
    }
    let cwd = cwd.to_string_lossy().to_string();

    for runtime in capabilities.runtimes {
        // A runtime that has already told us, or that has no session to open,
        // has nothing to add.
        if !runtime.available
            || (!runtime.models.is_empty()
                && !runtime.thinking.is_empty()
                && !runtime.modes.is_empty())
            || runtime.id == "custom"
        {
            continue;
        }
        let Some(command) = detect::runtime_command(&runtime.id) else {
            continue;
        };

        match tokio::time::timeout(PROBE_TIMEOUT, ask(&command, &cwd, &env)).await {
            Ok(Ok(session))
                if !session.models.is_empty()
                    || !session.thinking.is_empty()
                    || !session.modes.is_empty() =>
            {
                let _ = out.send(runtime_options(runtime, session));
            }
            // Not signed in, not answering, nothing to say: all the same here.
            // The list stays empty and the field stays typeable.
            Ok(Ok(_)) => {}
            Ok(Err(err)) => {
                tracing::debug!(runtime = %runtime.id, ?err, "runtime did not describe itself")
            }
            Err(_) => tracing::debug!(runtime = %runtime.id, "runtime took too long to answer"),
        }
    }
}

fn runtime_options(
    runtime: patchwork_core::models::RuntimeInstallation,
    session: crate::acp::NewSession,
) -> HostToRelay {
    let discover_models = runtime.models.is_empty();
    let discover_thinking = runtime.thinking.is_empty();
    let discover_modes = runtime.modes.is_empty();
    HostToRelay::RuntimeOptions {
        runtime: runtime.id,
        models: if discover_models { session.models } else { runtime.models },
        thinking: if discover_thinking {
            session.thinking
        } else {
            runtime.thinking
        },
        modes: if discover_modes { session.modes } else { runtime.modes },
        default_model: if discover_models {
            session.current_model
        } else {
            runtime.default_model
        },
        default_thinking: if discover_thinking {
            session.current_thinking
        } else {
            runtime.default_thinking
        },
        default_mode: if discover_modes {
            session.current_mode
        } else {
            runtime.default_mode
        },
    }
}

async fn ask(
    command: &[String],
    cwd: &str,
    env: &[(String, String)],
) -> anyhow::Result<crate::acp::NewSession> {
    // The receiver is held for as long as the connection: dropping it would
    // stop the reader that the request is waiting on.
    let (conn, _events) = AcpConnection::spawn(command, cwd, env).await?;
    let session = conn.new_session(cwd, json!([])).await?;
    Ok(session)
}

#[cfg(test)]
mod tests {
    use super::*;
    use patchwork_core::models::{RuntimeInstallation, RuntimeOption};

    fn option(id: &str) -> RuntimeOption {
        RuntimeOption {
            id: id.into(),
            name: id.into(),
            description: String::new(),
        }
    }

    #[test]
    fn a_partial_seed_keeps_its_models_and_learns_the_other_options() {
        let runtime: RuntimeInstallation = serde_json::from_value(json!({
            "id": "patchwork", "label": "Patchwork Agent", "available": true,
            "models": [{ "id": "curated", "name": "Curated" }],
            "default_model": "curated"
        }))
        .unwrap();
        let session = crate::acp::NewSession {
            models: vec![option("discovered")],
            thinking: vec![option("xhigh")],
            modes: vec![option("full-access")],
            current_model: Some("discovered".into()),
            current_thinking: Some("xhigh".into()),
            current_mode: Some("full-access".into()),
            ..Default::default()
        };

        let HostToRelay::RuntimeOptions {
            models,
            thinking,
            modes,
            default_model,
            default_thinking,
            default_mode,
            ..
        } = runtime_options(runtime, session)
        else {
            panic!("expected runtime options");
        };
        assert_eq!(models[0].id, "curated");
        assert_eq!(default_model.as_deref(), Some("curated"));
        assert_eq!(thinking[0].id, "xhigh");
        assert_eq!(default_thinking.as_deref(), Some("xhigh"));
        assert_eq!(modes[0].id, "full-access");
        assert_eq!(default_mode.as_deref(), Some("full-access"));
    }
}
