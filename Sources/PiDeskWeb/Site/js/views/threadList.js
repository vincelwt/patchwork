import { h, mount } from "../dom.js";
import { relativeTime } from "../time.mjs";
import { attachPullToRefresh } from "../pulltorefresh.js";
import { buildThreadTree, flattenTree, isFlatList } from "../folders.mjs";

const SKELETON_ROWS = 6;
// Indentation stops growing past this depth so a deeply nested folder still leaves usable room
// for a title on a narrow phone; the disclosure triangles keep the structure readable.
const MAX_INDENT_STEPS = 4;

/**
 * The Threads tab: list + pull-to-refresh + refresh button + live updates. `onStateChange` only
 * repaints the list body, never the top bar or FAB, so this is safe to call on every background
 * SSE update without disturbing anything else on screen (there is no persistent focus/typed
 * input on this screen to protect, unlike the forms).
 */
export function renderThreadList(state, actions) {
  const listBody = h("div", { id: "thread-list-body" });
  const indicator = h("div", { class: "ptr-indicator" });
  const scroll = h("div", { class: "scroll" }, listBody);
  const refreshBtn = h(
    "button",
    { class: "icon-btn", type: "button", "aria-label": "Refresh threads", onclick: () => actions.refreshThreads() },
    "\u21bb"
  );

  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h("h1", { tabindex: "-1" }, "Threads"),
      refreshBtn,
      h("button", { class: "icon-btn", type: "button", "aria-label": "Sign out", onclick: () => actions.signOut() }, "\u23fb")
    ),
    indicator,
    scroll,
    h("button", { class: "fab", type: "button", "aria-label": "New thread", onclick: () => actions.navigate("/new") }, "+")
  );

  attachPullToRefresh(scroll, indicator, () => actions.refreshThreads());
  paintList(listBody, state, actions);
  actions.refreshThreads();

  return {
    node,
    onStateChange: (next) => paintList(listBody, next, actions)
  };
}

function paintList(container, state, actions) {
  // A refresh that fails leaves the last good list on screen rather than replacing it with an
  // error page; the error only takes over when there is nothing else to show.
  container.setAttribute("aria-busy", String(state.threadsLoading));
  if (state.threadsError && !state.threads.length) {
    mount(
      container,
      h(
        "div",
        { class: "error-block" },
        h("div", { class: "inline-error", role: "alert" }, state.threadsError),
        h("button", { class: "btn", type: "button", onclick: () => actions.refreshThreads() }, "Try again")
      )
    );
    return;
  }
  if (!state.threads.length) {
    mount(container, state.threadsLoading ? skeletonList() : emptyState(actions));
    return;
  }
  // Grouping is worth its own chrome only when there is structure to show. A machine with one
  // project and no folders keeps the flat list it always had.
  const groups = buildThreadTree(state.threads, state.folders);
  const rows = isFlatList(groups)
    ? state.threads.map((thread) => renderRow(thread, actions, 0))
    : flattenTree(groups, state.collapsedGroups).map((row) =>
        row.kind === "group" ? renderGroup(row, actions) : renderRow(row.thread, actions, row.depth)
      );

  mount(container, [
    state.threadsError ? h("div", { class: "banner banner-error", role: "status" }, state.threadsError) : null,
    ...rows
  ]);
}

function indentStyle(depth) {
  return `--depth:${Math.min(depth, MAX_INDENT_STEPS)}`;
}

/**
 * A folder or project header. It is a real disclosure button (`aria-expanded`) rather than a
 * styled div, so a screen reader announces the collapsed state and a keyboard can toggle it.
 */
function renderGroup(row, actions) {
  const { group, depth, collapsed } = row;
  const counts = [
    group.total === 1 ? "1 thread" : `${group.total} threads`,
    group.unread ? `${group.unread} unread` : null,
    group.running ? `${group.running} running` : null
  ].filter(Boolean);

  return h(
    "button",
    {
      class: `group-row${group.kind === "virtual" ? " group-virtual" : ""}`,
      type: "button",
      style: indentStyle(depth),
      "aria-expanded": String(!collapsed),
      "aria-label": `${group.name}, ${counts.join(", ")}`,
      onclick: () => actions.toggleGroup(group.id)
    },
    h("span", { class: "group-caret", "aria-hidden": "true" }, collapsed ? "\u203a" : "\u2304"),
    h("span", { class: "group-glyph", "aria-hidden": "true" }, group.kind === "virtual" ? "\u25c8" : "\u25b8"),
    h("span", { class: "group-name", "aria-hidden": "true" }, group.name),
    group.unread ? h("span", { class: "dot", "aria-hidden": "true" }) : null,
    group.running ? h("span", { class: "spinner", "aria-hidden": "true" }) : null,
    h("span", { class: "group-count", "aria-hidden": "true" }, String(group.total))
  );
}

function skeletonList() {
  return Array.from({ length: SKELETON_ROWS }, () =>
    h(
      "div",
      { class: "skeleton-row", "aria-hidden": "true" },
      h("div", { class: "skeleton skeleton-title" }),
      h("div", { class: "skeleton skeleton-sub" })
    )
  );
}

function emptyState(actions) {
  return h(
    "div",
    { class: "empty-state" },
    h("div", { class: "empty-glyph", "aria-hidden": "true" }, "\u25a4"),
    h("p", { class: "empty-title" }, "No threads yet"),
    h("p", { class: "empty-body" }, "Start one on any folder on your Mac and it shows up here."),
    h("button", { class: "btn btn-primary", type: "button", onclick: () => actions.navigate("/new") }, "New thread")
  );
}

function renderRow(thread, actions, depth = 0) {
  const title = thread.name || "Untitled";
  return h(
    "button",
    {
      class: thread.unread ? "row row-unread" : "row",
      type: "button",
      style: indentStyle(depth),
      // The row's own children carry punctuation and abbreviations that read badly aloud, so
      // the whole control gets one clean label instead.
      "aria-label": [title, thread.folder, thread.unread ? "unread" : null, thread.running ? "running" : null]
        .filter(Boolean)
        .join(", "),
      onclick: () => actions.navigate(`/thread/${encodeURIComponent(thread.id)}`)
    },
    h(
      "div",
      { class: "row-main", "aria-hidden": "true" },
      h(
        "div",
        { class: "row-title-line" },
        thread.unread ? h("span", { class: "dot" }) : null,
        h("span", { class: "row-title" }, title),
        h("span", { class: "row-time" }, relativeTime(thread.updatedAt))
      ),
      thread.folder || thread.preview
        ? h(
            "div",
            { class: "row-sub" },
            thread.folder ? h("span", { class: "row-folder" }, thread.folder) : null,
            thread.folder && thread.preview ? " \u00b7 " : "",
            thread.preview || ""
          )
        : null
    ),
    thread.running ? h("span", { class: "spinner" }) : null
  );
}
