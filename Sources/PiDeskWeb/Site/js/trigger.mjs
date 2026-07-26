// Pure helpers for the schedule trigger form: parsing/formatting durations, describing a
// trigger for display, and building the wire `trigger` object the daemon API expects
// (docs/daemon-api.md "Triggers"). None of this touches the DOM, so it is covered by
// Tests/PiDeskWebTests-adjacent node checks without a browser.

/**
 * Parses a duration like "15m", "2h", "90s", "1d", or a bare integer (assumed seconds) into a
 * whole number of seconds. Returns null for anything unparsable or non-positive, so callers can
 * treat null as "show a validation error" uniformly.
 */
export function parseDurationToSeconds(input) {
  if (typeof input === "number") return Number.isFinite(input) && input > 0 ? Math.round(input) : null;
  const match = String(input ?? "").trim().match(/^(\d+(?:\.\d+)?)\s*(s|m|h|d)?$/i);
  if (!match) return null;
  const amount = parseFloat(match[1]);
  const unit = (match[2] || "s").toLowerCase();
  const multiplier = { s: 1, m: 60, h: 3600, d: 86400 }[unit];
  const seconds = Math.round(amount * multiplier);
  return seconds > 0 ? seconds : null;
}

/** Formats seconds back into the shortest friendly unit, inverse of `parseDurationToSeconds`. */
export function formatSecondsAsDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "";
  if (seconds % 86400 === 0) return `${seconds / 86400}d`;
  if (seconds % 3600 === 0) return `${seconds / 3600}h`;
  if (seconds % 60 === 0) return `${seconds / 60}m`;
  return `${seconds}s`;
}

// A friendly (not authoritative) shape check on a 5-field cron expression, purely to catch
// obvious typos before a round trip. The daemon is the real validator per docs/daemon-api.md:
// "Anything unparseable is rejected at creation time with a clear error."
export function looksLikeCron(expression) {
  const fields = String(expression ?? "").trim().split(/\s+/);
  return fields.length === 5 && fields.every((f) => /^[0-9A-Za-z*/,-]+$/.test(f));
}

/**
 * Builds the wire `trigger` object for one of the four documented kinds from raw form values, or
 * returns `{ error }` describing what to fix. `kind` is one of "once" | "interval" | "cron" |
 * "heartbeat", matching the segmented control in the schedule form.
 */
export function buildTrigger(kind, form) {
  switch (kind) {
    case "once": {
      const at = form.at ? new Date(form.at) : null;
      if (!at || Number.isNaN(at.getTime())) return { error: "Pick a valid date and time." };
      return { trigger: { kind: "once", at: at.toISOString() } };
    }
    case "interval": {
      const everySeconds = parseDurationToSeconds(form.every);
      if (!everySeconds) return { error: "Enter an interval like 15m, 2h, or 1d." };
      return { trigger: { kind: "interval", everySeconds } };
    }
    case "cron": {
      const expression = String(form.expression ?? "").trim();
      if (!looksLikeCron(expression)) {
        return { error: "Cron needs 5 space-separated fields, e.g. 0 9 * * 1-5." };
      }
      const timeZone = String(form.timeZone ?? "").trim() || Intl.DateTimeFormat().resolvedOptions().timeZone;
      return { trigger: { kind: "cron", expression, timeZone } };
    }
    case "heartbeat": {
      const everySeconds = parseDurationToSeconds(form.every);
      if (!everySeconds) return { error: "Enter an interval like 15m, 2h, or 1d." };
      return { trigger: { kind: "heartbeat", everySeconds } };
    }
    default:
      return { error: `Unknown trigger kind: ${kind}` };
  }
}

/** Human-readable one-liner for a trigger object, used in the schedule list and detail view. */
export function triggerSummary(trigger) {
  if (!trigger || typeof trigger !== "object") return "";
  switch (trigger.kind) {
    case "once":
      return `Once at ${formatAbsolute(trigger.at)}`;
    case "interval":
      return `Every ${formatSecondsAsDuration(trigger.everySeconds)}`;
    case "cron":
      return `Cron ${trigger.expression}${trigger.timeZone ? ` (${trigger.timeZone})` : ""}`;
    case "heartbeat":
      return `Every ${formatSecondsAsDuration(trigger.everySeconds)} while idle`;
    default:
      return `Unknown trigger (${trigger.kind ?? "?"})`; // forward-compatible: never throws
  }
}

function formatAbsolute(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso ?? "");
  return d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}
