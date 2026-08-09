import type {
  AutomationTrigger,
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

export function compactInterval(seconds: number) {
  if (seconds % 86_400 === 0) return `${seconds / 86_400}d`;
  if (seconds % 3600 === 0) return `${seconds / 3600}h`;
  if (seconds % 60 === 0) return `${seconds / 60}m`;
  return `${seconds}s`;
}
