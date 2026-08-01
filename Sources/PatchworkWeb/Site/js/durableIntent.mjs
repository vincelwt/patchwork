// Durable, cross-tab recovery for protected browser mutations. Every unresolved record is kept
// until a confirmed response or an explicit review reset. Capacity is fail-closed, never LRU.

const DEFAULT_TTL_MS = 30 * 60 * 1000;
const DEFAULT_ATTEMPT_TTL_MS = 2 * 60 * 1000;

function utf8Bytes(value) {
  return new TextEncoder().encode(String(value ?? "")).byteLength;
}

function availableStorage() {
  if (typeof process !== "undefined" && process?.versions?.node) return null;
  try {
    if (globalThis.localStorage) {
      globalThis.localStorage.setItem("patchwork-storage-check", "1");
      globalThis.localStorage.removeItem("patchwork-storage-check");
      return globalThis.localStorage;
    }
  } catch {
    // Session storage cannot protect a retry after the tab closes.
  }
  return null;
}

function canonicalJSONValue(value) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (Array.isArray(value)) return value.map(canonicalJSONValue);
  if (value && typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).sort()) {
      if (value[key] !== undefined) result[key] = canonicalJSONValue(value[key]);
    }
    return result;
  }
  return null;
}

export function stableCanonicalJSON(value) {
  return JSON.stringify(canonicalJSONValue(value));
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

export function createDurableMutationIntentStore({
  storage = availableStorage(),
  storageKey,
  maxEntries = 32,
  maxBytes = 256 * 1024,
  maxBodyBytes = 64 * 1024,
  ttl = DEFAULT_TTL_MS,
  attemptTTL = DEFAULT_ATTEMPT_TTL_MS,
  now = () => Date.now(),
  requireDurable = typeof window !== "undefined",
  lockManager = typeof navigator !== "undefined" ? navigator.locks : null,
  eventTarget = typeof window !== "undefined" ? window : null,
  canonicalize = canonicalJSONValue,
  validateScope = (scope) => typeof scope === "string" && scope.length > 0,
  validateBody = () => true,
  validateReservation = () => true,
  idFactory,
  requestLabel = "request",
  reviewInstruction = "Review authoritative state before resetting this saved request.",
  migrateLegacy = null
} = {}) {
  if (!storageKey || typeof idFactory !== "function") {
    throw new TypeError("storageKey and idFactory are required");
  }
  const capacity = Math.max(1, Math.floor(Number(maxEntries) || 1));
  const attemptWindow = Math.max(1, Number(attemptTTL) || DEFAULT_ATTEMPT_TTL_MS);
  let records = new Map();
  let healthy = !requireDurable || (storage !== null && typeof lockManager?.request === "function");
  let failureReason = healthy
    ? null
    : storage === null
      ? "Durable browser storage is unavailable."
      : "This browser cannot safely coordinate requests across tabs.";
  const listeners = new Set();

  function notify() {
    for (const listener of listeners) listener();
  }

  async function withLock(operation) {
    if (typeof lockManager?.request === "function") {
      return lockManager.request(`${storageKey}-lock`, { mode: "exclusive" }, operation);
    }
    if (requireDurable) return null;
    return operation();
  }

  function validClientID(value) {
    return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value);
  }

  function normalizeBody(raw) {
    try {
      const body = canonicalize(raw);
      if (body === undefined || !validateBody(body)) return null;
      const signature = stableCanonicalJSON(body);
      if (utf8Bytes(signature) > maxBodyBytes) return null;
      return { body: JSON.parse(signature), signature };
    } catch {
      return null;
    }
  }

  function structurallyValid(record) {
    if (!record || record.version !== 1 || !validateScope(record.scope)) return false;
    if (!validClientID(record.clientId) || !Number.isFinite(record.createdAt)) return false;
    if (!["attempting", "replayable", "review"].includes(record.disposition)) return false;
    if (typeof record.replayProtected !== "boolean") return false;
    if (record.disposition === "attempting"
        && (!Number.isFinite(record.attemptedAt) || record.attemptedAt < record.createdAt)) {
      return false;
    }
    const normalized = normalizeBody(record.body);
    return !!normalized && normalized.signature === record.signature;
  }

  function failRead(message) {
    healthy = false;
    failureReason = message;
    return { ok: false, records };
  }

  function loadPersisted(rawOverride = undefined) {
    if (!storage) return { ok: !requireDurable, records };
    let raw;
    try {
      raw = rawOverride === undefined ? storage.getItem(storageKey) : rawOverride;
    } catch {
      return failRead(`The saved ${requestLabel} could not be read safely.`);
    }
    if (!raw) {
      records = new Map();
      return { ok: true, records };
    }
    if (utf8Bytes(raw) > maxBytes) {
      return failRead(`The saved ${requestLabel} state is too large to recover safely.`);
    }
    try {
      const decoded = JSON.parse(raw);
      let entries;
      if (decoded?.version === 1 && Array.isArray(decoded.entries)) {
        entries = decoded.entries;
      } else if (typeof migrateLegacy === "function") {
        entries = migrateLegacy(decoded);
      }
      if (!Array.isArray(entries) || entries.length > capacity) {
        return failRead(`The saved ${requestLabel} state could not be recovered safely.`);
      }
      const next = new Map();
      for (const record of entries) {
        if (!structurallyValid(record) || next.has(record.scope)) {
          return failRead(`The saved ${requestLabel} state could not be recovered safely.`);
        }
        next.set(record.scope, record);
      }
      records = next;
      return { ok: true, records };
    } catch {
      return failRead(`The saved ${requestLabel} state could not be recovered safely.`);
    }
  }

  function persist(next) {
    if (!healthy || (!storage && requireDurable)) return false;
    if (!storage) {
      records = next;
      notify();
      return true;
    }
    const envelope = {
      version: 1,
      entries: Array.from(next.values()).sort((a, b) => a.createdAt - b.createdAt)
    };
    const encoded = JSON.stringify(envelope);
    if (utf8Bytes(encoded) > maxBytes) {
      failureReason = `The saved ${requestLabel} state exceeds its safe local limit.`;
      return false;
    }
    try {
      storage.setItem(storageKey, encoded);
      if (storage.getItem(storageKey) !== encoded) {
        healthy = false;
        failureReason = `The saved ${requestLabel} state could not be verified.`;
        return false;
      }
      records = next;
      notify();
      return true;
    } catch {
      healthy = false;
      failureReason = `The saved ${requestLabel} state could not be written safely.`;
      return false;
    }
  }

  async function reserve(scope, rawBody, { replayProtected = false } = {}) {
    return withLock(() => reserveLocked(scope, rawBody, replayProtected === true));
  }

  function reserveLocked(scope, rawBody, replayProtected) {
    if (!healthy || !validateScope(scope)) return null;
    const loaded = loadPersisted();
    if (!loaded.ok || !healthy) return null;
    const normalized = normalizeBody(rawBody);
    if (!normalized) {
      failureReason = `This ${requestLabel} exceeds the safe local retry limit.`;
      return null;
    }
    if (!validateReservation(scope, normalized.body)) {
      failureReason = `This ${requestLabel} does not match its recovery scope.`;
      return null;
    }
    let existing = records.get(scope);
    const age = existing ? now() - existing.createdAt : 0;
    if (existing && age >= ttl) {
      const next = new Map(records);
      next.set(scope, {
        ...existing, replayProtected: false, disposition: "review",
        attemptedAt: null, reason: "retry_window_expired"
      });
      persist(next);
      failureReason = `The protected retry window expired. ${reviewInstruction}`;
      return null;
    }
    if (existing) {
      if (existing.signature !== normalized.signature) {
        failureReason = `Another ${requestLabel} is unresolved. ${reviewInstruction}`;
        return null;
      }
      if (existing.disposition === "attempting") {
        const attemptAge = now() - existing.attemptedAt;
        if (attemptAge < attemptWindow) {
          failureReason = `This ${requestLabel} is already being attempted in another tab.`;
          return null;
        }
        const canReplay = replayProtected && existing.replayProtected === true;
        const next = new Map(records);
        existing = {
          ...existing,
          replayProtected: canReplay,
          disposition: canReplay ? "replayable" : "review",
          attemptedAt: null,
          reason: "attempt_window_expired"
        };
        next.set(scope, existing);
        if (!persist(next)) return null;
        if (!canReplay) {
          failureReason = `The request attempt could not be confirmed. ${reviewInstruction}`;
          return null;
        }
      }
      if (!replayProtected || existing.replayProtected !== true
          || existing.disposition !== "replayable") {
        const next = new Map(records);
        next.set(scope, {
          ...existing, replayProtected: false, disposition: "review", attemptedAt: null,
          reason: existing.reason || "replay_not_confirmed"
        });
        persist(next);
        failureReason = reviewInstruction;
        return null;
      }
      const next = new Map(records);
      next.set(scope, {
        ...existing, disposition: "attempting", attemptedAt: now(), reason: "request_in_flight"
      });
      if (!persist(next)) return null;
      failureReason = null;
      return {
        scope, body: clone(existing.body), clientId: existing.clientId,
        replayProtected: true, isReplay: true
      };
    }
    if (records.size >= capacity) {
      failureReason = `Too many unresolved ${requestLabel} records need review.`;
      return null;
    }
    const record = {
      version: 1,
      scope,
      body: normalized.body,
      signature: normalized.signature,
      clientId: idFactory(),
      createdAt: now(),
      replayProtected,
      disposition: "attempting",
      attemptedAt: now(),
      reason: "request_in_flight"
    };
    if (!structurallyValid(record)) {
      failureReason = `This ${requestLabel} could not be assigned a safe retry id.`;
      return null;
    }
    const next = new Map(records);
    next.set(scope, record);
    if (!persist(next)) return null;
    failureReason = null;
    return {
      scope, body: clone(record.body), clientId: record.clientId,
      replayProtected, isReplay: false
    };
  }

  async function complete(scope, clientId) {
    return withLock(() => removeLocked(scope, clientId, false));
  }

  async function discard(scope, clientId) {
    return withLock(() => removeLocked(scope, clientId, true));
  }

  function removeLocked(scope, clientId, explicit) {
    const loaded = loadPersisted();
    if (!loaded.ok || !healthy) return false;
    const existing = records.get(scope);
    if (!existing) {
      failureReason = null;
      return true;
    }
    if (clientId && existing.clientId !== clientId) return false;
    if (explicit && existing.disposition !== "review") {
      failureReason = reviewInstruction;
      return false;
    }
    const next = new Map(records);
    next.delete(scope);
    const saved = persist(next);
    if (saved) failureReason = null;
    return saved;
  }

  async function markReview(scope, clientId, reason = "outcome_unknown") {
    return withLock(() => {
      const loaded = loadPersisted();
      if (!loaded.ok || !healthy) return false;
      const existing = records.get(scope);
      if (!existing) {
        failureReason = null;
        return true;
      }
      if (clientId && existing.clientId !== clientId) return false;
      const next = new Map(records);
      next.set(scope, {
        ...existing, replayProtected: false, disposition: "review", attemptedAt: null, reason
      });
      const saved = persist(next);
      if (saved) failureReason = reviewInstruction;
      return saved;
    });
  }

  async function markReplayable(scope, clientId, reason = "retryable_failure") {
    return withLock(() => {
      const loaded = loadPersisted();
      if (!loaded.ok || !healthy) return false;
      const existing = records.get(scope);
      if (!existing) {
        failureReason = null;
        return true;
      }
      if (clientId && existing.clientId !== clientId) return false;
      if (existing.replayProtected !== true) {
        failureReason = reviewInstruction;
        return false;
      }
      const next = new Map(records);
      next.set(scope, {
        ...existing, disposition: "replayable", attemptedAt: null, reason
      });
      const saved = persist(next);
      if (saved) failureReason = null;
      return saved;
    });
  }

  function presentation(record) {
    if (!record) return null;
    const expired = now() - record.createdAt >= ttl;
    const attemptExpired = record.disposition === "attempting"
      && now() - record.attemptedAt >= attemptWindow;
    const expiredAttemptDisposition = record.replayProtected ? "replayable" : "review";
    return {
      scope: record.scope,
      body: clone(record.body),
      clientId: record.clientId,
      createdAt: record.createdAt,
      expired,
      replayProtected: !expired && record.replayProtected === true,
      disposition: expired
        ? "review"
        : attemptExpired ? expiredAttemptDisposition : record.disposition,
      reason: expired
        ? "retry_window_expired"
        : attemptExpired ? "attempt_window_expired" : record.reason
    };
  }

  function pending(scope) {
    loadPersisted();
    const record = records.get(scope);
    return presentation(record);
  }

  function list() {
    loadPersisted();
    return Array.from(records.values()).map(presentation);
  }

  loadPersisted();
  if (typeof eventTarget?.addEventListener === "function") {
    eventTarget.addEventListener("storage", (event) => {
      if (event?.key !== storageKey || event.storageArea && event.storageArea !== storage) return;
      if (loadPersisted(event.newValue).ok) notify();
    });
  }

  return {
    reserve,
    pending,
    list,
    markReview,
    markReplayable,
    complete,
    discard,
    subscribe(listener) {
      if (typeof listener !== "function") return () => {};
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    get error() { return failureReason; },
    get isHealthy() { return healthy; },
    get size() { return records.size; }
  };
}
