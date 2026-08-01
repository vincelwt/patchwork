// Durable new-thread creation is a one-scope specialization of the shared mutation-intent store.

import {
  createDurableMutationIntentStore,
  stableCanonicalJSON
} from "./durableIntent.mjs";

const STORAGE_KEY = "patchwork-create-intent-v1";
const DEFAULT_TTL_MS = 30 * 60 * 1000;
const MAX_PERSISTED_BYTES = 2 * 1024 * 1024;
const MAX_MESSAGE_BYTES = 1024 * 1024;
const SCOPE = "create";

function utf8Bytes(value) {
  return new TextEncoder().encode(String(value ?? "")).byteLength;
}

export function canonicalCreationBody(body) {
  const result = { cwd: String(body?.cwd || "").trim() };
  for (const key of ["name", "message", "mode", "agent"]) {
    const value = String(body?.[key] || "").trim();
    if (value) result[key] = value;
  }
  if (body?.worktree === true) result.worktree = true;
  return result;
}

function bodyWithinBounds(body) {
  return !!body.cwd
    && utf8Bytes(body.cwd) <= 16 * 1024
    && utf8Bytes(body.name) <= 256
    && utf8Bytes(body.message) <= MAX_MESSAGE_BYTES
    && utf8Bytes(body.mode) <= 256
    && utf8Bytes(body.agent) <= 32;
}

function migrateLegacy(record) {
  if (!record || record.version !== 1 || typeof record.clientId !== "string"
      || !Number.isFinite(record.createdAt)) return null;
  const body = canonicalCreationBody(record.body);
  if (!bodyWithinBounds(body) || JSON.stringify(body) !== record.signature) return null;
  const replayProtected = record.replayProtected === true;
  return [{
    version: 1,
    scope: SCOPE,
    body,
    signature: stableCanonicalJSON(body),
    clientId: record.clientId,
    createdAt: record.createdAt,
    replayProtected,
    disposition: record.disposition === "replayable" && replayProtected
      ? "replayable"
      : "review",
    reason: replayProtected ? null : "legacy_unprotected"
  }];
}

export function createCreationIntentStore({
  storage,
  storageKey = STORAGE_KEY,
  now = () => Date.now(),
  ttl = DEFAULT_TTL_MS,
  requireDurable = typeof window !== "undefined",
  lockManager = typeof navigator !== "undefined" ? navigator.locks : null,
  eventTarget = typeof window !== "undefined" ? window : null,
  idFactory = () => {
    const random = globalThis.crypto?.randomUUID
      ? globalThis.crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    return `web-create-${random}`;
  }
} = {}) {
  const options = {
    storageKey,
    maxEntries: 1,
    maxBytes: MAX_PERSISTED_BYTES,
    maxBodyBytes: MAX_PERSISTED_BYTES - 1024,
    ttl,
    now,
    requireDurable,
    lockManager,
    eventTarget,
    canonicalize: canonicalCreationBody,
    validateScope: (scope) => scope === SCOPE,
    validateBody: bodyWithinBounds,
    idFactory,
    requestLabel: "creation request",
    reviewInstruction: "Review the thread list before resetting this saved request.",
    migrateLegacy
  };
  if (Object.prototype.hasOwnProperty.call(arguments[0] || {}, "storage")) {
    options.storage = storage;
  }
  const store = createDurableMutationIntentStore(options);

  return {
    async begin(body, { replayProtected = false } = {}) {
      const reserved = await store.reserve(SCOPE, body, { replayProtected });
      if (!reserved) return null;
      return {
        body: reserved.replayProtected
          ? { ...reserved.body, clientId: reserved.clientId }
          : reserved.body,
        clientId: reserved.clientId,
        replayProtected: reserved.replayProtected
      };
    },
    complete(clientId) { return store.complete(SCOPE, clientId); },
    pending() {
      const value = store.pending(SCOPE);
      if (!value) return null;
      return {
        body: value.body,
        clientId: value.clientId,
        expired: value.expired,
        disposition: value.disposition,
        replayProtected: value.replayProtected
      };
    },
    markReview(clientId) { return store.markReview(SCOPE, clientId); },
    markReplayable(clientId) { return store.markReplayable(SCOPE, clientId); },
    async abandon() {
      const value = store.pending(SCOPE);
      if (!value) return false;
      if (value.disposition !== "review") return false;
      return store.discard(SCOPE, value.clientId);
    },
    subscribe(listener) { return store.subscribe(listener); },
    get error() { return store.error; },
    get isHealthy() { return store.isHealthy; }
  };
}
