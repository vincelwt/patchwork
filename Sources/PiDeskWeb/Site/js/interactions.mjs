// What the thread view does with the result of one `GET /v1/interactions`.
//
// The list is authoritative: it is what a reconnecting phone rehydrates its questionnaire cards
// from. That makes a *failed* read the dangerous case. Clearing the cards because a poll lost the
// tunnel for a second throws away a half-typed answer to a dialog Pi is still blocked on, and
// nothing brings it back until an unrelated `interaction` event happens to arrive.
//
// So a failure changes nothing on screen and schedules a bounded retry instead. Pure data in,
// pure data out — no DOM, no timers, no network (docs/js-checks/interactions.test.mjs).

/** Backoff for the bounded retry chain. Its length *is* the retry bound. */
export const RETRY_DELAYS_MS = [2000, 4000];

/**
 * `result` is `{ok: true, interactions}` for a successful read, anything falsy-`ok` for a failed
 * one. Returns the cards to show, the next attempt counter, and how long to wait before trying
 * again (`null` when the retries are spent — a reconnect refreshes anyway).
 */
export function applyInteractionLoad(previous, attempt, result) {
  if (result && result.ok) return { interactions: result.interactions || [], attempt: 0, retryInMs: null };
  const next = Math.max(0, attempt);
  return { interactions: previous, attempt: next + 1, retryInMs: RETRY_DELAYS_MS[next] ?? null };
}
