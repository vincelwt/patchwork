import { h, mount } from "../dom.js";
import { api, describeError } from "../api.js";
import { renderMarkdown } from "../markdown.mjs";
import { clockTime } from "../time.mjs";
import {
  addPending,
  announcement,
  applyRunEvent,
  markAccepted,
  markFailed,
  markInFlight,
  reconcile,
  rememberRun,
  removePending,
  statusLabel
} from "../pending.mjs";
import { applyInteractionLoad } from "../interactions.mjs";
import { imageCache, ImageCacheBusyError } from "../imagecache.mjs";
import { renderInteraction } from "./interaction.js";
import {
  activityProgress,
  activitySummary,
  compactionOf,
  durationSeconds,
  formatDuration,
  projectTranscript
} from "../transcript.mjs";

const INITIAL_MESSAGE_COUNT = 50;
const REFRESH_DEBOUNCE_MS = 700;
const NEAR_BOTTOM_PX = 120;
// While the thread is running the SSE `thread` event is only a hint, and a run that writes no
// session-file update for a while would otherwise look frozen. This is the floor on how often a
// running thread re-reads its transcript; it stops entirely once nothing is in flight.
const LIVE_POLL_MS = 2500;

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
  // The exact input `paintMessages` last rendered. A poll that brings back the same transcript
  // must not rebuild the DOM: that would restart animations, drop text selection, and fight the
  // reader's scroll position several times a second.
  let paintedSignature = null;
  // Disclosures the reader opened, by projection key, so a repaint reopens exactly what was open.
  const openDisclosures = new Set();
  let livePollTimer = null;
  let liveClockTimer = null;
  // Messages accepted by the daemon but not yet visible in Pi's own session file. See
  // js/pending.mjs for why this exists and how entries are reconciled away.
  let pending = [];
  let pendingSeq = 0;
  let lastMessages = [];
  let interactions = [];
  let fetchingInteractions = false;
  let interactionsQueued = false;
  let interactionRetryTimer = null;
  let interactionAttempt = 0;
  let lastInteraction = null;
  let lastConnection = state.connection;
  // The latest state of each recent run, so a run event that beat its own POST response is still
  // applied the moment that response names the run. See `rememberRun` in js/pending.mjs.
  const recentRuns = new Map();
  let renderedInteractionCards = new Map();
  let renderedInteractionSignature = null;
  let runtime = null;
  let runtimeLoading = false;
  let runtimeError = null;
  let runtimeUnavailable = false;
  let disposed = false;
  let closeLightbox = null;
  // One observer for every thumbnail on screen: images load when they scroll into view, not all
  // forty at once the moment the transcript paints.
  const imageObserver =
    typeof IntersectionObserver === "function"
      ? new IntersectionObserver(
          (entries, observer) => {
            for (const entry of entries) {
              if (!entry.isIntersecting) continue;
              observer.unobserve(entry.target);
              entry.target.__piLoad?.();
            }
          },
          { rootMargin: "200px" }
        )
      : null;

  const titleBtn = h("button", { class: "thread-title", type: "button", "aria-label": "Rename thread", onclick: onRenameStart });
  const titleInput = h("input", { type: "text", class: "visually-hidden", "aria-hidden": "true", "aria-label": "Thread name" });
  const cwdEl = h("div", { class: "cwd" });
  // A word, not a glyph: "archive" has no icon a reader can be expected to guess, and the label
  // has to say which way the toggle goes.
  const archiveBtn = h("button", { class: "link-btn topbar-action", type: "button", onclick: onToggleArchive }, "Archive");

  // A single persistent live region. Announcing from inside the bubbles themselves does not work:
  // they are replaced wholesale on every repaint, and assistive tech only announces changes to a
  // region that was already in the tree.
  const pendingLive = h("div", { class: "visually-hidden", role: "status", "aria-live": "polite" });
  let lastAnnouncement = "";

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

  const modelSelect = h("select", { "aria-label": "Model", onchange: onModelChange, disabled: true });
  const thinkingSelect = h("select", { "aria-label": "Thinking level", onchange: onThinkingChange, disabled: true });
  const runtimeStatus = h("span", { class: "runtime-status", role: "status", "aria-live": "polite" }, "Loading\u2026");
  const runtimeRetry = h("button", { class: "link-btn", type: "button", hidden: true, onclick: loadRuntime }, "Retry");
  const runtimeControls = h(
    "div",
    { class: "runtime-controls", "aria-label": "Runtime controls" },
    h("label", { class: "runtime-control runtime-model" }, h("span", null, "Model"), modelSelect),
    h("label", { class: "runtime-control runtime-thinking" }, h("span", null, "Thinking"), thinkingSelect),
    runtimeStatus,
    runtimeRetry
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
    pendingLive,
    h(
      "header",
      { class: "topbar" },
      h("button", { class: "icon-btn icon-btn-back", type: "button", "aria-label": "Back to threads", onclick: () => actions.navigate("/") }, "\u2039"),
      h("div", { class: "thread-header" }, h("div", null, titleBtn, titleInput), cwdEl),
      archiveBtn
    ),
    scroll,
    h("div", { class: "composer-dock" }, runtimeControls, runStatus, composerError, composerMenu, composerForm)
  );

  // The bridge images use to reach this screen's lifetime: an observer that stops with the view,
  // and a lightbox this view can close on disposal.
  const imageHost = {
    observeImage(tile) {
      if (!imageObserver || disposed) return false;
      imageObserver.observe(tile);
      return true;
    },
    openLightbox(src, label) {
      if (disposed) return;
      closeLightbox?.();
      closeLightbox = presentLightbox(src, label, node, () => {
        closeLightbox = null;
      });
    }
  };

  paintHeader();
  paintSkeleton();
  loadMessages();
  loadInteractions();
  loadRuntime();
  actions.markRead(threadId);

  function onInput() {
    // Height is set from the content and clamped by the stylesheet's max-height, so the growth
    // ceiling stays a layout concern rather than a magic number here.
    textarea.style.height = "auto";
    textarea.style.height = `${textarea.scrollHeight}px`;
    sendBtn.disabled = textarea.value.trim().length === 0;
  }

  function loadRuntime() {
    if (disposed || runtimeLoading || runtimeUnavailable) return Promise.resolve();
    runtimeLoading = true;
    runtimeError = null;
    paintRuntime();
    return api
      .threadRuntime(threadId)
      .then(({ runtime: fresh }) => {
        if (!disposed) runtime = fresh;
      })
      .catch((err) => {
        if (err?.status === 404) runtimeUnavailable = true; // older daemon: keep the thread usable
        else runtimeError = describeError(err);
      })
      .finally(() => {
        runtimeLoading = false;
        paintRuntime();
      });
  }

  function onModelChange() {
    let selected;
    try {
      selected = JSON.parse(modelSelect.value);
    } catch {
      return paintRuntime();
    }
    updateRuntime(api.setThreadModel(threadId, { provider: selected[0], modelId: selected[1] }));
  }

  function onThinkingChange() {
    updateRuntime(api.setThreadThinking(threadId, { level: thinkingSelect.value }));
  }

  function updateRuntime(request) {
    if (runtimeLoading) return;
    runtimeLoading = true;
    runtimeError = null;
    paintRuntime();
    request
      .then(({ runtime: fresh }) => {
        runtime = fresh;
      })
      .catch((err) => {
        runtimeError = describeError(err);
      })
      .finally(() => {
        runtimeLoading = false;
        paintRuntime();
      });
  }

  function paintRuntime() {
    runtimeControls.hidden = runtimeUnavailable;
    if (runtimeUnavailable) return;

    const models = [...(runtime?.availableModels || [])];
    if (runtime?.provider && runtime?.modelId && !models.some((model) => model.provider === runtime.provider && model.modelId === runtime.modelId)) {
      models.unshift({ provider: runtime.provider, modelId: runtime.modelId, name: runtime.modelName || runtime.modelId });
    }
    modelSelect.replaceChildren(
      ...models.map((model) =>
        h(
          "option",
          { value: JSON.stringify([model.provider, model.modelId]), title: `${model.provider} / ${model.modelId}` },
          `${model.name || model.modelId} \u00b7 ${model.provider}/${model.modelId}`
        )
      )
    );
    if (runtime?.provider && runtime?.modelId) modelSelect.value = JSON.stringify([runtime.provider, runtime.modelId]);

    const levels = [...(runtime?.availableThinkingLevels || [])];
    if (runtime?.thinkingLevel && !levels.includes(runtime.thinkingLevel)) levels.unshift(runtime.thinkingLevel);
    thinkingSelect.replaceChildren(...levels.map((level) => h("option", { value: level }, level.charAt(0).toUpperCase() + level.slice(1))));
    if (runtime?.thinkingLevel) thinkingSelect.value = runtime.thinkingLevel;

    modelSelect.disabled = runtimeLoading || models.length === 0;
    thinkingSelect.disabled = runtimeLoading || levels.length === 0;
    runtimeStatus.textContent = runtimeError || (runtimeLoading ? (runtime ? "Updating\u2026" : "Loading\u2026") : "");
    runtimeStatus.classList.toggle("runtime-failed", !!runtimeError);
    runtimeStatus.title = runtimeError || "";
    runtimeStatus.hidden = !runtimeStatus.textContent;
    runtimeRetry.hidden = !runtimeError;
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

  /**
   * `clientId` is generated once per bubble and reused verbatim on Retry, so the daemon can tell
   * "the response was lost, send me the answer again" from "prompt Pi a second time". Without it,
   * a retry after a dropped response is a duplicate turn.
   */
  function submit(text, delivery, clientId = newClientId()) {
    const key = `p${++pendingSeq}`;
    const added = addPending(pending, { key, text, delivery, clientId, messages: lastMessages });
    if (added.rejected) {
      // Every slot holds a message that was never sent. Give this one back rather than destroy
      // one of them.
      textarea.value = textarea.value ? `${text}\n${textarea.value}` : text;
      onInput();
      composerError.hidden = false;
      composerError.textContent = "Too many unsent messages. Retry or dismiss one first.";
      return;
    }
    pending = added.list;
    paintPending();
    scrollToBottom();

    // Only the send itself may mark the bubble failed. A refetch that fails afterwards is a
    // display problem, not a delivery one, and must never claim a message was not sent.
    actions.sendMessage(threadId, { text, delivery, clientId }).then(
      (response) => {
        pending = markAccepted(pending, key, {
          runId: response?.runId ?? null,
          queued: response?.queued === true,
          // Older daemons omit `delivery`; assume they did what was asked rather than inventing
          // a downgrade the server never reported.
          delivery: response?.delivery ?? delivery ?? null
        });
        // The bubble only just learned its run id, so any event that arrived for that run while
        // it was still `null` matched nothing. Replay the latest one now.
        const known = recentRuns.get(response?.runId);
        if (known) pending = applyRunEvent(pending, known);
        paintPending();
        loadMessages();
        loadInteractions();
      },
      (err) => {
        // The daemon is already handling this exact submission: a retry raced the original. That
        // is the idempotency guard working, not a failure to report.
        pending = err?.code === "submission_in_flight" ? markInFlight(pending, key) : markFailed(pending, key, describeError(err));
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
    archiveBtn.textContent = thread?.archived ? "Unarchive" : "Archive";
    archiveBtn.setAttribute("aria-label", thread?.archived ? "Unarchive thread" : "Archive thread");
    syncLive();
  }

  /**
   * Polling exists only while something is actually in flight — a daemon send, or a run the app
   * or terminal started — and stops the moment the thread settles. One timer, never overlapping
   * fetches, and a second timer that only advances the elapsed clocks already on screen.
   */
  function syncLive() {
    const live = !disposed && (thread?.running === true || pending.some((entry) => entry.status !== "failed"));
    if (live && !livePollTimer) {
      livePollTimer = setInterval(() => {
        // A slow response must not queue a second one behind it.
        if (!fetchingMessages) loadMessages();
      }, LIVE_POLL_MS);
    } else if (!live && livePollTimer) {
      clearInterval(livePollTimer);
      livePollTimer = null;
    }
    if (live && !liveClockTimer) liveClockTimer = setInterval(tickElapsed, 1000);
    else if (!live && liveClockTimer) {
      clearInterval(liveClockTimer);
      liveClockTimer = null;
    }
    tickElapsed();
  }

  /// Text-only updates to the clocks already in the tree, so a running turn never repaints.
  function tickElapsed() {
    for (const el of messagesEl.querySelectorAll(".work-elapsed[data-since]")) {
      const seconds = durationSeconds(el.dataset.since, new Date().toISOString());
      el.textContent = seconds === null ? "" : `\u00b7 ${formatDuration(seconds)}`;
    }
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
        const changed = paintMessages(messages);
        pending = reconcile(pending, messages);
        paintPending();
        loadEarlierBtn.hidden = messages.length < messageLimit;
        loadEarlierBtn.disabled = false;
        loadEarlierBtn.textContent = "Load earlier";
        // A poll that changed nothing must not move the reader, smooth-scroll, or fight a
        // deliberate scroll back through history.
        if (!changed) return;
        if (nearBottom) scrollToBottom(renderedCount ? "smooth" : "auto");
        // Older messages were prepended: hold the reading position instead of jumping.
        else scroll.scrollTop = scroll.scrollHeight - distanceFromBottom;
      })
      .catch((err) => {
        mount(messagesEl, h("div", { class: "inline-error", role: "alert" }, describeError(err)));
        renderedCount = 0;
        paintedSignature = null;
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
    syncLive();
    mount(
      pendingEl,
      pending.map((entry) =>
        renderPendingMessage(entry, {
          onRetry: () => {
            pending = removePending(pending, entry.key);
            // The delivery the reader *asked* for, and the same submission id, so a retry can
            // neither silently downgrade a steer nor duplicate the original.
            submit(entry.text, entry.requestedDelivery, entry.clientId || newClientId());
          },
          onDismiss: () => {
            pending = removePending(pending, entry.key);
            paintPending();
          }
        })
      )
    );
    announcePending();
  }

  /// The newest still-unconfirmed message is the one worth speaking; everything else is noise.
  function announcePending() {
    const newest = pending[pending.length - 1];
    const text = announcement(newest);
    if (text === lastAnnouncement) return;
    lastAnnouncement = text;
    pendingLive.textContent = text;
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
    if (interactionRetryTimer) {
      clearTimeout(interactionRetryTimer);
      interactionRetryTimer = null;
    }
    const settle = (result) => {
      // A failed read is not an empty list. Clearing the cards here would discard an answer
      // half-typed into a dialog Pi is still blocked on, so the last good set stays on screen
      // and a bounded retry chain (plus any reconnect) is what refreshes it.
      const next = applyInteractionLoad(interactions, interactionAttempt, result);
      interactions = next.interactions;
      interactionAttempt = next.attempt;
      paintInteractions();
      if (next.retryInMs === null || disposed) return;
      interactionRetryTimer = setTimeout(() => {
        interactionRetryTimer = null;
        loadInteractions();
      }, next.retryInMs);
    };
    return api
      .interactions(threadId)
      .then((response) => settle({ ok: true, interactions: response?.interactions }))
      // A daemon without the endpoint, or a transient failure: keep showing what was last known
      // good. The thread itself stays usable either way.
      .catch(() => settle({ ok: false }))
      .finally(() => {
        fetchingInteractions = false;
        if (interactionsQueued) {
          interactionsQueued = false;
          loadInteractions();
        }
      });
  }

  // Two guards, because a repaint is destructive in two different ways. An unchanged set does not
  // repaint at all, so a poll cannot steal focus mid-answer; and when the set *does* change, the
  // surviving cards are reused rather than rebuilt, so answering one dialog never wipes the answer
  // half-typed into another.
  function paintInteractions() {
    const signature = interactions.map((interaction) => interaction.id).join("|");
    if (signature === renderedInteractionSignature) return;
    renderedInteractionSignature = signature;

    const wasEmpty = !interactionsEl.childElementCount;
    const next = new Map();
    const nodes = interactions.map((interaction) => {
      const existing = renderedInteractionCards.get(interaction.id);
      const card =
        existing ||
        renderInteraction(interaction, {
          respond: (body) =>
            actions.respondInteraction(interaction.id, body).then(
              () => loadInteractions(),
              (err) => {
                // Expired, already answered, or its run ended: re-read the list so the card
                // disappears instead of sitting there accepting answers nobody is waiting for.
                if (err?.status === 404) loadInteractions();
                throw err;
              }
            ),
          describeError
        });
      next.set(interaction.id, card);
      return card;
    });
    renderedInteractionCards = next;
    mount(interactionsEl, nodes);
    if (wasEmpty && interactions.length) scrollToBottom();
  }

  /**
   * Projects the wire messages into the same turns the Mac app shows — one user message, one
   * collapsed work log, then the answer — and paints them. Returns whether anything changed, so a
   * poll that brought back an identical transcript costs one string comparison and nothing else.
   */
  function paintMessages(messages) {
    const signature = JSON.stringify([messages, thread?.running === true]);
    if (signature === paintedSignature) return false;
    paintedSignature = signature;

    if (!messages.length) {
      mount(messagesEl, h("div", { class: "empty-state" }, h("p", { class: "empty-body" }, "No messages yet. Send the first one below.")));
      renderedCount = 0;
      return true;
    }
    const items = projectTranscript(messages, { running: thread?.running === true });
    // Only genuinely new trailing rows animate in; a plain refresh of the same turn must not
    // flash the whole transcript.
    const firstNew = renderedCount && items.length > renderedCount ? renderedCount : items.length;
    mount(messagesEl, items.map((item, index) => renderItem(item, index >= firstNew)));
    renderedCount = items.length;
    tickElapsed();
    return true;
  }

  function renderItem(item, isNew) {
    return item.kind === "work"
      ? renderWork(item, isNew, threadId, imageHost, disclosure)
      : renderMessage(item.message, isNew, threadId, imageHost, disclosure);
  }

  /**
   * A `details`/`summary` pair — a native disclosure, so keyboard and screen-reader behaviour come
   * from the browser — whose open state is keyed by the projection so a live repaint reopens
   * exactly what the reader had opened.
   */
  function disclosure(key, className, summaryChildren, body) {
    const node = h(
      "details",
      {
        class: className,
        open: openDisclosures.has(key),
        ontoggle: () => {
          if (node.open) openDisclosures.add(key);
          else openDisclosures.delete(key);
        }
      },
      h("summary", { class: `${className}-sum` }, summaryChildren),
      body
    );
    return node;
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
    /// Called by the router before this screen is replaced. Everything owned outside `node` — the
    /// body-level lightbox, its key listener and scroll lock, and the observer watching thumbnails
    /// — has to be undone here, or it outlives the screen that created it.
    dispose() {
      disposed = true;
      closeLightbox?.();
      imageObserver?.disconnect();
      if (refetchTimer) clearTimeout(refetchTimer);
      if (interactionRetryTimer) clearTimeout(interactionRetryTimer);
      if (livePollTimer) clearInterval(livePollTimer);
      if (liveClockTimer) clearInterval(liveClockTimer);
    },
    onStateChange(next) {
      // A dropped tunnel is exactly when a poll fails and a dialog is answered on the Mac
      // instead. Coming back online re-reads the authoritative list rather than trusting
      // whatever survived the outage.
      if (next.connection === "online" && lastConnection !== "online") {
        interactionAttempt = 0;
        loadInteractions();
      }
      lastConnection = next.connection;

      const run = next.lastRunEvent;
      const runSignature = run ? `${run.id}:${run.status}:${run.finishedAt || ""}` : "";
      if (run && runSignature !== lastRunSignature) {
        lastRunSignature = runSignature;
        rememberRun(recentRuns, run);
        // A run event is matched by id as well as by thread: a steer answers with the *live* run,
        // whose `threadId` is already known here, and a brand-new thread's run reports its id
        // before the thread event lands.
        const before = pending;
        pending = applyRunEvent(pending, run);
        if (pending !== before) paintPending();
        // Only patch a thread that has actually loaded. Spreading over `null` used to invent a
        // nameless thread object, which repainted the header as "Untitled" until the next fetch.
        if (run.threadId === threadId && thread) {
          thread = { ...thread, running: run.status === "running" };
          paintHeader();
          scheduleRefetch();
        } else if (run.threadId === threadId) {
          scheduleRefetch();
        }
        if (run.threadId === threadId && ["ok", "failed", "skipped", "timeout", "interrupted"].includes(run.status)) {
          loadRuntime();
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

/** Distinct per bubble, stable across retries of that bubble. */
function newClientId() {
  const random = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  // The daemon accepts letters, numbers, dashes and underscores only.
  return `web-${random}`.replace(/[^a-zA-Z0-9_-]/g, "-").slice(0, 128);
}

function renderMessage(message, isNew, threadId, view, disclosure) {
  // A compaction outside any turn keeps the same quiet treatment it has inside one.
  const compaction = compactionOf(message);
  if (compaction) {
    return h(
      "div",
      { class: `msg msg-system${isNew ? " msg-new" : ""}` },
      renderCompaction(`compaction:${message.id}`, compaction, disclosure)
    );
  }
  const role = ["user", "assistant", "toolResult", "system"].includes(message.role) ? message.role : "system";
  const roleClass = { user: "msg-user", assistant: "msg-assistant", toolResult: "msg-tool", system: "msg-system" }[role];
  const classes = ["msg", roleClass];
  if (message.isError) classes.push("msg-error");
  if (isNew) classes.push("msg-new");
  const bodyClass = role === "user" ? "bubble" : "prose";
  const images = Array.isArray(message.images) ? message.images : [];
  const time = clockTime(message.at);
  const meta = role === "assistant" ? time : [roleLabel(role), time].filter(Boolean).join(" \u00b7 ");
  return h(
    "div",
    { class: classes.join(" ") },
    meta ? h("div", { class: "msg-meta" }, meta) : null,
    message.text ? h("div", { class: bodyClass, html: renderMarkdown(message.text) }) : null,
    images.length ? h("div", { class: "msg-images" }, images.map((image) => renderImage(image, threadId, view))) : null
  );
}

/**
 * One turn's work log: a single quiet row that says what Pi is doing (or how long it took) and
 * opens on demand. Reasoning and narration read as log; tool activity and each individual call
 * are their own nested disclosures, so routine arguments and results are never dumped into the
 * transcript. Images a tool produced stay outside the collapsed row.
 */
function renderWork(item, isNew, threadId, view, disclosure) {
  const elapsed = item.active && item.startedAt ? h("span", { class: "work-elapsed", "data-since": item.startedAt }) : null;
  const settledDuration =
    !item.active && item.showsStatus && item.duration !== null
      ? h("span", { class: "work-elapsed" }, `\u00b7 ${formatDuration(item.duration)}`)
      : null;
  const details = disclosure(
    item.key,
    "work",
    [
      item.active ? h("span", { class: "dot dot-green", "aria-hidden": "true" }) : null,
      h("span", { class: "work-headline" }, item.headline),
      elapsed,
      settledDuration,
      item.answerFailed ? h("span", { class: "work-failed" }, "\u00b7 failed") : null
    ],
    h("div", { class: "work-body" }, item.entries.map((entry) => renderWorkEntry(entry, threadId, view, disclosure)))
  );
  // `details`/`summary` announces expanded state on its own; this only names the row, and keeps
  // the live status in the label rather than replacing it with a generic "working".
  details.querySelector("summary").setAttribute("aria-label", item.active ? `Pi is working: ${item.headline}` : item.title);

  return h(
    "div",
    { class: `msg msg-work${isNew ? " msg-new" : ""}` },
    details,
    item.images.length
      ? h("div", { class: "msg-images" }, item.images.map((image) => renderImage(image, threadId, view)))
      : null
  );
}

function renderWorkEntry(entry, threadId, view, disclosure) {
  if (entry.kind === "thinking") return h("div", { class: "work-think prose", html: renderMarkdown(entry.text) });
  if (entry.kind === "activity") return renderActivity(entry, disclosure);
  if (entry.compaction) return renderCompaction(entry.key, entry.compaction, disclosure);

  const message = entry.message;
  const images = Array.isArray(message.images) ? message.images : [];
  return h(
    "div",
    { class: `work-note${message.isError ? " work-note-error" : ""}` },
    message.isError ? h("div", { class: "work-label" }, "Pi error") : null,
    message.text ? h("div", { class: "prose", html: renderMarkdown(message.text) }) : null,
    images.length ? h("div", { class: "msg-images" }, images.map((image) => renderImage(image, threadId, view))) : null
  );
}

function renderActivity(entry, disclosure) {
  const node = disclosure(
    entry.key,
    "act",
    [
      h("span", { class: "work-headline" }, activitySummary(entry)),
      h("span", { class: "work-count" }, activityProgress(entry))
    ],
    h("div", { class: "act-body" }, entry.steps.map((step) => renderStep(step, entry.active, disclosure)))
  );
  if (entry.steps.some((step) => step.failed)) node.classList.add("act-failed");
  return node;
}

function renderStep(step, isLive, disclosure) {
  // A step left unfinished by a run that ended must not read as still running.
  const status = step.failed ? "failed" : step.complete ? null : isLive ? "running" : "no result";
  const detail = [];
  if (step.arguments) detail.push(h("div", { class: "work-label" }, "Arguments"), h("pre", { class: "tool-text" }, step.arguments));
  const resultText = step.result?.text;
  if (resultText) detail.push(h("div", { class: "work-label" }, "Result"), h("pre", { class: "tool-text" }, resultText));
  if (!detail.length) detail.push(h("div", { class: "work-label" }, step.complete ? "No text result." : "Waiting for a result\u2026"));

  const node = disclosure(
    step.key,
    "step",
    [h("span", { class: "work-headline" }, step.label), status ? h("span", { class: "work-count" }, status) : null],
    h("div", { class: "step-detail" }, detail)
  );
  if (step.failed) node.classList.add("step-failed");
  return node;
}

function renderCompaction(key, compaction, disclosure) {
  if (!compaction.summary) return h("div", { class: "work-compaction-flat" }, compaction.title);
  return disclosure(
    key,
    "work-compaction",
    [h("span", { class: "work-headline" }, compaction.title)],
    h("div", { class: "prose work-compaction-body", html: renderMarkdown(compaction.summary) })
  );
}

/**
 * A responsive thumbnail whose bytes load when it scrolls into view (or on tap, if this browser
 * has no IntersectionObserver), never all at once: forty images at the 1 MB server cap would be a
 * 40 MB burst on a phone tunnel. Decoded results go through a bounded shared LRU, so the
 * transcript's 700ms debounced repaint re-renders from memory instead of refetching.
 *
 * Anything the daemon refused to serve stays visible as a labelled placeholder. `omitted` means
 * "past this view's automatic budget", not "gone", so it offers an explicit Load.
 */
function renderImage(image, threadId, view) {
  const label = image.fileName || "Image";
  const status = image.status || "ok";

  if (status !== "ok" && status !== "omitted") {
    return h(
      "div",
      { class: "img-placeholder", role: "note" },
      h("span", { class: "img-glyph", "aria-hidden": "true" }, "\u25a3"),
      h("span", null, image.note || `${label} is not available here.`)
    );
  }

  const img = h("img", { class: "thumb", alt: label, decoding: "async", hidden: true });
  const caption = h(
    "span",
    { class: "img-loading" },
    status === "omitted" ? `Load ${label}` : `${label} \u00b7 ${formatBytes(image.byteCount)}`
  );
  const tile = h(
    "button",
    { class: "img-tile", type: "button", "aria-label": `Open ${label}`, onclick: onActivate },
    img,
    caption
  );

  const cacheKey = `${threadId}\u0000${image.id}`;
  let loaded = false;

  function load() {
    const cached = imageCache.peek(cacheKey);
    if (cached) {
      show(cached);
      return Promise.resolve(cached);
    }
    caption.textContent = `Loading ${label}\u2026`;
    return imageCache
      .fetch(cacheKey, () =>
        api.threadImage(threadId, image.id).then((payload) => `data:${payload.mimeType || "image/png"};base64,${payload.data}`)
      )
      .then((src) => {
        show(src);
        return src;
      })
      .catch((err) => {
        // A capacity refusal is this view's own doing and says what to do about it; anything
        // else came off the wire and goes through the shared phrasing.
        caption.textContent = err instanceof ImageCacheBusyError ? err.message : describeError(err);
        caption.classList.add("img-failed");
        throw err;
      });
  }

  function show(src) {
    loaded = true;
    img.src = src;
    img.hidden = false;
    caption.remove();
  }

  function onActivate() {
    load()
      .then((src) => view.openLightbox(src, label))
      .catch(() => {});
  }

  // An image beyond the automatic budget waits for a deliberate tap; everything else loads when
  // it comes near the viewport.
  if (status === "ok") {
    tile.__piLoad = () => {
      if (!loaded) load().catch(() => {});
    };
    if (view.observeImage(tile)) {
      // Observed: it will load on approach.
    } else {
      load().catch(() => {});
    }
  }
  return tile;
}

/**
 * A focus-trapped overlay with the full image plus a download link. Dismissed by Escape, by the
 * backdrop, or by the close button — all three, because a phone has no keyboard and a desktop
 * browser has no back gesture.
 *
 * Returns its own close function. The overlay lives on `document.body`, outside the screen that
 * opened it, so the caller owns tearing it down when that screen goes away — otherwise navigating
 * away leaves a full-screen image with a live key listener over the next route.
 */
function presentLightbox(src, label, background, onClosed) {
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

  let closed = false;
  function close() {
    if (closed) return;
    closed = true;
    document.removeEventListener("keydown", onKeydown, true);
    overlay.remove();
    // `aria-modal` alone is not enough on every screen reader, and the scroll lock has to come off
    // whether the overlay was dismissed or torn down with its screen.
    background.removeAttribute("aria-hidden");
    background.removeAttribute("inert");
    document.body.classList.remove("modal-open");
    if (previouslyFocused instanceof HTMLElement && previouslyFocused.isConnected) previouslyFocused.focus();
    onClosed?.();
  }

  document.addEventListener("keydown", onKeydown, true);
  background.setAttribute("aria-hidden", "true");
  background.setAttribute("inert", "");
  document.body.classList.add("modal-open");
  document.body.appendChild(overlay);
  closeBtn.focus();
  return close;
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
      // No `role="status"` here: this node is replaced on every repaint, so it would announce
      // unreliably and duplicate the screen's persistent live region when it did fire.
      { class: "msg-pending-status" },
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
