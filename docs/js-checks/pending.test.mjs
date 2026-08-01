import test from "node:test";
import assert from "node:assert/strict";
import {
  PENDING_LIMIT,
  RUN_MEMO_LIMIT,
  addPending as addPendingRaw,
  announcement,
  markInFlight,
  applyRunEvent,
  markAccepted,
  markFailed,
  normalizeText,
  reconcile,
  rememberRun,
  removePending,
  resolveDelivery,
  statusLabel,
  userTextCounts
} from "../../Sources/PatchworkWeb/Site/js/pending.mjs";

const user = (text) => ({ role: "user", text });

/** Most tests only care about the resulting list; the bound test uses the raw form. */
const addPending = (list, options) => addPendingRaw(list, options).list;

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

test("primary delivery steers only while the thread is running", () => {
  assert.equal(resolveDelivery("auto", false), "auto");
  assert.equal(resolveDelivery("auto", true), "steer");
  assert.equal(resolveDelivery("followUp", true), "followUp");
  assert.equal(resolveDelivery("steer", false), "steer");
});

test("steer and follow-up delivery labels show their distinct timing", () => {
  let list = addPending([], { key: "p1", text: "stop that", messages: [] });
  list = markAccepted(list, "p1", { runId: "run_1", queued: false, delivery: "steer" });
  assert.equal(statusLabel(list[0]), "Steering the current run\u2026");

  let followUp = addPending([], { key: "p2", text: "and then", messages: [] });
  followUp = markAccepted(followUp, "p2", { runId: "run_1", queued: false, delivery: "followUp" });
  assert.equal(statusLabel(followUp[0]), "Queued \u2014 waiting for the current run");

  // The daemon reports `auto` when there was no live turn to interrupt.
  let downgraded = addPending([], { key: "p3", text: "stop that", messages: [] });
  downgraded = markAccepted(downgraded, "p3", { runId: "run_2", queued: true, delivery: "auto" });
  assert.equal(statusLabel(downgraded[0]), "Queued \u2014 waiting for the current run");
});

test("the pending list is bounded, and evicts only messages that were actually sent", () => {
  let list = [];
  for (let i = 0; i < PENDING_LIMIT + 5; i += 1) {
    const added = addPendingRaw(list, { key: `p${i}`, text: `m${i}`, messages: [] });
    assert.equal(added.rejected, false);
    list = markAccepted(added.list, `p${i}`, { runId: `run_${i}` });
  }
  assert.equal(list.length, PENDING_LIMIT);
  assert.equal(list[0].key, "p5", "the oldest accepted entry is the one dropped");
});

test("a list full of sends still waiting on a response refuses a new one", () => {
  // The dangerous eviction: a bubble whose POST has not been answered yet holds the only copy of
  // that text. If the send later fails, dropping the bubble is how the message disappears for
  // good — so the ninth is refused and the composer takes its text back instead.
  let list = [];
  for (let i = 0; i < PENDING_LIMIT; i += 1) {
    list = addPendingRaw(list, { key: `p${i}`, text: `m${i}`, messages: [] }).list;
  }
  assert.ok(list.every((entry) => entry.status === "sending" && entry.accepted === false));

  const added = addPendingRaw(list, { key: "new", text: "must not be lost", messages: [] });
  assert.equal(added.rejected, true);
  assert.equal(added.entry, null);
  assert.deepEqual(added.list.map((entry) => entry.key), list.map((entry) => entry.key), "nothing was evicted");

  // Once the daemon answers one of them, that text is on its way into the transcript and its
  // bubble is safe to drop.
  const accepted = markAccepted(list, "p0", { runId: "run_0" });
  const room = addPendingRaw(accepted, { key: "new", text: "fits now", messages: [] });
  assert.equal(room.rejected, false);
  assert.ok(!room.list.some((entry) => entry.key === "p0"), "the accepted one is what made room");
});

test("an overlapping submission is not an acceptance, so its bubble is not evictable", () => {
  // `submission_in_flight` says the daemon is already working on this exact submission — which
  // can still fail and release its claim. Until something is confirmed, this bubble is the only
  // copy of the text.
  let list = [];
  for (let i = 0; i < PENDING_LIMIT; i += 1) {
    list = markInFlight(addPendingRaw(list, { key: `p${i}`, text: `m${i}`, messages: [] }).list, `p${i}`);
  }
  assert.ok(list.every((entry) => entry.status === "working" && entry.accepted === false));

  const added = addPendingRaw(list, { key: "new", text: "must not be lost", messages: [] });
  assert.equal(added.rejected, true, "a retry that raced the original must not cost a message");
});

test("a full list of failed messages refuses a new one rather than destroying unsent text", () => {
  let list = [];
  for (let i = 0; i < PENDING_LIMIT; i += 1) {
    list = markFailed(addPendingRaw(list, { key: `p${i}`, text: `m${i}`, messages: [] }).list, `p${i}`, "offline");
  }
  const added = addPendingRaw(list, { key: "new", text: "must not be lost", messages: [] });
  assert.equal(added.rejected, true);
  assert.equal(added.entry, null);
  assert.equal(added.list.length, PENDING_LIMIT);
  assert.ok(added.list.every((entry) => entry.status === "failed"), "nothing was evicted");
});

test("a run event that beat its own POST response still lands on the bubble", () => {
  // Pi is fast and the tunnel is not: `run` can arrive while the bubble still has `runId: null`,
  // matching nothing. The view remembers recent runs and replays the latest state the moment
  // `markAccepted` supplies the id.
  const memo = new Map();
  rememberRun(memo, { id: "run_1", status: "running" });
  rememberRun(memo, { id: "run_1", status: "ok" });
  assert.equal(memo.size, 1, "one entry per run, latest state");

  let list = addPendingRaw([], { key: "p1", text: "hello", messages: [] }).list;
  list = applyRunEvent(list, memo.get("run_1"));
  assert.equal(list[0].settled, false, "nothing matched: the bubble has no run id yet");

  list = markAccepted(list, "p1", { runId: "run_1" });
  list = applyRunEvent(list, memo.get("run_1"));
  assert.equal(list[0].settled, true, "the missed event is applied as soon as the id is known");
});

test("a failed run that arrived early is not lost either", () => {
  const memo = new Map();
  rememberRun(memo, { id: "run_1", status: "failed", error: "Pi crashed." });

  let list = addPendingRaw([], { key: "p1", text: "hello", messages: [] }).list;
  list = markAccepted(list, "p1", { runId: "run_1" });
  list = applyRunEvent(list, memo.get("run_1"));
  assert.equal(list[0].status, "failed");
  assert.equal(statusLabel(list[0]), "Pi crashed.", "and it offers Retry instead of spinning forever");
});

test("the remembered runs are bounded and keep the newest", () => {
  const memo = new Map();
  for (let i = 0; i < RUN_MEMO_LIMIT + 5; i += 1) rememberRun(memo, { id: `run_${i}`, status: "running" });
  assert.equal(memo.size, RUN_MEMO_LIMIT);
  assert.equal(memo.has("run_0"), false, "the oldest went first");
  assert.equal(memo.has(`run_${RUN_MEMO_LIMIT + 4}`), true);

  assert.equal(rememberRun(memo, null).size, RUN_MEMO_LIMIT, "a junk event changes nothing");
  assert.equal(rememberRun(memo, { status: "ok" }).size, RUN_MEMO_LIMIT);
});

test("a mixed full list evicts the oldest sent message, never a failed one", () => {
  let list = addPendingRaw([], { key: "failed", text: "unsent", messages: [] }).list;
  list = markFailed(list, "failed", "offline");
  for (let i = 1; i < PENDING_LIMIT; i += 1) {
    list = markAccepted(addPendingRaw(list, { key: `p${i}`, text: `m${i}`, messages: [] }).list, `p${i}`, {});
  }
  const added = addPendingRaw(list, { key: "fresh", text: "fresh", messages: [] });
  assert.equal(added.rejected, false);
  assert.ok(
    added.list.some((entry) => entry.key === "failed"),
    "the unsent message survives"
  );
  assert.ok(!added.list.some((entry) => entry.key === "p1"), "the oldest sent one went instead");
});

test("retry keeps the requested delivery even after the daemon downgraded it", () => {
  const added = addPendingRaw([], { key: "p1", text: "stop", delivery: "steer", clientId: "c1", messages: [] });
  const downgraded = markAccepted(added.list, "p1", { runId: "run_1", queued: true, delivery: "auto" });
  assert.equal(downgraded[0].delivery, "auto", "the status line tells the truth");
  assert.equal(downgraded[0].requestedDelivery, "steer", "retry still asks to steer");
  assert.equal(downgraded[0].clientId, "c1", "and reuses the same submission id");
});

test("an overlapping retry is shown as still working, not as a failure", () => {
  let list = addPendingRaw([], { key: "p1", text: "x", messages: [] }).list;
  list = markFailed(list, "p1", "boom");
  list = markInFlight(list, "p1");
  assert.equal(list[0].status, "working");
  assert.equal(list[0].error, null);
});

test("announcements name the message and stay quiet for nothing", () => {
  const list = addPendingRaw([], { key: "p1", text: "run the tests", messages: [] }).list;
  assert.equal(announcement(list[0]), "run the tests: Sending\u2026");
  assert.equal(announcement(undefined), "");
  const long = addPendingRaw([], { key: "p2", text: "x".repeat(80), messages: [] }).list[0];
  assert.ok(announcement(long).length < 80, "long text is excerpted");
});

test("only user messages count toward reconciliation", () => {
  const counts = userTextCounts([user("a"), { role: "assistant", text: "a" }, { role: "toolResult", text: "a" }]);
  assert.equal(counts.get("a"), 1);
});
