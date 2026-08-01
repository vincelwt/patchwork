import type { Member, Millis, RunStatus, TaskStatus } from "./types";

export function timeOfDay(at: Millis) {
  return new Date(at).toLocaleTimeString([], {
    hour: "numeric",
    minute: "2-digit",
  });
}

export function dayLabel(at: Millis) {
  const date = new Date(at);
  const today = new Date();
  const yesterday = new Date(today.getTime() - 86_400_000);
  const same = (a: Date, b: Date) => a.toDateString() === b.toDateString();
  if (same(date, today)) return "Today";
  if (same(date, yesterday)) return "Yesterday";
  return date.toLocaleDateString([], {
    weekday: "long",
    month: "short",
    day: "numeric",
  });
}

export function relative(at?: Millis) {
  if (!at) return "";
  const seconds = Math.round((Date.now() - at) / 1000);
  if (seconds < 45) return "just now";
  if (seconds < 90) return "a minute ago";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(at).toLocaleDateString([], { month: "short", day: "numeric" });
}

export function duration(from?: Millis, to?: Millis) {
  if (!from) return "";
  const seconds = Math.max(0, Math.round(((to ?? Date.now()) - from) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

export function initials(member?: Member) {
  if (!member) return "?";
  if (member.avatar && member.avatar.length <= 2) return member.avatar;
  return member.display_name
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase() ?? "")
    .join("");
}

export function statusTone(status: TaskStatus | RunStatus): string {
  switch (status) {
    case "running":
    case "dispatched":
    case "queued":
      return "accent";
    case "blocked":
    case "failed":
      return "danger";
    case "waiting":
    case "review":
      return "caution";
    case "done":
    case "succeeded":
      return "positive";
    default:
      return "";
  }
}

export function statusLabel(status: TaskStatus | RunStatus) {
  return status.charAt(0).toUpperCase() + status.slice(1);
}

export function bytes(size: number) {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}
