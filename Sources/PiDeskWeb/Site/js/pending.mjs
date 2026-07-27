// Optimistic pending user messages: the bridge between "the daemon accepted my text" and "Pi has
// actually written it into the session file".
//
// Those two moments are seconds apart. `POST /v1/threads/{id}/messages` only *queues* (or steers)
// the text; Pi appends the user entry to its JSONL later, and the thread view learns about it
// only on the next refetch. Clearing the composer on the POST response and refetching immediately
// — which is what this screen used to do — therefore made the message vanish completely until an
// unrelated thread/run event happened to arrive.
//
// So the text is held here, rendered immediately with an honest status, and dropped only once the
// real parsed message shows up (or the run definitively fails). Pure data in, pure data out: no
// DOM, no timers, no network, so the reconciliation rules are testable on their own
// (docs/js-checks/pending.test.mjs).

/** Never hold more than this many unconfirmed messages; the oldest are dropped first. */
export const PENDING_LIMIT = 8;

/** Run statuses that mean the text will never produce a user message. */
const FAILED_RUN_STATUSES = new Set(["failed", "timeout", "skipped"]);

/**
 * Whitespace-insensitive comparison key. The daemon trims the text it accepts and Pi re-emits it
 * through its own JSON encoding, so an exact string match would miss legitimate reconciliations.
 */
export function normalizeText(text) {
  return String(text ?? "")
    .replace(/\s+/g, " ")
    .trim();
}

/** How many real user messages currently carry each normalized text. */
export function userTextCounts(messages) {
  const counts = new Map();
  for (const message of messages || []) {
    if (message?.role !== "user") continue;
    const key = normalizeText(message.text);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return counts;
}

/**
 * Records a newly submitted message. `baseline` is how many identical user messages the
 * transcript *already* showed: reconciliation waits for one more than that, so re-sending the
 * same text twice resolves the two bubbles one at a time instead of both at once.
 */
export function addPending(list, { key, text, messages = [], at = Date.now() }) {
  const entry = {
    key,
    text,
    at,
    status: "sending",
    runId: null,
    error: null,
    settled: false,
    baseline: userTextCounts(messages).get(normalizeText(text)) || 0
  };
  return [...list, entry].slice(-PENDING_LIMIT);
}

function patch(list, key, changes) {
  return list.map((entry) => (entry.key === key ? { ...entry, ...changes } : entry));
}

/**
 * The daemon accepted the text. `queued` distinguishes "waiting for the current run to finish"
 * from "Pi is on it", and `delivery` reports what actually happened — a `steer` the daemon could
 * not deliver live comes back as `auto`, and saying so is the whole point.
 */
export function markAccepted(list, key, { runId = null, queued = false, delivery = null } = {}) {
  return patch(list, key, { runId, delivery, status: queued ? "queued" : "working", error: null });
}

/** The request itself failed. The text stays put so it can be retried or copied back out. */
export function markFailed(list, key, error) {
  return patch(list, key, { status: "failed", error: error || "Message was not sent." });
}

export function removePending(list, key) {
  return list.filter((entry) => entry.key !== key);
}

/**
 * A run event moves every pending entry it owns. A finished-ok run means Pi certainly wrote the
 * user entry, so the bubble is marked `settled` and the next reconcile drops it even if the text
 * match cannot be made (e.g. Pi normalised the prompt).
 */
export function applyRunEvent(list, run) {
  if (!run || !run.id) return list;
  return list.map((entry) => {
    if (entry.runId !== run.id || entry.status === "failed") return entry;
    if (run.status === "running") return { ...entry, status: "working" };
    if (run.status === "ok") return { ...entry, settled: true };
    if (FAILED_RUN_STATUSES.has(run.status)) {
      return { ...entry, status: "failed", error: run.error || `The run ${run.status}.` };
    }
    return entry;
  });
}

/**
 * Drops every pending entry the transcript now accounts for. Entries are consumed in submission
 * order and each real message is used at most once, so two identical pending messages never both
 * disappear on the strength of a single arrival. A failed entry is never reconciled away: it
 * stays until the reader retries or dismisses it.
 */
export function reconcile(list, messages) {
  const counts = userTextCounts(messages);
  const used = new Map();
  return list.filter((entry) => {
    if (entry.status === "failed") return true;
    if (entry.settled) return false;
    const key = normalizeText(entry.text);
    const available = (counts.get(key) || 0) - entry.baseline - (used.get(key) || 0);
    if (available <= 0) return true;
    used.set(key, (used.get(key) || 0) + 1);
    return false;
  });
}

/** Short status line shown under an unconfirmed bubble. */
export function statusLabel(entry) {
  switch (entry.status) {
    case "sending":
      return "Sending\u2026";
    case "queued":
      return "Queued \u2014 waiting for the current run";
    case "working":
      return entry.delivery === "steer" ? "Steering the current run\u2026" : "Sent \u2014 waiting for Pi";
    case "failed":
      return entry.error || "Not sent";
    default:
      return "Pending";
  }
}
