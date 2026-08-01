// Bootstraps the app: owns the one piece of global state, the router, the SSE connection, and
// every action a view can call. Views never call `api.js` or touch global state directly for
// anything that other screens need to stay in sync with (thread/schedule lists) — they go
// through `actions`. Views MAY call `api.js` directly for data that is local to just that screen
// (thread detail messages, schedule detail runs), which keeps this file from having to know
// about every screen's private loading state.

import { h, mount } from "./dom.js";
import { api, ApiError, getToken, setToken, clearToken, hasToken, describeError } from "./api.js";
import { connectEvents } from "./sse.js";
import {
  forgetRelayDevice,
  hasRelayDevice,
  isRelayMode,
  relayPairingState,
  shouldReloadPairingLink,
  startRelay
} from "./relay.js";
import { renderTokenScreen } from "./views/token.js";
import { renderPairingScreen } from "./views/pairing.js";
import { renderThreadList } from "./views/threadList.js";
import { renderThreadView } from "./views/threadView.js";
import { renderNewThread } from "./views/newThread.js";
import { renderSchedules, renderScheduleDetail } from "./views/schedules.js";
import { renderScheduleForm } from "./views/scheduleForm.js";
import { applyThreadUpdate, findThreadByReference, threadIdentity } from "./folders.mjs";
import { createThreadViewStateStore } from "./threadState.mjs";
import {
  applyActivityAndRunEventsToThreads,
  applyRunEventToThreads,
  applyScheduleEvent,
  createBoundedThreadMutationGate,
  createCoalescedTask,
  createRequestGate,
  createSnapshotGate
} from "./liveSync.mjs";

const hosted = isRelayMode();
const threadViewStates = createThreadViewStateStore();
const openingPairingLink = hosted && location.pathname.startsWith("/pair/");
const state = {
  authed: hosted ? hasRelayDevice() && !openingPairingLink : hasToken(),
  relayPairing: relayPairingState(),
  connection: "connecting", // "connecting" | "online" | "offline"
  threads: [],
  threadsLoading: false,
  threadsLoadingMore: false,
  threadsNextCursor: null,
  threadsError: null,
  // Which list the Threads tab is showing. Archiving is only useful if the archived thread
  // actually leaves the list and stays reachable somewhere, so the list has two explicit modes
  // rather than one mixed one. Session-scoped: a view preference, not something to persist.
  showArchived: false,
  schedules: [],
  schedulesLoading: false,
  schedulesError: null,
  activity: null,
  // `GET /v1/folders`: the Mac app's own virtual folders, read-only. `null` until loaded (or on
  // an older daemon that has no such endpoint), which the thread list renders as plain project
  // grouping rather than an error.
  folders: null,
  // Collapsed group ids for the thread tree. Session-scoped on purpose: it is a view preference,
  // not something worth persisting to a device or syncing back to the Mac.
  collapsedGroups: new Set(),
  // Most recent SSE payload of each kind, so a view whose data isn't part of global state (e.g.
  // an open thread's message list) can tell whether it needs to refetch. See threadView.js.
  lastThreadEvent: null,
  lastScheduleEvent: null,
  lastRunEvent: null,
  lastActivityEvent: null,
  lastInteractionEvent: null,
  // Incremented for every authoritative reconnect pass. Detail views use this to re-read their
  // transcript, runtime, runs, and dialogs even if all point events were missed while offline.
  authoritativeGeneration: 0
};

let currentView = null;
let events = null;

const root = document.getElementById("app");
const bannerEl = h("div", { id: "banner" });
const mainEl = h("main");
const tabbarEl = h(
  "nav",
  { class: "tabbar", "aria-label": "Primary" },
  h("button", { type: "button", onclick: () => actions.navigate("/") }, h("span", { class: "tab-icon", "aria-hidden": "true" }, "\u25a4"), "Threads"),
  h("button", { type: "button", onclick: () => actions.navigate("/schedules") }, h("span", { class: "tab-icon", "aria-hidden": "true" }, "\u23f0"), "Schedules")
);
mount(root, [bannerEl, mainEl, tabbarEl]);

// A phone hides the tab bar on detail screens to give the composer the full height; a desktop
// window is wide enough to keep the rail permanently, and hiding it there would shift the whole
// layout sideways on every navigation.
const wideLayout = window.matchMedia("(min-width: 800px)");
wideLayout.addEventListener("change", () => paintChrome());

// The on-screen keyboard: iOS leaves the layout viewport at full height and slides the keyboard
// over it, so `100dvh` alone would put the composer underneath. visualViewport reports the real
// overlap; the shell subtracts it through `--kb` (see css/app.css). Android with
// `interactive-widget=resizes-content` shrinks the layout viewport itself, which makes the
// overlap zero and leaves the same code correct.
const viewport = window.visualViewport;
if (viewport) {
  const syncKeyboardInset = () => {
    const overlap = Math.max(0, Math.round(window.innerHeight - viewport.height - viewport.offsetTop));
    document.documentElement.style.setProperty("--kb", `${overlap}px`);
    root.dataset.keyboard = overlap > 80 ? "open" : "closed";
  };
  viewport.addEventListener("resize", syncKeyboardInset);
  viewport.addEventListener("scroll", syncKeyboardInset);
  syncKeyboardInset();
}

// ---------- state plumbing ----------

function setState(patch) {
  Object.assign(state, typeof patch === "function" ? patch(state) : patch);
  currentView?.onStateChange?.(state);
  paintChrome();
}

function paintChrome() {
  mount(
    bannerEl,
    state.connection === "offline"
      ? h(
          "div",
          { class: "banner banner-offline", role: "status" },
          h("span", { class: "spinner", "aria-hidden": "true" }),
          "Offline \u2014 reconnecting\u2026"
        )
      : []
  );
  const onList = location.pathname === "/" || location.pathname === "/schedules";
  tabbarEl.hidden = !state.authed || (!onList && !wideLayout.matches);
  const buttons = tabbarEl.querySelectorAll("button");
  buttons[0]?.setAttribute("aria-current", String(location.pathname === "/"));
  buttons[1]?.setAttribute("aria-current", String(location.pathname === "/schedules"));
}

function upsertBy(list, item, key) {
  const idx = list.findIndex((entry) => entry[key] === item[key]);
  const next = idx === -1 ? [item, ...list] : list.map((entry, i) => (i === idx ? { ...entry, ...item } : entry));
  return next;
}

function sortByUpdatedAt(list) {
  return [...list].sort((a, b) => new Date(b.updatedAt || 0) - new Date(a.updatedAt || 0));
}

const terminalRunStatuses = new Set(["ok", "failed", "skipped", "timeout", "interrupted"]);
const pollDelay = () => new Promise((resolve) => setTimeout(resolve, 750));

// Older daemons return `pending:<run>` for a message-bearing create. That value is deliberately
// not a thread id; resolve it through the documented run endpoint before routing to a detail.
async function waitForCreatedThread(runId) {
  while (true) {
    let run;
    try {
      ({ run } = await api.run(runId));
      if (run?.threadPath || run?.threadId) {
        return (await api.thread(run.threadPath || run.threadId, 0)).thread;
      }
      if (terminalRunStatuses.has(run?.status)) {
        throw new ApiError(409, "create_failed", run.error || "Pi could not create this thread.");
      }
    } catch (err) {
      if (err instanceof ApiError && (err.status === 401 || err.code === "create_failed")) throw err;
      // A dropped phone connection after creation must not invite a second first prompt. Keep
      // resolving the accepted run; the global banner already explains that the Mac is offline.
    }
    await pollDelay();
  }
}

// ---------- data loading ----------

const threadsGate = createSnapshotGate();
const foldersGate = createRequestGate();
const schedulesGate = createSnapshotGate();
const activityGate = createSnapshotGate();
let authoritativeGeneration = 0;
const recentRunByThread = new Map();
const threadMutationGate = createBoundedThreadMutationGate(512);

function beginThreadMutation(reference) {
  return threadMutationGate.begin(reference);
}

function recordThreadEvent(thread) {
  threadMutationGate.recordEvent([thread?.path, thread?.id]);
}

function canPublishThreadMutation(ticket) {
  return threadMutationGate.canPublish(ticket);
}

function rememberRunState(run) {
  const key = run?.threadPath || run?.threadId;
  if (!key) return;
  recentRunByThread.delete(key);
  recentRunByThread.set(key, run);
  while (recentRunByThread.size > 256) recentRunByThread.delete(recentRunByThread.keys().next().value);
}

function applyActivityAndRecentRunStates(threads, activity = state.activity) {
  const runs = [...recentRunByThread.values()];
  return applyActivityAndRunEventsToThreads(threads, activity, runs);
}

function uniqueThreads(threads) {
  const unique = [];
  const seen = new Set();
  for (const thread of threads) {
    const identity = threadIdentity(thread);
    if (!identity || seen.has(identity)) continue;
    seen.add(identity);
    unique.push(thread);
  }
  return unique;
}

async function loadThreadsOnce() {
  const archived = state.showArchived;
  const request = threadsGate.begin();
  setState({ threadsLoading: true, threadsLoadingMore: false, threadsError: null });
  try {
    const page = await api.threads({ limit: 200, archived, sidebar: true });
    const disposition = threadsGate.disposition(request);
    if (disposition === "superseded" || archived !== state.showArchived) return;
    if (disposition === "eventChanged") {
      threadsLoader.markDirty();
      return;
    }
    const unique = applyActivityAndRecentRunStates(uniqueThreads(
      Array.isArray(page?.threads) ? page.threads : []
    ));
    setState({
      threads: sortByUpdatedAt(unique),
      threadsLoading: false,
      threadsLoadingMore: false,
      threadsNextCursor: page?.nextCursor || null
    });
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) return;
    const disposition = threadsGate.disposition(request);
    if (disposition === "superseded" || archived !== state.showArchived) return;
    if (disposition === "eventChanged") {
      threadsLoader.markDirty();
      return;
    }
    setState({ threadsLoading: false, threadsError: describeError(err) });
  }
}

const threadsLoader = createCoalescedTask(loadThreadsOnce);
function loadThreads() {
  return threadsLoader.run();
}

let loadMoreThreadsPromise = null;
function loadMoreThreads() {
  if (loadMoreThreadsPromise) return loadMoreThreadsPromise;
  const archived = state.showArchived;
  const cursor = state.threadsNextCursor;
  if (!cursor || state.threadsLoading) return Promise.resolve();
  const request = threadsGate.begin();
  setState({ threadsLoadingMore: true, threadsError: null });
  loadMoreThreadsPromise = api
    .threads({ limit: 200, cursor, archived, sidebar: true })
    .then((page) => {
      const disposition = threadsGate.disposition(request);
      if (disposition === "superseded" || archived !== state.showArchived) return;
      if (disposition === "eventChanged") {
        setState({ threadsLoadingMore: false });
        threadsLoader.markDirty();
        return;
      }
      if (state.threadsNextCursor !== cursor) return;
      const appended = uniqueThreads([
        ...state.threads,
        ...(Array.isArray(page?.threads) ? page.threads : [])
      ]);
      setState({
        threads: sortByUpdatedAt(applyActivityAndRecentRunStates(appended)),
        threadsLoadingMore: false,
        threadsNextCursor: page?.nextCursor || null
      });
    })
    .catch((err) => {
      if (err instanceof ApiError && err.status === 401) return;
      const disposition = threadsGate.disposition(request);
      if (disposition === "superseded" || archived !== state.showArchived) return;
      if (err?.code === "cursor_expired" || disposition === "eventChanged") {
        setState({ threadsLoadingMore: false, threadsNextCursor: null });
        threadsLoader.markDirty();
        return;
      }
      setState({ threadsLoadingMore: false, threadsError: describeError(err) });
    })
    .finally(() => {
      loadMoreThreadsPromise = null;
    });
  return loadMoreThreadsPromise;
}

// Folders change only when someone edits them in the Mac app, so this is loaded with the thread
// list rather than polled. A daemon without the endpoint leaves `folders` null: the list falls
// back to project grouping instead of showing an error for a purely organisational feature.
function loadFolders() {
  const request = foldersGate.begin();
  return api
    .folders()
    .then((folders) => {
      if (foldersGate.isCurrent(request)) setState({ folders });
    })
    .catch(() => {
      if (foldersGate.isCurrent(request)) setState({ folders: null });
    });
}

function loadSchedulesOnce() {
  const request = schedulesGate.begin();
  setState({ schedulesLoading: true, schedulesError: null });
  return api
    .schedules()
    .then(({ schedules }) => {
      const disposition = schedulesGate.disposition(request);
      if (disposition === "superseded") return;
      if (disposition === "eventChanged") {
        schedulesLoader.markDirty();
        return;
      }
      setState({ schedules, schedulesLoading: false });
    })
    .catch((err) => {
      if (err instanceof ApiError && err.status === 401) return;
      const disposition = schedulesGate.disposition(request);
      if (disposition === "superseded") return;
      if (disposition === "eventChanged") {
        schedulesLoader.markDirty();
        return;
      }
      setState({ schedulesLoading: false, schedulesError: describeError(err) });
    });
}

const schedulesLoader = createCoalescedTask(loadSchedulesOnce);
function loadSchedules() {
  return schedulesLoader.run();
}

function loadActivity() {
  const request = activityGate.begin();
  return api
    .activity()
    .then((activity) => {
      if (activityGate.disposition(request) === "current") {
        threadsGate.recordEvent();
        setState((s) => ({
          activity,
          threads: applyActivityAndRecentRunStates(s.threads, activity),
          lastActivityEvent: activity
        }));
      }
    })
    .catch(() => {});
}

function reloadAuthoritativeState() {
  authoritativeGeneration += 1;
  setState({ authoritativeGeneration });
  return Promise.allSettled([loadThreads(), loadFolders(), loadSchedules(), loadActivity()]);
}

function invalidateLoads() {
  threadsGate.invalidate();
  foldersGate.invalidate();
  schedulesGate.invalidate();
  activityGate.invalidate();
}

// ---------- live updates ----------

function handleEvent(name, data) {
  if (name === "ready") {
    // `ready` is a barrier for this new stream, not proof that the preceding connection delivered
    // every mutation. Replace every cached projection from its authoritative endpoint.
    recentRunByThread.clear();
    reloadAuthoritativeState();
    return;
  }
  if (!data || typeof data !== "object") return;
  if (name === "thread") {
    threadsGate.recordEvent();
    activityGate.recordEvent();
    recordThreadEvent(data);
    // The event carries the thread's current `archived` flag, so a thread that no longer belongs
    // in the visible list leaves it instead of being merged back in.
    setState((s) => {
      const updated = applyThreadUpdate(s.threads, data, s.showArchived);
      return {
        threads: updated === s.threads ? s.threads : sortByUpdatedAt(updated),
        lastThreadEvent: data
      };
    });
  } else if (name === "schedule" || name === "schedule_deleted") {
    schedulesGate.recordEvent();
    setState((s) => ({
      schedules: applyScheduleEvent(s.schedules, name, data),
      lastScheduleEvent: name === "schedule_deleted" ? { ...data, deleted: true } : data
    }));
  } else if (name === "run") {
    threadsGate.recordEvent();
    activityGate.recordEvent();
    rememberRunState(data);
    setState((s) => {
      const updated = applyRunEventToThreads(s.threads, data);
      return {
        // The point event is newer than the cached activity response. Discard that projection so
        // a later catalog read cannot resurrect its old running bit before the next heartbeat.
        activity: null,
        threads: updated === s.threads ? s.threads : sortByUpdatedAt(updated),
        lastRunEvent: data
      };
    });
  } else if (name === "activity") {
    activityGate.recordEvent();
    threadsGate.recordEvent();
    setState((s) => ({
      activity: data,
      threads: applyActivityAndRecentRunStates(s.threads, data),
      lastActivityEvent: data
    }));
  } else if (name === "interaction") {
    // Only a hint. The thread view re-reads GET /v1/interactions rather than accumulating
    // frames, so a missed or out-of-order event cannot leave a stale dialog on screen.
    setState({ lastInteractionEvent: data });
  }
  // Any other event name is forward-compatible-ignored per docs/daemon-api.md.
}

function startEvents() {
  events?.close();
  events = connectEvents({
    onEvent: handleEvent,
    onStatus: (status) => {
      const wasOnline = state.connection === "online";
      setState({ connection: status });
      // The hosted relay has its own connection-ready control frame rather than the local SSE
      // barrier. Its offline-to-online edge is the equivalent authoritative refresh boundary.
      if (hosted && status === "online" && !wasOnline) reloadAuthoritativeState();
    }
  });
}

function stopEvents() {
  events?.close();
  events = null;
  invalidateLoads();
}

// ---------- actions passed to every view ----------

const actions = {
  navigate: (path, opts) => go(path, opts),

  connect(token) {
    setToken(token);
    return api.health().then(
      () => {
        setState({ authed: true });
        loadThreads();
        loadFolders();
        loadSchedules();
        loadActivity();
        startEvents();
        go("/", { replace: true });
      },
      (err) => {
        clearToken();
        throw err;
      }
    );
  },

  async signOut() {
    stopEvents();
    threadMutationGate.clear();
    if (hosted) await forgetRelayDevice();
    else clearToken();
    Object.assign(state, {
      authed: false,
      relayPairing: relayPairingState(),
      threads: [],
      threadsNextCursor: null,
      threadsLoadingMore: false,
      schedules: [],
      connection: "connecting"
    });
    go("/", { replace: true });
  },

  refreshThreads: () => Promise.all([loadThreads(), loadFolders()]),
  loadMoreThreads: () => loadMoreThreads(),
  refreshSchedules: () => loadSchedules(),

  showArchivedThreads(showArchived) {
    if (state.showArchived === showArchived) return;
    // Clear first: the previous list belongs to the other mode entirely, and leaving it up while
    // the new one loads would show archived threads under "Active".
    setState({
      showArchived,
      threads: [],
      threadsNextCursor: null,
      threadsLoadingMore: false
    });
    loadThreads();
  },

  worktrees: (cwd) => api.worktrees(cwd),

  toggleGroup(id) {
    const collapsed = new Set(state.collapsedGroups);
    if (collapsed.has(id)) collapsed.delete(id);
    else collapsed.add(id);
    setState({ collapsedGroups: collapsed });
  },

  async createThread(body) {
    const response = await api.createThread(body);
    const thread = response.thread?.id?.startsWith("pending:") && response.runId
      ? await waitForCreatedThread(response.runId)
      : response.thread;
    setState((s) => ({ threads: sortByUpdatedAt(applyThreadUpdate(s.threads, thread, s.showArchived)) }));
    if (response.firstMessageError && body.message) {
      const saved = await threadViewStates.updateAtomic(threadIdentity(thread), (shared) => ({
        ...shared,
        draft: shared.draft || body.message,
        notice: `The thread was created, but its first message was not sent. ${response.firstMessageError}`
      }));
      if (!saved) {
        // Creation succeeded. Keep the original form visible and let the new-thread view offer an
        // explicit route to the real thread; replaying the create id cannot send this message.
        return {
          ...thread,
          firstMessageRecoveryError:
            `Thread ${thread.name || thread.id} was created, but its first message was not sent. The message remains in this form.`
        };
      }
    }
    if (location.pathname === "/new") go(`/thread/${encodeURIComponent(threadIdentity(thread))}`, { replace: true });
    return thread;
  },

  sendMessage(id, body) {
    return api.sendMessage(id, body);
  },
  abortThread: (id) => api.abortThread(id),
  respondInteraction: (id, body) => api.respondInteraction(id, body),
  loadThreadViewState: (id) => threadViewStates.load(id),
  updateThreadViewStateAtomic: (id, updater) => threadViewStates.updateAtomic(id, updater),
  subscribeThreadViewState: (id, listener) => threadViewStates.subscribe(id, listener),

  archiveThread(id, archived) {
    const ticket = beginThreadMutation(id);
    return api.archiveThread(id, archived).then(({ thread }) => {
      if (canPublishThreadMutation(ticket)) {
        setState((s) => ({ threads: applyThreadUpdate(s.threads, thread, s.showArchived) }));
      }
      return findThreadByReference(state.threads, id) || thread;
    });
  },

  renameThread(id, name) {
    const ticket = beginThreadMutation(id);
    return api.renameThread(id, name).then(({ thread }) => {
      if (canPublishThreadMutation(ticket)) {
        setState((s) => ({ threads: applyThreadUpdate(s.threads, thread, s.showArchived) }));
      }
      return findThreadByReference(state.threads, id) || thread;
    });
  },

  markRead(id) {
    const ticket = beginThreadMutation(id);
    return api
      .markThreadRead(id, false)
      .then(({ thread }) => {
        if (canPublishThreadMutation(ticket)) {
          setState((s) => ({ threads: applyThreadUpdate(s.threads, thread, s.showArchived) }));
        }
      })
      .catch(() => {}); // best-effort; not worth surfacing a failure to mark something read
  },

  createSchedule(body) {
    return api.createSchedule(body).then(({ schedule }) => {
      setState((s) => ({ schedules: upsertBy(s.schedules, schedule, "id") }));
      return schedule;
    });
  },

  pauseSchedule: (id, paused) => api.pauseSchedule(id, paused),
  runScheduleNow: (id, body) => api.runScheduleNow(id, body),
  deleteSchedule(id) {
    return api.deleteSchedule(id).then(() => {
      setState((s) => ({ schedules: s.schedules.filter((sched) => sched.id !== id) }));
    });
  }
};

// ---------- router ----------

const routes = [
  { pattern: /^\/$/, build: () => renderThreadList(state, actions) },
  { pattern: /^\/new$/, build: () => renderNewThread(state, actions) },
  { pattern: /^\/thread\/([^/]+)$/, build: (m) => renderThreadView(state, actions, decodeURIComponent(m[1])) },
  { pattern: /^\/schedules$/, build: () => renderSchedules(state, actions) },
  { pattern: /^\/schedules\/new$/, build: () => renderScheduleForm(state, actions) },
  { pattern: /^\/schedules\/([^/]+)$/, build: (m) => renderScheduleDetail(state, actions, decodeURIComponent(m[1])) }
];

function go(path, { replace = false } = {}) {
  if (location.pathname !== path) {
    if (replace) history.replaceState(null, "", path);
    else history.pushState(null, "", path);
  }
  mountRoute();
}

function mountRoute() {
  // A screen may own things outside its own node — a body-level overlay, a document listener, an
  // observer, a timer — and replacing `mainEl`'s children would leave all of them running.
  currentView?.dispose?.();
  const view = state.authed
    ? resolveRoute(location.pathname)
    : hosted
      ? renderPairingScreen(state, actions)
      : renderTokenScreen(state, actions);
  currentView = view;
  view.node.classList.add("view-enter");
  mount(mainEl, view.node);
  paintChrome();
  // Move focus to the new screen so assistive tech announces it and keyboard scrolling starts
  // inside it. Every screen exposes exactly one such target: its heading, or (thread view, whose
  // title lives in an editable button that must stay in the tab order) its labelled scroll area.
  const target = view.node.querySelector('h1, h2, [tabindex="-1"]');
  if (target) {
    target.setAttribute("tabindex", "-1");
    target.focus({ preventScroll: true });
    const label = (target.getAttribute("aria-label") || target.textContent || "").trim();
    document.title = label ? `${label} \u00b7 Patchwork` : "Patchwork";
  } else {
    document.title = "Patchwork";
  }
}

function resolveRoute(pathname) {
  for (const route of routes) {
    const match = pathname.match(route.pattern);
    if (match) return route.build(match);
  }
  // Unknown client-side path: land on the thread list rather than a dead end.
  history.replaceState(null, "", "/");
  return renderThreadList(state, actions);
}

window.addEventListener("popstate", mountRoute);
// iPhone Safari can reuse the existing `/pair/<installation>` tab when only the fragment changed.
// Reload so the new fragment is consumed instead of leaving the expired pairing screen in place.
window.addEventListener("hashchange", () => {
  if (hosted && shouldReloadPairingLink(location.pathname, location.hash)) location.reload();
});
window.addEventListener("pi:unauthorized", () => {
  stopEvents();
  clearToken();
  Object.assign(state, {
    authed: false,
    threads: [],
    threadsNextCursor: null,
    threadsLoadingMore: false,
    schedules: [],
    connection: "connecting"
  });
  mountRoute();
});
window.addEventListener("pi:relay-pairing", (event) => {
  if (event.detail?.phase === "unpaired" && state.authed) {
    stopEvents();
    Object.assign(state, {
      authed: false,
      threads: [],
      threadsNextCursor: null,
      threadsLoadingMore: false,
      schedules: [],
      connection: "connecting",
      relayPairing: event.detail
    });
    history.replaceState(null, "", "/");
    mountRoute();
  } else {
    setState({ relayPairing: event.detail });
  }
});
window.addEventListener("pi:relay-paired", () => {
  setState({ authed: true, relayPairing: relayPairingState() });
  loadThreads();
  loadFolders();
  loadSchedules();
  loadActivity();
  startEvents();
  go("/", { replace: true });
});

// ---------- boot ----------

if (hosted) startRelay();
if (state.authed) {
  loadThreads();
  loadFolders();
  loadSchedules();
  loadActivity();
  startEvents();
}
mountRoute();
