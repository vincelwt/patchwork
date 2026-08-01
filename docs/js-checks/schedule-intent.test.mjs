import test from "node:test";
import assert from "node:assert/strict";
import {
  createScheduleCreationIntentStore,
  createScheduleRunIntentStore
} from "../../Sources/PatchworkWeb/Site/js/scheduleIntent.mjs";

class MemoryStorage {
  values = new Map();
  getItem(key) { return this.values.get(key) ?? null; }
  setItem(key, value) { this.values.set(key, String(value)); }
  removeItem(key) { this.values.delete(key); }
}

class MemoryLockManager {
  tail = Promise.resolve();
  request(_name, _options, operation) {
    const result = this.tail.then(operation);
    this.tail = result.catch(() => {});
    return result;
  }
}

class StorageEvents {
  listeners = new Set();
  addEventListener(name, listener) {
    if (name === "storage") this.listeners.add(listener);
  }
  dispatch(key, newValue, storageArea) {
    for (const listener of this.listeners) listener({ key, newValue, storageArea });
  }
}

class ThrowingReadStorage extends MemoryStorage {
  throwOnRead = false;
  writes = 0;
  getItem(key) {
    if (this.throwOnRead) throw new Error("read failed");
    return super.getItem(key);
  }
  setItem(key, value) {
    this.writes += 1;
    super.setItem(key, value);
  }
}

function creation(overrides = {}) {
  return {
    name: "Morning review",
    target: { kind: "newThread", cwd: "/tmp/project" },
    prompt: "Review the queue",
    trigger: { kind: "interval", everySeconds: 3600 },
    ...overrides
  };
}

test("protected schedule creation survives reload with one stable id", async () => {
  const storage = new MemoryStorage();
  const first = createScheduleCreationIntentStore({
    storage, now: () => 1000, idFactory: () => "schedule-create-one"
  });
  const request = creation();
  const admitted = await first.reserve("create", request, { replayProtected: true });
  assert.equal(admitted.clientId, "schedule-create-one");
  assert.equal(first.pending("create").disposition, "attempting");
  await first.markReplayable("create", admitted.clientId, "response_lost");

  const reloaded = createScheduleCreationIntentStore({
    storage, now: () => 1100, idFactory: () => "must-not-run"
  });
  const retry = await reloaded.reserve("create", { ...request }, { replayProtected: true });
  assert.equal(retry.clientId, admitted.clientId);
  assert.equal(retry.isReplay, true);
});

test("a changed schedule cannot replace unresolved work", async () => {
  const storage = new MemoryStorage();
  const store = createScheduleCreationIntentStore({
    storage, idFactory: () => "schedule-create-one"
  });
  await store.reserve("create", creation(), { replayProtected: true });
  assert.equal(await store.reserve(
    "create", creation({ prompt: "Different work" }), { replayProtected: true }
  ), null);
  assert.equal(store.pending("create").body.prompt, "Review the queue");
});

test("an unprotected older daemon admits one tab and blocks every other tab", async () => {
  const storage = new MemoryStorage();
  const lockManager = new MemoryLockManager();
  const first = createScheduleCreationIntentStore({
    storage, lockManager, requireDurable: true,
    idFactory: () => "schedule-old-daemon"
  });
  const second = createScheduleCreationIntentStore({
    storage, lockManager, requireDurable: true,
    idFactory: () => "must-not-run"
  });
  const request = creation();
  const [one, two] = await Promise.all([
    first.reserve("create", request, { replayProtected: false }),
    second.reserve("create", request, { replayProtected: false })
  ]);
  assert.equal(one.clientId, "schedule-old-daemon");
  assert.equal(two, null);
  assert.equal(second.pending("create").disposition, "attempting");
  assert.equal(await second.discard("create", one.clientId), false);

  await first.markReview("create", one.clientId, "transport_unknown");
  assert.equal(second.pending("create").disposition, "review");
});

test("protected manual runs reuse an id and never overlap across tabs", async () => {
  const storage = new MemoryStorage();
  const lockManager = new MemoryLockManager();
  const first = createScheduleRunIntentStore({
    storage, lockManager, requireDurable: true, idFactory: () => "run-one"
  });
  const second = createScheduleRunIntentStore({
    storage, lockManager, requireDurable: true, idFactory: () => "run-two"
  });
  const admitted = await first.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  assert.equal(await second.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  }), null);
  await first.markReplayable("schedule-a", admitted.clientId, "response_lost");
  const retry = await second.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  assert.equal(retry.clientId, admitted.clientId);
  assert.equal(retry.isReplay, true);
});

test("completion is idempotent but a stale id cannot clear newer work", async () => {
  const storage = new MemoryStorage();
  const ids = ["run-one", "run-two"];
  const store = createScheduleRunIntentStore({ storage, idFactory: () => ids.shift() });
  const first = await store.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  assert.equal(await store.complete("schedule-a", first.clientId), true);
  assert.equal(await store.complete("schedule-a", first.clientId), true);

  const second = await store.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  assert.equal(await store.complete("schedule-a", first.clientId), false);
  assert.equal(store.pending("schedule-a").clientId, second.clientId);
});

test("manual run scopes are isolated and capacity never evicts unresolved work", async () => {
  const storage = new MemoryStorage();
  const store = createScheduleRunIntentStore({
    storage, maxEntries: 1, idFactory: () => "run-one"
  });
  await store.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  assert.equal(await store.reserve("schedule-b", { scheduleId: "schedule-b" }, {
    replayProtected: true
  }), null);
  assert.equal(store.pending("schedule-a").clientId, "run-one");
  assert.equal(store.pending("schedule-b"), null);
  assert.equal(await store.reserve("schedule-a", { scheduleId: "schedule-b" }, {
    replayProtected: true
  }), null);
});

test("attempt leases expire to retry for protected work and review for unprotected work", async () => {
  const storage = new MemoryStorage();
  let now = 1000;
  const protectedStore = createScheduleRunIntentStore({
    storage, now: () => now, attemptTTL: 100, ttl: 1000,
    idFactory: () => "run-protected"
  });
  await protectedStore.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  now = 1101;
  assert.equal(protectedStore.pending("schedule-a").disposition, "replayable");
  assert.equal((await protectedStore.reserve(
    "schedule-a", { scheduleId: "schedule-a" }, { replayProtected: true }
  )).clientId, "run-protected");

  const oldStorage = new MemoryStorage();
  now = 2000;
  const unprotectedStore = createScheduleRunIntentStore({
    storage: oldStorage, now: () => now, attemptTTL: 100, ttl: 1000,
    idFactory: () => "run-unprotected"
  });
  await unprotectedStore.reserve("schedule-b", { scheduleId: "schedule-b" }, {
    replayProtected: false
  });
  now = 2101;
  assert.equal(unprotectedStore.pending("schedule-b").disposition, "review");
  assert.equal(await unprotectedStore.reserve(
    "schedule-b", { scheduleId: "schedule-b" }, { replayProtected: true }
  ), null);
});

test("capability downgrade becomes review-only and explicit review survives reload", async () => {
  const storage = new MemoryStorage();
  const first = createScheduleRunIntentStore({ storage, idFactory: () => "run-one" });
  await first.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  await first.markReplayable("schedule-a", "run-one", "response_lost");
  assert.equal(await first.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: false
  }), null);
  assert.equal(first.pending("schedule-a").disposition, "review");

  const reloaded = createScheduleRunIntentStore({
    storage, idFactory: () => "must-not-run"
  });
  assert.equal(reloaded.pending("schedule-a").disposition, "review");
  assert.equal(await reloaded.discard("schedule-a", "run-one"), true);
});

test("storage events restore recovery state in another mounted tab", async () => {
  const storage = new MemoryStorage();
  const events = new StorageEvents();
  const first = createScheduleRunIntentStore({
    storage, eventTarget: null, idFactory: () => "run-one"
  });
  const second = createScheduleRunIntentStore({
    storage, eventTarget: events, idFactory: () => "run-two"
  });
  let notifications = 0;
  second.subscribe(() => { notifications += 1; });
  await first.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  events.dispatch(
    "patchwork-schedule-run-intents-v1",
    storage.getItem("patchwork-schedule-run-intents-v1"),
    storage
  );
  assert.equal(notifications, 1);
  assert.equal(second.pending("schedule-a").clientId, "run-one");
});

test("a throwing storage read never mints or overwrites recovery work", async () => {
  const storage = new ThrowingReadStorage();
  const first = createScheduleRunIntentStore({
    storage, lockManager: new MemoryLockManager(), requireDurable: true,
    idFactory: () => "run-one"
  });
  await first.reserve("schedule-a", { scheduleId: "schedule-a" }, {
    replayProtected: true
  });
  const encoded = storage.getItem("patchwork-schedule-run-intents-v1");
  const writes = storage.writes;
  storage.throwOnRead = true;
  let minted = false;
  const failed = createScheduleRunIntentStore({
    storage, lockManager: new MemoryLockManager(), requireDurable: true,
    idFactory: () => { minted = true; return "run-two"; }
  });
  assert.equal(await failed.reserve("schedule-b", { scheduleId: "schedule-b" }, {
    replayProtected: true
  }), null);
  assert.equal(failed.isHealthy, false);
  assert.equal(minted, false);
  assert.equal(storage.writes, writes);
  assert.equal(storage.values.get("patchwork-schedule-run-intents-v1"), encoded);
});
