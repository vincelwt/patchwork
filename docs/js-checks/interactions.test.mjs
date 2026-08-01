import test from "node:test";
import assert from "node:assert/strict";
import { RETRY_DELAYS_MS, applyInteractionLoad } from "../../Sources/PatchworkWeb/Site/js/interactions.mjs";

const card = (id) => ({ id, method: "ask", title: "Pick one", options: ["a", "b"] });

test("a successful read replaces the set and clears the retry chain", () => {
  const next = applyInteractionLoad([card("old")], 2, { ok: true, interactions: [card("fresh")] });
  assert.deepEqual(next.interactions.map((i) => i.id), ["fresh"]);
  assert.equal(next.attempt, 0);
  assert.equal(next.retryInMs, null);
});

test("an empty successful read really does clear the cards", () => {
  // Pi answered the dialog on the Mac: the card must go, or a phone keeps offering an answer
  // nobody is waiting for.
  const next = applyInteractionLoad([card("old")], 0, { ok: true, interactions: [] });
  assert.deepEqual(next.interactions, []);
});

test("a failed read keeps the last good set instead of wiping a half-typed answer", () => {
  const previous = [card("q1")];
  const next = applyInteractionLoad(previous, 0, { ok: false });
  assert.equal(next.interactions, previous, "the same array: unchanged cards are reused, so typed input survives");
  assert.equal(next.attempt, 1);
  assert.equal(next.retryInMs, RETRY_DELAYS_MS[0]);
});

test("retries back off and then stop", () => {
  const previous = [card("q1")];
  let attempt = 0;
  const delays = [];
  for (let i = 0; i < RETRY_DELAYS_MS.length + 2; i += 1) {
    const next = applyInteractionLoad(previous, attempt, { ok: false });
    attempt = next.attempt;
    delays.push(next.retryInMs);
  }
  assert.deepEqual(delays, [...RETRY_DELAYS_MS, null, null], "bounded: a reconnect is what refreshes after that");
  assert.ok(RETRY_DELAYS_MS.every((delay, i) => i === 0 || delay > RETRY_DELAYS_MS[i - 1]), "and it backs off");
});

test("one success resets the chain, so a later outage retries again", () => {
  const previous = [card("q1")];
  let state = applyInteractionLoad(previous, RETRY_DELAYS_MS.length, { ok: false });
  assert.equal(state.retryInMs, null, "spent");

  state = applyInteractionLoad(state.interactions, state.attempt, { ok: true, interactions: previous });
  state = applyInteractionLoad(state.interactions, state.attempt, { ok: false });
  assert.equal(state.retryInMs, RETRY_DELAYS_MS[0]);
});
