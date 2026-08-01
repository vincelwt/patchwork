// Per-thread composer and optimistic-send state that survives navigation and page reloads.
// Entries are bounded by count and retained size. A pending send is never evicted to make room
// for another one because it may be the only durable copy of a submission id and its text.

const STORAGE_VERSION = 1;
const DEFAULT_STORAGE_KEY = "patchwork-thread-view-state-v1";
const DEFAULT_REPLAY_TTL_MS = 30 * 60 * 1000;

/** Only adopt a shared draft while the local composer still matches the last shared baseline. */
export function draftAfterSharedUpdate(localDraft, observedSharedDraft, nextSharedDraft) {
  return localDraft === observedSharedDraft ? nextSharedDraft : localDraft;
}

/** Removes the submitted composer snapshot while retaining text typed during send admission. */
export function draftAfterSubmit(currentDraft, submittedDraft) {
  if (currentDraft === submittedDraft || currentDraft === "") return "";
  const suffix = currentDraft.slice(submittedDraft.length);
  if (!currentDraft.startsWith(submittedDraft)) return currentDraft;
  if (submittedDraft.endsWith("\n")) return suffix;
  if (!/^\r?\n/.test(suffix)) return currentDraft;
  return suffix.replace(/^\r?\n/, "");
}

function availableBrowserStorage() {
  if (typeof process !== "undefined" && process?.versions?.node) return null;
  try {
    if (globalThis.localStorage) {
      globalThis.localStorage.setItem("patchwork-storage-check", "1");
      globalThis.localStorage.removeItem("patchwork-storage-check");
      return globalThis.localStorage;
    }
  } catch {
    // A safety-critical outbox must survive tab closure, so session storage is not enough.
  }
  return null;
}

export function createThreadViewStateStore({
  maxEntries = 64,
  maxBytes = 16 * 1024 * 1024,
  storage = availableBrowserStorage(),
  storageKey = DEFAULT_STORAGE_KEY,
  now = () => Date.now(),
  replayTTL = DEFAULT_REPLAY_TTL_MS,
  requireDurable = typeof window !== "undefined",
  lockManager = typeof navigator !== "undefined" ? navigator.locks : null,
  eventTarget = typeof window !== "undefined" ? window : null
} = {}) {
  const states = new Map();
  const sizes = new Map();
  const listeners = new Map();
  let retainedBytes = 0;
  let lastSerialized;
  let persistenceHealthy = !requireDurable
    || (storage !== null && typeof lockManager?.request === "function");

  async function withLock(operation) {
    if (typeof lockManager?.request === "function") {
      return lockManager.request(`${storageKey}-lock`, { mode: "exclusive" }, operation);
    }
    if (requireDurable) return null;
    return operation();
  }

  const empty = () => ({
    draft: "", pending: [], pendingSeq: 0, recentRuns: [], notice: null,
    revision: 0, updatedAt: now()
  });

  function boundedString(value, limit) {
    return String(value ?? "");
  }

  function isWithinBounds(value) {
    if (typeof value?.draft !== "undefined"
      && (typeof value.draft !== "string" || value.draft.length > 1024 * 1024)) return false;
    if (typeof value?.notice !== "undefined" && value.notice !== null
      && (typeof value.notice !== "string" || value.notice.length > 2000)) return false;
    if (value?.pending !== undefined && !Array.isArray(value.pending)) return false;
    if ((value?.pending?.length || 0) > 8) return false;
    for (const entry of value?.pending || []) {
      if (typeof entry?.key !== "string" || !entry.key || entry.key.length > 128) return false;
      if (typeof entry?.text !== "string" || !entry.text || entry.text.length > 1024 * 1024) return false;
      if (entry.clientId != null
        && (typeof entry.clientId !== "string" || entry.clientId.length > 128)) return false;
      if (entry.error != null && (typeof entry.error !== "string" || entry.error.length > 2000)) return false;
      if (entry.runId != null && (typeof entry.runId !== "string" || entry.runId.length > 256)) return false;
    }
    if (value?.recentRuns !== undefined && !Array.isArray(value.recentRuns)) return false;
    if ((value?.recentRuns?.length || 0) > 16) return false;
    return (value?.recentRuns || []).every((run) => {
      try { return JSON.stringify(run).length <= 8192; } catch { return false; }
    });
  }

  function normalizePending(entry) {
    const at = Number(entry?.at);
    const retryMode = ["sameSubmission", "newSubmission", "review"].includes(entry?.retryMode)
      ? entry.retryMode
      : "sameSubmission";
    const normalized = {
      key: boundedString(entry?.key, 128),
      text: boundedString(entry?.text, 1024 * 1024),
      at: Number.isFinite(at) ? at : now(),
      clientId: entry?.clientId == null ? null : boundedString(entry.clientId, 128),
      status: ["sending", "queued", "working", "failed"].includes(entry?.status)
        ? entry.status
        : "failed",
      requestedDelivery: ["auto", "steer", "followUp"].includes(entry?.requestedDelivery)
        ? entry.requestedDelivery
        : null,
      delivery: ["auto", "steer", "followUp"].includes(entry?.delivery) ? entry.delivery : null,
      runId: entry?.runId == null ? null : boundedString(entry.runId, 256),
      error: entry?.error == null ? null : boundedString(entry.error, 2000),
      settled: entry?.settled === true,
      retryMode,
      accepted: entry?.accepted === true,
      baseline: Math.max(0, Number(entry?.baseline) || 0)
    };
    if (
      now() - normalized.at >= replayTTL
      && !normalized.settled
      && normalized.retryMode === "sameSubmission"
    ) {
      normalized.status = "failed";
      normalized.retryMode = "review";
      normalized.error = "The protected retry window expired. Review the thread before sending again.";
    }
    return normalized;
  }

  function normalizeRun(pair) {
    if (!Array.isArray(pair) || pair.length !== 2) return null;
    try {
      const encoded = JSON.stringify(pair[1] ?? null);
      if (encoded.length > 8192) return null;
      return [boundedString(pair[0], 256), pair[1]];
    } catch {
      return null;
    }
  }

  function normalize(value) {
    const pending = Array.isArray(value?.pending)
      ? value.pending.slice(0, 8).map(normalizePending).filter((entry) => entry.key && entry.text)
      : [];
    const recentRuns = Array.isArray(value?.recentRuns)
      ? value.recentRuns.slice(-16).map(normalizeRun).filter(Boolean)
      : [];
    const updatedAt = Number(value?.updatedAt);
    return {
      draft: boundedString(value?.draft, 1024 * 1024),
      pending,
      pendingSeq: Math.max(0, Number(value?.pendingSeq) || 0),
      recentRuns,
      notice: value?.notice ? boundedString(value.notice, 2000) : null,
      revision: Math.max(0, Number(value?.revision) || 0),
      updatedAt: Number.isFinite(updatedAt) ? updatedAt : now()
    };
  }

  // UTF-16 code units are a conservative, constant-time proxy for retained JS string storage.
  function sizeOf(value) {
    let characters = value.draft.length;
    for (const entry of value.pending) {
      characters += entry.text.length + String(entry.error || "").length;
      characters += String(entry.clientId || "").length + String(entry.runId || "").length;
    }
    for (const run of value.recentRuns) characters += JSON.stringify(run || {}).length;
    characters += String(value.notice || "").length;
    return characters * 2 + value.pending.length * 256 + value.recentRuns.length * 128;
  }

  function clone(value) {
    return normalize(value);
  }

  function serialized(candidate) {
    return JSON.stringify({ version: STORAGE_VERSION, entries: [...candidate.entries()] });
  }

  function persist(candidate) {
    if (!persistenceHealthy || (!storage && requireDurable)) return false;
    if (!storage) return true;
    try {
      const value = serialized(candidate);
      if (value.length * 2 > maxBytes + 256 * 1024) return false;
      if (candidate.size) {
        storage.setItem(storageKey, value);
        lastSerialized = value;
      } else {
        storage.removeItem(storageKey);
        lastSerialized = null;
      }
      return true;
    } catch {
      persistenceHealthy = false;
      return false;
    }
  }

  function commit(id, raw, notify, refresh = true) {
    if (refresh && !refreshFromStorage()) return null;
    if (typeof id !== "string" || !id || !persistenceHealthy || !isWithinBounds(raw)) return null;
    const previous = states.get(id);
    const value = normalize({
      ...raw,
      revision: (previous?.revision || 0) + 1,
      updatedAt: now()
    });
    const isEmpty = !value.draft && value.pending.length === 0 && !value.notice;
    const oldSize = sizes.get(id) || 0;
    const newSize = isEmpty ? 0 : sizeOf(value);
    if (!previous && !isEmpty && states.size >= maxEntries) return null;
    if (retainedBytes - oldSize + newSize > maxBytes) return null;

    const candidate = new Map(states);
    if (isEmpty) candidate.delete(id);
    else {
      candidate.delete(id);
      candidate.set(id, value);
    }
    if (!persist(candidate)) return null;

    retainedBytes = retainedBytes - oldSize + newSize;
    states.clear();
    for (const [key, state] of candidate) states.set(key, state);
    if (isEmpty) sizes.delete(id);
    else sizes.set(id, newSize);
    const result = isEmpty ? empty() : clone(value);
    if (notify) {
      for (const listener of listeners.get(id) || []) listener(clone(result));
    }
    return result;
  }

  function discardCorruptStorage() {
    persistenceHealthy = false;
    states.clear();
    sizes.clear();
    retainedBytes = 0;
    // Preserve the raw bytes for recovery or inspection. New submissions remain blocked until the
    // state is repaired or explicitly cleared by a future recovery UI.
  }

  function hydrate(rewriteNormalized = true, suppliedRaw = undefined) {
    if (!storage) return true;
    let raw;
    try {
      raw = suppliedRaw === undefined ? storage.getItem(storageKey) : suppliedRaw;
    } catch {
      persistenceHealthy = false;
      return false;
    }
    lastSerialized = raw;
    if (!raw) return true;
    if (raw.length * 2 > maxBytes + 256 * 1024) {
      discardCorruptStorage();
      return false;
    }
    try {
      const envelope = JSON.parse(raw);
      if (envelope?.version !== STORAGE_VERSION || !Array.isArray(envelope.entries)) {
        discardCorruptStorage();
        return false;
      }
      if (envelope.entries.length > maxEntries) {
        discardCorruptStorage();
        return false;
      }
      for (const pair of envelope.entries) {
        if (!Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== "string" || !pair[0]) {
          discardCorruptStorage();
          return false;
        }
        if (states.has(pair[0])) {
          discardCorruptStorage();
          return false;
        }
        if (!isWithinBounds(pair[1])) {
          discardCorruptStorage();
          return false;
        }
        const value = normalize(pair[1]);
        const size = sizeOf(value);
        if (retainedBytes + size > maxBytes) {
          discardCorruptStorage();
          return false;
        }
        states.set(pair[0], value);
        sizes.set(pair[0], size);
        retainedBytes += size;
      }
      // Persist any replay-window downgrade made during normalization.
      if (rewriteNormalized && !persist(states)) {
        states.clear();
        sizes.clear();
        retainedBytes = 0;
        return false;
      }
      return true;
    } catch {
      discardCorruptStorage();
      return false;
    }
  }

  function refreshFromStorage(suppliedRaw = undefined) {
    if (!storage) return true;
    if (!persistenceHealthy) return false;
    let raw;
    try {
      raw = suppliedRaw === undefined ? storage.getItem(storageKey) : suppliedRaw;
    } catch {
      persistenceHealthy = false;
      return false;
    }
    if (raw === lastSerialized) return true;
    states.clear();
    sizes.clear();
    retainedBytes = 0;
    return hydrate(false, raw);
  }

  function load(id) {
    const value = states.get(id);
    if (!value) return empty();
    states.delete(id);
    states.set(id, value);
    return clone(value);
  }

  function saveUnlocked(id, raw, notify = false) {
    return commit(id, raw, notify) !== null;
  }

  // Updates always begin from the latest shared record and notify the currently mounted view.
  // A completion from a retired view can therefore settle its own pending key without replacing a
  // newer draft or another send added after navigation. Browser callers must use the atomic form:
  // localStorage has no compare-and-swap, so even a fresh read is unsafe without the shared lock.
  function updateUnlocked(id, updater) {
    if (typeof updater !== "function") return null;
    if (!refreshFromStorage()) return null;
    const current = load(id);
    const next = updater(current);
    if (next == null) return null;
    // `load` already refreshed while the shared lock is held. Parsing the full bounded envelope a
    // second time here adds synchronous main-thread work without increasing isolation.
    return commit(id, next, true, false);
  }

  function save(id, raw) {
    if (requireDurable) return false;
    return saveUnlocked(id, raw);
  }

  function update(id, updater) {
    if (requireDurable) return null;
    return updateUnlocked(id, updater);
  }

  async function saveAtomic(id, raw) {
    try {
      return await withLock(() => saveUnlocked(id, raw, true));
    } catch {
      persistenceHealthy = false;
      return false;
    }
  }

  async function updateAtomic(id, updater) {
    try {
      return await withLock(() => updateUnlocked(id, updater));
    } catch {
      persistenceHealthy = false;
      return null;
    }
  }

  function subscribe(id, listener) {
    if (typeof listener !== "function") return () => {};
    const set = listeners.get(id) || new Set();
    set.add(listener);
    listeners.set(id, set);
    return () => {
      set.delete(listener);
      if (!set.size) listeners.delete(id);
    };
  }

  // Initial hydration is read-only. Rewriting a normalized envelope here would happen before an
  // asynchronous Web Lock can be acquired and could erase another tab's just-committed send.
  hydrate(false);

  if (typeof eventTarget?.addEventListener === "function") {
    eventTarget.addEventListener("storage", (event) => {
      if (event?.key !== storageKey || !persistenceHealthy) return;
      if (event.storageArea && event.storageArea !== storage) return;
      // A queued event can arrive after this tab has committed a newer envelope. Its old value
      // must match our baseline before its new value is safe to hydrate directly.
      if (event.oldValue === lastSerialized) refreshFromStorage(event.newValue);
      else refreshFromStorage();
      for (const [id, callbacks] of listeners) {
        const value = states.get(id);
        const snapshot = value ? clone(value) : empty();
        for (const listener of callbacks) listener(clone(snapshot));
      }
    });
  }

  return {
    load,
    save,
    saveAtomic,
    update,
    updateAtomic,
    subscribe,
    get entryCount() { return states.size; },
    get byteCount() { return retainedBytes; },
    get isHealthy() { return persistenceHealthy; }
  };
}
