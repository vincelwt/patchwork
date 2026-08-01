//! Application previews.
//!
//! An agent starts a dev server in its worktree and exposes the port; the
//! preview, the evidence it attached, and the pull request are then shown
//! together when work is ready for review.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;

use patchwork_core::host::HostToRelay;
use patchwork_core::models::PreviewStatus;
use patchwork_core::Id;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::runner::Sink;

struct Running {
    child: Child,
    port: u16,
}

pub struct PreviewManager {
    out: Sink,
    running: Arc<Mutex<HashMap<Id, Running>>>,
}

impl PreviewManager {
    pub fn new(out: Sink) -> Self {
        Self {
            out,
            running: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn start(
        &self,
        preview_id: Id,
        _task_id: Id,
        cwd: String,
        command: String,
        port: u16,
        _label: String,
    ) {
        let _ = self.out.send(HostToRelay::PreviewStatus {
            preview_id: preview_id.clone(),
            status: PreviewStatus::Starting,
            url: None,
            error: None,
        });

        let mut cmd = Command::new("sh");
        cmd.arg("-lc")
            .arg(&command)
            .current_dir(&cwd)
            .env("PORT", port.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(err) => {
                let _ = self.out.send(HostToRelay::PreviewStatus {
                    preview_id,
                    status: PreviewStatus::Failed,
                    url: None,
                    error: Some(format!("could not start `{command}`: {err}")),
                });
                return;
            }
        };

        // Drain output so the child never blocks on a full pipe.
        if let Some(stdout) = child.stdout.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                while let Ok(Some(_)) = lines.next_line().await {}
            });
        }
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    tracing::debug!(target: "preview", "{line}");
                }
            });
        }

        self.running
            .lock()
            .await
            .insert(preview_id.clone(), Running { child, port });

        // Wait for the port to actually answer before telling anyone it is live.
        let out = self.out.clone();
        let running = self.running.clone();
        tokio::spawn(async move {
            let live = wait_for_port(port, std::time::Duration::from_secs(60)).await;
            if live {
                let _ = out.send(HostToRelay::PreviewStatus {
                    preview_id,
                    status: PreviewStatus::Live,
                    url: Some(format!("http://127.0.0.1:{port}")),
                    error: None,
                });
            } else {
                running.lock().await.remove(&preview_id);
                let _ = out.send(HostToRelay::PreviewStatus {
                    preview_id,
                    status: PreviewStatus::Failed,
                    url: None,
                    error: Some(format!("nothing was listening on port {port} after 60s")),
                });
            }
        });
    }

    pub async fn stop(&self, preview_id: &Id) {
        if let Some(mut running) = self.running.lock().await.remove(preview_id) {
            let _ = running.child.start_kill();
            let _ = running.child.wait().await;
        }
        let _ = self.out.send(HostToRelay::PreviewStatus {
            preview_id: preview_id.clone(),
            status: PreviewStatus::Stopped,
            url: None,
            error: None,
        });
    }

    pub async fn stop_all(&self) {
        let ids: Vec<Id> = self.running.lock().await.keys().cloned().collect();
        for id in ids {
            self.stop(&id).await;
        }
    }

    pub async fn port_of(&self, preview_id: &Id) -> Option<u16> {
        self.running.lock().await.get(preview_id).map(|r| r.port)
    }
}

async fn wait_for_port(port: u16, timeout: std::time::Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    }
}

/// Pick a free port for a preview, starting from the project's preferred one.
pub async fn pick_port(preferred: Option<u16>) -> u16 {
    if let Some(p) = preferred {
        if tokio::net::TcpListener::bind(("127.0.0.1", p)).await.is_ok() {
            return p;
        }
    }
    for port in 4300u16..4400 {
        if tokio::net::TcpListener::bind(("127.0.0.1", port)).await.is_ok() {
            return port;
        }
    }
    4399
}
