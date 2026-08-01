import test from "node:test";
import assert from "node:assert/strict";
import {
  applyActivityToThreads,
  applyActivityAndRunEventsToThreads,
  applyRunEventToThreads,
  applyRunEventsToThreads,
  applyScheduleEvent,
  createAdmissionGate,
  createBoundedDisclosureState,
  createBoundedThreadMutationGate,
  createCoalescedTask,
  createProtectedMutationIntent,
  createRequestGate,
  createSnapshotGate,
  isActiveRunStatus,
  protectedMutationDisposition,
  runPresentationSignature
} from "../../Sources/PatchworkWeb/Site/js/liveSync.mjs";

test("bounded disclosure state prunes invisible keys and its oldest overflow", () => {
  const state = createBoundedDisclosureState(2);
  state.set("one", true);
  state.set("two", false);
  state.set("three", true);
  assert.equal(state.has("one"), false);
  assert.equal(state.size, 2);
  state.retain(new Set(["three"]));
  assert.equal(state.has("two"), false);
  assert.equal(state.get("three"), true);
  assert.equal(state.size, 1);
});

test("send admission closes synchronously while durable reservation is pending", () => {
  const gate = createAdmissionGate();
  assert.equal(gate.enter(), true);
  assert.equal(gate.active, true);
  assert.equal(gate.enter(), false);
  gate.leave();
  assert.equal(gate.enter(), true);
});

test("protected mutation intent single-flights and reuses an ambiguous id", () => {
  let sequence = 0;
  const intent = createProtectedMutationIntent(() => `intent-${++sequence}`);
  assert.equal(intent.begin(), "intent-1");
  assert.equal(intent.begin(), null);
  intent.finish(false);
  assert.equal(intent.begin(), "intent-1");
  intent.finish(true);
  assert.equal(intent.begin(), "intent-2");
  intent.reset();
  assert.equal(intent.retainedID, null);
  assert.equal(intent.begin(), "intent-3");
});

test("bounded thread mutation tickets fail closed across events, eviction, and reinsertion", () => {
  const gate = createBoundedThreadMutationGate(2);
  const first = gate.begin("one");
  assert.equal(gate.canPublish(first), true);
  gate.recordEvent(["one"]);
  assert.equal(gate.canPublish(first), false);

  const afterEvent = gate.begin("one");
  const newer = gate.begin("one");
  assert.equal(gate.canPublish(afterEvent), false);
  assert.equal(gate.canPublish(newer), true);

  const evicted = gate.begin("two");
  gate.begin("three");
  assert.equal(gate.size, 2);
  assert.equal(gate.canPublish(newer), false);
  gate.begin("one");
  assert.equal(gate.canPublish(newer), false);
  assert.equal(gate.canPublish(evicted), false);
});

test("protected mutation failures distinguish retry, review, and definite reset", () => {
  assert.equal(protectedMutationDisposition(
    { status: 409, code: "schedule_run_outcome_unknown" },
    { replaySafe: true, reviewCodes: ["run_id_conflict"] }
  ), "review");
  assert.equal(protectedMutationDisposition(
    { status: 409, code: "run_id_conflict" },
    { replaySafe: true, reviewCodes: ["run_id_conflict"] }
  ), "review");
  assert.equal(protectedMutationDisposition(new Error("network"), { replaySafe: true }), "retry");
  assert.equal(protectedMutationDisposition(new Error("network"), { replaySafe: false }), "review");
  assert.equal(protectedMutationDisposition({ status: 422, code: "invalid" }, { replaySafe: true }), "reset");
});

test("activity snapshots reconcile terminal and app thinking without guessing copied ids", () => {
  const threads = [
    { id: "unique", path: "/unique", running: false },
    { id: "copied", path: "/copy-one", running: true },
    { id: "copied", path: "/copy-two", running: false }
  ];
  const updated = applyActivityToThreads(threads, {
    running: [
      { threadId: "unique" },
      { threadId: "copied" },
      { threadId: "copied", threadPath: "/copy-two" }
    ]
  });
  assert.equal(updated[0].running, true);
  assert.equal(updated[1].running, false);
  assert.equal(updated[2].running, true);
});

test("an old terminal run memo cannot override a fresher running snapshot", () => {
  const thread = { id: "one", path: "/one", running: true, updatedAt: "2026-08-01T10:05:00Z" };
  const updated = applyRunEventToThreads([thread], {
    threadId: "one", threadPath: "/one", status: "ok", finishedAt: "2026-08-01T10:00:00Z"
  });
  assert.equal(updated[0], thread);
});

test("a snapshot captured before completion cannot relight the finished run", () => {
  const thread = { id: "one", path: "/one", running: true };
  const updated = applyActivityAndRunEventsToThreads([thread], {
    observedAt: "2026-08-01T10:04:00Z",
    running: [{ threadId: "one", threadPath: "/one", since: "2026-08-01T10:00:00Z" }]
  }, [{
    threadId: "one", threadPath: "/one", status: "ok",
    startedAt: "2026-08-01T10:00:00Z", finishedAt: "2026-08-01T10:05:00Z"
  }]);
  assert.equal(updated[0].running, false);
});

test("a genuinely newer heartbeat instance supersedes an older terminal memo", () => {
  const updated = applyActivityAndRunEventsToThreads([
    { id: "one", path: "/one", running: false }
  ], {
    observedAt: "2026-08-01T10:07:00Z",
    running: [{ threadId: "one", threadPath: "/one", since: "2026-08-01T10:06:00Z" }]
  }, [{
    threadId: "one", threadPath: "/one", status: "ok", finishedAt: "2026-08-01T10:05:00Z"
  }]);
  assert.equal(updated[0].running, true);
});

test("run events patch one physical thread without a catalog refresh", () => {
  const threads = [
    { id: "shared", path: "/one.jsonl", running: false },
    { id: "shared", path: "/two.jsonl", running: false }
  ];
  const running = applyRunEventToThreads(threads, {
    threadId: "shared", threadPath: "/two.jsonl", status: "running"
  });
  assert.equal(running[0], threads[0]);
  assert.equal(running[1].running, true);
  assert.equal(
    applyRunEventToThreads(running, {
      threadId: "shared", threadPath: "/two.jsonl", status: "running"
    }),
    running,
    "a duplicate run event preserves list identity"
  );

  const settled = applyRunEventToThreads(running, {
    threadId: "shared", threadPath: "/two.jsonl", status: "ok"
  });
  assert.equal(settled[1].running, false);
  assert.equal(
    applyRunEventToThreads(threads, { threadId: "shared", status: "running" }),
    threads,
    "a copied public id is never guessed"
  );
});

test("queued runs stay visibly active and enriched terminal events are not deduplicated", () => {
  assert.equal(isActiveRunStatus("queued"), true);
  assert.equal(isActiveRunStatus("running"), true);
  assert.equal(isActiveRunStatus("ok"), false);

  const terminal = { id: "r1", status: "failed", finishedAt: "now" };
  assert.notEqual(
    runPresentationSignature(terminal),
    runPresentationSignature({
      ...terminal, error: "runtime unavailable", retryable: true, promptStartedAt: null
    })
  );
});

test("a run memo overlays a catalog in one pass without guessing copied ids", () => {
  const threads = [
    { id: "unique", path: "/unique", running: false },
    { id: "copied", path: "/copy-one", running: false },
    { id: "copied", path: "/copy-two", running: false }
  ];
  const updated = applyRunEventsToThreads(threads, [
    { threadId: "unique", status: "queued" },
    { threadId: "copied", status: "running" },
    { threadId: "copied", threadPath: "/copy-two", status: "running" }
  ]);

  assert.equal(updated[0].running, true);
  assert.equal(updated[1], threads[1]);
  assert.equal(updated[2].running, true);
  assert.equal(applyRunEventsToThreads(updated, []), updated);
});

test("only the newest request generation may publish", () => {
  const gate = createRequestGate();
  const oldRequest = gate.begin();
  const newRequest = gate.begin();

  assert.equal(gate.isCurrent(oldRequest), false);
  assert.equal(gate.isCurrent(newRequest), true);
  gate.invalidate();
  assert.equal(gate.isCurrent(newRequest), false);
});

test("a point event invalidates an older snapshot without superseding a later retry", () => {
  const gate = createSnapshotGate();
  const beforeEvent = gate.begin();
  gate.recordEvent();
  assert.equal(gate.disposition(beforeEvent), "eventChanged");

  const afterEvent = gate.begin();
  assert.equal(gate.disposition(afterEvent), "current");
  const newerRequest = gate.begin();
  assert.equal(gate.disposition(afterEvent), "superseded");
  assert.equal(gate.disposition(newerRequest), "current");
});

test("schedule events upsert and deletion events remove exactly one schedule", () => {
  const original = [
    { id: "first", name: "Old" },
    { id: "second", name: "Keep" }
  ];
  const updated = applyScheduleEvent(original, "schedule", { id: "first", name: "Fresh" });
  assert.deepEqual(updated, [
    { id: "first", name: "Fresh" },
    { id: "second", name: "Keep" }
  ]);

  assert.deepEqual(applyScheduleEvent(updated, "schedule_deleted", { id: "first" }), [
    { id: "second", name: "Keep" }
  ]);
});

test("unknown and malformed schedule events preserve the current list", () => {
  const original = [{ id: "first", name: "Keep" }];
  assert.equal(applyScheduleEvent(original, "future_event", { id: "first" }), original);
  assert.equal(applyScheduleEvent(original, "schedule_deleted", { id: 42 }), original);
});

test("bursty refresh requests allow one active pass and one trailing pass", async () => {
  let active = 0;
  let maximumActive = 0;
  let invocations = 0;
  const releases = [];
  const task = createCoalescedTask(async () => {
    invocations += 1;
    active += 1;
    maximumActive = Math.max(maximumActive, active);
    await new Promise((resolve) => releases.push(resolve));
    active -= 1;
  });

  const first = task.run();
  await Promise.resolve();
  for (let index = 0; index < 100; index += 1) task.run();
  assert.equal(invocations, 1);
  assert.equal(maximumActive, 1);

  releases.shift()();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(invocations, 2, "the burst becomes exactly one trailing pass");
  assert.equal(maximumActive, 1);

  releases.shift()();
  await first;
  assert.equal(task.isActive(), false);
});
