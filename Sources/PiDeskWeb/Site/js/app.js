// Bootstraps the app: owns the one piece of global state, the router, the SSE connection, and
// every action a view can call. Views never call `api.js` or touch global state directly for
// anything that other screens need to stay in sync with (thread/schedule lists) — they go
// through `actions`. Views MAY call `api.js` directly for data that is local to just that screen
// (thread detail messages, schedule detail runs), which keeps this file from having to know
// about every screen's private loading state.

import { h, mount } from "./dom.js";
import { api, ApiError, getToken, setToken, clearToken, hasToken, describeError } from "./api.js";
import { connectEvents } from "./sse.js";
import { renderTokenScreen } from "./views/token.js";
import { renderThreadList } from "./views/threadList.js";
import { renderThreadView } from "./views/threadView.js";
import { renderNewThread } from "./views/newThread.js";
import { renderSchedules, renderScheduleDetail } from "./views/schedules.js";
import { renderScheduleForm } from "./views/scheduleForm.js";

const state = {
  authed: hasToken(),
  connection: "connecting", // "connecting" | "online" | "offline"
  threads: [],
  threadsLoading: false,
  threadsError: null,
  schedules: [],
  schedulesLoading: false,
  schedulesError: null,
  activity: null,
  // Most recent SSE payload of each kind, so a view whose data isn't part of global state (e.g.
  // an open thread's message list) can tell whether it needs to refetch. See threadView.js.
  lastThreadEvent: null,
  lastScheduleEvent: null,
  lastRunEvent: null
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

// ---------- data loading ----------

function loadThreads() {
  setState({ threadsLoading: true, threadsError: null });
  return api
    .threads({ limit: 50 })
    .then(({ threads }) => setState({ threads: sortByUpdatedAt(threads), threadsLoading: false }))
    .catch((err) => {
      if (err instanceof ApiError && err.status === 401) return;
      setState({ threadsLoading: false, threadsError: describeError(err) });
    });
}

function loadSchedules() {
  setState({ schedulesLoading: true, schedulesError: null });
  return api
    .schedules()
    .then(({ schedules }) => setState({ schedules, schedulesLoading: false }))
    .catch((err) => {
      if (err instanceof ApiError && err.status === 401) return;
      setState({ schedulesLoading: false, schedulesError: describeError(err) });
    });
}

// ---------- live updates ----------

function handleEvent(name, data) {
  if (!data || typeof data !== "object") return;
  if (name === "thread") {
    setState((s) => ({ threads: sortByUpdatedAt(upsertBy(s.threads, data, "id")), lastThreadEvent: data }));
  } else if (name === "schedule") {
    setState((s) => ({ schedules: upsertBy(s.schedules, data, "id"), lastScheduleEvent: data }));
  } else if (name === "run") {
    setState({ lastRunEvent: data });
  } else if (name === "activity") {
    setState({ activity: data });
  }
  // Any other event name is forward-compatible-ignored per docs/daemon-api.md.
}

function startEvents() {
  events?.close();
  events = connectEvents({ onEvent: handleEvent, onStatus: (status) => setState({ connection: status }) });
}

function stopEvents() {
  events?.close();
  events = null;
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
        loadSchedules();
        startEvents();
        go("/", { replace: true });
      },
      (err) => {
        clearToken();
        throw err;
      }
    );
  },

  signOut() {
    stopEvents();
    clearToken();
    Object.assign(state, { authed: false, threads: [], schedules: [], connection: "connecting" });
    go("/", { replace: true });
  },

  refreshThreads: () => loadThreads(),
  refreshSchedules: () => loadSchedules(),

  createThread(body) {
    return api.createThread(body).then(({ thread }) => {
      setState((s) => ({ threads: sortByUpdatedAt(upsertBy(s.threads, thread, "id")) }));
      go(`/thread/${encodeURIComponent(thread.id)}`, { replace: true });
      return thread;
    });
  },

  sendMessage: (id, body) => api.sendMessage(id, body),
  abortThread: (id) => api.abortThread(id),

  archiveThread(id, archived) {
    return api.archiveThread(id, archived).then(({ thread }) => {
      setState((s) => ({ threads: upsertBy(s.threads, thread, "id") }));
      return thread;
    });
  },

  renameThread(id, name) {
    return api.renameThread(id, name).then(({ thread }) => {
      setState((s) => ({ threads: upsertBy(s.threads, thread, "id") }));
      return thread;
    });
  },

  markRead(id) {
    return api
      .markThreadRead(id, false)
      .then(({ thread }) => setState((s) => ({ threads: upsertBy(s.threads, thread, "id") })))
      .catch(() => {}); // best-effort; not worth surfacing a failure to mark something read
  },

  createSchedule(body) {
    return api.createSchedule(body).then(({ schedule }) => {
      setState((s) => ({ schedules: upsertBy(s.schedules, schedule, "id") }));
      go("/schedules", { replace: true });
      return schedule;
    });
  },

  pauseSchedule: (id, paused) => api.pauseSchedule(id, paused),
  runScheduleNow: (id) => api.runScheduleNow(id),
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
  const view = state.authed ? resolveRoute(location.pathname) : renderTokenScreen(state, actions);
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
    document.title = label ? `${label} \u00b7 Pi Desktop` : "Pi Desktop";
  } else {
    document.title = "Pi Desktop";
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
window.addEventListener("pi:unauthorized", () => {
  stopEvents();
  clearToken();
  Object.assign(state, { authed: false, threads: [], schedules: [], connection: "connecting" });
  mountRoute();
});

// ---------- boot ----------

if (state.authed) {
  loadThreads();
  loadSchedules();
  startEvents();
}
mountRoute();
