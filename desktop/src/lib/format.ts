import type { Member, Millis, RunStatus, TaskStatus } from "@client/types";

// Locale formatting is the expensive part of drawing a transcript: every
// message carries a time, and a channel's day markers are recomputed whenever
// a reply streams in. `Intl` formatters are costly to construct and cheap to
// reuse, and the answer for a given day never changes, so both are kept.
const TIME_FORMAT = new Intl.DateTimeFormat([], {
  hour: "numeric",
  minute: "2-digit",
});

const DATE_FORMAT = new Intl.DateTimeFormat([], {
  weekday: "long",
  month: "short",
  day: "numeric",
});

export function timeOfDay(at: Millis) {
  return TIME_FORMAT.format(at);
}

/// Which calendar day a moment falls on, in local time, as a number that can
/// be compared and used as a cache key.
function dayNumber(at: Millis): number {
  const date = new Date(at);
  return (
    date.getFullYear() * 10_000 + (date.getMonth() + 1) * 100 + date.getDate()
  );
}

const dayLabels = new Map<number, string>();
let labelsAnchoredTo = -1;

export function dayLabel(at: Millis) {
  const day = dayNumber(at);
  const today = dayNumber(Date.now());
  // "Today" stops being true at midnight, so the cache is only good for as
  // long as today is.
  if (today !== labelsAnchoredTo) {
    dayLabels.clear();
    labelsAnchoredTo = today;
  }
  const known = dayLabels.get(day);
  if (known !== undefined) return known;

  let label: string;
  if (day === today) label = "Today";
  else if (day === dayNumber(Date.now() - 86_400_000)) label = "Yesterday";
  else label = DATE_FORMAT.format(at);
  dayLabels.set(day, label);
  return label;
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

/// A due date reads as a deadline, not as a timestamp: what matters is how
/// many days are left, and whether that number is negative.
export function dueLabel(at?: Millis): { text: string; overdue: boolean } | undefined {
  if (!at) return undefined;
  const days = Math.round((dayStart(at) - dayStart(Date.now())) / 86_400_000);
  const text =
    days === 0
      ? "due today"
      : days === 1
        ? "due tomorrow"
        : days === -1
          ? "due yesterday"
          : days > 0
            ? `due in ${days}d`
            : `${-days}d overdue`;
  return { text, overdue: days <= 0 };
}

/// Local midnight: a due date is a day, not an instant.
export function dayStart(at: Millis): Millis {
  const date = new Date(at);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/// The `yyyy-mm-dd` an `<input type="date">` speaks, in local time.
export function dateInputValue(at?: Millis): string {
  if (!at) return "";
  const date = new Date(at);
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

/// 0 means "no date", which is what the relay understands as clearing it.
export function dateInputToMillis(value: string): number {
  if (!value) return 0;
  const [year, month, day] = value.split("-").map(Number);
  if (!year || !month || !day) return 0;
  return new Date(year, month - 1, day).getTime();
}

export function duration(from?: Millis, to?: Millis) {
  if (!from) return "";
  const seconds = Math.max(0, Math.round(((to ?? Date.now()) - from) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`;
  const hours = Math.floor(minutes / 60);
  // A relay measures its uptime in days, and "197h 4m" is not an answer.
  if (hours < 24) return `${hours}h ${minutes % 60}m`;
  return `${Math.floor(hours / 24)}d ${hours % 24}h`;
}

export function initials(member?: Member) {
  if (!member) return "?";
  if (member.avatar && member.avatar.length <= 2) return member.avatar;
  const name = member.display_name.trim() || member.handle;
  const parts = name.split(/[\s._-]+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) {
    // One word: two letters read better than one lonely capital.
    return parts[0].slice(0, 2).replace(/^./, (c) => c.toUpperCase());
  }
  return parts
    .slice(0, 2)
    .map((part) => part[0].toUpperCase())
    .join("");
}

/// A workspace full of identical grey squares tells you nothing. Colour is
/// derived from the id, so the same teammate is the same colour on every
/// machine, and the set is deliberately desaturated — this is a calm app, and
/// an avatar is a landmark, not a highlight.
const AVATAR_HUES = [212, 258, 292, 330, 8, 24, 44, 96, 152, 178];

export function avatarStyle(member?: Member): {
  "--avatar-h": string;
} {
  const seed = member?.id ?? member?.handle ?? "";
  let hash = 0;
  for (let index = 0; index < seed.length; index += 1) {
    hash = (hash * 31 + seed.charCodeAt(index)) >>> 0;
  }
  return { "--avatar-h": String(AVATAR_HUES[hash % AVATAR_HUES.length]) };
}

const PULL_REQUEST_TONES: Record<string, string> = {
  OPEN: "accent",
  DRAFT: "caution",
  MERGED: "positive",
  CLOSED: "danger",
};

export function pullRequestTone(state?: string): string {
  return PULL_REQUEST_TONES[state?.toUpperCase() ?? ""] ?? "";
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
  if (size < 1024 * 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  return `${(size / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}
