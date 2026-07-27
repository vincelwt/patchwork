import test from "node:test";
import assert from "node:assert/strict";
import {
  PENDING_LIMIT,
  addPending,
  applyRunEvent,
  markAccepted,
  markFailed,
  normalizeText,
  reconcile,
  removePending,
  statusLabel,
  userTextCounts
} from "../../Sources/PiDeskWeb/Site/js/pending.mjs";

const user = (text) => ({ role: "user", text });

test("a pending message survives a refetch that does not yet contain it", () => {
  // The exact bug this module exists for: the daemon accepts the text, the view refetches
  // immediately, and Pi has not appended the user entry yet.
  let list = addPending([], { key: "p1", text: "hello", messages: [] });
  list = markAccepted(list, "p1", { runId: "run_1", queued: false });
  assert.equal(list.length, 1);
  assert.equal(list[0].status, "working");

  list = reconcile(list, [{ role: "assistant", text: "older reply" }]);
  assert.equal(list.length, 1, "must not vanish before the real message lands");

  list = reconcile(list, [{ role: "assistant", text: "older reply" }, user("hello")]);
  assert.equal(list.length, 0, "dropped once Pi wrote the user entry");
});

test("reconciliation is whitespace-insensitive but never double-consumes", () => {
  assert.equal(normalizeText("  a \n b  "), "a b");

  let list = addPending([], { key: "p1", text: "same", messages: [] });
  list = addPending(list, { key: "p2", text: "same", messages: [] });

  list = reconcile(list, [user("same")]);
  assert.deepEqual(list.map((e) => e.key), ["p2"], "one arrival resolves exactly one bubble");

  list = reconcile(list, [user("same"), user("  same  ")]);
  assert.equal(list.length, 0);
});

test("an identical earlier message does not resolve a new send", () => {
  const history = [user("run tests")];
  let list = addPending([], { key: "p1", text: "run tests", messages: history });
  assert.equal(list[0].baseline, 1);

  list = reconcile(list, history);
  assert.equal(list.length, 1, "the pre-existing copy is not the one just sent");

  list = reconcile(list, [...history, user("run tests")]);
  assert.equal(list.length, 0);
});

test("failure preserves the text, blocks reconciliation, and reads honestly", () => {
  let list = addPending([], { key: "p1", text: "keep me", messages: [] });
  list = markFailed(list, "p1", "Can\u2019t reach your Mac.");
  assert.equal(list[0].text, "keep me");
  assert.equal(statusLabel(list[0]), "Can\u2019t reach your Mac.");

  // Even a matching user message must not silently clear a failure the reader has not seen.
  list = reconcile(list, [user("keep me")]);
  assert.equal(list.length, 1);

  assert.equal(removePending(list, "p1").length, 0);
});

test("run events drive status and a failed run marks the bubble failed", () => {
  let list = addPending([], { key: "p1", text: "go", messages: [] });
  list = markAccepted(list, "p1", { runId: "run_1", queued: true });
  assert.equal(statusLabel(list[0]), "Queued \u2014 waiting for the current run");

  list = applyRunEvent(list, { id: "run_1", status: "running" });
  assert.equal(list[0].status, "working");

  list = applyRunEvent(list, { id: "run_other", status: "failed", error: "nope" });
  assert.equal(list[0].status, "working", "another run's event is ignored");

  list = applyRunEvent(list, { id: "run_1", status: "failed", error: "Pi exited" });
  assert.equal(statusLabel(list[0]), "Pi exited");
  assert.equal(reconcile(list, [user("go")]).length, 1);
});

test("a run that finished ok drops the bubble even if the text never matches", () => {
  // Pi may normalise or wrap a prompt; a successful run still proves the entry was written.
  let list = addPending([], { key: "p1", text: "original", messages: [] });
  list = markAccepted(list, "p1", { runId: "run_1" });
  list = applyRunEvent(list, { id: "run_1", status: "ok" });
  assert.equal(reconcile(list, [user("something else entirely")]).length, 0);
});

test("steer delivery is labelled as steering, and a downgrade is reported honestly", () => {
  let list = addPending([], { key: "p1", text: "stop that", messages: [] });
  list = markAccepted(list, "p1", { runId: "run_1", queued: false, delivery: "steer" });
  assert.equal(statusLabel(list[0]), "Steering the current run\u2026");

  // The daemon reports `auto` when there was no live turn to interrupt.
  let downgraded = addPending([], { key: "p2", text: "stop that", messages: [] });
  downgraded = markAccepted(downgraded, "p2", { runId: "run_2", queued: true, delivery: "auto" });
  assert.equal(statusLabel(downgraded[0]), "Queued \u2014 waiting for the current run");
});

test("the pending list is bounded", () => {
  let list = [];
  for (let i = 0; i < PENDING_LIMIT + 5; i += 1) {
    list = addPending(list, { key: `p${i}`, text: `m${i}`, messages: [] });
  }
  assert.equal(list.length, PENDING_LIMIT);
  assert.equal(list[0].key, `p${5}`, "oldest entries are dropped first");
});

test("only user messages count toward reconciliation", () => {
  const counts = userTextCounts([user("a"), { role: "assistant", text: "a" }, { role: "toolResult", text: "a" }]);
  assert.equal(counts.get("a"), 1);
});
