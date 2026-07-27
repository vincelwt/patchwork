import { h, mount } from "../dom.js";
import { api, describeError } from "../api.js";
import { renderMarkdown } from "../markdown.mjs";
import { clockTime } from "../time.mjs";
import {
  addPending,
  applyRunEvent,
  markAccepted,
  markFailed,
  reconcile,
  removePending,
  statusLabel
} from "../pending.mjs";
import { renderInteraction } from "./interaction.js";

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
  let lastRunSignature = "";
  // Messages accepted by the daemon but not yet visible in Pi's own session file. See
  // js/pending.mjs for why this exists and how entries are reconciled away.
  let pending = [];
  let pendingSeq = 0;
  let lastMessages = [];
  let interactions = [];
  let fetchingInteractions = false;
  let interactionsQueued = false;
  let lastInteraction = null;
  let renderedInteractionSignature = null;

  const titleBtn = h("button", { class: "thread-title", type: "button", "aria-label": "Rename thread", onclick: onRenameStart });
  const titleInput = h("input", { type: "text", class: "visually-hidden", "aria-hidden": "true", "aria-label": "Thread name" });
  const cwdEl = h("div", { class: "cwd" });
  const archiveBtn = h("button", { class: "icon-btn", type: "button", "aria-label": "Archive thread", onclick: onToggleArchive }, "\u2298");

  const messagesEl = h("div", { class: "messages" });
  // Unconfirmed messages live in their own container after the transcript, so `paintMessages`'s
  // "only animate genuinely new trailing messages" bookkeeping stays about real messages only
  // and a pending bubble can never be mistaken for one.
  const pendingEl = h("div", { class: "messages messages-pending" });
  const interactionsEl = h("div", { class: "interactions" });
  const loadEarlierBtn = h("button", { class: "btn btn-block", type: "button", onclick: onLoadEarlier, hidden: true }, "Load earlier");
  // Focus target for the router (see app.js): the thread's title lives in an editable button
  // that has to stay in the tab order, so the labelled message region announces the screen.
  const scroll = h(
    "div",
    { class: "scroll content-pad", tabindex: "-1", "aria-label": "Thread" },
    loadEarlierBtn,
    messagesEl,
    pendingEl,
    interactionsEl
  );

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
  loadInteractions();
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
    closeMenu(false);
    // The composer empties now, not after the response: the text is not lost, it has moved into
    // the pending bubble below, where it stays visible (and retryable) even if the send fails.
    textarea.value = "";
    onInput();
    submit(text, delivery);
  }

  function submit(text, delivery) {
    const key = `p${++pendingSeq}`;
    pending = addPending(pending, { key, text, messages: lastMessages });
    paintPending();
    scrollToBottom();
    // Only the send itself may mark the bubble failed. A refetch that fails afterwards is a
    // display problem, not a delivery one, and must never claim a message was not sent.
    actions.sendMessage(threadId, { text, delivery }).then(
      (response) => {
        pending = markAccepted(pending, key, {
          runId: response?.runId ?? null,
          queued: response?.queued === true,
          // Older daemons omit `delivery`; assume they did what was asked rather than inventing
          // a downgrade the server never reported.
          delivery: response?.delivery ?? delivery ?? null
        });
        paintPending();
        loadMessages();
        loadInteractions();
      },
      (err) => {
        pending = markFailed(pending, key, describeError(err));
        paintPending();
      }
    );
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
        lastMessages = messages;
        paintHeader();
        paintMessages(messages);
        pending = reconcile(pending, messages);
        paintPending();
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

  function paintPending() {
    mount(
      pendingEl,
      pending.map((entry) =>
        renderPendingMessage(entry, {
          onRetry: () => {
            pending = removePending(pending, entry.key);
            submit(entry.text, entry.delivery);
          },
          onDismiss: () => {
            pending = removePending(pending, entry.key);
            paintPending();
          }
        })
      )
    );
  }

  // Always re-read the list rather than accumulating SSE frames: `interaction` events are a hint
  // that something changed, and a phone that was backgrounded or missed a frame must not be left
  // showing a dialog Pi has already stopped waiting on.
  function loadInteractions() {
    if (fetchingInteractions) {
      interactionsQueued = true;
      return Promise.resolve();
    }
    fetchingInteractions = true;
    return api
      .interactions(threadId)
      .then((response) => {
        interactions = response?.interactions || [];
        paintInteractions();
      })
      // A daemon without the endpoint, or a transient failure, simply means "nothing to answer
      // here"; the thread itself stays usable.
      .catch(() => {
        interactions = [];
        paintInteractions();
      })
      .finally(() => {
        fetchingInteractions = false;
        if (interactionsQueued) {
          interactionsQueued = false;
          loadInteractions();
        }
      });
  }

  function paintInteractions() {
    // Repaint only when the *set* of pending dialogs changed. A poll triggered by some other
    // thread's interaction event must not wipe a half-typed answer or a selected option.
    const signature = interactions.map((interaction) => interaction.id).join("|");
    if (signature === renderedInteractionSignature) return;
    renderedInteractionSignature = signature;

    const wasEmpty = !interactionsEl.childElementCount;
    mount(
      interactionsEl,
      interactions.map((interaction) =>
        renderInteraction(interaction, {
          respond: (body) => actions.respondInteraction(interaction.id, body).then(() => loadInteractions()),
          describeError
        })
      )
    );
    if (wasEmpty && interactions.length) scrollToBottom();
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
      messages.map((message, index) => renderMessage(message, index >= firstNew, threadId))
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
      const run = next.lastRunEvent;
      const runSignature = run ? `${run.id}:${run.status}:${run.finishedAt || ""}` : "";
      if (run && runSignature !== lastRunSignature) {
        lastRunSignature = runSignature;
        // A run event is matched by id as well as by thread: a steer answers with the *live* run,
        // whose `threadId` is already known here, and a brand-new thread's run reports its id
        // before the thread event lands.
        const before = pending;
        pending = applyRunEvent(pending, run);
        if (pending !== before) paintPending();
        if (run.threadId === threadId) {
          thread = { ...thread, running: run.status === "running" };
          paintHeader();
          scheduleRefetch();
        }
      }

      if (next.lastInteractionEvent && next.lastInteractionEvent !== lastInteraction) {
        lastInteraction = next.lastInteractionEvent;
        loadInteractions();
      }

      const event = next.lastThreadEvent;
      if (!event || (event.id !== threadId && event.path !== thread?.path)) return;
      const wasUpdatedAt = thread?.updatedAt;
      thread = event;
      paintHeader();
      if (event.updatedAt !== wasUpdatedAt) scheduleRefetch();
    }
  };
}

function renderMessage(message, isNew, threadId) {
  const role = ["user", "assistant", "toolResult", "system"].includes(message.role) ? message.role : "system";
  const roleClass = { user: "msg-user", assistant: "msg-assistant", toolResult: "msg-tool", system: "msg-system" }[role];
  const classes = ["msg", roleClass];
  if (message.isError) classes.push("msg-error");
  if (isNew) classes.push("msg-new");
  const bodyClass = role === "user" ? "bubble" : "prose";
  const images = Array.isArray(message.images) ? message.images : [];
  return h(
    "div",
    { class: classes.join(" ") },
    h("div", { class: "msg-meta" }, `${roleLabel(role)} \u00b7 ${clockTime(message.at)}`),
    message.text ? h("div", { class: bodyClass, html: renderMarkdown(message.text) }) : null,
    images.length ? h("div", { class: "msg-images" }, images.map((image) => renderImage(image, threadId))) : null
  );
}

/**
 * A responsive thumbnail that loads its bytes only when tapped/opened, since the transcript
 * carries metadata only. Anything the daemon refused to serve (too large, unreadable, past the
 * per-view image budget) stays visible as a labelled placeholder instead of disappearing.
 */
function renderImage(image, threadId) {
  const label = image.fileName || "Image";
  if (image.status && image.status !== "ok") {
    return h(
      "div",
      { class: "img-placeholder", role: "note" },
      h("span", { class: "img-glyph", "aria-hidden": "true" }, "\u25a3"),
      h("span", null, image.note || `${label} is not available here.`)
    );
  }

  const img = h("img", { class: "thumb", alt: label, loading: "lazy", decoding: "async", hidden: true });
  const status = h("span", { class: "img-loading" }, `${label} \u00b7 ${formatBytes(image.byteCount)}`);
  const figure = h("button", { class: "img-tile", type: "button", "aria-label": `Open ${label}`, onclick: open }, img, status);

  let source = null;
  let loading = null;

  function load() {
    if (source) return Promise.resolve(source);
    if (loading) return loading;
    loading = api
      .threadImage(threadId, image.id)
      .then((payload) => {
        source = `data:${payload.mimeType || "image/png"};base64,${payload.data}`;
        img.src = source;
        img.hidden = false;
        status.remove();
        return source;
      })
      .catch((err) => {
        status.textContent = describeError(err);
        status.classList.add("img-failed");
        loading = null;
        throw err;
      });
    return loading;
  }

  function open() {
    load().then((src) => openLightbox(src, label)).catch(() => {});
  }

  // Thumbnails fetch as soon as they exist; the bytes are already bounded server-side and a
  // transcript is capped at a small number of images per view.
  load().catch(() => {});
  return figure;
}

/**
 * A focus-trapped overlay with the full image plus a download link. Dismissed by Escape, by the
 * backdrop, or by the close button — all three, because a phone has no keyboard and a desktop
 * browser has no back gesture.
 */
function openLightbox(src, label) {
  const previouslyFocused = document.activeElement;
  const closeBtn = h("button", { class: "icon-btn", type: "button", "aria-label": "Close image", onclick: close }, "\u2715");
  const overlay = h(
    "div",
    {
      class: "lightbox",
      role: "dialog",
      "aria-modal": "true",
      "aria-label": label,
      onclick: (event) => {
        if (event.target === overlay) close();
      }
    },
    h(
      "div",
      { class: "lightbox-bar" },
      h("span", { class: "lightbox-title" }, label),
      // No `target="_blank"`: a top-level `data:` navigation is blocked by browsers, and the
      // `download` attribute is what actually saves the file.
      h("a", { class: "link-btn", href: src, download: label }, "Download"),
      closeBtn
    ),
    h("img", { class: "lightbox-img", src, alt: label })
  );

  function onKeydown(event) {
    if (event.key === "Escape") close();
    else if (event.key === "Tab") {
      // Two focusables only; keeping the ring inside them is the whole trap.
      const focusable = overlay.querySelectorAll("a, button");
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
  }

  function close() {
    document.removeEventListener("keydown", onKeydown, true);
    overlay.remove();
    if (previouslyFocused instanceof HTMLElement) previouslyFocused.focus();
  }

  document.addEventListener("keydown", onKeydown, true);
  document.body.appendChild(overlay);
  closeBtn.focus();
}

function formatBytes(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

/** A message the daemon has accepted but Pi has not yet written into the session file. */
function renderPendingMessage(entry, { onRetry, onDismiss }) {
  const failed = entry.status === "failed";
  return h(
    "div",
    { class: `msg msg-user msg-pending${failed ? " msg-error" : ""}` },
    h("div", { class: "msg-meta" }, "You"),
    h("div", { class: "bubble" }, entry.text),
    h(
      "div",
      { class: "msg-pending-status", role: "status" },
      failed ? null : h("span", { class: "spinner", "aria-hidden": "true" }),
      h("span", null, statusLabel(entry)),
      failed ? h("button", { class: "link-btn", type: "button", onclick: onRetry }, "Retry") : null,
      failed ? h("button", { class: "link-btn", type: "button", onclick: onDismiss }, "Dismiss") : null
    )
  );
}

function roleLabel(role) {
  return { user: "You", assistant: "Pi", toolResult: "Tool", system: "System" }[role] || role;
}
