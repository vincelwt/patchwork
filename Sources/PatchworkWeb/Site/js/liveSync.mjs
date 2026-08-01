// Small, DOM-free pieces of live reconciliation. Keeping the request gate here makes the same
// stale-response rule usable by global lists and detail views, and keeps it directly testable.

export function createRequestGate() {
  let current = 0;
  return {
    begin() {
      current += 1;
      return current;
    },
    isCurrent(generation) {
      return generation === current;
    },
    invalidate() {
      current += 1;
    }
  };
}

/** Closes a same-tick admission window before an asynchronous durable reservation can finish. */
export function createAdmissionGate() {
  let active = false;
  return {
    enter() {
      if (active) return false;
      active = true;
      return true;
    },
    leave() { active = false; },
    get active() { return active; }
  };
}

/**
 * One protected mutation at a time, retaining its stable id through an ambiguous failure.
 * A successful admission clears the id so the next intentional action is distinct.
 */
export function createProtectedMutationIntent(idFactory) {
  let active = false;
  let retainedID = null;
  return {
    begin() {
      if (active) return null;
      active = true;
      retainedID ||= idFactory();
      return retainedID;
    },
    finish(succeeded) {
      active = false;
      if (succeeded) retainedID = null;
    },
    reset() {
      active = false;
      retainedID = null;
    },
    get active() { return active; },
    get retainedID() { return retainedID; }
  };
}

/** Bounded disclosure choices for only the transcript window retained by the page. */
export function createBoundedDisclosureState(limit = 2048) {
  const capacity = Math.max(1, Math.floor(Number(limit) || 1));
  const values = new Map();
  return {
    has(key) { return values.has(key); },
    get(key) {
      if (!values.has(key)) return undefined;
      const value = values.get(key);
      values.delete(key);
      values.set(key, value);
      return value;
    },
    set(key, value) {
      values.delete(key);
      values.set(key, value === true);
      while (values.size > capacity) values.delete(values.keys().next().value);
    },
    retain(keys) {
      const retained = keys instanceof Set ? keys : new Set(keys || []);
      for (const key of values.keys()) if (!retained.has(key)) values.delete(key);
    },
    clear() { values.clear(); },
    get size() { return values.size; }
  };
}

/**
 * Keeps per-thread mutation publication safe without retaining every thread ever observed.
 * Global tokens prevent an evicted and later reinserted key from reviving an old ticket.
 */
export function createBoundedThreadMutationGate(limit = 512) {
  const capacity = Math.max(1, Math.floor(Number(limit) || 1));
  const entries = new Map();
  let nextMutationToken = 0;
  let nextEventToken = 0;

  function touch(reference, entry) {
    entries.delete(reference);
    entries.set(reference, entry);
    while (entries.size > capacity) entries.delete(entries.keys().next().value);
  }

  return {
    begin(reference) {
      nextMutationToken += 1;
      const current = entries.get(reference);
      const entry = {
        mutationToken: nextMutationToken,
        eventToken: current?.eventToken || 0
      };
      touch(reference, entry);
      return { reference, ...entry };
    },
    recordEvent(references) {
      nextEventToken += 1;
      for (const reference of new Set(references || [])) {
        if (typeof reference !== "string" || !reference) continue;
        const current = entries.get(reference);
        touch(reference, {
          mutationToken: current?.mutationToken || 0,
          eventToken: nextEventToken
        });
      }
    },
    canPublish(ticket) {
      const current = ticket && entries.get(ticket.reference);
      return Boolean(current)
        && current.mutationToken === ticket.mutationToken
        && current.eventToken === ticket.eventToken;
    },
    clear() { entries.clear(); },
    get size() { return entries.size; }
  };
}

/** Classifies a failed protected mutation without confusing a refusal with an unknown result. */
export function protectedMutationDisposition(
  error,
  { replaySafe = false, reviewCodes = [] } = {}
) {
  const code = typeof error?.code === "string" ? error.code : "";
  if (reviewCodes.includes(code) || code.endsWith("_outcome_unknown")) return "review";
  if (code.endsWith("_in_flight")) return replaySafe ? "retry" : "review";
  const status = Number(error?.status);
  if (Number.isFinite(status) && status >= 400 && status < 500) return "reset";
  return replaySafe ? "retry" : "review";
}

/**
 * A request gate that also notices point events delivered while a full snapshot is in flight.
 * `eventChanged` means the caller should retry the full read after painting the point event;
 * `superseded` means a newer read already owns publication.
 */
export function createSnapshotGate() {
  let requestGeneration = 0;
  let eventRevision = 0;
  return {
    begin() {
      requestGeneration += 1;
      return { requestGeneration, eventRevision };
    },
    recordEvent() {
      eventRevision += 1;
    },
    disposition(ticket) {
      if (ticket?.requestGeneration !== requestGeneration) return "superseded";
      return ticket.eventRevision === eventRevision ? "current" : "eventChanged";
    },
    invalidate() {
      requestGeneration += 1;
    }
  };
}

/**
 * Runs at most one expensive snapshot request at a time. Any burst received while it runs is
 * represented by one trailing pass, so point events cannot create an unbounded request storm.
 */
export function createCoalescedTask(operation) {
  let active = null;
  let trailing = false;

  const run = () => {
    if (active) {
      trailing = true;
      return active;
    }
    active = Promise.resolve()
      .then(operation)
      .finally(() => {
        active = null;
        if (!trailing) return;
        trailing = false;
        return run();
      });
    return active;
  };

  return {
    run,
    markDirty() {
      if (active) {
        trailing = true;
        return active;
      }
      return run();
    },
    isActive() {
      return active !== null;
    }
  };
}

/** Applies the two schedule event shapes without retaining malformed or unbounded payloads. */
export function applyScheduleEvent(schedules, name, data) {
  const list = Array.isArray(schedules) ? schedules : [];
  const id = typeof data?.id === "string" ? data.id : "";
  if (!id) return list;

  if (name === "schedule_deleted") return list.filter((schedule) => schedule?.id !== id);
  if (name !== "schedule") return list;

  const index = list.findIndex((schedule) => schedule?.id === id);
  if (index === -1) return [data, ...list];
  return list.map((schedule, offset) => (offset === index ? { ...schedule, ...data } : schedule));
}

const ACTIVE_RUN_STATUSES = new Set(["queued", "running"]);
const TERMINAL_RUN_STATUSES = new Set(["ok", "failed", "skipped", "timeout", "interrupted"]);

export function isActiveRunStatus(status) {
  return ACTIVE_RUN_STATUSES.has(status);
}

/** Every run field that can alter pending-state recovery or the visible live indicator. */
export function runPresentationSignature(run) {
  if (!run?.id) return "";
  return JSON.stringify([
    run.id, run.status, run.startedAt, run.finishedAt, run.error,
    run.retryable, run.promptStartedAt, run.promptAcceptedAt,
    run.threadPath, run.threadId
  ]);
}

/** Applies a bounded run memo to a catalog in one pass, preserving copied-id ambiguity. */
export function applyRunEventsToThreads(threads, runs) {
  const list = Array.isArray(threads) ? threads : [];
  const pathRuns = new Map();
  const idRuns = new Map();
  for (const run of runs || []) {
    if (!run || (!ACTIVE_RUN_STATUSES.has(run.status) && !TERMINAL_RUN_STATUSES.has(run.status))) continue;
    if (typeof run.threadPath === "string" && run.threadPath) pathRuns.set(run.threadPath, run);
    else if (typeof run.threadId === "string" && run.threadId) idRuns.set(run.threadId, run);
  }
  if (!pathRuns.size && !idRuns.size) return list;

  const idCounts = new Map();
  for (const thread of list) {
    if (thread?.id) idCounts.set(thread.id, (idCounts.get(thread.id) || 0) + 1);
  }
  let changed = false;
  const updated = list.map((thread) => {
    const run = pathRuns.get(thread?.path)
      || (idCounts.get(thread?.id) === 1 ? idRuns.get(thread.id) : null);
    if (!run) return thread;
    const running = isActiveRunStatus(run.status);
    const updatedAt = run.finishedAt || run.startedAt || null;
    const eventTime = updatedAt ? new Date(updatedAt).getTime() : Number.NaN;
    const threadTime = thread.updatedAt ? new Date(thread.updatedAt).getTime() : Number.NaN;
    if (!running && thread.running === true && Number.isFinite(threadTime)
      && (!Number.isFinite(eventTime) || threadTime > eventTime)) {
      return thread;
    }
    const canAdvanceTime = updatedAt
      && (!Number.isFinite(threadTime) || !Number.isFinite(eventTime) || eventTime >= threadTime);
    const timestampChanged = canAdvanceTime && thread.updatedAt !== updatedAt;
    if (thread.running === running && !timestampChanged) return thread;
    changed = true;
    return { ...thread, running, ...(canAdvanceTime ? { updatedAt } : {}) };
  });
  return changed ? updated : list;
}

/** Updates only the physical transcript named by a run event, without rebuilding the catalog. */
export function applyRunEventToThreads(threads, run) {
  return applyRunEventsToThreads(threads, run ? [run] : []);
}

/** Applies one authoritative heartbeat snapshot without guessing between copied thread ids. */
export function applyActivityToThreads(threads, activity) {
  const list = Array.isArray(threads) ? threads : [];
  if (!Array.isArray(activity?.running)) return list;
  const runningPaths = new Set();
  const runningIDs = new Set();
  for (const entry of activity.running) {
    if (typeof entry?.threadPath === "string" && entry.threadPath) runningPaths.add(entry.threadPath);
    else if (typeof entry?.threadId === "string" && entry.threadId) runningIDs.add(entry.threadId);
  }
  const idCounts = new Map();
  for (const thread of list) {
    if (thread?.id) idCounts.set(thread.id, (idCounts.get(thread.id) || 0) + 1);
  }
  let changed = false;
  const updated = list.map((thread) => {
    const running = runningPaths.has(thread?.path)
      || (idCounts.get(thread?.id) === 1 && runningIDs.has(thread.id));
    if (thread?.running === running) return thread;
    changed = true;
    return { ...thread, running };
  });
  return changed ? updated : list;
}

function runEventTime(run) {
  const raw = run?.finishedAt || run?.startedAt;
  const value = raw ? new Date(raw).getTime() : Number.NaN;
  return Number.isFinite(value) ? value : null;
}

/**
 * Merges the polling heartbeat with point run events without relighting a run from a snapshot
 * that began before its terminal event. A genuinely newer heartbeat instance still wins.
 */
export function applyActivityAndRunEventsToThreads(threads, activity, runs) {
  const list = Array.isArray(runs) ? runs : [...(runs || [])];
  const terminal = list.filter((run) => run && TERMINAL_RUN_STATUSES.has(run.status));
  const active = list.filter((run) => run && ACTIVE_RUN_STATUSES.has(run.status));
  const terminalByPath = new Map();
  const terminalByID = new Map();
  for (const run of terminal) {
    if (typeof run.threadPath === "string" && run.threadPath) terminalByPath.set(run.threadPath, run);
    else if (typeof run.threadId === "string" && run.threadId) terminalByID.set(run.threadId, run);
  }

  let heartbeat = activity;
  if (Array.isArray(activity?.running) && (terminalByPath.size || terminalByID.size)) {
    const running = activity.running.filter((entry) => {
      const run = terminalByPath.get(entry?.threadPath) || terminalByID.get(entry?.threadId);
      if (!run) return true;
      const finishedAt = runEventTime(run);
      if (finishedAt === null) return false;
      const since = entry?.since ? new Date(entry.since).getTime() : Number.NaN;
      // Only a distinct running instance that began after this completion can supersede it.
      return Number.isFinite(since) && since > finishedAt;
    });
    heartbeat = { ...activity, running };
  }

  const afterTerminal = applyRunEventsToThreads(threads, terminal);
  const afterActivity = applyActivityToThreads(afterTerminal, heartbeat);
  return applyRunEventsToThreads(afterActivity, active);
}
