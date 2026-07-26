// Pure time-formatting helpers. Take an explicit `now` everywhere so behavior is deterministic
// and testable without mocking the system clock.

/**
 * Compact relative time for list rows: "now", "5m", "3h", "2d", then a short absolute date once
 * it stops being useful as a relative label. Returns "" for an unparsable input rather than
 * throwing, since it renders directly into a list row.
 */
export function relativeTime(iso, now = new Date()) {
  const then = iso instanceof Date ? iso : new Date(iso);
  if (Number.isNaN(then.getTime())) return "";
  const seconds = Math.round((now.getTime() - then.getTime()) / 1000);
  const abs = Math.abs(seconds);
  if (abs < 5) return "now";
  if (abs < 60) return `${signed(seconds)}${abs}s`;
  if (abs < 3600) return `${signed(seconds)}${Math.round(abs / 60)}m`;
  if (abs < 86400) return `${signed(seconds)}${Math.round(abs / 3600)}h`;
  if (abs < 86400 * 7) return `${signed(seconds)}${Math.round(abs / 86400)}d`;
  const sameYear = then.getFullYear() === now.getFullYear();
  return then.toLocaleDateString(undefined, { month: "short", day: "numeric", year: sameYear ? undefined : "numeric" });
}

// Future timestamps (e.g. a schedule's nextRunAt) read as "in 5m" rather than "5m".
function signed(seconds) {
  return seconds < 0 ? "in " : "";
}

/** `HH:MM` in the viewer's local time, for message timestamps within a thread. */
export function clockTime(iso) {
  const d = iso instanceof Date ? iso : new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}
