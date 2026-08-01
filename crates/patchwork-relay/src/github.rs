//! GitHub stays the source of truth for pull requests; Patchwork only watches
//! and brings the right agent back when review feedback arrives.

use std::process::Stdio;

use patchwork_core::events::Event;
use patchwork_core::models::*;
use patchwork_core::{now_ms, Id};
use serde_json::Value;
use tokio::process::Command;

use crate::orchestrator::{self, StartRunParams};
use crate::state::Shared;

const POLL_SECONDS: u64 = 60;

pub async fn watcher(state: Shared) {
    if which::which("gh").is_err() {
        tracing::info!("gh is not installed on the relay; pull request state will not be tracked");
        return;
    }
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(POLL_SECONDS));
    loop {
        ticker.tick().await;
        let Ok(tasks) = state.store.tasks() else {
            continue;
        };
        for task in tasks
            .into_iter()
            .filter(|t| t.pr_url.is_some() && t.status != TaskStatus::Done)
        {
            if let Err(err) = poll_task(&state, &task).await {
                tracing::debug!(?err, task = %task.key, "pull request poll failed");
            }
        }
    }
}

async fn poll_task(state: &Shared, task: &Task) -> anyhow::Result<()> {
    let Some(url) = &task.pr_url else {
        return Ok(());
    };
    let Some(fresh) = fetch(url).await? else {
        return Ok(());
    };

    let previous = task.pr_state.clone();
    let changed = previous
        .as_ref()
        .map(|p| p.state != fresh.state || p.checks != fresh.checks || p.review != fresh.review)
        .unwrap_or(true);
    if !changed {
        return Ok(());
    }

    let mut task = task.clone();
    task.pr_state = Some(fresh.clone());
    state.store.update_task(&task)?;
    state.emit(Event::TaskUpdated { task: task.clone() });

    let review_arrived = fresh.review == "CHANGES_REQUESTED"
        && previous.as_ref().map(|p| p.review.clone()).unwrap_or_default() != "CHANGES_REQUESTED";
    let checks_failed = fresh.checks == "FAILURE"
        && previous.as_ref().map(|p| p.checks.clone()).unwrap_or_default() != "FAILURE";

    if fresh.state == "MERGED" {
        let _ = orchestrator::post_system(
            state,
            &task.discussion_channel_id,
            &format!("Pull request #{} was merged.", fresh.number),
        )
        .await;
        return Ok(());
    }

    if review_arrived || checks_failed {
        let what = if review_arrived {
            "Changes were requested on the pull request."
        } else {
            "Pull request checks are failing."
        };
        let _ = orchestrator::post_system(state, &task.discussion_channel_id, what).await;

        automations_hook(state, &task, review_arrived).await;
        bring_agent_back(state, &task, what).await;
    }

    Ok(())
}

async fn automations_hook(state: &Shared, task: &Task, review: bool) {
    crate::automations::on_pull_request(
        state,
        task,
        if review { "review" } else { "checks" },
        task.pr_url.as_deref().unwrap_or_default(),
    )
    .await;
}

/// Review feedback pulls the assigned agent back in without a mention.
async fn bring_agent_back(state: &Shared, task: &Task, what: &str) {
    let Some(owner) = task.owner_id.clone() else {
        return;
    };
    let is_agent = state
        .store
        .member(&owner)
        .ok()
        .flatten()
        .map(|m| m.kind == MemberKind::Agent)
        .unwrap_or(false);
    if !is_agent {
        return;
    }
    if task.current_run_id.is_some() {
        return;
    }

    let prompt = format!(
        "{what}\nPull request: {}\n\nRead the feedback with `gh pr view --comments`, address it in \
this worktree, push, and reply with a short summary of what changed.",
        task.pr_url.clone().unwrap_or_default()
    );
    let params = StartRunParams {
        agent_id: owner,
        channel_id: task.discussion_channel_id.clone(),
        task_id: Some(task.id.clone()),
        prompt,
        trigger: RunTrigger::PullRequestFeedback {
            task_id: task.id.clone(),
        },
        automation_id: None,
        depth: 0,
        host_id: task.host_id.clone(),
        project_id: task.project_id.clone(),
    };
    if let Err(err) = orchestrator::start_run(state, params).await {
        tracing::warn!(?err, "could not bring the agent back for review feedback");
    }
}

async fn fetch(url: &str) -> anyhow::Result<Option<PullRequestState>> {
    let output = Command::new("gh")
        .args([
            "pr",
            "view",
            url,
            "--json",
            "number,title,state,isDraft,reviewDecision,statusCheckRollup",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await?;
    if !output.status.success() {
        return Ok(None);
    }
    let json: Value = serde_json::from_slice(&output.stdout)?;

    let checks = json
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .map(|checks| {
            if checks.iter().any(|c| {
                c.get("conclusion").and_then(|v| v.as_str()) == Some("FAILURE")
            }) {
                "FAILURE"
            } else if checks.iter().any(|c| {
                matches!(
                    c.get("status").and_then(|v| v.as_str()),
                    Some("IN_PROGRESS") | Some("QUEUED") | Some("PENDING")
                )
            }) {
                "PENDING"
            } else if checks.is_empty() {
                ""
            } else {
                "SUCCESS"
            }
        })
        .unwrap_or("")
        .to_string();

    let draft = json
        .get("isDraft")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let state = json
        .get("state")
        .and_then(|v| v.as_str())
        .unwrap_or("OPEN")
        .to_string();

    Ok(Some(PullRequestState {
        number: json.get("number").and_then(|v| v.as_i64()).unwrap_or(0),
        title: json
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        state: if draft && state == "OPEN" {
            "DRAFT".into()
        } else {
            state
        },
        checks,
        review: json
            .get("reviewDecision")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        updated_at: now_ms(),
    }))
}

/// Best-effort detection of a pull request URL an agent mentioned in chat, so
/// the task links itself without anyone copying the URL by hand.
pub fn detect_pr_url(body: &str) -> Option<String> {
    let re = regex::Regex::new(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+").ok()?;
    re.find(body).map(|m| m.as_str().to_string())
}

pub async fn link_pr_from_message(state: &Shared, task_id: &Id, body: &str) {
    let Some(url) = detect_pr_url(body) else {
        return;
    };
    let Ok(Some(mut task)) = state.store.task(task_id) else {
        return;
    };
    if task.pr_url.as_deref() == Some(url.as_str()) {
        return;
    }
    task.pr_url = Some(url);
    if state.store.update_task(&task).is_ok() {
        state.emit(Event::TaskUpdated { task });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_pull_request_url_in_prose() {
        let body = "Opened https://github.com/acme/app/pull/42 for review.";
        assert_eq!(
            detect_pr_url(body).as_deref(),
            Some("https://github.com/acme/app/pull/42")
        );
        assert!(detect_pr_url("no link here").is_none());
    }
}
