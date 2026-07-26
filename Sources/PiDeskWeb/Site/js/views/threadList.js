import { h, mount } from "../dom.js";
import { relativeTime } from "../time.mjs";
import { attachPullToRefresh } from "../pulltorefresh.js";

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

  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h("h1", { tabindex: "-1" }, "Threads"),
      h("button", { class: "icon-btn", "aria-label": "Refresh threads", onclick: () => actions.refreshThreads() }, "\u21bb"),
      h("button", { class: "icon-btn", "aria-label": "Sign out", onclick: () => actions.signOut() }, "\u23fb")
    ),
    indicator,
    scroll,
    h("button", { class: "fab", "aria-label": "New thread", onclick: () => actions.navigate("/new") }, "+")
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
  if (state.threadsError) {
    mount(
      container,
      h(
        "div",
        { class: "content-pad" },
        h("div", { class: "inline-error", role: "alert" }, state.threadsError),
        h("button", { class: "btn", onclick: () => actions.refreshThreads() }, "Retry")
      )
    );
    return;
  }
  if (!state.threads.length) {
    mount(container, h("div", { class: "empty-state" }, state.threadsLoading ? "Loading\u2026" : "No threads yet. Tap + to start one."));
    return;
  }
  mount(
    container,
    state.threads.map((thread) => renderRow(thread, actions))
  );
}

function renderRow(thread, actions) {
  const sub = [thread.folder, thread.preview].filter(Boolean);
  return h(
    "button",
    { class: "row", type: "button", onclick: () => actions.navigate(`/thread/${encodeURIComponent(thread.id)}`) },
    h(
      "div",
      { class: "row-main" },
      h(
        "div",
        { class: "row-title-line" },
        thread.unread ? h("span", { class: "dot", "aria-hidden": "true" }) : null,
        thread.unread ? h("span", { class: "visually-hidden" }, "Unread") : null,
        h("span", { class: "row-title" }, thread.name || "Untitled"),
        h("span", { class: "row-time" }, relativeTime(thread.updatedAt))
      ),
      sub.length
        ? h(
            "div",
            { class: "row-sub" },
            thread.folder ? h("span", { class: "row-folder" }, thread.folder) : null,
            thread.folder && thread.preview ? " \u00b7 " : "",
            thread.preview || ""
          )
        : null
    ),
    thread.running ? h("span", { class: "spinner", role: "status", "aria-label": "Running" }) : null
  );
}
