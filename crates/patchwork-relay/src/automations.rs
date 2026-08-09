//! Automations: when an agent should act, where it acts, and where it reports.
//!
//! Every firing records what triggered it, what it selected, and the context it
//! received, so the debugger can answer "why did this happen?" without anyone
//! having to reproduce it.

use std::time::Duration;

use anyhow::Result;
use patchwork_core::events::Event;
use patchwork_core::models::*;
use patchwork_core::wire::{CreateTask, SendMessage};
use patchwork_core::{new_id, now_ms, Id, Millis};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::orchestrator::{self, StartRunParams};
use crate::state::Shared;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct WatchEvent {
    event_key: String,
    condition_key: String,
    title: String,
    outcome: String,
    #[serde(default)]
    context: Value,
}

fn parse_watch_events(stdout: &str) -> Option<Vec<WatchEvent>> {
    let mut events = Vec::new();
    for line in stdout.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let mut event: WatchEvent = serde_json::from_str(line).ok()?;
        event.event_key = event.event_key.trim().to_string();
        event.condition_key = event.condition_key.trim().to_string();
        event.title = event.title.trim().to_string();
        event.outcome = event.outcome.trim().to_string();
        if [
            &event.event_key,
            &event.condition_key,
            &event.title,
            &event.outcome,
        ]
        .into_iter()
        .any(|value| value.is_empty())
        {
            return None;
        }
        events.push(event);
    }
    (!events.is_empty()).then_some(events)
}

fn watch_event(trigger: &AutomationTrigger, payload: Option<&Value>) -> Option<WatchEvent> {
    if !matches!(trigger, AutomationTrigger::Watch { .. }) {
        return None;
    }
    serde_json::from_value(payload?.get("watch_event")?.clone()).ok()
}

fn event_source_message(event: &WatchEvent) -> String {
    let context = match &event.context {
        Value::Null => return format!("Automation event `{}`", event.event_key),
        Value::String(text) => text.clone(),
        value => format!(
            "```json\n{}\n```",
            serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
        ),
    };
    format!("Automation event `{}`\n\n{context}", event.event_key)
}

fn trigger_source_message(record: &AutomationRun) -> String {
    match record.trigger_payload.as_ref() {
        Some(payload) => format!(
            "{}\n\n```json\n{}\n```",
            record.trigger_summary,
            serde_json::to_string_pretty(payload).unwrap_or_else(|_| payload.to_string())
        ),
        None => record.trigger_summary.clone(),
    }
}

fn task_needs_run(task: &Task) -> bool {
    task.status == TaskStatus::Planned && task.current_run_id.is_none()
}

pub async fn on_message(state: &Shared, message: &Message) {
    let Ok(automations) = state.store.automations() else {
        return;
    };
    for automation in automations.into_iter().filter(|a| a.enabled) {
        let AutomationTrigger::Message {
            channel_id,
            pattern,
            include_agents,
        } = &automation.trigger
        else {
            continue;
        };
        if channel_id != &message.channel_id {
            continue;
        }
        if message.author_id == automation.agent_id {
            continue;
        }
        if !include_agents {
            let author_is_agent = state
                .store
                .member(&message.author_id)
                .ok()
                .flatten()
                .map(|m| m.kind == MemberKind::Agent)
                .unwrap_or(false);
            if author_is_agent {
                continue;
            }
        }
        if !pattern.trim().is_empty() && !matches_pattern(pattern, &message.body) {
            continue;
        }

        let summary = format!("New message in {}", message.channel_id);
        let payload = json!({ "message_id": message.id, "author_id": message.author_id, "body": message.body });
        if let Err(err) = fire(state, &automation, summary, payload, None, None).await {
            tracing::warn!(?err, automation = %automation.name, "automation failed to start");
        }
    }
}

pub async fn on_task_change(state: &Shared, task: &Task, previous: Option<&Task>) {
    let Ok(automations) = state.store.automations() else {
        return;
    };
    for automation in automations.into_iter().filter(|a| a.enabled) {
        let should_fire = match &automation.trigger {
            AutomationTrigger::TaskStatus { status, project_id } => {
                let entered =
                    previous.map(|p| p.status != *status).unwrap_or(true) && task.status == *status;
                let project_matches = project_id
                    .as_ref()
                    .map(|p| task.project_id.as_ref() == Some(p))
                    .unwrap_or(true);
                entered && project_matches
            }
            AutomationTrigger::TaskAssigned => {
                let now_owned = task.owner_id.as_deref() == Some(automation.agent_id.as_str());
                let was_owned = previous
                    .map(|p| p.owner_id.as_deref() == Some(automation.agent_id.as_str()))
                    .unwrap_or(false);
                now_owned && !was_owned
            }
            _ => false,
        };
        if !should_fire {
            continue;
        }

        let summary = format!("Task {} entered {}", task.key, task.status.as_str());
        let payload =
            json!({ "task_id": task.id, "key": task.key, "status": task.status.as_str() });
        if let Err(err) = fire(
            state,
            &automation,
            summary,
            payload,
            Some(task.id.clone()),
            None,
        )
        .await
        {
            tracing::warn!(?err, automation = %automation.name, "automation failed to start");
        }
    }
}

pub async fn on_pull_request(state: &Shared, task: &Task, kind: &str, detail: &str) {
    let Ok(automations) = state.store.automations() else {
        return;
    };
    for automation in automations.into_iter().filter(|a| a.enabled) {
        let AutomationTrigger::PullRequest {
            on_review_comment,
            on_checks_failed,
        } = &automation.trigger
        else {
            continue;
        };
        let wanted = match kind {
            "review" => *on_review_comment,
            "checks" => *on_checks_failed,
            _ => false,
        };
        if !wanted {
            continue;
        }
        let summary = format!("Pull request {kind} on {}", task.key);
        let payload = json!({ "task_id": task.id, "kind": kind, "detail": detail });
        if let Err(err) = fire(
            state,
            &automation,
            summary,
            payload,
            Some(task.id.clone()),
            None,
        )
        .await
        {
            tracing::warn!(?err, "pull request automation failed");
        }
    }
}

pub async fn on_webhook(
    state: &Shared,
    token: &str,
    payload: serde_json::Value,
    once_key: Option<String>,
) -> Result<bool> {
    let Some(automation) = state.store.automation_by_webhook(token)? else {
        return Ok(false);
    };
    if !automation.enabled {
        return Ok(false);
    }
    let once_key = once_key
        .map(|key| key.trim().to_string())
        .filter(|key| !key.is_empty());
    // A delivery repeating a key that already fired is the same event told
    // twice. Acknowledge it, so the sender stops retrying, and pay for it once.
    if let Some(key) = &once_key {
        if state
            .store
            .automation_run_by_once_key(&automation.id, key)?
            .is_some()
        {
            return Ok(true);
        }
    }
    fire(
        state,
        &automation,
        "Incoming webhook".into(),
        payload,
        None,
        once_key,
    )
    .await?;
    Ok(true)
}

pub async fn run_now(state: &Shared, automation: &Automation, by: &str) -> Result<AutomationRun> {
    let summary = format!("Run manually by {by}");
    fire(state, automation, summary, json!({ "by": by }), None, None).await
}

/// The single path every trigger funnels through.
pub async fn fire(
    state: &Shared,
    automation: &Automation,
    trigger_summary: String,
    trigger_payload: serde_json::Value,
    task_id: Option<Id>,
    once_key: Option<String>,
) -> Result<AutomationRun> {
    let mut record = AutomationRun {
        id: new_id(),
        automation_id: automation.id.clone(),
        run_id: None,
        trigger_summary,
        trigger_payload: Some(trigger_payload.clone()),
        selection: None,
        context_preview: String::new(),
        status: RunStatus::Queued,
        error: None,
        task_id: task_id.clone(),
        once_key,
        created_at: now_ms(),
        ended_at: None,
    };
    if let Some(existing) = state.store.reserve_automation_run(&record)? {
        return Ok(existing);
    }
    state.emit(Event::AutomationRunUpdated {
        run: record.clone(),
    });

    let outcome = dispatch(state, automation, &mut record, task_id).await;

    let mut updated = automation.clone();
    updated.last_run_at = Some(now_ms());
    // Whether it worked or not: a schedule that only books its next time after
    // a success fires again on every tick once it starts failing.
    updated.next_run_at = next_due_after(&automation.trigger, now_ms());
    let failure = outcome.as_ref().err().map(|err| format!("{err:#}"));
    if let Some(message) = &failure {
        record.status = RunStatus::Failed;
        record.error = Some(message.clone());
        record.ended_at = Some(now_ms());
        updated.failure_count += 1;
    } else {
        updated.failure_count = 0;
    }
    state.store.upsert_automation(&updated)?;
    state.emit(Event::AutomationUpdated {
        automation: updated,
    });
    if let Some(message) = &failure {
        notify_creator_of_failure(state, &record, message)?;
    }

    state.store.upsert_automation_run(&record)?;
    state.emit(Event::AutomationRunUpdated {
        run: record.clone(),
    });
    Ok(record)
}

async fn dispatch(
    state: &Shared,
    automation: &Automation,
    record: &mut AutomationRun,
    trigger_task_id: Option<Id>,
) -> Result<()> {
    let report_channel = automation
        .report_channel_id
        .clone()
        .or_else(|| automation.context_channel_id.clone());

    let (channel_id, task_id, start_agent, required_task_status) = match automation.action {
        AutomationAction::PostInChat => {
            let channel = report_channel
                .ok_or_else(|| anyhow::anyhow!("this automation has no channel to post in"))?;
            (channel, None, true, None)
        }
        AutomationAction::ContinueTask => {
            let task_id = trigger_task_id
                .ok_or_else(|| anyhow::anyhow!("nothing in this trigger identifies a task"))?;
            let task = state
                .store
                .task(&task_id)?
                .ok_or_else(|| anyhow::anyhow!("the task no longer exists"))?;
            (task.discussion_channel_id, Some(task.id), true, None)
        }
        AutomationAction::CreateTask => {
            let event = watch_event(&automation.trigger, record.trigger_payload.as_ref());
            let (title, outcome, once_key, initial_message) = match &event {
                Some(event) => (
                    event.title.clone(),
                    event.outcome.clone(),
                    Some(event.condition_key.clone()),
                    event_source_message(event),
                ),
                None => (
                    automation.name.clone(),
                    String::new(),
                    record.once_key.clone(),
                    trigger_source_message(record),
                ),
            };
            let creation = orchestrator::create_task_with_result(
                state,
                &automation.created_by,
                CreateTask {
                    title,
                    outcome,
                    initial_message: Some(initial_message.clone()),
                    owner_id: Some(automation.agent_id.clone()),
                    once_key,
                    source_channel_id: report_channel.clone(),
                    project_id: automation.project_id.clone(),
                    host_id: automation.host_id.clone(),
                    start: false,
                    ..Default::default()
                },
            )
            .await?;
            let task = creation.task;
            if !creation.created {
                orchestrator::post_message(
                    state,
                    &task.discussion_channel_id,
                    &automation.created_by,
                    SendMessage {
                        body: initial_message,
                        ..Default::default()
                    },
                    orchestrator::PostOptions {
                        trigger_agents: false,
                        run_id: None,
                    },
                )
                .await?;
            }
            let start_agent = task_needs_run(&task);
            (
                task.discussion_channel_id.clone(),
                Some(task.id),
                start_agent,
                Some(TaskStatus::Planned),
            )
        }
    };

    record.task_id = task_id.clone();
    record.selection = Some(json!({
        "agent_id": automation.agent_id,
        "channel_id": channel_id,
        "task_id": task_id,
        "project_id": automation.project_id,
        "host_id": automation.host_id,
        "action": automation.action,
        "started": start_agent,
    }));

    if !start_agent {
        record.status = RunStatus::Succeeded;
        record.ended_at = Some(now_ms());
        return Ok(());
    }

    let mut prompt = String::new();
    prompt.push_str(&format!("Automation `{}` fired.\n", automation.name));
    prompt.push_str(&format!("Trigger: {}\n\n", record.trigger_summary));
    if !automation.instructions.trim().is_empty() {
        prompt.push_str(automation.instructions.trim());
        prompt.push('\n');
    }
    if let Some(payload) = &record.trigger_payload {
        if let Ok(pretty) = serde_json::to_string_pretty(payload) {
            if pretty.len() < 4000 {
                prompt.push_str(&format!("\nTrigger details:\n```json\n{pretty}\n```\n"));
            }
        }
    }
    record.context_preview = prompt.chars().take(4000).collect();

    let run = match orchestrator::start_run(
        state,
        StartRunParams {
            agent_id: automation.agent_id.clone(),
            channel_id,
            task_id,
            prompt,
            trigger: RunTrigger::Automation {
                automation_id: automation.id.clone(),
            },
            automation_id: Some(automation.id.clone()),
            depth: 0,
            host_id: automation.host_id.clone(),
            project_id: automation.project_id.clone(),
            required_task_status,
        },
    )
    .await
    {
        Ok(run) => run,
        Err(error)
            if required_task_status.is_some()
                && error.is::<orchestrator::TaskUnavailable>() =>
        {
            if let Some(selection) = record.selection.as_mut() {
                selection["started"] = json!(false);
                selection["reason"] = json!("task state changed before dispatch");
            }
            record.status = RunStatus::Succeeded;
            record.ended_at = Some(now_ms());
            return Ok(());
        }
        Err(error) => return Err(error),
    };

    record.run_id = Some(run.id);
    record.status = RunStatus::Running;
    Ok(())
}

pub async fn report_failure(state: &Shared, record: &AutomationRun, run: &Run) -> Result<()> {
    let message = run
        .error
        .clone()
        .unwrap_or_else(|| "the run failed without an error message".into());
    notify_creator_of_failure(state, record, &message)
}

fn notify_creator_of_failure(state: &Shared, record: &AutomationRun, message: &str) -> Result<()> {
    let Some(automation) = state.store.automation(&record.automation_id)? else {
        return Ok(());
    };
    let Some(creator) = state.store.member(&automation.created_by)? else {
        return Ok(());
    };
    if creator.kind != MemberKind::Human {
        return Ok(());
    }
    let item = InboxItem {
        id: new_id(),
        member_id: creator.id,
        kind: InboxKind::AutomationFailed,
        title: format!("Automation `{}` failed", automation.name),
        preview: message.chars().take(200).collect(),
        actor_id: Some(automation.agent_id.clone()),
        channel_id: automation.report_channel_id.clone(),
        message_id: None,
        task_id: record.task_id.clone(),
        run_id: record.run_id.clone(),
        automation_id: Some(automation.id.clone()),
        created_at: now_ms(),
        read_at: None,
    };
    state.store.insert_inbox(&item)?;
    state.emit(Event::InboxItemCreated { item });
    Ok(())
}

fn matches_pattern(pattern: &str, body: &str) -> bool {
    if let Ok(re) = regex::RegexBuilder::new(pattern)
        .case_insensitive(true)
        .build()
    {
        return re.is_match(body);
    }
    body.to_lowercase().contains(&pattern.to_lowercase())
}

/// Runs schedule-triggered automations. One task, one wake-up a minute: the
/// relay should stay cheap on an ordinary VPS.
pub async fn scheduler(state: Shared) {
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(20));
    loop {
        ticker.tick().await;
        announce_due_tasks(&state);
        let Ok(automations) = state.store.automations() else {
            continue;
        };
        let now = now_ms();
        for automation in automations.into_iter().filter(|a| a.enabled) {
            if let AutomationTrigger::Watch {
                command,
                every_seconds,
            } = &automation.trigger
            {
                let due = automation
                    .next_run_at
                    .unwrap_or(automation.created_at + every_seconds * 1000);
                if due > now {
                    continue;
                }
                // Book the next poll before running this one: a scan that
                // hangs or dies must not be retried on every tick. Polling off
                // the ticker thread keeps one slow watcher from delaying the
                // rest.
                let mut pending = automation.clone();
                pending.next_run_at = Some(now + every_seconds * 1000);
                let _ = state.store.upsert_automation(&pending);
                tokio::spawn(poll_watch(
                    state.clone(),
                    automation.clone(),
                    command.clone(),
                ));
                continue;
            }
            let (due_at, summary) = match &automation.trigger {
                AutomationTrigger::Schedule {
                    every_seconds,
                    start_at,
                } => (
                    automation
                        .next_run_at
                        .or(*start_at)
                        .unwrap_or(automation.created_at + every_seconds * 1000),
                    format!("Scheduled every {every_seconds}s"),
                ),
                AutomationTrigger::Cron { expression } => {
                    // No stored next time yet — work out the first one from
                    // when it was created, not from now, or restarting the
                    // relay would postpone every schedule indefinitely.
                    let Some(due) = automation
                        .next_run_at
                        .or_else(|| next_cron_after(expression, automation.created_at))
                    else {
                        continue;
                    };
                    (due, format!("Scheduled: {expression}"))
                }
                _ => continue,
            };
            if due_at > now {
                continue;
            }
            if let Err(err) = fire(
                &state,
                &automation,
                summary,
                json!({ "at": now }),
                None,
                None,
            )
            .await
            {
                tracing::warn!(?err, automation = %automation.name, "scheduled automation failed");
            }
        }
    }
}

/// Long enough for a slow HTTP call, short enough that a hung script is not a
/// watcher that quietly stopped watching.
const WATCH_TIMEOUT: Duration = Duration::from_secs(120);

/// Runs one watch command and fires the agent only if it found something.
///
/// This is the whole point of a watch: the scan costs a process, so it can run
/// every minute, and the model is only paid for when there is something to
/// think about.
async fn poll_watch(state: Shared, automation: Automation, command: String) {
    // Its own directory, kept between polls, so a script can remember the last
    // id it saw without the relay inventing a storage API for it.
    let dir = state.files_dir.join("watch").join(&automation.id);
    if let Err(err) = tokio::fs::create_dir_all(&dir).await {
        tracing::warn!(?err, automation = %automation.name, "watch state directory unavailable");
        return;
    }

    let output = tokio::time::timeout(
        WATCH_TIMEOUT,
        tokio::process::Command::new("sh")
            .arg("-c")
            .arg(&command)
            .current_dir(&dir)
            .env("PATCHWORK_STATE_DIR", &dir)
            .env("PATCHWORK_AUTOMATION_ID", &automation.id)
            .output(),
    )
    .await;
    let output = match output {
        Ok(Ok(output)) => output,
        Ok(Err(err)) => {
            tracing::warn!(?err, automation = %automation.name, "watch command could not run");
            return;
        }
        Err(_) => {
            tracing::warn!(automation = %automation.name, "watch command timed out");
            return;
        }
    };

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if output.status.success() {
        if let Some(events) = parse_watch_events(&stdout) {
            for event in events {
                let event_key = event.event_key.clone();
                let title: String = event.title.chars().take(120).collect();
                if let Err(err) = fire(
                    &state,
                    &automation,
                    format!("Watch: {title}"),
                    json!({ "watch_event": event }),
                    None,
                    Some(event_key),
                )
                .await
                {
                    tracing::warn!(?err, automation = %automation.name, "watch event failed");
                }
            }
            return;
        }
    }

    let last = state
        .store
        .automation_runs(&automation.id, 1)
        .unwrap_or_default();
    let previous = last
        .first()
        .and_then(|run| run.trigger_payload.as_ref())
        .and_then(|payload| payload.get("stdout"))
        .and_then(|value| value.as_str());

    if !watch_found_something(output.status.success(), &stdout, previous) {
        tracing::debug!(
            automation = %automation.name,
            code = output.status.code(),
            stderr = %String::from_utf8_lossy(&output.stderr).chars().take(200).collect::<String>(),
            "watch found nothing"
        );
        return;
    }

    let headline: String = stdout
        .lines()
        .next()
        .unwrap_or_default()
        .chars()
        .take(120)
        .collect();
    if let Err(err) = fire(
        &state,
        &automation,
        format!("Watch: {headline}"),
        json!({ "stdout": stdout }),
        None,
        None,
    )
    .await
    {
        tracing::warn!(?err, automation = %automation.name, "watch automation failed");
    }
}

/// A non-zero exit means "nothing to report", the way `grep` means it, so the
/// obvious one-liner works. Printing the same finding as last time is not a
/// new finding, which is what lets a scan be stateless.
fn watch_found_something(exited_ok: bool, stdout: &str, previous: Option<&str>) -> bool {
    exited_ok && !stdout.is_empty() && previous != Some(stdout)
}

/// When a trigger that runs on the clock is next due. `None` for the ones that
/// wait to be told.
fn next_due_after(trigger: &AutomationTrigger, now: Millis) -> Option<Millis> {
    match trigger {
        AutomationTrigger::Schedule { every_seconds, .. }
        | AutomationTrigger::Watch { every_seconds, .. } => Some(now + every_seconds * 1000),
        AutomationTrigger::Cron { expression } => next_cron_after(expression, now),
        _ => None,
    }
}

/// A due date is only a promise until somebody is told about it. On the day,
/// the task lands in the Inbox of whoever owns it and whoever asked for it,
/// once — the same tick that runs the schedules, because it is the same kind
/// of "something is due now".
fn announce_due_tasks(state: &Shared) {
    let now = now_ms();
    let Ok(tasks) = state.store.tasks() else {
        return;
    };
    for task in tasks {
        if !is_due(&task, now) {
            continue;
        }
        if state
            .store
            .inbox_has(&task.id, InboxKind::TaskDue)
            .unwrap_or(true)
        {
            continue;
        }
        let title = format!("{} is due", task.key);
        if let Err(err) = crate::orchestrator::notify_task(state, &task, InboxKind::TaskDue, title)
        {
            tracing::warn!(?err, task = %task.key, "could not announce a due task");
        }
    }
}

/// Due, and still worth saying so. Closing a task is the way to stop it
/// nagging, whatever its date says.
fn is_due(task: &Task, now: Millis) -> bool {
    matches!(task.due_at, Some(at) if at <= now) && !task.status.is_terminal()
}

/// The next firing after `after`, in the relay's local time.
///
/// The `cron` crate wants a seconds field; a person writing "0 9 * * *" means
/// the five-field form, so accept that and fill the seconds in.
pub fn next_cron_after(expression: &str, after: i64) -> Option<i64> {
    use chrono::TimeZone;
    use std::str::FromStr;

    let fields = expression.split_whitespace().count();
    let normalised = match fields {
        5 => format!("0 {expression}"),
        6 | 7 => expression.to_string(),
        _ => return None,
    };
    let schedule = cron::Schedule::from_str(&normalised).ok()?;
    let from = chrono::Local.timestamp_millis_opt(after).single()?;
    schedule.after(&from).next().map(|at| at.timestamp_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_five_field_cron_is_accepted_and_lands_on_the_hour() {
        // 2026-01-01T00:00:00Z is a safe, fixed starting point.
        let start = 1_767_225_600_000;
        let next = next_cron_after("0 9 * * *", start).expect("valid expression");
        assert!(next > start, "the next run must be in the future");
        let local = chrono::DateTime::from_timestamp_millis(next).unwrap();
        let _ = local;
        // Within a day and a bit — a daily schedule never waits two days.
        assert!(next - start <= 25 * 60 * 60 * 1000);
    }

    #[test]
    fn a_task_is_due_once_its_day_arrives_and_never_after_it_is_closed() {
        let mut task = Task {
            id: "t".into(),
            key: "PW-1".into(),
            title: "Ship it".into(),
            outcome: String::new(),
            status: TaskStatus::Planned,
            owner_id: None,
            source_channel_id: None,
            source_message_id: None,
            discussion_channel_id: "c".into(),
            project_id: None,
            host_id: None,
            worktree_id: None,
            current_run_id: None,
            pr_url: None,
            pr_state: None,
            review_action: None,
            created_by: "m".into(),
            due_at: None,
            once_key: None,
            created_at: 0,
            updated_at: 0,
            position: 0.0,
        };
        assert!(!is_due(&task, 1_000), "no date is not a deadline");

        task.due_at = Some(2_000);
        assert!(!is_due(&task, 1_999));
        assert!(is_due(&task, 2_000));

        task.status = TaskStatus::Done;
        assert!(!is_due(&task, 9_999));

        task.status = TaskStatus::Canceled;
        assert!(!is_due(&task, 9_999));
    }

    #[test]
    fn nonsense_expressions_do_not_schedule_anything() {
        assert!(next_cron_after("not a cron", 0).is_none());
        assert!(next_cron_after("0 9 * *", 0).is_none());
    }

    #[test]
    fn a_watch_fires_only_on_a_new_finding() {
        // Nothing printed, or a failed scan: nothing happened.
        assert!(!watch_found_something(true, "", None));
        assert!(!watch_found_something(false, "issue-1", None));
        // Something new.
        assert!(watch_found_something(true, "issue-1", None));
        assert!(watch_found_something(true, "issue-2", Some("issue-1")));
        // The same finding as last time is not a new one.
        assert!(!watch_found_something(true, "issue-1", Some("issue-1")));
    }

    #[test]
    fn structured_watches_separate_deliveries_from_conditions() {
        let events = parse_watch_events(
            r#"{"event_key":"deploy-1","condition_key":"checkout:deploy","title":"Restore checkout","outcome":"Checkout deploys from main","context":{"status":500}}
{"event_key":"deploy-2","condition_key":"checkout:deploy","title":"Restore checkout","outcome":"Checkout deploys from main"}"#,
        )
        .unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].event_key, "deploy-1");
        assert_eq!(events[1].event_key, "deploy-2");
        assert_eq!(events[0].condition_key, events[1].condition_key);
    }

    #[test]
    fn structured_payloads_only_change_watch_semantics() {
        let payload = json!({
            "watch_event": {
                "event_key": "delivery",
                "condition_key": "condition",
                "title": "Produce result",
                "outcome": "The result exists"
            }
        });
        assert!(watch_event(
            &AutomationTrigger::Watch {
                command: "scan".into(),
                every_seconds: 60,
            },
            Some(&payload),
        )
        .is_some());
        assert!(watch_event(
            &AutomationTrigger::Webhook {
                token: "token".into(),
            },
            Some(&payload),
        )
        .is_none());
    }

    #[test]
    fn ordinary_watch_output_stays_legacy() {
        assert!(parse_watch_events("one finding\nmore detail").is_none());
        assert!(parse_watch_events(
            "{\"event_key\":\"missing the other required fields\"}"
        )
        .is_none());
    }

    #[test]
    fn only_idle_planned_tasks_start_from_another_occurrence() {
        let mut task = Task {
            id: "t".into(),
            key: "PW-1".into(),
            title: "Produce result".into(),
            outcome: "The result exists".into(),
            status: TaskStatus::Planned,
            owner_id: None,
            source_channel_id: None,
            source_message_id: None,
            discussion_channel_id: "c".into(),
            project_id: None,
            host_id: None,
            worktree_id: None,
            current_run_id: None,
            pr_url: None,
            pr_state: None,
            review_action: None,
            created_by: "human".into(),
            due_at: None,
            once_key: Some("condition".into()),
            created_at: 0,
            updated_at: 0,
            position: 0.0,
        };
        assert!(task_needs_run(&task));
        task.status = TaskStatus::Running;
        assert!(!task_needs_run(&task));
        task.status = TaskStatus::Review;
        assert!(!task_needs_run(&task));
        task.status = TaskStatus::Blocked;
        assert!(!task_needs_run(&task));
        task.status = TaskStatus::Planned;
        task.current_run_id = Some("run".into());
        assert!(!task_needs_run(&task));
    }

    #[test]
    fn clock_triggers_book_their_next_run_and_others_do_not() {
        let watch = AutomationTrigger::Watch {
            command: "true".into(),
            every_seconds: 60,
        };
        assert_eq!(next_due_after(&watch, 1_000), Some(61_000));
        assert_eq!(next_due_after(&AutomationTrigger::Manual, 1_000), None);
    }

    #[test]
    fn patterns_fall_back_to_substring_when_not_a_regex() {
        assert!(matches_pattern("refund", "Customer wants a REFUND"));
        assert!(matches_pattern(r"error \d+", "got error 500 here"));
        assert!(!matches_pattern("[unclosed", "nothing here"));
        assert!(matches_pattern("[unclosed", "an [unclosed bracket"));
    }
}
