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
/// Long comments are quoted, not reprinted: the thread itself is one `gh` call away.
const MAX_BODY: usize = 1200;
/// A backlog this size means nobody was watching; the newest ones still say why.
const MAX_ITEMS: usize = 20;

/// One thing somebody wrote on the pull request: a comment, a review body, or
/// an inline note on a line of the diff.
#[derive(Debug, Clone, PartialEq)]
struct Feedback {
    /// GitHub's own ISO 8601 UTC timestamp, which sorts correctly as a string.
    at: String,
    author: String,
    /// What they did, in the middle of the sentence: "@ana requested changes:".
    what: String,
    body: String,
}

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
            .filter(|t| t.pr_url.is_some() && !t.status.is_terminal())
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
    let Some((mut fresh, thread)) = fetch(url).await? else {
        return Ok(());
    };

    let previous = task.pr_state.clone();
    let mark = previous
        .as_ref()
        .map(|p| p.last_feedback_at.clone())
        .unwrap_or_default();
    fresh.last_feedback_at = newest(&thread, &mark);
    // The first sighting only records where the thread already was: linking an
    // old pull request must not replay its history into the task.
    let arrived = match previous.is_some() {
        true => since(&mark, thread),
        false => Vec::new(),
    };

    let changed = previous
        .as_ref()
        .map(|p| {
            p.state != fresh.state
                || p.checks != fresh.checks
                || p.review != fresh.review
                || p.last_feedback_at != fresh.last_feedback_at
        })
        .unwrap_or(true);
    if !changed {
        return Ok(());
    }

    // Re-read: this snapshot predates the `gh` call, so anything decided while
    // it ran (a run finishing, a status change) is only in the stored row.
    let Some(task) = state.store.set_task_pr_state(&task.id, &fresh)? else {
        return Ok(());
    };
    state.emit(Event::TaskUpdated { task: task.clone() });

    let review_arrived = fresh.review == "CHANGES_REQUESTED"
        && previous
            .as_ref()
            .map(|p| p.review.clone())
            .unwrap_or_default()
            != "CHANGES_REQUESTED";
    let checks_failed = fresh.checks == "FAILURE"
        && previous
            .as_ref()
            .map(|p| p.checks.clone())
            .unwrap_or_default()
            != "FAILURE";

    if fresh.state == "MERGED" {
        let _ = orchestrator::post_system(
            state,
            &task.discussion_channel_id,
            &format!("Pull request #{} was merged.", fresh.number),
        )
        .await;
        return Ok(());
    }

    // Everything new in one message: the headline of what changed, then the
    // comments themselves, so the task reads as the review reads.
    let mut parts = Vec::new();
    if review_arrived {
        parts.push("Changes were requested on the pull request.".to_string());
    }
    if checks_failed {
        parts.push("Pull request checks are failing.".to_string());
    }
    if !arrived.is_empty() {
        parts.push(render(&arrived));
    }
    if parts.is_empty() {
        return Ok(());
    }
    let what = parts.join("\n\n");

    // Quoted feedback is somebody talking, so it goes in a message body that
    // renders markdown; a bare state change stays a quiet activity line.
    let _ = match arrived.is_empty() {
        true => orchestrator::post_system(state, &task.discussion_channel_id, &what).await,
        false => orchestrator::post_note(state, &task.discussion_channel_id, &what).await,
    };
    if review_arrived || !arrived.is_empty() {
        automations_hook(state, &task, "review").await;
    }
    if checks_failed {
        automations_hook(state, &task, "checks").await;
    }
    bring_agent_back(state, &task, &what).await;

    Ok(())
}

async fn automations_hook(state: &Shared, task: &Task, kind: &str) {
    crate::automations::on_pull_request(
        state,
        task,
        kind,
        task.pr_url.as_deref().unwrap_or_default(),
    )
    .await;
}

/// Review feedback pulls the assigned agent back in without a mention.
///
/// ponytail: an agent that comments on its own pull request wakes itself once
/// per comment. Nothing here can tell the two apart, because the relay's `gh`
/// is authenticated as the same account a person reviews with; skip authors
/// matching `gh api user` if that ever becomes a problem.
async fn bring_agent_back(state: &Shared, task: &Task, what: &str) {
    let prompt = format!(
        "{what}\n\nPull request: {}\n\nRead the full thread with `gh pr view --comments`, address \
the feedback in this worktree, push, and reply with a short summary of what changed.",
        task.pr_url.clone().unwrap_or_default()
    );

    // Feedback that lands mid-run joins the session it is about, rather than
    // waiting for a run that already has the branch open to come back.
    if !state
        .store
        .active_task_runs(&task.id)
        .unwrap_or_default()
        .is_empty()
    {
        orchestrator::tell_task_peers(state, &task.id, "", prompt).await;
        return;
    }

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
        required_task_status: None,
    };
    if let Err(err) = orchestrator::start_run(state, params).await {
        tracing::warn!(?err, "could not bring the agent back for review feedback");
    }
}

/// Everything written after the mark, oldest first, newest kept when there is
/// a flood. The mark is the newest timestamp already reported, so no comment
/// is ever posted into the task twice.
fn since(mark: &str, mut items: Vec<Feedback>) -> Vec<Feedback> {
    items.retain(|f| f.at.as_str() > mark);
    items.sort_by(|a, b| a.at.cmp(&b.at));
    if items.len() > MAX_ITEMS {
        items.drain(..items.len() - MAX_ITEMS);
    }
    items
}

fn newest(items: &[Feedback], mark: &str) -> String {
    items
        .iter()
        .map(|f| f.at.as_str())
        .chain(std::iter::once(mark))
        .max()
        .unwrap_or_default()
        .to_string()
}

fn render(items: &[Feedback]) -> String {
    items
        .iter()
        .map(|f| {
            let body = f.body.trim();
            let mut short: String = body.chars().take(MAX_BODY).collect();
            if short.len() < body.len() {
                short.push('…');
            }
            let quoted = short
                .lines()
                .map(|line| format!("> {line}"))
                .collect::<Vec<_>>()
                .join("\n");
            format!("**@{}** {}:\n{quoted}", f.author, f.what)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string()
}

fn items<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value
        .get(key)
        .and_then(|v| v.as_array())
        .map(|v| v.as_slice())
        .unwrap_or_default()
}

/// Comments on the conversation tab and the summary a reviewer wrote, out of
/// one `gh pr view` payload.
fn thread_of(json: &Value) -> Vec<Feedback> {
    let mut out = Vec::new();
    for comment in items(json, "comments") {
        out.push(Feedback {
            at: text(comment, "createdAt"),
            author: text(&comment["author"], "login"),
            what: "commented on the pull request".into(),
            body: text(comment, "body"),
        });
    }
    for review in items(json, "reviews") {
        out.push(Feedback {
            at: text(review, "submittedAt"),
            author: text(&review["author"], "login"),
            what: match text(review, "state").as_str() {
                "CHANGES_REQUESTED" => "requested changes",
                "APPROVED" => "approved the pull request",
                _ => "reviewed the pull request",
            }
            .into(),
            body: text(review, "body"),
        });
    }
    // A review with no words is a container for the line notes below it, or a
    // bare approval. Neither is worth waking anybody for.
    out.retain(|f| !f.body.trim().is_empty() && !f.at.is_empty());
    out
}

/// Notes attached to lines of the diff. These carry most of a code review and
/// `gh pr view` does not return them, so they cost one extra call.
fn line_notes_of(json: &Value) -> Vec<Feedback> {
    json.as_array()
        .map(|notes| {
            notes
                .iter()
                .map(|note| {
                    let path = text(note, "path");
                    // `line` is null once the diff moves on; the number the
                    // reviewer was looking at survives in `original_line`.
                    let line = ["line", "original_line"]
                        .iter()
                        .find_map(|key| note.get(key).and_then(|v| v.as_i64()));
                    let where_ = match line {
                        Some(line) => format!("{path}:{line}"),
                        None => path,
                    };
                    Feedback {
                        at: text(note, "created_at"),
                        author: text(&note["user"], "login"),
                        what: format!("commented on `{where_}`"),
                        body: text(note, "body"),
                    }
                })
                .filter(|f| !f.body.trim().is_empty() && !f.at.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

async fn gh_json(args: &[&str]) -> anyhow::Result<Option<Value>> {
    let output = Command::new("gh")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await?;
    if !output.status.success() {
        return Ok(None);
    }
    Ok(Some(serde_json::from_slice(&output.stdout)?))
}

async fn line_notes(url: &str) -> Option<Vec<Feedback>> {
    let caps = regex::Regex::new(r"github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
        .ok()?
        .captures(url)?;
    let path = format!(
        "repos/{}/{}/pulls/{}/comments?per_page=100&sort=created&direction=desc",
        &caps[1], &caps[2], &caps[3]
    );
    Some(line_notes_of(&gh_json(&["api", &path]).await.ok()??))
}

async fn fetch(url: &str) -> anyhow::Result<Option<(PullRequestState, Vec<Feedback>)>> {
    let Some(json) = gh_json(&[
        "pr",
        "view",
        url,
        "--json",
        "number,title,state,isDraft,reviewDecision,statusCheckRollup,comments,reviews",
    ])
    .await?
    else {
        return Ok(None);
    };

    let checks = json
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .map(|checks| {
            if checks
                .iter()
                .any(|c| c.get("conclusion").and_then(|v| v.as_str()) == Some("FAILURE"))
            {
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

    let mut thread = thread_of(&json);
    thread.extend(line_notes(url).await.unwrap_or_default());

    let pr = PullRequestState {
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
        last_feedback_at: String::new(),
        updated_at: now_ms(),
    };
    Ok(Some((pr, thread)))
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
    task.pr_state = None;
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

    #[test]
    fn reports_each_comment_once_and_in_order() {
        let pr = serde_json::json!({
            "comments": [{
                "author": { "login": "ana" },
                "body": "Old news.",
                "createdAt": "2026-08-01T10:00:00Z"
            }, {
                "author": { "login": "ana" },
                "body": "Please rebase this.",
                "createdAt": "2026-08-02T12:00:00Z"
            }],
            "reviews": [{
                "author": { "login": "bo" },
                "body": "",
                "state": "COMMENTED",
                "submittedAt": "2026-08-02T13:00:00Z"
            }, {
                "author": { "login": "bo" },
                "body": "Two things.",
                "state": "CHANGES_REQUESTED",
                "submittedAt": "2026-08-02T13:00:01Z"
            }]
        });
        let notes = serde_json::json!([{
            "user": { "login": "bo" },
            "body": "This leaks a file handle.",
            "path": "src/lib.rs",
            // Outdated notes null this out and keep the number they were
            // written against, which is what GitHub really returns.
            "line": serde_json::Value::Null,
            "original_line": 12,
            "created_at": "2026-08-02T13:00:02Z"
        }]);

        let mut thread = thread_of(&pr);
        thread.extend(line_notes_of(&notes));
        // The empty review body is a container for the line note, not a comment.
        assert_eq!(thread.len(), 4);

        let mark = "2026-08-01T10:00:00Z";
        let arrived = since(mark, thread.clone());
        assert_eq!(
            arrived.iter().map(|f| f.at.as_str()).collect::<Vec<_>>(),
            [
                "2026-08-02T12:00:00Z",
                "2026-08-02T13:00:01Z",
                "2026-08-02T13:00:02Z"
            ]
        );

        let body = render(&arrived);
        assert!(body.contains("**@ana** commented on the pull request:\n> Please rebase this."));
        assert!(body.contains("**@bo** requested changes:"));
        assert!(body.contains("**@bo** commented on `src/lib.rs:12`:"));

        // The mark moves to the newest thing seen, so the next poll is silent.
        let mark = newest(&thread, mark);
        assert_eq!(mark, "2026-08-02T13:00:02Z");
        assert!(since(&mark, thread.clone()).is_empty());
        // And it never walks backwards when GitHub returns nothing.
        assert_eq!(newest(&[], &mark), mark);
    }

    #[test]
    fn quotes_a_long_comment_instead_of_reprinting_it() {
        let body = render(&[Feedback {
            at: "2026-08-02T12:00:00Z".into(),
            author: "ana".into(),
            what: "commented on the pull request".into(),
            body: "x".repeat(MAX_BODY + 500),
        }]);
        assert!(body.ends_with('…'));
        assert!(body.len() < MAX_BODY + 100);
    }
}
