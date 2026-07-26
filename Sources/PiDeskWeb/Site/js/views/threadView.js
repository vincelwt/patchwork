import { h, mount } from "../dom.js";
import { api, describeError } from "../api.js";
import { renderMarkdown } from "../markdown.mjs";
import { clockTime } from "../time.mjs";

const INITIAL_MESSAGE_COUNT = 50;
const REFRESH_DEBOUNCE_MS = 700;

/**
 * A single thread: messages plus compose/abort/archive/rename. Message text is untrusted model
 * output — it is only ever inserted via `renderMarkdown()` (see js/markdown.mjs), never as raw
 * text through innerHTML. Live updates arrive indirectly: the SSE `thread` event carries a
 * refreshed `Thread` summary (name/running/archived/updatedAt) but never message bodies (see
 * docs/daemon-api.md), so a matching event here updates the header immediately and schedules a
 * debounced refetch of the messages themselves.
 */
export function renderThreadView(state, actions, threadId) {
  let messageLimit = INITIAL_MESSAGE_COUNT;
  let thread = state.threads.find((t) => t.id === threadId) || null;
  let refetchTimer = null;
  let fetchingMessages = false;

  const titleBtn = h("button", { class: "thread-title", type: "button", "aria-label": "Rename thread", onclick: onRenameStart });
  const titleInput = h("input", { type: "text", class: "visually-hidden", "aria-hidden": "true" });
  const cwdEl = h("div", { class: "cwd" });
  const runningBadge = h("span", { class: "spinner", role: "status", "aria-label": "Running", hidden: true });
  const archiveBtn = h("button", { class: "icon-btn", type: "button", "aria-label": "Archive thread", onclick: onToggleArchive }, "\u2298");
  const abortBtn = h("button", { class: "icon-btn btn-danger", type: "button", "aria-label": "Abort run", hidden: true, onclick: onAbort }, "\u25a0");

  const messagesEl = h("div", { class: "messages" });
  const loadEarlierBtn = h("button", { class: "btn btn-block", type: "button", onclick: onLoadEarlier, hidden: true }, "Load earlier");
  const scroll = h("div", { class: "scroll content-pad" }, loadEarlierBtn, messagesEl);

  const textarea = h("textarea", { rows: "1", "aria-label": "Message", placeholder: "Message", oninput: autoGrow });
  const sendBtn = h("button", { class: "btn btn-primary", type: "submit" }, "Send");
  const composerError = h("div", { class: "inline-error", role: "alert", hidden: true });
  const menuToggle = h("button", { class: "icon-btn", type: "button", "aria-label": "More send options", "aria-expanded": "false", onclick: onToggleMenu }, "\u22ef");
  const composerForm = h("form", { class: "composer", onsubmit: (e) => onSend(e, "auto") }, textarea, menuToggle, sendBtn);
  const composerMenu = h(
    "div",
    { class: "composer-menu", hidden: true },
    h("button", { class: "link-btn", type: "button", onclick: () => onSend(null, "followUp") }, "Send as follow-up"),
    h("button", { class: "link-btn", type: "button", onclick: () => onSend(null, "steer") }, "Send as steer (interrupt)")
  );

  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h("button", { class: "icon-btn", "aria-label": "Back to threads", onclick: () => actions.navigate("/") }, "\u2039"),
      h("div", { class: "thread-header" }, h("div", null, titleBtn, titleInput), cwdEl),
      runningBadge,
      archiveBtn,
      abortBtn
    ),
    scroll,
    composerError,
    composerMenu,
    composerForm
  );

  paintHeader();
  loadMessages();
  actions.markRead(threadId);

  function autoGrow() {
    textarea.style.height = "auto";
    textarea.style.height = `${Math.min(textarea.scrollHeight, 160)}px`;
  }

  function onToggleMenu() {
    const open = composerMenu.hidden;
    composerMenu.hidden = !open;
    menuToggle.setAttribute("aria-expanded", String(open));
  }

  function onSend(event, delivery) {
    if (event) event.preventDefault();
    const text = textarea.value.trim();
    if (!text) return;
    composerError.hidden = true;
    sendBtn.disabled = true;
    actions
      .sendMessage(threadId, { text, delivery })
      .then(() => {
        textarea.value = "";
        autoGrow();
        composerMenu.hidden = true;
        menuToggle.setAttribute("aria-expanded", "false");
        return loadMessages();
      })
      .catch((err) => {
        composerError.hidden = false;
        composerError.textContent = describeError(err);
      })
      .finally(() => {
        sendBtn.disabled = false;
      });
  }

  function onAbort() {
    abortBtn.disabled = true;
    actions.abortThread(threadId).catch(() => {}).finally(() => {
      abortBtn.disabled = false;
    });
  }

  function onToggleArchive() {
    if (!thread) return;
    actions.archiveThread(threadId, !thread.archived).then((updated) => {
      thread = updated;
      paintHeader();
    });
  }

  function onRenameStart() {
    titleInput.value = thread?.name || "";
    titleBtn.classList.add("visually-hidden");
    titleInput.classList.remove("visually-hidden");
    titleInput.removeAttribute("aria-hidden");
    titleInput.focus();
    titleInput.select();
  }

  function onRenameCommit() {
    titleBtn.classList.remove("visually-hidden");
    titleInput.classList.add("visually-hidden");
    titleInput.setAttribute("aria-hidden", "true");
    const name = titleInput.value.trim();
    if (!name || name === thread?.name) return;
    actions.renameThread(threadId, name).then((updated) => {
      thread = updated;
      paintHeader();
    });
  }

  titleInput.addEventListener("blur", onRenameCommit);
  titleInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      titleInput.blur();
    } else if (event.key === "Escape") {
      titleInput.value = thread?.name || "";
      titleInput.blur();
    }
  });

  function onLoadEarlier() {
    messageLimit += INITIAL_MESSAGE_COUNT;
    loadEarlierBtn.textContent = "Loading\u2026";
    loadMessages();
  }

  function paintHeader() {
    titleBtn.textContent = thread?.name || "Untitled";
    cwdEl.textContent = thread?.cwd || "";
    runningBadge.hidden = !thread?.running;
    abortBtn.hidden = !thread?.running;
    archiveBtn.setAttribute("aria-pressed", String(!!thread?.archived));
    archiveBtn.setAttribute("aria-label", thread?.archived ? "Unarchive thread" : "Archive thread");
  }

  function loadMessages() {
    if (fetchingMessages) return Promise.resolve();
    fetchingMessages = true;
    const nearBottom = isScrolledNearBottom();
    return api
      .thread(threadId, messageLimit)
      .then(({ thread: freshThread, messages }) => {
        thread = freshThread;
        paintHeader();
        paintMessages(messages);
        loadEarlierBtn.hidden = messages.length < messageLimit;
        loadEarlierBtn.textContent = "Load earlier";
        if (nearBottom) scroll.scrollTop = scroll.scrollHeight;
      })
      .catch((err) => {
        mount(messagesEl, h("div", { class: "inline-error", role: "alert" }, describeError(err)));
      })
      .finally(() => {
        fetchingMessages = false;
      });
  }

  function isScrolledNearBottom() {
    return scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 120;
  }

  function paintMessages(messages) {
    mount(
      messagesEl,
      messages.map((message) => renderMessage(message))
    );
  }

  function scheduleRefetch() {
    if (refetchTimer) clearTimeout(refetchTimer);
    refetchTimer = setTimeout(() => {
      refetchTimer = null;
      loadMessages();
    }, REFRESH_DEBOUNCE_MS);
  }

  return {
    node,
    onStateChange(next) {
      const event = next.lastThreadEvent;
      if (!event || (event.id !== threadId && event.path !== thread?.path)) return;
      const wasUpdatedAt = thread?.updatedAt;
      thread = event;
      paintHeader();
      if (event.updatedAt !== wasUpdatedAt) scheduleRefetch();
    }
  };
}

function renderMessage(message) {
  const role = ["user", "assistant", "toolResult", "system"].includes(message.role) ? message.role : "system";
  const roleClass = { user: "msg-user", assistant: "msg-assistant", toolResult: "msg-tool", system: "msg-system" }[role];
  const wrapClass = message.isError ? `msg ${roleClass} msg-error` : `msg ${roleClass}`;
  const bodyClass = role === "user" ? "bubble" : "prose";
  return h(
    "div",
    { class: wrapClass },
    h("div", { class: "msg-meta" }, `${roleLabel(role)} \u00b7 ${clockTime(message.at)}`),
    h("div", { class: bodyClass, html: renderMarkdown(message.text || "") })
  );
}

function roleLabel(role) {
  return { user: "You", assistant: "Pi", toolResult: "Tool", system: "System" }[role] || role;
}
