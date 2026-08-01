import test from "node:test";
import assert from "node:assert/strict";
import {
  canonicalCreationBody,
  createCreationIntentStore
} from "../../Sources/PatchworkWeb/Site/js/creationIntent.mjs";

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

test("canonical creation input is stable across missing optional fields", () => {
  assert.deepEqual(
    canonicalCreationBody({ cwd: " /tmp/project ", name: " ", message: " hi " }),
    { cwd: "/tmp/project", message: "hi" }
  );
});

test("a response-loss retry and page reload reuse one creation id", async () => {
  const storage = new MemoryStorage();
  const first = createCreationIntentStore({
    storage, now: () => 1000, idFactory: () => "create-one"
  });
  const request = { cwd: "/tmp/project", message: "hello", agent: "pi" };
  assert.equal((await first.begin(request, { replayProtected: true })).clientId, "create-one");
  assert.equal(first.pending().disposition, "attempting");
  await first.markReplayable("create-one");
  assert.equal((await first.begin({ ...request }, { replayProtected: true })).clientId, "create-one");
  await first.markReplayable("create-one");

  const reloaded = createCreationIntentStore({
    storage, now: () => 1100, idFactory: () => "create-two"
  });
  assert.equal((await reloaded.begin(request, { replayProtected: true })).clientId, "create-one");
  assert.equal(reloaded.pending().body.message, "hello");
});

test("different input cannot overwrite an unresolved creation", async () => {
  const storage = new MemoryStorage();
  const ids = ["create-one", "create-two"];
  const store = createCreationIntentStore({ storage, idFactory: () => ids.shift() });
  assert.equal((await store.begin({ cwd: "/one" }, { replayProtected: true })).clientId, "create-one");
  assert.equal(await store.begin({ cwd: "/two" }, { replayProtected: true }), null);
  assert.equal(store.pending().clientId, "create-one");
  await store.markReview("create-one");
  await store.abandon();
  const second = await store.begin({ cwd: "/two" }, { replayProtected: true });
  assert.equal(second.clientId, "create-two");
  await store.complete("create-one");
  assert.equal(store.pending().clientId, "create-two");
  await store.complete("create-two");
  assert.equal(store.pending(), null);
});

test("an expired intent becomes review-only and is not silently replaced", async () => {
  const storage = new MemoryStorage();
  const first = createCreationIntentStore({
    storage, now: () => 1000, ttl: 100, idFactory: () => "create-one"
  });
  await first.begin({ cwd: "/one" }, { replayProtected: true });
  const reloaded = createCreationIntentStore({
    storage, now: () => 1200, ttl: 100, idFactory: () => "create-two"
  });
  assert.equal(await reloaded.begin({ cwd: "/one" }, { replayProtected: true }), null);
  assert.equal(reloaded.pending().clientId, "create-one");
  assert.equal(reloaded.pending().expired, true);
  assert.match(reloaded.error, /Review/);
});

test("required durable storage blocks creation before a request id is minted", async () => {
  const store = createCreationIntentStore({
    storage: null, requireDurable: true, idFactory: () => "must-not-run"
  });
  assert.equal(await store.begin({ cwd: "/one" }, { replayProtected: true }), null);
  assert.equal(store.isHealthy, false);
});

test("corrupt storage is preserved and blocks creation", async () => {
  const storage = new MemoryStorage();
  storage.setItem("patchwork-create-intent-v1", "{broken");
  const store = createCreationIntentStore({ storage, requireDurable: true });
  assert.equal(await store.begin({ cwd: "/one" }, { replayProtected: true }), null);
  assert.equal(store.isHealthy, false);
  assert.equal(storage.getItem("patchwork-create-intent-v1"), "{broken");
});

test("an oversized first message is rejected before anything is persisted", async () => {
  const storage = new MemoryStorage();
  const store = createCreationIntentStore({ storage, idFactory: () => "create-one" });
  assert.equal(await store.begin(
    { cwd: "/one", message: "x".repeat(1024 * 1024 + 1) },
    { replayProtected: true }
  ), null);
  assert.match(store.error, /safe local retry limit/);
  assert.equal(storage.values.size, 0);
});

test("two tabs serialize creation claims and a stale completion cannot clear the winner", async () => {
  const storage = new MemoryStorage();
  const lockManager = new MemoryLockManager();
  const first = createCreationIntentStore({
    storage, lockManager, requireDurable: true, idFactory: () => "create-one"
  });
  const second = createCreationIntentStore({
    storage, lockManager, requireDurable: true, idFactory: () => "create-two"
  });

  const [one, two] = await Promise.all([
    first.begin({ cwd: "/one" }, { replayProtected: true }),
    second.begin({ cwd: "/two" }, { replayProtected: true })
  ]);
  assert.equal(one.clientId, "create-one");
  assert.equal(two, null);

  await first.complete("create-one");
  const replacement = await second.begin({ cwd: "/two" }, { replayProtected: true });
  assert.equal(replacement.clientId, "create-two");
  await first.complete("create-one");
  assert.equal(second.pending().clientId, "create-two");
});

test("an older daemon gets one unprotected attempt and reload restores review-only state", async () => {
  const storage = new MemoryStorage();
  const first = createCreationIntentStore({
    storage, idFactory: () => "create-old-daemon"
  });
  const attempt = await first.begin({ cwd: "/one", message: "hello" }, {
    replayProtected: false
  });
  assert.deepEqual(attempt.body, { cwd: "/one", message: "hello" });
  assert.equal(attempt.clientId, "create-old-daemon");
  assert.equal(first.pending().disposition, "attempting");

  const reloaded = createCreationIntentStore({
    storage, idFactory: () => "must-not-run"
  });
  assert.equal(await reloaded.begin(
    { cwd: "/one", message: "hello" }, { replayProtected: true }
  ), null);
  assert.equal(reloaded.pending().disposition, "attempting");
  await first.markReview("create-old-daemon");
  assert.equal(reloaded.pending().disposition, "review");
});

test("capability loss and an explicit review marker survive reload until reset", async () => {
  const storage = new MemoryStorage();
  const first = createCreationIntentStore({ storage, idFactory: () => "create-one" });
  await first.begin({ cwd: "/one" }, { replayProtected: true });
  await first.markReplayable("create-one");
  assert.equal(await first.begin({ cwd: "/one" }, { replayProtected: false }), null);
  assert.equal(first.pending().disposition, "review");
  assert.equal(await first.markReview("create-one"), true);

  const reloaded = createCreationIntentStore({ storage, idFactory: () => "create-two" });
  assert.equal(reloaded.pending().disposition, "review");
  assert.equal(await reloaded.begin({ cwd: "/one" }, { replayProtected: true }), null);
  assert.equal(await reloaded.abandon(), true);
  assert.equal((await reloaded.begin(
    { cwd: "/one" }, { replayProtected: true }
  )).clientId, "create-two");
});

test("a legacy record without a capability fails closed to review", async () => {
  const storage = new MemoryStorage();
  const body = { cwd: "/legacy" };
  storage.setItem("patchwork-create-intent-v1", JSON.stringify({
    version: 1,
    body,
    signature: JSON.stringify(body),
    clientId: "legacy-create",
    createdAt: 1000
  }));
  const store = createCreationIntentStore({ storage, now: () => 1100 });
  assert.equal(store.pending().disposition, "review");
  assert.equal(await store.begin(body, { replayProtected: true }), null);
});

test("a storage read failure blocks a fresh id and preserves the unresolved record", async () => {
  const storage = new ThrowingReadStorage();
  const first = createCreationIntentStore({
    storage, requireDurable: true, lockManager: new MemoryLockManager(),
    idFactory: () => "create-one"
  });
  await first.begin({ cwd: "/one" }, { replayProtected: true });
  const encoded = storage.values.get("patchwork-create-intent-v1");
  const writesBeforeFailure = storage.writes;
  storage.throwOnRead = true;

  let minted = false;
  const reloaded = createCreationIntentStore({
    storage, requireDurable: true, lockManager: new MemoryLockManager(),
    idFactory: () => { minted = true; return "create-two"; }
  });
  assert.equal(await reloaded.begin({ cwd: "/two" }, { replayProtected: true }), null);
  assert.equal(reloaded.isHealthy, false);
  assert.equal(minted, false);
  assert.equal(storage.writes, writesBeforeFailure);
  assert.equal(storage.values.get("patchwork-create-intent-v1"), encoded);
});
