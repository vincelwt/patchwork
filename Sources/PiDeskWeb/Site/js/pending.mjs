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

/** Never hold more than this many unconfirmed messages; new sends are refused at capacity. */
export const PENDING_LIMIT = 8;

/** Run statuses that mean the text will never produce a user message. */
const FAILED_RUN_STATUSES = new Set(["failed", "timeout", "skipped", "interrupted"]);

/** The primary Send action matches Desktop: normal prompt while idle, immediate steer while live. */
export function resolveDelivery(delivery, isRunning) {
  return delivery === "auto" && isRunning ? "steer" : delivery;
}

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
 * Records a newly submitted message.
 *
 * `baseline` is how many identical user messages the transcript *already* showed: reconciliation
 * waits for one more than that, so re-sending the same text twice resolves the two bubbles one at
 * a time instead of both at once. `requestedDelivery` is fixed at creation and never overwritten
 * by what the daemon actually did, so retrying a steer that was downgraded to `auto` still asks
 * to steer.
 *
 * Returns `{ list, entry, rejected }`. When the bound is full of unresolved messages, `rejected`
 * is true and the caller must put the text back in the composer. A daemon acceptance only means
 * queued, so even an accepted bubble remains the only visible retry path until its run succeeds
 * or the transcript accounts for it.
 */
export function addPending(list, { key, text, delivery = null, clientId = null, messages = [], at = Date.now() }) {
  const entry = {
    key,
    text,
    at,
    clientId,
    status: "sending",
    requestedDelivery: delivery,
    delivery,
    runId: null,
    error: null,
    settled: false,
    // A transport failure safely retries the same submission id. A terminal run that is
    // explicitly retryable before prompt delivery needs a new id, because the old id replays the
    // terminal answer. An accepted or ambiguous failure is review-only.
    retryMode: "sameSubmission",
    // Set only by `markAccepted`: the daemon answered, so this text is on its way into the
    // transcript whatever happens to this bubble. Until then the bubble holds the only copy.
    accepted: false,
    baseline: userTextCounts(messages).get(normalizeText(text)) || 0
  };

  if (list.length < PENDING_LIMIT) return { list: [...list, entry], entry, rejected: false };

  // A successful run proves the transcript write completed, so a settled bubble is the sole safe
  // eviction candidate. Sending, queued, working, and failed entries must all remain visible.
  const index = list.findIndex((candidate) => candidate.settled && candidate.status !== "failed");
  if (index === -1) return { list, entry: null, rejected: true };
  return { list: [...list.slice(0, index), ...list.slice(index + 1), entry], entry, rejected: false };
}

function patch(list, key, changes) {
  return list.map((entry) => (entry.key === key ? { ...entry, ...changes } : entry));
}

/**
 * The daemon accepted the text. `queued` reports the daemon's run queue, while `delivery` names
 * Pi's live queue (`followUp`) or immediate interruption (`steer`). A command the daemon could not
 * deliver live comes back as `auto`, and saying so is the whole point.
 */
export function markAccepted(list, key, { runId = null, queued = false, delivery = null } = {}) {
  // `requestedDelivery` is deliberately untouched: it is what Retry must ask for again.
  return patch(list, key, { runId, delivery, status: queued ? "queued" : "working", error: null, accepted: true });
}

/**
 * The daemon is already processing this exact submission — a retry that overlapped the original.
 * Not a failure: the bubble stays alive rather than offering a Retry that would race it again.
 *
 * Deliberately *not* an acceptance. The original attempt can still fail and release its claim,
 * and this bubble would then hold the only copy of the text, so it must stay un-evictable.
 */
export function markInFlight(list, key) {
  return patch(list, key, { status: "sending", error: null });
}

/** The request itself failed. The text stays put so it can be retried or copied back out. */
export function markFailed(list, key, error, retryMode = "sameSubmission") {
  return patch(list, key, {
    status: "failed",
    error: error || "Message was not sent.",
    retryMode
  });
}

/** Whether an endpoint error may safely retry the same protected submission. */
export function retryModeForSubmissionError(error, replaySafe = false) {
  const code = String(error?.code || "");
  if (["submission_outcome_unknown", "submission_id_conflict"].includes(code)) return "review";
  if (["prompt_too_large", "empty_text", "invalid_client_id", "attachments_unsupported"].includes(code)) {
    return "review";
  }
  if ([400, 404, 413, 422].includes(Number(error?.status))) return "review";
  return replaySafe ? "sameSubmission" : "review";
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
      const retryMode = run.retryable === true && !run.promptStartedAt
        ? "newSubmission"
        : "review";
      return {
        ...entry,
        status: "failed",
        error: run.error || `The run ${run.status}.`,
        retryMode
      };
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
    // Until the daemon answers, this bubble is the only durable copy of the text. A history page
    // containing an older identical message can never prove this particular send was accepted.
    if (!entry.accepted) return true;
    const key = normalizeText(entry.text);
    const available = (counts.get(key) || 0) - entry.baseline - (used.get(key) || 0);
    if (available <= 0) return true;
    used.set(key, (used.get(key) || 0) + 1);
    return false;
  });
}

/** How many recent runs the view remembers for entries that have no `runId` yet. */
export const RUN_MEMO_LIMIT = 16;

/**
 * Remembers the latest state of a run, newest last, bounded.
 *
 * A run event can beat the POST response that names its run: Pi is fast, the tunnel is not, and
 * a `running` — or even a `failed` — event then arrives while the bubble still has `runId: null`
 * and matches nothing. Replaying the remembered state the moment `markAccepted` supplies the id
 * is what keeps that bubble from sitting on "Sending…" forever.
 */
export function rememberRun(memo, run, limit = RUN_MEMO_LIMIT) {
  if (!run || !run.id) return memo;
  memo.delete(run.id); // re-insert so the map stays in recency order
  memo.set(run.id, run);
  while (memo.size > limit) memo.delete(memo.keys().next().value);
  return memo;
}

/** Short status line shown under an unconfirmed bubble. */
export function statusLabel(entry) {
  switch (entry.status) {
    case "sending":
      return "Sending\u2026";
    case "queued":
      return "Queued: waiting for the current run";
    case "working":
      if (entry.delivery === "steer") return "Steering the current run\u2026";
      if (entry.delivery === "followUp") return "Queued: waiting for the current run";
      return "Sent: waiting for Pi";
    case "failed":
      return entry.error || "Not sent";
    default:
      return "Pending";
  }
}

/**
 * One sentence for the screen-reader live region, naming the message so a status is unambiguous
 * when several are in flight. Returns "" when there is nothing to announce.
 */
export function announcement(entry) {
  if (!entry) return "";
  const excerpt = entry.text.length > 40 ? `${entry.text.slice(0, 39)}\u2026` : entry.text;
  return `${excerpt}: ${statusLabel(entry)}`;
}
