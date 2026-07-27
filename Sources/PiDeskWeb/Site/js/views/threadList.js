import { h, mount } from "../dom.js";
import { relativeTime } from "../time.mjs";
import { attachPullToRefresh } from "../pulltorefresh.js";

const SKELETON_ROWS = 6;

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
  mount(container, [
    state.threadsError ? h("div", { class: "banner banner-error", role: "status" }, state.threadsError) : null,
    ...state.threads.map((thread) => renderRow(thread, actions))
  ]);
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

function renderRow(thread, actions) {
  const title = thread.name || "Untitled";
  return h(
    "button",
    {
      class: thread.unread ? "row row-unread" : "row",
      type: "button",
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
