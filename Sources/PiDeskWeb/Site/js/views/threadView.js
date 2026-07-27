import { h, mount } from "../dom.js";
import { api, describeError } from "../api.js";
import { renderMarkdown } from "../markdown.mjs";
import { clockTime } from "../time.mjs";

const INITIAL_MESSAGE_COUNT = 50;
const REFRESH_DEBOUNCE_MS = 700;
const NEAR_BOTTOM_PX = 120;

// A physical keyboard means Enter should send and Shift+Enter should break the line, the way
// every desktop chat client behaves. On a touch keyboard Enter stays a newline — the Send button
// is right there, and a mistyped Return should not fire a prompt at the model.
const hasPointer = window.matchMedia("(pointer: fine)").matches;

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
  let refetchQueued = false;
  let renderedCount = 0;
  let loadedOnce = false;

  const titleBtn = h("button", { class: "thread-title", type: "button", "aria-label": "Rename thread", onclick: onRenameStart });
  const titleInput = h("input", { type: "text", class: "visually-hidden", "aria-hidden": "true", "aria-label": "Thread name" });
  const cwdEl = h("div", { class: "cwd" });
  const archiveBtn = h("button", { class: "icon-btn", type: "button", "aria-label": "Archive thread", onclick: onToggleArchive }, "\u2298");

  const messagesEl = h("div", { class: "messages" });
  const loadEarlierBtn = h("button", { class: "btn btn-block", type: "button", onclick: onLoadEarlier, hidden: true }, "Load earlier");
  // Focus target for the router (see app.js): the thread's title lives in an editable button
  // that has to stay in the tab order, so the labelled message region announces the screen.
  const scroll = h("div", { class: "scroll content-pad", tabindex: "-1", "aria-label": "Thread" }, loadEarlierBtn, messagesEl);

  const textarea = h("textarea", {
    rows: "1",
    "aria-label": "Message",
    placeholder: "Message",
    autocapitalize: "sentences",
    oninput: onInput,
    onkeydown: onComposerKeydown,
    onfocus: () => scrollToBottom("auto")
  });
  const sendBtn = h("button", { class: "btn btn-primary", type: "submit", disabled: true }, "Send");
  const composerError = h("div", { class: "inline-error composer-error", role: "alert", hidden: true });
  const menuToggle = h(
    "button",
    { class: "icon-btn", type: "button", "aria-label": "More send options", "aria-expanded": "false", onclick: toggleMenu },
    "\u22ef"
  );
  const composerForm = h("form", { class: "composer", onsubmit: (e) => onSend(e, "auto") }, textarea, menuToggle, sendBtn);
  const composerMenu = h(
    "div",
    { class: "composer-menu", hidden: true, onkeydown: (e) => e.key === "Escape" && closeMenu(true) },
    h("button", { class: "link-btn", type: "button", onclick: () => onSend(null, "followUp") }, "Send as follow-up"),
    h("button", { class: "link-btn", type: "button", onclick: () => onSend(null, "steer") }, "Send as steer (interrupt)")
  );

  const runStatus = h(
    "div",
    { class: "run-status", role: "status", hidden: true },
    h("span", { class: "spinner" }),
    h("span", null, "Pi is working\u2026"),
    h("button", { class: "link-btn btn-danger", type: "button", onclick: onAbort }, "Stop")
  );

  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h("button", { class: "icon-btn icon-btn-back", type: "button", "aria-label": "Back to threads", onclick: () => actions.navigate("/") }, "\u2039"),
      h("div", { class: "thread-header" }, h("div", null, titleBtn, titleInput), cwdEl),
      archiveBtn
    ),
    scroll,
    h("div", { class: "composer-dock" }, runStatus, composerError, composerMenu, composerForm)
  );

  paintHeader();
  paintSkeleton();
  loadMessages();
  actions.markRead(threadId);

  function onInput() {
    // Height is set from the content and clamped by the stylesheet's max-height, so the growth
    // ceiling stays a layout concern rather than a magic number here.
    textarea.style.height = "auto";
    textarea.style.height = `${textarea.scrollHeight}px`;
    sendBtn.disabled = textarea.value.trim().length === 0;
  }

  function onComposerKeydown(event) {
    if (event.key !== "Enter") return;
    const send = (event.metaKey || event.ctrlKey) || (hasPointer && !event.shiftKey && !event.altKey);
    if (!send) return;
    event.preventDefault();
    onSend(null, "auto");
  }

  function toggleMenu() {
    if (composerMenu.hidden) {
      composerMenu.hidden = false;
      menuToggle.setAttribute("aria-expanded", "true");
      composerMenu.querySelector("button")?.focus();
    } else {
      closeMenu(true);
    }
  }

  function closeMenu(restoreFocus) {
    if (composerMenu.hidden) return;
    composerMenu.hidden = true;
    menuToggle.setAttribute("aria-expanded", "false");
    if (restoreFocus) menuToggle.focus();
  }

  function onSend(event, delivery) {
    if (event) event.preventDefault();
    const text = textarea.value.trim();
    if (!text) return;
    composerError.hidden = true;
    sendBtn.disabled = true;
    sendBtn.textContent = "Sending\u2026";
    actions
      .sendMessage(threadId, { text, delivery })
      .then(() => {
        textarea.value = "";
        onInput();
        closeMenu(false);
        scrollToBottom();
        return loadMessages();
      })
      .catch((err) => {
        composerError.hidden = false;
        composerError.textContent = describeError(err);
      })
      .finally(() => {
        sendBtn.textContent = "Send";
        sendBtn.disabled = textarea.value.trim().length === 0;
      });
  }

  function onAbort() {
    const stopBtn = runStatus.querySelector("button");
    stopBtn.disabled = true;
    actions
      .abortThread(threadId)
      .catch((err) => {
        composerError.hidden = false;
        composerError.textContent = describeError(err);
      })
      .finally(() => {
        stopBtn.disabled = false;
      });
  }

  function onToggleArchive() {
    if (!thread) return;
    archiveBtn.disabled = true;
    actions
      .archiveThread(threadId, !thread.archived)
      .then((updated) => {
        thread = updated;
        paintHeader();
      })
      .catch((err) => {
        composerError.hidden = false;
        composerError.textContent = describeError(err);
      })
      .finally(() => {
        archiveBtn.disabled = false;
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
    loadEarlierBtn.disabled = true;
    loadEarlierBtn.textContent = "Loading\u2026";
    loadMessages();
  }

  function paintHeader() {
    const name = thread?.name || "Untitled";
    titleBtn.textContent = name;
    scroll.setAttribute("aria-label", name);
    cwdEl.textContent = thread?.cwd || "";
    cwdEl.hidden = !thread?.cwd;
    runStatus.hidden = !thread?.running;
    archiveBtn.setAttribute("aria-pressed", String(!!thread?.archived));
    archiveBtn.setAttribute("aria-label", thread?.archived ? "Unarchive thread" : "Archive thread");
  }

  function loadMessages() {
    if (fetchingMessages) {
      // A refresh that arrives mid-flight would otherwise be dropped and the newest message
      // would sit invisible until the next event.
      refetchQueued = true;
      return Promise.resolve();
    }
    fetchingMessages = true;
    const nearBottom = !loadedOnce || isScrolledNearBottom();
    const distanceFromBottom = scroll.scrollHeight - scroll.scrollTop;
    return api
      .thread(threadId, messageLimit)
      .then(({ thread: freshThread, messages }) => {
        thread = freshThread;
        loadedOnce = true;
        paintHeader();
        paintMessages(messages);
        loadEarlierBtn.hidden = messages.length < messageLimit;
        loadEarlierBtn.disabled = false;
        loadEarlierBtn.textContent = "Load earlier";
        if (nearBottom) scrollToBottom(renderedCount ? "smooth" : "auto");
        // Older messages were prepended: hold the reading position instead of jumping.
        else scroll.scrollTop = scroll.scrollHeight - distanceFromBottom;
      })
      .catch((err) => {
        mount(messagesEl, h("div", { class: "inline-error", role: "alert" }, describeError(err)));
        renderedCount = 0;
      })
      .finally(() => {
        fetchingMessages = false;
        if (refetchQueued) {
          refetchQueued = false;
          loadMessages();
        }
      });
  }

  function isScrolledNearBottom() {
    return scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < NEAR_BOTTOM_PX;
  }

  function scrollToBottom(behavior = "smooth") {
    requestAnimationFrame(() => {
      scroll.scrollTo({ top: scroll.scrollHeight, behavior });
    });
  }

  function paintSkeleton() {
    mount(
      messagesEl,
      Array.from({ length: 3 }, () =>
        h(
          "div",
          { class: "msg msg-skeleton", "aria-hidden": "true" },
          h("div", { class: "skeleton" }),
          h("div", { class: "skeleton" }),
          h("div", { class: "skeleton" })
        )
      )
    );
  }

  function paintMessages(messages) {
    if (!messages.length) {
      mount(messagesEl, h("div", { class: "empty-state" }, h("p", { class: "empty-body" }, "No messages yet. Send the first one below.")));
      renderedCount = 0;
      return;
    }
    // Only genuinely new trailing messages animate in; a plain refresh of the same list must not
    // flash the whole transcript.
    const firstNew = renderedCount && messages.length > renderedCount ? renderedCount : messages.length;
    mount(
      messagesEl,
      messages.map((message, index) => renderMessage(message, index >= firstNew))
    );
    renderedCount = messages.length;
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

function renderMessage(message, isNew) {
  const role = ["user", "assistant", "toolResult", "system"].includes(message.role) ? message.role : "system";
  const roleClass = { user: "msg-user", assistant: "msg-assistant", toolResult: "msg-tool", system: "msg-system" }[role];
  const classes = ["msg", roleClass];
  if (message.isError) classes.push("msg-error");
  if (isNew) classes.push("msg-new");
  const bodyClass = role === "user" ? "bubble" : "prose";
  return h(
    "div",
    { class: classes.join(" ") },
    h("div", { class: "msg-meta" }, `${roleLabel(role)} \u00b7 ${clockTime(message.at)}`),
    h("div", { class: bodyClass, html: renderMarkdown(message.text || "") })
  );
}

function roleLabel(role) {
  return { user: "You", assistant: "Pi", toolResult: "Tool", system: "System" }[role] || role;
}
