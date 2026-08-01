import test from "node:test";
import assert from "node:assert/strict";
import {
  createThreadViewStateStore,
  draftAfterSharedUpdate,
  draftAfterSubmit
} from "../../Sources/PatchworkWeb/Site/js/threadState.mjs";

class MemoryStorage {
  values = new Map();
  reads = 0;
  getItem(key) { this.reads += 1; return this.values.get(key) ?? null; }
  setItem(key, value) { this.values.set(key, String(value)); }
  removeItem(key) { this.values.delete(key); }
}

test("shared draft updates preserve local typing and clean composers adopt remote text", () => {
  assert.equal(draftAfterSharedUpdate("local edit", "old", "remote"), "local edit");
  assert.equal(draftAfterSharedUpdate("old", "old", "remote"), "remote");
});

test("send admission keeps text typed after the submitted snapshot", () => {
  assert.equal(draftAfterSubmit("first", "first"), "");
  assert.equal(draftAfterSubmit("first\nsecond", "first"), "second");
  assert.equal(draftAfterSubmit("first\nsecond", "first\n"), "second");
  assert.equal(draftAfterSubmit("first aid", "first"), "first aid");
  assert.equal(draftAfterSubmit("independent edit", "first"), "independent edit");
});

test("cached thread opens do not reread the durable envelope", () => {
  const storage = new MemoryStorage();
  storage.setItem("patchwork-thread-view-state-v1", JSON.stringify({
    version: 1,
    entries: [["thread", { draft: "cached" }]]
  }));
  const store = createThreadViewStateStore({ storage });
  const hydratedReads = storage.reads;
  for (let index = 0; index < 20; index += 1) assert.equal(store.load("thread").draft, "cached");
  assert.equal(storage.reads, hydratedReads);
});

class MemoryLockManager {
  tail = Promise.resolve();
  request(_name, _options, operation) {
    const result = this.tail.then(operation);
    this.tail = result.catch(() => {});
    return result;
  }
}

class MemoryEventTarget {
  listeners = new Map();
  addEventListener(name, listener) { this.listeners.set(name, listener); }
  emit(name, event) { this.listeners.get(name)?.(event); }
}

test("an out-of-order storage event cannot rewind a newer local commit", async () => {
  const storage = new MemoryStorage();
  const eventTarget = new MemoryEventTarget();
  const lockManager = new MemoryLockManager();
  const key = "patchwork-thread-view-state-v1";
  const envelope = (draft) => JSON.stringify({ version: 1, entries: [["thread", { draft }]] });
  const oldest = envelope("old");
  storage.setItem(key, oldest);
  const store = createThreadViewStateStore({
    storage, eventTarget, lockManager, requireDurable: true
  });
  await store.updateAtomic("thread", (state) => ({ ...state, draft: "newest" }));
  const newest = storage.getItem(key);

  eventTarget.emit("storage", {
    key,
    oldValue: oldest,
    newValue: envelope("stale"),
    storageArea: storage
  });

  assert.equal(storage.getItem(key), newest);
  assert.equal(store.load("thread").draft, "newest");
});

test("a pending send and draft survive leaving and reopening a thread", () => {
  const store = createThreadViewStateStore();
  const pending = [{ key: "p1", text: "keep me", status: "failed", clientId: "client-1" }];
  assert.equal(store.save("/thread.jsonl", { draft: "next", pending, pendingSeq: 1 }), true);

  const restored = store.load("/thread.jsonl");
  assert.equal(restored.draft, "next");
  assert.equal(restored.pending[0].text, pending[0].text);
  assert.equal(restored.pending[0].clientId, pending[0].clientId);
  assert.equal(restored.pendingSeq, 1);
});

test("the state store refuses capacity overflow instead of evicting a retry", () => {
  const store = createThreadViewStateStore({ maxEntries: 1, maxBytes: 4096 });
  assert.equal(store.save("one", {
    draft: "", pending: [{ key: "p1", text: "first", status: "queued" }], pendingSeq: 1
  }), true);
  assert.equal(store.save("two", {
    draft: "second", pending: [], pendingSeq: 0
  }), false);
  assert.equal(store.load("one").pending[0].text, "first");
});

test("retained text is byte-bounded", () => {
  const store = createThreadViewStateStore({ maxEntries: 4, maxBytes: 100 });
  assert.equal(store.save("one", { draft: "x".repeat(20), pending: [] }), true);
  assert.equal(store.save("two", { draft: "y".repeat(40), pending: [] }), false);
  assert.ok(store.byteCount <= 100);
});

test("pending state survives a complete page-store reconstruction", () => {
  const storage = new MemoryStorage();
  const first = createThreadViewStateStore({ storage, now: () => 1000 });
  assert.equal(first.save("thread", {
    draft: "next",
    pending: [{ key: "p1", text: "send once", at: 1000, status: "sending", clientId: "stable" }],
    pendingSeq: 1
  }), true);

  const reloaded = createThreadViewStateStore({ storage, now: () => 1500 });
  assert.equal(reloaded.load("thread").draft, "next");
  assert.equal(reloaded.load("thread").pending[0].clientId, "stable");
});

test("a late pending settlement cannot overwrite a newer draft or send", () => {
  const store = createThreadViewStateStore();
  store.save("thread", {
    draft: "old draft",
    pending: [{ key: "p1", text: "first", status: "sending", clientId: "one" }],
    pendingSeq: 1
  });
  const stale = store.load("thread");
  store.save("thread", {
    draft: "new draft",
    pending: [...stale.pending, { key: "p2", text: "second", status: "sending", clientId: "two" }],
    pendingSeq: 2
  });

  store.update("thread", (latest) => ({
    ...latest,
    pending: latest.pending.map((entry) => entry.key === "p1"
      ? { ...entry, accepted: true, status: "working", runId: "run-1" }
      : entry)
  }));

  const result = store.load("thread");
  assert.equal(result.draft, "new draft");
  assert.deepEqual(result.pending.map((entry) => entry.key), ["p1", "p2"]);
  assert.equal(result.pending[0].runId, "run-1");
});

test("expired same-id retry state becomes review-only without losing its text", () => {
  const storage = new MemoryStorage();
  const first = createThreadViewStateStore({ storage, now: () => 1000, replayTTL: 100 });
  first.save("thread", {
    pending: [{ key: "p1", text: "inspect me", at: 1000, status: "sending", clientId: "stable" }]
  });

  const reloaded = createThreadViewStateStore({ storage, now: () => 1200, replayTTL: 100 });
  const entry = reloaded.load("thread").pending[0];
  assert.equal(entry.text, "inspect me");
  assert.equal(entry.status, "failed");
  assert.equal(entry.retryMode, "review");
});

test("corrupt durable state is preserved and blocks new commits", () => {
  const storage = new MemoryStorage();
  storage.setItem("patchwork-thread-view-state-v1", JSON.stringify({
    version: 1,
    entries: [["thread", { draft: "one" }], ["thread", { draft: "duplicate" }]]
  }));
  const store = createThreadViewStateStore({ storage });
  assert.equal(store.entryCount, 0);
  assert.equal(store.isHealthy, false);
  assert.equal(storage.values.size, 1);
  assert.equal(store.save("new", { draft: "must not replace recovery data" }), false);
});

test("required durable storage blocks a send reservation", () => {
  const store = createThreadViewStateStore({ storage: null, requireDurable: true });
  assert.equal(store.save("thread", {
    pending: [{ key: "p1", text: "do not post", status: "sending", clientId: "stable" }]
  }), false);
  assert.equal(store.isHealthy, false);
});

test("nine pending records fail closed instead of silently dropping one", () => {
  const storage = new MemoryStorage();
  storage.setItem("patchwork-thread-view-state-v1", JSON.stringify({
    version: 1,
    entries: [["thread", {
      pending: Array.from({ length: 9 }, (_, index) => ({
        key: `p${index}`, text: `message ${index}`, clientId: `client-${index}`
      }))
    }]]
  }));
  const store = createThreadViewStateStore({ storage, requireDurable: true });
  assert.equal(store.isHealthy, false);
  assert.equal(storage.values.size, 1);
});

test("two tabs reserve different sends without overwriting either durable record", async () => {
  const storage = new MemoryStorage();
  const lockManager = new MemoryLockManager();
  const first = createThreadViewStateStore({ storage, lockManager, requireDurable: true });
  const second = createThreadViewStateStore({ storage, lockManager, requireDurable: true });

  const reserve = (store, key, clientId) => store.updateAtomic("thread", (state) => ({
    ...state,
    pendingSeq: state.pendingSeq + 1,
    pending: [...state.pending, { key, text: key, status: "sending", clientId }]
  }));
  const [one, two] = await Promise.all([
    reserve(first, "p1", "client-one"),
    reserve(second, "p2", "client-two")
  ]);
  assert.ok(one);
  assert.ok(two);

  const reloaded = createThreadViewStateStore({ storage, lockManager, requireDurable: true });
  assert.deepEqual(
    reloaded.load("thread").pending.map((entry) => entry.clientId),
    ["client-one", "client-two"]
  );
});

test("a completion and another tab draft write preserve every protected send", async () => {
  const storage = new MemoryStorage();
  const lockManager = new MemoryLockManager();
  const first = createThreadViewStateStore({ storage, lockManager, requireDurable: true });
  const second = createThreadViewStateStore({ storage, lockManager, requireDurable: true });
  await first.updateAtomic("thread", (state) => ({
    ...state,
    pending: [{ key: "p1", text: "first", status: "sending", clientId: "one" }]
  }));

  await Promise.all([
    first.updateAtomic("thread", (state) => ({
      ...state,
      pending: state.pending.map((entry) => ({ ...entry, status: "working", accepted: true }))
    })),
    second.updateAtomic("thread", (state) => ({
      ...state,
      draft: "second tab",
      pending: [...state.pending, { key: "p2", text: "second", status: "sending", clientId: "two" }]
    }))
  ]);

  const reloaded = createThreadViewStateStore({ storage, lockManager, requireDurable: true });
  assert.equal(reloaded.load("thread").draft, "second tab");
  assert.deepEqual(reloaded.load("thread").pending.map((entry) => entry.clientId), ["one", "two"]);
  assert.equal(first.update("thread", () => ({ draft: "unsafe" })), null);
});

test("a locked update fails closed when the authoritative storage read throws", async () => {
  class ThrowingStorage extends MemoryStorage {
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
  const storage = new ThrowingStorage();
  const lockManager = new MemoryLockManager();
  const first = createThreadViewStateStore({ storage, lockManager, requireDurable: true });
  await first.updateAtomic("thread", (state) => ({ ...state, draft: "protected" }));
  const encoded = storage.values.get("patchwork-thread-view-state-v1");
  const writesBeforeFailure = storage.writes;
  storage.throwOnRead = true;

  const second = createThreadViewStateStore({ storage, lockManager, requireDurable: true });
  assert.equal(await second.updateAtomic("thread", (state) => ({ ...state, draft: "lost" })), null);
  assert.equal(second.isHealthy, false);
  assert.equal(storage.writes, writesBeforeFailure);
  assert.equal(storage.values.get("patchwork-thread-view-state-v1"), encoded);
});
