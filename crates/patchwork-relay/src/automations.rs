//! Automations: when an agent should act, where it acts, and where it reports.
//!
//! Every firing records what triggered it, what it selected, and the context it
//! received, so the debugger can answer "why did this happen?" without anyone
//! having to reproduce it.

use std::process::Stdio;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
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

#[derive(Debug, Deserialize)]
struct ContinuationOutput {
    status: ContinuationStatus,
    summary: String,
}

fn parse_continuation_output(stdout: &str) -> Result<Option<(ContinuationStatus, String)>> {
    let stdout = stdout.trim();
    if stdout.is_empty() {
        return Ok(None);
    }
    let output: ContinuationOutput =
        serde_json::from_str(stdout).context("checker output must be one JSON object")?;
    let summary = output.summary.trim();
    if summary.is_empty() || summary.chars().count() > 500 {
        return Err(anyhow!(
            "checker summary must be between 1 and 500 characters"
        ));
    }
    Ok(Some((output.status, summary.to_string())))
}

fn parse_watch_events(stdout: &str) -> Result<Vec<WatchEvent>> {
    if stdout.is_empty() {
        return Ok(Vec::new());
    }
    let mut events = Vec::new();
    for (index, line) in stdout.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let mut event: WatchEvent = serde_json::from_str(line)
            .with_context(|| format!("watch output line {} must be a JSON event", index + 1))?;
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
            return Err(anyhow!(
                "watch output line {} has an empty required field",
                index + 1
            ));
        }
        events.push(event);
    }
    if events.is_empty() {
        return Err(anyhow!(
            "watch stdout must be empty or contain one JSON event per line"
        ));
    }
    Ok(events)
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
            trigger @ AutomationTrigger::TaskStatus { .. } => {
                task_status_fires(trigger, task, previous)
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
        // A listener naming one task has nothing left to wait for once it
        // fires; leaving it enabled is clutter on the automations list.
        if let AutomationTrigger::TaskStatus {
            task_id: Some(_), ..
        } = &automation.trigger
        {
            if let Ok(Some(mut latest)) = state.store.automation(&automation.id) {
                latest.enabled = false;
                if state.store.upsert_automation(&latest).is_ok() {
                    state.emit(Event::AutomationUpdated { automation: latest });
                }
            }
        }
    }
}

/// Does this task change satisfy a task-status trigger? Status has to be
/// *entered*, and a trigger naming a project or a task only watches that one.
fn task_status_fires(trigger: &AutomationTrigger, task: &Task, previous: Option<&Task>) -> bool {
    let AutomationTrigger::TaskStatus {
        status,
        project_id,
        task_id,
    } = trigger
    else {
        return false;
    };
    let entered = previous.map(|p| p.status != *status).unwrap_or(true) && task.status == *status;
    let project_matches = project_id
        .as_ref()
        .map(|p| task.project_id.as_ref() == Some(p))
        .unwrap_or(true);
    let task_matches = task_id.as_ref().map(|id| *id == task.id).unwrap_or(true);
    entered && project_matches && task_matches
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

    let finished_at = now_ms();
    let failure = outcome.as_ref().err().map(|err| format!("{err:#}"));
    if let Some(message) = &failure {
        record.status = RunStatus::Failed;
        record.error = Some(message.clone());
        record.ended_at = Some(finished_at);
    }
    // A watch's health belongs to the command poll, not to the action it
    // triggered. Update only firing metadata here, and never write a stale
    // configuration back after asynchronous dispatch.
    let is_watch = matches!(automation.trigger, AutomationTrigger::Watch { .. });
    if let Some(updated) = state.store.record_automation_firing(
        &automation.id,
        &automation.trigger,
        finished_at,
        if is_watch {
            None
        } else {
            next_due_after(&automation.trigger, finished_at)
        },
        failure.is_some(),
        !is_watch,
    )? {
        state.emit(Event::AutomationUpdated {
            automation: updated,
        });
    }
    if let Some(message) = &failure {
        if let Some((current, notify)) = state
            .store
            .record_automation_execution_failure(&automation.id, message)?
        {
            if notify {
                if let Err(err) =
                    deliver_execution_failure_notification(state, &current, message).await
                {
                    tracing::warn!(?err, automation = %automation.name, "could not notify automation creator");
                }
            }
        }
    } else if record.status == RunStatus::Succeeded {
        state
            .store
            .clear_automation_execution_failure(&automation.id)?;
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
                    // The automation starts this task itself below, with its trigger context.
                    status: Some(TaskStatus::Planned),
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
            if required_task_status.is_some() && error.is::<orchestrator::TaskUnavailable>() =>
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
    let Some((automation, notify)) = state
        .store
        .record_automation_execution_failure(&record.automation_id, &message)?
    else {
        return Ok(());
    };
    if notify {
        deliver_execution_failure_notification(state, &automation, &message).await?;
    }
    Ok(())
}

pub fn report_success(state: &Shared, record: &AutomationRun) -> Result<()> {
    state
        .store
        .clear_automation_execution_failure(&record.automation_id)
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
        check_task_continuations(&state).await;
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
                if WatchPollGuard::is_active(&state, &automation.id) {
                    continue;
                }
                let due = automation
                    .next_run_at
                    .unwrap_or(automation.created_at + every_seconds * 1000);
                let mut current = automation.clone();
                if watch_is_stale(due, *every_seconds, now) {
                    let reason =
                        format!("watch missed its expected poll at {due}; relay time is {now}");
                    match record_stale_watch_failure(&state, &automation, &reason) {
                        Ok((updated, notify)) => {
                            if notify {
                                if let Err(err) =
                                    deliver_watch_failure_notification(&state, &updated, &reason)
                                        .await
                                {
                                    tracing::warn!(?err, automation = %automation.name, "could not notify watch creator");
                                }
                            }
                            if let Err(err) =
                                ensure_watch_operator_task(&state, &updated, &reason).await
                            {
                                tracing::warn!(?err, automation = %automation.name, "could not escalate stale watch");
                            }
                            current = updated;
                        }
                        Err(err) => {
                            tracing::warn!(?err, automation = %automation.name, "could not record stale watch")
                        }
                    }
                }
                if due > now {
                    continue;
                }
                // Book the next poll before running this one: a scan that
                // hangs or dies must not be retried on every tick. Polling off
                // the ticker thread keeps one slow watcher from delaying the
                // rest.
                let Some(guard) = WatchPollGuard::acquire(&state, &automation.id) else {
                    continue;
                };
                match state.store.claim_watch_poll(
                    &automation.id,
                    &automation.trigger,
                    now + every_seconds * 1000,
                ) {
                    Ok(true) => {}
                    Ok(false) => continue,
                    Err(err) => {
                        tracing::warn!(?err, automation = %automation.name, "could not schedule watch poll");
                        continue;
                    }
                }
                tokio::spawn(poll_watch(
                    state.clone(),
                    current,
                    command.clone(),
                    *every_seconds,
                    guard,
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
const WATCH_FAILURE_THRESHOLD: i64 = 3;
const WATCH_ERROR_MAX_CHARS: usize = 500;
const WATCH_STALE_MIN_GRACE_MS: Millis = 60_000;

struct WatchPollGuard {
    state: Shared,
    automation_id: Id,
}

impl WatchPollGuard {
    fn is_active(state: &Shared, automation_id: &str) -> bool {
        state
            .watch_polls
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains(automation_id)
    }

    fn acquire(state: &Shared, automation_id: &str) -> Option<Self> {
        let mut active = state
            .watch_polls
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !active.insert(automation_id.to_string()) {
            return None;
        }
        Some(Self {
            state: state.clone(),
            automation_id: automation_id.to_string(),
        })
    }
}

impl Drop for WatchPollGuard {
    fn drop(&mut self) {
        self.state
            .watch_polls
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&self.automation_id);
    }
}

fn bounded_watch_error(error: impl AsRef<str>) -> String {
    error.as_ref().chars().take(WATCH_ERROR_MAX_CHARS).collect()
}

fn watch_is_stale(due_at: Millis, every_seconds: i64, now: Millis) -> bool {
    let interval = every_seconds.max(1).saturating_mul(1_000);
    let grace = interval.saturating_mul(2).max(WATCH_STALE_MIN_GRACE_MS);
    now > due_at.saturating_add(grace)
}

async fn relay_command(
    dir: &std::path::Path,
    command: &str,
    env: &[(&str, &str)],
    timeout: Duration,
) -> Result<std::process::Output> {
    tokio::fs::create_dir_all(dir)
        .await
        .context("checker state directory unavailable")?;
    let mut process = tokio::process::Command::new("sh");
    process
        .arg("-c")
        .arg(command)
        .current_dir(dir)
        .env("PATCHWORK_STATE_DIR", dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(unix)]
    process.process_group(0);
    for (key, value) in env {
        process.env(key, value);
    }
    let child = process.spawn().context("checker command could not run")?;
    let pid = child.id();
    match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(output) => output.context("checker command could not finish"),
        Err(_) => {
            // The shell owns a process group, so a timeout also stops children
            // it launched rather than letting them overlap the next poll.
            #[cfg(unix)]
            if let Some(pid) = pid {
                let _ = tokio::process::Command::new("kill")
                    .args(["-KILL", "--", &format!("-{pid}")])
                    .status()
                    .await;
            }
            Err(anyhow!("checker command timed out"))
        }
    }
}

fn classify_watch_output(output: Result<std::process::Output>) -> Result<Vec<WatchEvent>> {
    let output = output?;
    if !output.status.success() {
        let status = output
            .status
            .code()
            .map(|code| code.to_string())
            .unwrap_or_else(|| "a signal".into());
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let diagnostic = stderr
            .trim()
            .is_empty()
            .then(|| stdout.trim())
            .unwrap_or_else(|| stderr.trim());
        return Err(anyhow!(bounded_watch_error(format!(
            "watch command exited with {status}: {}",
            if diagnostic.is_empty() {
                "no diagnostic output"
            } else {
                diagnostic
            }
        ))));
    }
    let stdout = String::from_utf8(output.stdout).context("watch stdout must be UTF-8")?;
    parse_watch_events(&stdout)
}

fn watch_command(automation: &Automation) -> Result<&str> {
    match &automation.trigger {
        AutomationTrigger::Watch { command, .. } => Ok(command),
        _ => Err(anyhow!("automation is not a watch")),
    }
}

fn watch_accepts_events(automation: &Automation, command: &str) -> bool {
    automation.enabled && watch_command(automation).is_ok_and(|saved| saved == command)
}

fn record_watch_success(
    state: &Shared,
    expected: &Automation,
    validated: bool,
) -> Result<Automation> {
    let automation = state
        .store
        .record_watch_success(&expected.id, watch_command(expected)?, now_ms(), validated)?
        .ok_or_else(|| anyhow!("automation changed or was deleted while its watch command ran"))?;
    state.emit(Event::AutomationUpdated {
        automation: automation.clone(),
    });
    Ok(automation)
}

fn record_stale_watch_failure(
    state: &Shared,
    expected: &Automation,
    error: &str,
) -> Result<(Automation, bool)> {
    let error = bounded_watch_error(error);
    let (automation, notify) = state
        .store
        .record_stale_watch_failure(&expected.id, &expected.trigger, now_ms(), &error)?
        .ok_or_else(|| anyhow!("automation changed or was deleted before its stale check"))?;
    state.emit(Event::AutomationUpdated {
        automation: automation.clone(),
    });
    Ok((automation, notify))
}

fn record_watch_failure(
    state: &Shared,
    expected: &Automation,
    error: &str,
) -> Result<(Automation, bool)> {
    let error = bounded_watch_error(error);
    let (automation, notify) = state
        .store
        .record_watch_failure(&expected.id, watch_command(expected)?, now_ms(), &error)?
        .ok_or_else(|| anyhow!("automation changed or was deleted while its watch command ran"))?;
    state.emit(Event::AutomationUpdated {
        automation: automation.clone(),
    });
    Ok((automation, notify))
}

fn automation_notification_channel(
    state: &Shared,
    automation: &Automation,
    creator: &Member,
) -> Result<Id> {
    if let Some(channel_id) = automation
        .report_channel_id
        .clone()
        .or_else(|| automation.context_channel_id.clone())
    {
        return Ok(channel_id);
    }
    let system = state
        .store
        .member_by_handle("patchwork")?
        .ok_or_else(|| anyhow!("system member is unavailable"))?;
    if let Some(channel) = state.store.find_dm(&system.id, &creator.id)? {
        return Ok(channel.id);
    }
    let channel = Channel {
        id: new_id(),
        kind: ChannelKind::Dm,
        section_id: None,
        slug: String::new(),
        name: creator.display_name.clone(),
        topic: String::new(),
        position: now_ms() as f64,
        created_at: now_ms(),
        member_ids: vec![system.id, creator.id.clone()],
        task_id: None,
        last_message_at: 0,
    };
    state.store.insert_channel(&channel)?;
    state.emit(Event::ChannelCreated {
        channel: channel.clone(),
    });
    Ok(channel.id)
}

async fn notify_automation_creator(
    state: &Shared,
    automation: &Automation,
    diagnostic: &str,
) -> Result<()> {
    let diagnostic = bounded_watch_error(diagnostic);
    let Some(creator) = state
        .store
        .members()?
        .into_iter()
        .find(|member| member.id == automation.created_by)
    else {
        return Ok(());
    };
    if creator.kind == MemberKind::Human {
        let item = InboxItem {
            id: new_id(),
            member_id: creator.id,
            kind: InboxKind::AutomationFailed,
            title: format!("Automation `{}` failed", automation.name),
            preview: diagnostic.chars().take(200).collect(),
            actor_id: Some(automation.agent_id.clone()),
            channel_id: automation
                .report_channel_id
                .clone()
                .or_else(|| automation.context_channel_id.clone()),
            message_id: None,
            task_id: None,
            run_id: None,
            automation_id: Some(automation.id.clone()),
            created_at: now_ms(),
            read_at: None,
        };
        state.store.insert_inbox(&item)?;
        state.emit(Event::InboxItemCreated { item });
        return Ok(());
    }

    let channel_id = automation_notification_channel(state, automation, &creator)?;
    orchestrator::start_run(
        state,
        StartRunParams {
            agent_id: creator.id,
            channel_id,
            task_id: None,
            prompt: format!(
                "Automation `{}` failed.\n\nDiagnostic:\n{}\n\nInvestigate the command now. Fix it and run `patchwork automation test \"{}\"`, or pause the automation if it should not keep running.",
                automation.name, diagnostic, automation.name
            ),
            trigger: RunTrigger::Automation {
                automation_id: automation.id.clone(),
            },
            automation_id: Some(automation.id.clone()),
            depth: 0,
            host_id: None,
            project_id: automation.project_id.clone(),
            required_task_status: None,
        },
    )
    .await?;
    Ok(())
}

async fn deliver_watch_failure_notification(
    state: &Shared,
    automation: &Automation,
    diagnostic: &str,
) -> Result<()> {
    if let Err(err) = notify_automation_creator(state, automation, diagnostic).await {
        state
            .store
            .retry_watch_failure_notification(&automation.id, diagnostic)?;
        return Err(err);
    }
    Ok(())
}

async fn deliver_execution_failure_notification(
    state: &Shared,
    automation: &Automation,
    diagnostic: &str,
) -> Result<()> {
    if let Err(err) = notify_automation_creator(state, automation, diagnostic).await {
        state
            .store
            .retry_automation_execution_notification(&automation.id, diagnostic)?;
        return Err(err);
    }
    Ok(())
}

async fn ensure_watch_operator_task(
    state: &Shared,
    automation: &Automation,
    reason: &str,
) -> Result<()> {
    let owner_id = state
        .store
        .members()?
        .into_iter()
        .find(|member| member.id == automation.created_by && member.kind == MemberKind::Human)
        .map(|member| member.id);
    let creation = orchestrator::create_task_with_result(
        state,
        &automation.created_by,
        CreateTask {
            title: format!("Restore watch automation: {}", automation.name),
            outcome: format!(
                "The `{}` watch validates and its scheduled checks succeed",
                automation.name
            ),
            initial_message: Some(format!(
                "Watch automation `{}` needs operator action. Consecutive failures: {}.\n\n{}",
                automation.name, automation.failure_count, reason
            )),
            owner_id,
            source_channel_id: automation
                .report_channel_id
                .clone()
                .or_else(|| automation.context_channel_id.clone()),
            project_id: automation.project_id.clone(),
            host_id: automation.host_id.clone(),
            once_key: Some(format!("automation-watch-health:{}", automation.id)),
            ..Default::default()
        },
    )
    .await?;
    if creation.created && creation.task.owner_id.is_none() {
        orchestrator::notify_task(
            state,
            &creation.task,
            InboxKind::TaskBlocked,
            format!("{} needs an operator", creation.task.key),
        )?;
    }
    Ok(())
}

pub async fn test_watch(state: &Shared, automation: &Automation) -> Result<WatchTestResult> {
    let AutomationTrigger::Watch {
        command,
        every_seconds,
    } = &automation.trigger
    else {
        return Err(anyhow!("only watch automations have a command to test"));
    };
    let tested_at = now_ms();
    let dir = state.files_dir.join("watch-test").join(&automation.id);
    let timeout = WATCH_TIMEOUT.min(Duration::from_secs((*every_seconds).max(1) as u64));
    let result = classify_watch_output(
        relay_command(
            &dir,
            command,
            &[("PATCHWORK_AUTOMATION_ID", automation.id.as_str())],
            timeout,
        )
        .await,
    );
    match result {
        Ok(events) => {
            record_watch_success(state, automation, true)?;
            Ok(WatchTestResult {
                ok: true,
                event_count: events.len(),
                tested_at,
                error: None,
            })
        }
        Err(err) => {
            let error = bounded_watch_error(format!("{err:#}"));
            let (updated, notify) = record_watch_failure(state, automation, &error)?;
            if notify {
                if let Err(err) = deliver_watch_failure_notification(state, &updated, &error).await
                {
                    tracing::warn!(?err, automation = %automation.name, "could not notify watch creator");
                }
            }
            Ok(WatchTestResult {
                ok: false,
                event_count: 0,
                tested_at,
                error: Some(error),
            })
        }
    }
}

async fn check_task_continuations(state: &Shared) {
    let now = now_ms();
    match state.store.expire_task_continuations(now) {
        Ok(tasks) => {
            for task in tasks {
                state.emit(Event::TaskUpdated { task: task.clone() });
                let _ = orchestrator::post_system(
                    state,
                    &task.discussion_channel_id,
                    task.active_continuation
                        .as_ref()
                        .map(|continuation| continuation.summary.as_str())
                        .unwrap_or("The continuation deadline was reached"),
                )
                .await;
                let _ = orchestrator::notify_task(
                    state,
                    &task,
                    InboxKind::TaskBlocked,
                    format!("{} needs action", task.key),
                );
                on_task_change(state, &task, None).await;
            }
        }
        Err(err) => tracing::warn!(?err, "could not expire task continuations"),
    }

    match state.store.claim_due_task_continuations(now) {
        Ok(continuations) => {
            for continuation in continuations {
                tokio::spawn(poll_task_continuation(state.clone(), continuation));
            }
        }
        Err(err) => tracing::warn!(?err, "could not claim due task continuations"),
    }

    let Ok(ready) = state.store.ready_task_continuations() else {
        return;
    };
    for continuation in ready {
        let Ok(Some(task)) = state.store.task(&continuation.task_id) else {
            continue;
        };
        if task.status != TaskStatus::Running
            || !state
                .store
                .active_task_runs(&task.id)
                .unwrap_or_default()
                .is_empty()
        {
            continue;
        }
        let prompt = format!(
            "{}\n\nContinuation checker reported:\n{}",
            continuation.wake_prompt, continuation.summary
        );
        if let Err(err) = orchestrator::start_run(
            state,
            StartRunParams {
                agent_id: continuation.agent_id.clone(),
                channel_id: task.discussion_channel_id.clone(),
                task_id: Some(task.id.clone()),
                prompt,
                trigger: RunTrigger::Continuation {
                    continuation_id: continuation.id.clone(),
                },
                automation_id: None,
                depth: 0,
                host_id: task.host_id.clone(),
                project_id: task.project_id.clone(),
                required_task_status: Some(TaskStatus::Running),
            },
        )
        .await
        {
            tracing::warn!(?err, task = %task.key, "could not wake a ready task continuation");
        }
    }
}

async fn poll_task_continuation(state: Shared, continuation: TaskContinuation) {
    let dir = state.files_dir.join("continuations").join(&continuation.id);
    let timeout = Duration::from_secs(continuation.every_seconds.clamp(20, 120) as u64);
    let output = relay_command(
        &dir,
        &continuation.command,
        &[
            ("PATCHWORK_TASK_ID", continuation.task_id.as_str()),
            ("PATCHWORK_CONTINUATION_ID", continuation.id.as_str()),
        ],
        timeout,
    )
    .await;
    let result = match output {
        Ok(output) if output.status.success() => {
            parse_continuation_output(&String::from_utf8_lossy(&output.stdout)).map(|parsed| {
                parsed.unwrap_or((ContinuationStatus::Waiting, continuation.summary.clone()))
            })
        }
        Ok(output) => Err(anyhow!(
            "checker command exited with {}",
            output
                .status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "a signal".into())
        )),
        Err(err) => Err(err),
    };
    let (status, summary) = match result {
        Ok(result) => result,
        Err(err) => (
            ContinuationStatus::Waiting,
            format!("Checker error; retrying: {err:#}")
                .chars()
                .take(500)
                .collect(),
        ),
    };
    let Ok(Some(task)) =
        state
            .store
            .apply_task_continuation_result(&continuation.id, status, &summary)
    else {
        return;
    };
    state.emit(Event::TaskUpdated { task: task.clone() });
    if matches!(
        status,
        ContinuationStatus::ActionRequired | ContinuationStatus::Failed
    ) {
        let _ = orchestrator::post_system(&state, &task.discussion_channel_id, &summary).await;
        let _ = orchestrator::notify_task(
            &state,
            &task,
            InboxKind::TaskBlocked,
            format!("{} needs action", task.key),
        );
        on_task_change(&state, &task, None).await;
    }
}

/// Runs one watch command and fires the agent only if it found something.
///
/// This is the whole point of a watch: the scan costs a process, so it can run
/// every minute, and the model is only paid for when there is something to
/// think about.
async fn poll_watch(
    state: Shared,
    automation: Automation,
    command: String,
    every_seconds: i64,
    _guard: WatchPollGuard,
) {
    // Its own directory, kept between polls, so a script can remember the last
    // id it saw without the relay inventing a storage API for it.
    let dir = state.files_dir.join("watch").join(&automation.id);
    let timeout = WATCH_TIMEOUT.min(Duration::from_secs(every_seconds.max(1) as u64));
    let events = match classify_watch_output(
        relay_command(
            &dir,
            &command,
            &[("PATCHWORK_AUTOMATION_ID", automation.id.as_str())],
            timeout,
        )
        .await,
    ) {
        Ok(events) => events,
        Err(err) => {
            let error = bounded_watch_error(format!("{err:#}"));
            match record_watch_failure(&state, &automation, &error) {
                Ok((updated, notify)) => {
                    if notify {
                        if let Err(err) =
                            deliver_watch_failure_notification(&state, &updated, &error).await
                        {
                            tracing::warn!(?err, automation = %automation.name, "could not notify watch creator");
                        }
                    }
                    if updated.failure_count >= WATCH_FAILURE_THRESHOLD {
                        if let Err(err) = ensure_watch_operator_task(&state, &updated, &error).await
                        {
                            tracing::warn!(?err, automation = %automation.name, "could not escalate watch failure");
                        }
                    }
                }
                Err(err) => {
                    tracing::warn!(?err, automation = %automation.name, "could not record watch failure")
                }
            }
            return;
        }
    };

    if let Err(err) = record_watch_success(&state, &automation, false) {
        tracing::warn!(?err, automation = %automation.name, "could not record watch success");
        return;
    }
    for event in events {
        let event_key = event.event_key.clone();
        let title: String = event.title.chars().take(120).collect();
        let current = match state.store.automation(&automation.id) {
            Ok(Some(current)) if watch_accepts_events(&current, &command) => current,
            _ => return,
        };
        if let Err(err) = fire(
            &state,
            &current,
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
            active_continuation: None,
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
    fn continuation_checkers_use_one_small_json_protocol() {
        assert!(parse_continuation_output("").unwrap().is_none());
        for (value, expected) in [
            ("waiting", ContinuationStatus::Waiting),
            ("ready", ContinuationStatus::Ready),
            ("action_required", ContinuationStatus::ActionRequired),
            ("failed", ContinuationStatus::Failed),
        ] {
            let output = format!(r#"{{"status":"{value}","summary":"status changed"}}"#);
            assert_eq!(
                parse_continuation_output(&output).unwrap(),
                Some((expected, "status changed".into()))
            );
        }
        assert!(parse_continuation_output("not json").is_err());
        assert!(parse_continuation_output(r#"{"status":"ready","summary":""}"#).is_err());
    }

    #[tokio::test]
    async fn continuation_checkers_get_durable_state_and_task_identity() {
        let dir = std::env::temp_dir().join(format!("patchwork-checker-{}", new_id()));
        let output = relay_command(
            &dir,
            r#"printf '{"status":"ready","summary":"%s"}' "$PATCHWORK_TASK_ID"; printf seen > "$PATCHWORK_STATE_DIR/seen""#,
            &[("PATCHWORK_TASK_ID", "PW-82")],
            Duration::from_secs(2),
        )
        .await
        .unwrap();
        assert!(output.status.success());
        assert_eq!(
            parse_continuation_output(&String::from_utf8_lossy(&output.stdout)).unwrap(),
            Some((ContinuationStatus::Ready, "PW-82".into()))
        );
        assert_eq!(std::fs::read_to_string(dir.join("seen")).unwrap(), "seen");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn a_404_with_no_stdout_is_a_watch_failure() {
        let dir = std::env::temp_dir().join(format!("patchwork-watch-{}", new_id()));
        let output = relay_command(
            &dir,
            "printf 'HTTP 404 Not Found\\n' >&2; exit 22",
            &[],
            Duration::from_secs(2),
        )
        .await
        .unwrap();
        assert!(output.stdout.is_empty());
        let error = classify_watch_output(Ok(output)).unwrap_err().to_string();
        assert!(error.contains("404 Not Found"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn a_watch_timeout_is_a_failure() {
        let dir = std::env::temp_dir().join(format!("patchwork-watch-timeout-{}", new_id()));
        let output = relay_command(&dir, "sleep 1", &[], Duration::from_millis(10)).await;
        let error = classify_watch_output(output).unwrap_err().to_string();
        assert!(error.contains("timed out"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn stale_watches_allow_two_intervals_of_grace() {
        assert!(!watch_is_stale(1_000, 60, 121_000));
        assert!(watch_is_stale(1_000, 60, 121_001));
        assert!(!watch_is_stale(1_000, 5, 61_000));
        assert!(watch_is_stale(1_000, 5, 61_001));
    }

    #[test]
    fn watch_diagnostics_are_bounded() {
        assert_eq!(bounded_watch_error("x".repeat(600)).chars().count(), 500);
    }

    #[tokio::test]
    async fn repeated_watch_escalation_creates_one_operator_task() {
        let path = std::env::temp_dir().join(format!("patchwork-watch-task-{}.sqlite", new_id()));
        let files = path.with_extension("files");
        let store = crate::store::Store::open(&path).unwrap();
        store.create_workspace("ws", "Test").unwrap();
        store
            .insert_member(&Member {
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
            })
            .unwrap();
        store
            .insert_member(&Member {
                id: "system".into(),
                kind: MemberKind::Human,
                handle: "patchwork".into(),
                display_name: "Patchwork".into(),
                email: None,
                avatar: None,
                is_admin: true,
                created_at: 1,
                agent: None,
                presence: Presence::Offline,
            })
            .unwrap();
        store
            .insert_member(&Member {
                id: "creator-agent".into(),
                kind: MemberKind::Agent,
                handle: "creator".into(),
                display_name: "Creator".into(),
                email: None,
                avatar: None,
                is_admin: false,
                created_at: 1,
                agent: Some(AgentProfile::default()),
                presence: Presence::Offline,
            })
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            files.clone(),
            "http://workspace".into(),
            "relay".into(),
        ));
        let (host_tx, mut host_rx) = tokio::sync::mpsc::unbounded_channel();
        state
            .hosts
            .write()
            .await
            .insert("relay".into(), crate::state::HostConn { tx: host_tx });
        let guard = WatchPollGuard::acquire(&state, "watch").unwrap();
        assert!(WatchPollGuard::is_active(&state, "watch"));
        assert!(WatchPollGuard::acquire(&state, "watch").is_none());
        drop(guard);
        assert!(!WatchPollGuard::is_active(&state, "watch"));
        assert!(WatchPollGuard::acquire(&state, "watch").is_some());

        let automation = Automation {
            id: "watch".into(),
            name: "Release watch".into(),
            description: String::new(),
            enabled: true,
            trigger: AutomationTrigger::Watch {
                command: "false".into(),
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
            created_by: "human".into(),
            created_at: 1,
            last_run_at: None,
            next_run_at: None,
            last_success_at: None,
            last_error_at: Some(2),
            last_error: Some("HTTP 404".into()),
            last_validated_at: Some(1),
            failure_count: WATCH_FAILURE_THRESHOLD,
        };
        assert!(watch_accepts_events(&automation, "false"));
        let mut paused = automation.clone();
        paused.enabled = false;
        assert!(!watch_accepts_events(&paused, "false"));
        assert!(!watch_accepts_events(&automation, "changed"));

        let mut agent_created = automation.clone();
        agent_created.created_by = "creator-agent".into();
        notify_automation_creator(&state, &agent_created, "HTTP 404")
            .await
            .unwrap();
        let patchwork_core::host::RelayToHost::StartRun { spec } = host_rx.recv().await.unwrap()
        else {
            panic!("creator notification did not start a run");
        };
        assert_eq!(spec.agent_id, "creator-agent");
        assert!(spec.prompt.contains("HTTP 404"));
        assert!(spec.prompt.contains("patchwork automation test"));

        ensure_watch_operator_task(&state, &automation, "HTTP 404")
            .await
            .unwrap();
        ensure_watch_operator_task(&state, &automation, "HTTP 404")
            .await
            .unwrap();
        let tasks = store.tasks().unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(
            tasks[0].once_key.as_deref(),
            Some("automation-watch-health:watch")
        );
        drop(state);
        drop(store);
        let _ = std::fs::remove_dir_all(files);
        let _ = std::fs::remove_file(path);
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
    fn watch_output_is_either_empty_or_structured() {
        assert!(parse_watch_events("").unwrap().is_empty());
        assert!(parse_watch_events("one finding\nmore detail").is_err());
        assert!(
            parse_watch_events("{\"event_key\":\"missing the other required fields\"}").is_err()
        );
        assert!(parse_watch_events("  \n").is_err());
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
            active_continuation: None,
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
    fn a_task_scoped_listener_only_wakes_for_its_own_task() {
        let mut task = Task {
            id: "mine".into(),
            key: "PW-1".into(),
            title: "Produce result".into(),
            outcome: "The result exists".into(),
            status: TaskStatus::Running,
            owner_id: None,
            source_channel_id: None,
            source_message_id: None,
            discussion_channel_id: "c".into(),
            project_id: None,
            host_id: None,
            worktree_id: None,
            current_run_id: None,
            active_continuation: None,
            pr_url: None,
            pr_state: None,
            review_action: None,
            created_by: "agent".into(),
            due_at: None,
            once_key: None,
            created_at: 0,
            updated_at: 0,
            position: 0.0,
        };
        let previous = task.clone();
        let mine = AutomationTrigger::TaskStatus {
            status: TaskStatus::Done,
            project_id: None,
            task_id: Some("mine".into()),
        };
        let anyones = AutomationTrigger::TaskStatus {
            status: TaskStatus::Done,
            project_id: None,
            task_id: None,
        };

        assert!(!task_status_fires(&mine, &task, Some(&previous)));
        task.status = TaskStatus::Done;
        assert!(task_status_fires(&mine, &task, Some(&previous)));
        // Already done before the change: entered, not sitting there.
        assert!(!task_status_fires(&mine, &task, Some(&task.clone())));

        task.id = "someone else's".into();
        assert!(!task_status_fires(&mine, &task, Some(&previous)));
        assert!(task_status_fires(&anyones, &task, Some(&previous)));
    }

    #[test]
    fn patterns_fall_back_to_substring_when_not_a_regex() {
        assert!(matches_pattern("refund", "Customer wants a REFUND"));
        assert!(matches_pattern(r"error \d+", "got error 500 here"));
        assert!(!matches_pattern("[unclosed", "nothing here"));
        assert!(matches_pattern("[unclosed", "an [unclosed bracket"));
    }
}
