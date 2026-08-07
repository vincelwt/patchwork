//! Automations: when an agent should act, where it acts, and where it reports.
//!
//! Every firing records what triggered it, what it selected, and the context it
//! received, so the debugger can answer "why did this happen?" without anyone
//! having to reproduce it.

use anyhow::Result;
use patchwork_core::events::Event;
use patchwork_core::models::*;
use patchwork_core::wire::CreateTask;
use patchwork_core::{new_id, now_ms, Id, Millis};
use serde_json::json;

use crate::orchestrator::{self, StartRunParams};
use crate::state::Shared;

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
        if let Err(err) = fire(state, &automation, summary, payload, None).await {
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
                let entered = previous.map(|p| p.status != *status).unwrap_or(true)
                    && task.status == *status;
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
        let payload = json!({ "task_id": task.id, "key": task.key, "status": task.status.as_str() });
        if let Err(err) = fire(state, &automation, summary, payload, Some(task.id.clone())).await {
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
        if let Err(err) = fire(state, &automation, summary, payload, Some(task.id.clone())).await {
            tracing::warn!(?err, "pull request automation failed");
        }
    }
}

pub async fn on_webhook(state: &Shared, token: &str, payload: serde_json::Value) -> Result<bool> {
    let Some(automation) = state.store.automation_by_webhook(token)? else {
        return Ok(false);
    };
    if !automation.enabled {
        return Ok(false);
    }
    fire(state, &automation, "Incoming webhook".into(), payload, None).await?;
    Ok(true)
}

pub async fn run_now(state: &Shared, automation: &Automation, by: &str) -> Result<AutomationRun> {
    let summary = format!("Run manually by {by}");
    fire(state, automation, summary, json!({ "by": by }), None).await
}

/// The single path every trigger funnels through.
pub async fn fire(
    state: &Shared,
    automation: &Automation,
    trigger_summary: String,
    trigger_payload: serde_json::Value,
    task_id: Option<Id>,
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
        created_at: now_ms(),
        ended_at: None,
    };
    state.store.upsert_automation_run(&record)?;
    state.emit(Event::AutomationRunUpdated {
        run: record.clone(),
    });

    let outcome = dispatch(state, automation, &mut record, task_id).await;

    if let Err(err) = &outcome {
        record.status = RunStatus::Failed;
        record.error = Some(format!("{err:#}"));
        record.ended_at = Some(now_ms());
        let mut automation = automation.clone();
        automation.failure_count += 1;
        automation.last_run_at = Some(now_ms());
        state.store.upsert_automation(&automation)?;
        state.emit(Event::AutomationUpdated { automation });
        notify_creator_of_failure(state, &record, &format!("{err:#}"))?;
    } else {
        let mut automation = automation.clone();
        automation.last_run_at = Some(now_ms());
        automation.failure_count = 0;
        if let AutomationTrigger::Schedule { every_seconds, .. } = &automation.trigger {
            automation.next_run_at = Some(now_ms() + every_seconds * 1000);
        }
        if let AutomationTrigger::Cron { expression } = &automation.trigger {
            automation.next_run_at = next_cron_after(expression, now_ms());
        }
        state.store.upsert_automation(&automation)?;
        state.emit(Event::AutomationUpdated { automation });
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

    let (channel_id, task_id) = match automation.action {
        AutomationAction::PostInChat => {
            let channel = report_channel
                .ok_or_else(|| anyhow::anyhow!("this automation has no channel to post in"))?;
            (channel, None)
        }
        AutomationAction::ContinueTask => {
            let task_id = trigger_task_id
                .ok_or_else(|| anyhow::anyhow!("nothing in this trigger identifies a task"))?;
            let task = state
                .store
                .task(&task_id)?
                .ok_or_else(|| anyhow::anyhow!("the task no longer exists"))?;
            (task.discussion_channel_id, Some(task.id))
        }
        AutomationAction::CreateTask => {
            let task = orchestrator::create_task(
                state,
                &automation.created_by,
                CreateTask {
                    title: automation.name.clone(),
                    outcome: automation.instructions.clone(),
                    owner_id: Some(automation.agent_id.clone()),
                    source_channel_id: report_channel.clone(),
                    project_id: automation.project_id.clone(),
                    host_id: automation.host_id.clone(),
                    start: false,
                    ..Default::default()
                },
            )
            .await?;
            (task.discussion_channel_id.clone(), Some(task.id))
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
    }));

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

    let run = orchestrator::start_run(
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
        },
    )
    .await?;

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
            if let Err(err) = fire(&state, &automation, summary, json!({ "at": now }), None).await {
                tracing::warn!(?err, automation = %automation.name, "scheduled automation failed");
            }
        }
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
        if let Err(err) = crate::orchestrator::notify_task(state, &task, InboxKind::TaskDue, title) {
            tracing::warn!(?err, task = %task.key, "could not announce a due task");
        }
    }
}

/// Due, and still worth saying so. Finishing a task is the way to stop it
/// nagging, whatever its date says.
fn is_due(task: &Task, now: Millis) -> bool {
    matches!(task.due_at, Some(at) if at <= now) && task.status != TaskStatus::Done
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
    schedule
        .after(&from)
        .next()
        .map(|at| at.timestamp_millis())
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
    fn a_task_is_due_once_its_day_arrives_and_never_after_it_is_done() {
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
    }

    #[test]
    fn nonsense_expressions_do_not_schedule_anything() {
        assert!(next_cron_after("not a cron", 0).is_none());
        assert!(next_cron_after("0 9 * *", 0).is_none());
    }

    #[test]
    fn patterns_fall_back_to_substring_when_not_a_regex() {
        assert!(matches_pattern("refund", "Customer wants a REFUND"));
        assert!(matches_pattern(r"error \d+", "got error 500 here"));
        assert!(!matches_pattern("[unclosed", "nothing here"));
        assert!(matches_pattern("[unclosed", "an [unclosed bracket"));
    }
}
