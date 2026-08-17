import type {
  Automation,
  AutomationTrigger,
  Message,
  Millis,
  RunStatus,
  Task,
  TaskStatus,
} from "@client/types";

export function relative(value?: Millis, now = Date.now()) {
  if (!value) return "";
  const seconds = Math.round((value - now) / 1000);
  const absolute = Math.abs(seconds);
  if (absolute < 10) return "now";
  if (absolute >= 604_800) return new Date(value).toLocaleDateString();
  const [amount, unit] = absolute < 60
    ? [absolute, "second"]
    : absolute < 3600
      ? [Math.round(absolute / 60), "minute"]
      : absolute < 86_400
        ? [Math.round(absolute / 3600), "hour"]
        : [Math.round(absolute / 86_400), "day"];
  const phrase = `${amount} ${unit}${amount === 1 ? "" : "s"}`;
  return seconds < 0 ? `${phrase} ago` : `in ${phrase}`;
}

export function timeOfDay(value: Millis) {
  return new Date(value).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

export function dayLabel(value: Millis) {
  return new Date(value).toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" });
}

/// Someone saying three things in a row is one turn, not three headers, so only
/// the first line of a turn carries a face, a name, and a time. A run line or a
/// reply reference belongs to its own message, so either one starts a new turn.
const SAME_TURN_WINDOW = 5 * 60_000;
export function isSameTurn(previous: Message | undefined, message: Message) {
  return (
    !!previous &&
    previous.author_id === message.author_id &&
    previous.kind === message.kind &&
    message.created_at - previous.created_at < SAME_TURN_WINDOW &&
    !message.reply_to_id &&
    !message.run_id
  );
}

export function duration(start?: Millis, end?: Millis) {
  if (!start) return "not started";
  const seconds = Math.max(0, Math.round(((end ?? Date.now()) - start) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

export function bytes(value: number) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

export function taskStatusLabel(status: TaskStatus) {
  return status[0].toUpperCase() + status.slice(1);
}

export function pullRequestLabel(task: Pick<Task, "pr_url" | "pr_state">) {
  const number = task.pr_state?.number ?? pullRequestNumber(task.pr_url);
  const prefix = number ? `PR #${number}` : "Pull request";
  return task.pr_state?.state
    ? `${prefix} · ${task.pr_state.state.toLowerCase()}`
    : prefix;
}

function pullRequestNumber(url?: string) {
  const match = url?.match(/\/pull\/(\d+)(?:[/?#]|$)/);
  return match ? Number(match[1]) : undefined;
}

export function runStatusLabel(status: RunStatus) {
  if (status === "succeeded") return "Finished";
  if (status === "cancelled") return "Stopped";
  return status[0].toUpperCase() + status.slice(1);
}

export function triggerLabel(trigger: AutomationTrigger) {
  switch (trigger.type) {
    case "schedule":
      return `Every ${compactInterval(trigger.every_seconds)}`;
    case "cron":
      return `Cron: ${trigger.expression}`;
    case "message":
      return trigger.pattern ? `Message matching “${trigger.pattern}”` : "New message";
    case "task_status":
      return `Task becomes ${trigger.status}`;
    case "task_assigned":
      return "Task assigned";
    case "pull_request":
      return "Pull request activity";
    case "webhook":
      return "Webhook";
    case "watch":
      return `Watch every ${compactInterval(trigger.every_seconds)}`;
    case "manual":
      return "Manual only";
  }
}

/// Only a successful command test writes this timestamp.
export function watchValidated(automation: Automation) {
  return automation.last_validated_at !== undefined;
}

/// The relay refuses to enable a watch whose current command has not passed a
/// test, so a new watch and an edited command both have to be tested first.
export function watchNeedsTest(
  automation: Automation | undefined,
  trigger: { type: string; command?: string },
) {
  if (trigger.type !== "watch") return false;
  return !(
    automation?.trigger.type === "watch" &&
    automation.trigger.command === trigger.command &&
    watchValidated(automation)
  );
}

/// What a watch is worth relies on its last successful check, not its last
/// attempt: a command that has been failing all week still has a fresh
/// `last_run_at`, which is exactly how a dead watch looks healthy.
export function watchHealth(automation: Automation, now = Date.now()) {
  const failures = automation.failure_count;
  if (failures > 0) {
    const when = automation.last_error_at ? ` · ${relative(automation.last_error_at, now)}` : "";
    return { tone: "danger" as const, text: `${failures} failed check${failures === 1 ? "" : "s"}${when}` };
  }
  if (automation.last_success_at) {
    return { tone: "positive" as const, text: `Checked ${relative(automation.last_success_at, now)}` };
  }
  return {
    tone: "caution" as const,
    text: watchValidated(automation) ? "Validated, no check yet" : "Never tested",
  };
}

export function compactInterval(seconds: number) {
  if (seconds % 86_400 === 0) return `${seconds / 86_400}d`;
  if (seconds % 3600 === 0) return `${seconds / 3600}h`;
  if (seconds % 60 === 0) return `${seconds / 60}m`;
  return `${seconds}s`;
}
