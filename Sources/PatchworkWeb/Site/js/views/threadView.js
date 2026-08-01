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
  resolveDelivery,
  retryModeForSubmissionError,
  statusLabel
} from "../pending.mjs";
import { applyInteractionLoad } from "../interactions.mjs";
import {
  agentLabel, canChangeThinking, canRenameSession, shouldShowAgentBadge
} from "../agents.mjs";
import { findThreadByReference } from "../folders.mjs";
import { imageCache, ImageCacheBusyError } from "../imagecache.mjs";
import { newClientId } from "../clientId.mjs";
import {
  createAdmissionGate,
  createBoundedDisclosureState,
  createRequestGate,
  isActiveRunStatus,
  runPresentationSignature
} from "../liveSync.mjs";
import {
  boundedNextOffset,
  latestPageSignature,
  mergeLatestPage,
  mergeOlderPage,
  scrollTopAfterPrepend
} from "../history.mjs";
import { renderInteraction } from "./interaction.js";
import { draftAfterSharedUpdate, draftAfterSubmit } from "../threadState.mjs";
import {
  activityProgress,
  activitySummary,
  compactionOf,
  durationSeconds,
  formatDuration,
  preserveWorkKeys,
  projectTranscript,
  settledDisclosureKeys
} from "../transcript.mjs";

const MESSAGE_PAGE_SIZE = 50;
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
  const savedViewState = actions.loadThreadViewState?.(threadId) || {
    draft: "", pending: [], pendingSeq: 0, recentRuns: [], notice: null
  };
  let nextMessageOffset = null;
  let loadedOlderPage = false;
  let thread = findThreadByReference(state.threads, threadId);
  let refetchTimer = null;
  let fetchingMessages = false;
  let refetchQueued = false;
  let olderPageQueued = false;
  let renderedCount = 0;
  let loadedOnce = false;
  let lastRunSignature = "";
  let handledThreadEvent = state.lastThreadEvent;
  let handledActivityEvent = state.lastActivityEvent;
  // Only the daemon's bounded newest page is signed. This keeps an identical live poll O(page)
  // even after the reader has loaded the bounded older-history window.
  let paintedLatestPageSignature = null;
  // Explicit open and closed choices, by projection key, so failed steps only start open once and
  // a live activity group settles closed exactly like the native transcript.
  const disclosureStates = createBoundedDisclosureState();
  let renderedMessageNodes = new Map();
  let previousProjectedItems = [];
  let livePollTimer = null;
  let liveClockTimer = null;
  let draftPersistTimer = null;
  let draftGeneration = 0;
  let lastObservedSharedDraft = savedViewState.draft || "";
  // Messages accepted by the daemon but not yet visible in Pi's own session file. See
  // js/pending.mjs for why this exists and how entries are reconciled away.
  let pending = savedViewState.pending;
  let pendingSeq = savedViewState.pendingSeq;
  let viewNotice = savedViewState.notice || null;
  const submissionRetryTimers = new Map();
  let lastMessages = [];
  let lastLatestMessages = [];
  let lastPendingReconciliationSignature = null;
  let interactions = [];
  let fetchingInteractions = false;
  let interactionsQueued = false;
  let interactionRetryTimer = null;
  let interactionAttempt = 0;
  let lastInteraction = null;
  let lastConnection = state.connection;
  let lastAuthoritativeGeneration = state.authoritativeGeneration;
  const messagesGate = createRequestGate();
  const interactionsGate = createRequestGate();
  const runtimeGate = createRequestGate();
  const sendAdmission = createAdmissionGate();
  // The latest state of each recent run, so a run event that beat its own POST response is still
  // applied the moment that response names the run. See `rememberRun` in js/pending.mjs.
  const recentRuns = new Map(savedViewState.recentRuns || []);
  let renderedInteractionCards = new Map();
  let renderedInteractionSignature = null;
  let runtime = null;
  let runtimeLoading = false;
  let runtimeQueued = false;
  let runtimeError = null;
  let runtimeUnavailable = false;
  let disposed = false;
  let closeLightbox = null;
  let unsubscribeViewState = () => {};
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
  const agentEl = h("span", { class: "agent-badge", hidden: true });
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

  const runStatusText = h("span", null, "Agent is working\u2026");
  const runStatus = h(
    "div",
    { class: "run-status", role: "status", hidden: true },
    h("span", { class: "spinner" }),
    runStatusText,
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
      h("div", { class: "thread-header" }, h("div", null, titleBtn, titleInput), h("div", { class: "thread-subhead" }, agentEl, cwdEl)),
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

  textarea.value = savedViewState.draft || "";
  unsubscribeViewState = actions.subscribeThreadViewState?.(threadId, (shared) => {
    if (disposed) return;
    pending = shared.pending;
    pendingSeq = Math.max(pendingSeq, shared.pendingSeq || 0);
    viewNotice = shared.notice || null;
    recentRuns.clear();
    for (const [id, run] of shared.recentRuns || []) recentRuns.set(id, run);
    const reconciledDraft = draftAfterSharedUpdate(
      textarea.value,
      lastObservedSharedDraft,
      shared.draft
    );
    lastObservedSharedDraft = shared.draft;
    if (textarea.value !== reconciledDraft) {
      draftGeneration += 1;
      if (draftPersistTimer) {
        clearTimeout(draftPersistTimer);
        draftPersistTimer = null;
      }
      textarea.value = reconciledDraft;
      refreshComposerLayout();
    }
    paintPending();
  }) || (() => {});
  const initialRun = state.lastRunEvent;
  const initialRunMatches = initialRun?.threadPath
    ? initialRun.threadPath === threadId
    : !!thread && initialRun?.threadId === thread.id
      && state.threads.filter((candidate) => candidate.id === thread.id).length === 1;
  if (initialRun?.id && initialRunMatches) {
    lastRunSignature = runPresentationSignature(initialRun);
    rememberRun(recentRuns, initialRun);
    pending = applyRunEvent(pending, initialRun);
  }
  paintHeader();
  paintSkeleton();
  refreshComposerLayout();
  paintPending();
  if (savedViewState.notice) {
    composerError.hidden = false;
    composerError.textContent = savedViewState.notice;
  }
  loadMessages();
  loadInteractions();
  loadRuntime();
  resumeRestoredPending();
  actions.markRead(threadId);

  function onInput() {
    draftGeneration += 1;
    refreshComposerLayout();
    if (draftPersistTimer) clearTimeout(draftPersistTimer);
    const generation = draftGeneration;
    draftPersistTimer = setTimeout(() => {
      draftPersistTimer = null;
      persistViewState(generation);
    }, 350);
  }

  function refreshComposerLayout() {
    // Height is set from the content and clamped by the stylesheet's max-height, so the growth
    // ceiling stays a layout concern rather than a magic number here.
    textarea.style.height = "auto";
    textarea.style.height = `${textarea.scrollHeight}px`;
    sendBtn.disabled = sendAdmission.active || textarea.value.trim().length === 0;
  }

  function persistViewState(generation = draftGeneration) {
    const draft = textarea.value;
    const notice = viewNotice;
    return actions.updateThreadViewStateAtomic?.(threadId, (shared) => {
      if (generation !== draftGeneration) return null;
      if (shared.draft === draft && shared.notice === notice) return null;
      // Draft writes are deliberately field-level. A whole-view snapshot from this tab could be
      // older than another tab's newly reserved pending send even while both use the same lock.
      return { ...shared, draft, notice };
    }) ?? Promise.resolve(null);
  }

  async function updateSharedPending(updater) {
    let changed = false;
    const updated = await actions.updateThreadViewStateAtomic?.(threadId, (shared) => {
      const next = updater(shared.pending, shared);
      changed = next !== shared.pending;
      return changed ? { ...shared, pending: next } : null;
    });
    if (updated) return true;
    if (!changed) return true;
    // Keep the durable record intact on a lock/storage failure. Mutating only this tab would make
    // a reload forget the protected submission id and could invite a duplicate retry.
    if (!disposed) {
      composerError.hidden = false;
      composerError.textContent = "Message status could not be saved safely. Free browser storage, then reconnect.";
    }
    return false;
  }

  function updateSharedState(updater) {
    return actions.updateThreadViewStateAtomic?.(threadId, updater) ?? Promise.resolve(null);
  }

  function pendingReconciliationSignature(pageSignature) {
    return JSON.stringify([
      pageSignature,
      pending.map((entry) => [
        entry.key, entry.accepted, entry.settled, entry.status, entry.baseline
      ])
    ]);
  }

  function reconcilePendingIfNeeded(pageSignature) {
    const signature = pendingReconciliationSignature(pageSignature);
    if (signature === lastPendingReconciliationSignature) return;
    void updateSharedPending((sharedPending) => {
      const next = reconcile(sharedPending, lastLatestMessages);
      return next.length === sharedPending.length
        && next.every((entry, index) => entry === sharedPending[index])
        ? sharedPending
        : next;
    });
    // The synchronous shared-state notification may have removed an accounted-for entry.
    lastPendingReconciliationSignature = pendingReconciliationSignature(pageSignature);
  }

  function loadRuntime() {
    if (disposed || runtimeUnavailable) return Promise.resolve();
    const request = runtimeGate.begin();
    if (runtimeLoading) {
      runtimeQueued = true;
      return Promise.resolve();
    }
    runtimeLoading = true;
    runtimeError = null;
    paintRuntime();
    return api
      .threadRuntime(threadId)
      .then(({ runtime: fresh }) => {
        if (!disposed && runtimeGate.isCurrent(request)) runtime = fresh;
      })
      .catch((err) => {
        if (disposed || !runtimeGate.isCurrent(request)) return;
        if (err?.status === 404) runtimeUnavailable = true; // older daemon: keep the thread usable
        else runtimeError = describeError(err);
      })
      .finally(() => {
        runtimeLoading = false;
        if (runtimeQueued && !disposed && !runtimeUnavailable) {
          runtimeQueued = false;
          loadRuntime();
          return;
        }
        runtimeQueued = false;
        if (!disposed) paintRuntime();
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
    const generation = runtimeGate.begin();
    runtimeLoading = true;
    runtimeError = null;
    paintRuntime();
    request
      .then(({ runtime: fresh }) => {
        if (!disposed && runtimeGate.isCurrent(generation)) runtime = fresh;
      })
      .catch((err) => {
        if (!disposed && runtimeGate.isCurrent(generation)) runtimeError = describeError(err);
      })
      .finally(() => {
        runtimeLoading = false;
        if (runtimeQueued && !disposed) {
          runtimeQueued = false;
          loadRuntime();
          return;
        }
        if (!disposed) paintRuntime();
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
    const thinkingSupported = canChangeThinking(thread?.agent);
    thinkingSelect.closest("label").hidden = !thinkingSupported;
    thinkingSelect.disabled = !thinkingSupported || runtimeLoading || levels.length === 0;
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
    const composerAtSubmit = textarea.value;
    const text = textarea.value.trim();
    if (!text) return;
    draftGeneration += 1;
    if (draftPersistTimer) {
      clearTimeout(draftPersistTimer);
      draftPersistTimer = null;
    }
    closeMenu(false);
    submit(text, resolveDelivery(delivery, thread?.running === true), undefined, null, {
      composerAtSubmit,
      sharedDraftAtSubmit: lastObservedSharedDraft
    });
  }

  /**
   * `clientId` is generated once per bubble. Transport retries reuse it so the daemon can replay
   * a lost response without prompting twice. Only an explicit terminal pre-prompt failure gets a
   * fresh id, because reusing that id would replay the old failed run forever.
   */
  async function submit(
    text,
    delivery,
    clientId = newClientId(),
    replaceKey = null,
    composerReservation = null
  ) {
    if (!sendAdmission.enter()) return;
    refreshComposerLayout();
    let key = null;
    let rejected = false;
    try {
      const updated = await actions.updateThreadViewStateAtomic?.(threadId, (shared) => {
        const base = replaceKey ? removePending(shared.pending, replaceKey) : shared.pending;
        const nextSequence = Math.max(shared.pendingSeq || 0, pendingSeq) + 1;
        key = `p${nextSequence}`;
        const added = addPending(base, {
          key, text, delivery, clientId, messages: lastLatestMessages
        });
        if (added.rejected) {
          rejected = true;
          return null;
        }
        return {
          ...shared,
          draft: replaceKey || !composerReservation || shared.draft !== composerReservation.sharedDraftAtSubmit
            ? shared.draft
            : "",
          pending: added.list,
          pendingSeq: nextSequence
        };
      });
      if (!updated || !key) {
        composerError.hidden = false;
        composerError.textContent = rejected
          ? "Too many unsent messages. Retry or dismiss one first."
          : "This message could not be saved safely. Free browser storage, then try again.";
        return;
      }
      if (composerReservation) {
        const retainedDraft = draftAfterSubmit(textarea.value, composerReservation.composerAtSubmit);
        if (textarea.value !== retainedDraft) {
          textarea.value = retainedDraft;
          onInput();
        }
      }
      composerError.hidden = true;
      scrollToBottom();

      // Only the send itself may mark the bubble failed. A refetch that fails afterwards is a
      // display problem, not a delivery one, and must never claim a message was not sent.
      sendPending(key, text, delivery, clientId);
    } finally {
      sendAdmission.leave();
      refreshComposerLayout();
    }
  }

  function sendPending(key, text, delivery, clientId, attempt = 0) {
    actions.sendMessage(threadId, { text, delivery, clientId }).then(
      async (response) => {
        await updateSharedPending((sharedPending, shared) => {
          let next = markAccepted(sharedPending, key, {
            runId: response?.runId ?? null,
            queued: response?.queued === true,
            // Older daemons omit `delivery`; assume they did what was asked rather than inventing
            // a downgrade the server never reported.
            delivery: response?.delivery ?? delivery ?? null
          });
          // The bubble only just learned its run id, so any event that arrived for that run while
          // it was still `null` matched nothing. Replay the latest one now.
          const sharedRuns = new Map(shared.recentRuns || []);
          const known = sharedRuns.get(response?.runId) || recentRuns.get(response?.runId);
          if (known) next = applyRunEvent(next, known);
          return next;
        });
        // Confirm the named run after acceptance as well. This covers the narrow case where its
        // point event arrived before the POST response but could not yet match a pending run id.
        refreshPendingRuns();
        if (!disposed) {
          loadMessages();
          loadInteractions();
        }
      },
      async (err) => {
        if (err?.code === "submission_in_flight" && attempt < 5 && !disposed) {
          if (!(await supportsMessageReplay())) {
            await updateSharedPending((sharedPending) => markFailed(
              sharedPending,
              key,
              "The message may still be processing. Review the thread before sending it again.",
              "review"
            ));
            return;
          }
          // The original request still owns this stable client id. Poll the same submission with
          // bounded backoff; never create a new id and never send the prompt a second time.
          void updateSharedPending((sharedPending) => markInFlight(sharedPending, key));
          const timer = setTimeout(() => {
            submissionRetryTimers.delete(timer);
            sendPending(key, text, delivery, clientId, attempt + 1);
          }, Math.min(4000, 250 * 2 ** attempt));
          submissionRetryTimers.set(timer, { key });
        } else {
          const replaySafe = await supportsMessageReplay();
          const retryMode = retryModeForSubmissionError(err, replaySafe);
          const message = disposed && err?.code === "submission_in_flight"
            ? "The message is still being processed. Retry checks the same protected submission."
            : describeError(err);
          void updateSharedPending((sharedPending) => markFailed(sharedPending, key, message, retryMode));
        }
      }
    );
  }

  async function resumeRestoredPending() {
    const restored = (savedViewState.pending || []).filter(
      (entry) => entry.status === "sending" && !entry.accepted && entry.clientId
    );
    const replaySafe = restored.length > 0 && await supportsMessageReplay();
    for (const entry of restored) {
      if (entry.status === "sending" && !entry.accepted && entry.clientId) {
        if (replaySafe) {
          sendPending(entry.key, entry.text, entry.requestedDelivery, entry.clientId);
        } else {
          await updateSharedPending((sharedPending) => markFailed(
            sharedPending,
            entry.key,
            "This restored message may already have been accepted. Review the thread before resending it.",
            "review"
          ));
        }
      }
    }
    refreshPendingRuns();
  }

  async function supportsMessageReplay() {
    return api.health().then(
      (health) => health?.messageSubmissionIdempotency === true,
      () => false
    );
  }

  function refreshPendingRuns() {
    const runIDs = new Set(
      pending
        .filter((entry) => entry.accepted && entry.runId && !entry.settled)
        .map((entry) => entry.runId)
    );
    for (const runID of runIDs) {
      api.run(runID).then(({ run }) => {
        if (!run) return;
        void updateSharedState((shared) => ({
          ...shared,
          pending: applyRunEvent(shared.pending, run)
        }));
      }).catch(() => {
        // A reconnect or the normal SSE stream will try again without changing delivery state.
      });
    }
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
    if (!canRenameSession(thread?.agent)) return;
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
    actions.renameThread(threadId, name)
      .then((updated) => {
        thread = updated;
        paintHeader();
      })
      .catch((err) => {
        composerError.hidden = false;
        composerError.textContent = describeError(err);
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
    if (nextMessageOffset === null) return;
    loadEarlierBtn.disabled = true;
    loadEarlierBtn.textContent = "Loading\u2026";
    loadMessages("older");
  }

  function paintHeader() {
    const name = thread?.name || "Untitled";
    titleBtn.textContent = name;
    scroll.setAttribute("aria-label", name);
    cwdEl.textContent = thread?.cwd || "";
    cwdEl.hidden = !thread?.cwd;
    // Only non-Pi threads carry a badge: Pi is the historical default and labelling every thread
    // would be noise on a machine that only runs Pi.
    agentEl.hidden = !shouldShowAgentBadge(thread?.agent);
    agentEl.textContent = agentLabel(thread?.agent);
    const renameSupported = canRenameSession(thread?.agent);
    titleBtn.disabled = !renameSupported;
    titleBtn.setAttribute(
      "aria-label", renameSupported
        ? "Rename thread"
        : `${agentLabel(thread?.agent)} cannot rename this thread`
    );
    runStatusText.textContent = `${agentLabel(thread?.agent)} is working\u2026`;
    runStatus.hidden = !thread?.running;
    sendBtn.textContent = thread?.running ? "Steer" : "Send";
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

  function loadMessages(kind = "latest") {
    if (kind === "older" && nextMessageOffset === null) return Promise.resolve();
    if (fetchingMessages) {
      if (kind === "older") olderPageQueued = true;
      else refetchQueued = true;
      return Promise.resolve();
    }
    const request = messagesGate.begin();
    fetchingMessages = true;
    const offset = kind === "older" ? nextMessageOffset : 0;
    return api
      .thread(threadId, MESSAGE_PAGE_SIZE, offset)
      .then(({ thread: freshThread, messages, nextOffset }) => {
        if (disposed || !messagesGate.isCurrent(request)) return;
        const pageMessages = Array.isArray(messages) ? messages : [];
        const pageSignature = kind === "latest"
          ? latestPageSignature(pageMessages, freshThread?.running)
          : null;
        if (kind === "latest") lastLatestMessages = pageMessages;
        const unchangedLatest = kind === "latest" && loadedOnce
          && pageSignature === paintedLatestPageSignature;
        const nearBottom = !loadedOnce || isScrolledNearBottom();
        const oldTop = scroll.scrollTop;
        const oldHeight = scroll.scrollHeight;
        thread = freshThread;
        if (kind === "latest") paintedLatestPageSignature = pageSignature;
        if (unchangedLatest) {
          if (!loadedOlderPage) nextMessageOffset = boundedNextOffset(nextOffset);
          paintHeader();
          reconcilePendingIfNeeded(pageSignature);
          loadEarlierBtn.hidden = nextMessageOffset === null;
          loadEarlierBtn.disabled = false;
          loadEarlierBtn.textContent = "Load earlier";
          return;
        }
        if (kind === "older") {
          loadedOlderPage = true;
          lastMessages = mergeOlderPage(lastMessages, pageMessages);
          nextMessageOffset = boundedNextOffset(nextOffset);
        } else {
          // Until the reader explicitly paginates, the daemon's newest page is authoritative.
          // Retaining every row that falls off its front would silently grow a live view to the
          // retained-history cap even though only fifty rows are visible.
          lastMessages = loadedOlderPage
            ? mergeLatestPage(lastMessages, pageMessages)
            : pageMessages;
          if (!loadedOlderPage) nextMessageOffset = boundedNextOffset(nextOffset);
        }
        loadedOnce = true;
        paintHeader();
        const changed = paintMessages(lastMessages, { animateTail: kind === "latest" });
        if (kind === "latest") reconcilePendingIfNeeded(pageSignature);
        loadEarlierBtn.hidden = nextMessageOffset === null;
        loadEarlierBtn.disabled = false;
        loadEarlierBtn.textContent = "Load earlier";
        // A poll that changed nothing must not move the reader, smooth-scroll, or fight a
        // deliberate scroll back through history.
        if (!changed) return;
        if (kind === "older") {
          scroll.scrollTop = scrollTopAfterPrepend(oldTop, oldHeight, scroll.scrollHeight);
        } else if (nearBottom) {
          scrollToBottom(renderedCount ? "smooth" : "auto");
        } else {
          scroll.scrollTop = oldTop;
        }
      })
      .catch((err) => {
        if (disposed || !messagesGate.isCurrent(request)) return;
        if (!loadedOnce) {
          renderedMessageNodes.clear();
          mount(messagesEl, h("div", { class: "inline-error", role: "alert" }, describeError(err)));
          renderedCount = 0;
          paintedLatestPageSignature = null;
        } else {
          composerError.hidden = false;
          composerError.textContent = describeError(err);
        }
      })
      .finally(() => {
        fetchingMessages = false;
        loadEarlierBtn.disabled = false;
        loadEarlierBtn.textContent = "Load earlier";
        if (olderPageQueued) {
          olderPageQueued = false;
          loadMessages("older");
        } else if (refetchQueued) {
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
    renderedMessageNodes.clear();
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
    if (disposed) return;
    syncLive();
    mount(
      pendingEl,
      pending.map((entry) =>
        renderPendingMessage(entry, {
          onRetry: async () => {
            // A lost response reuses the stable id. A terminal run that was definitively stopped
            // before prompt delivery needs a fresh id or the daemon would replay its old failure.
            if (entry.retryMode === "sameSubmission" && !(await supportsMessageReplay())) {
              await updateSharedPending((sharedPending) => markFailed(
                sharedPending,
                entry.key,
                "Replay protection is unavailable. Review the thread before sending this again.",
                "review"
              ));
              return;
            }
            const clientId = entry.retryMode === "newSubmission"
              ? newClientId()
              : entry.clientId || newClientId();
            submit(entry.text, entry.requestedDelivery, clientId, entry.key);
          },
          onReview: async () => {
            const updated = await updateSharedState((shared) => ({
              ...shared,
              draft: shared.draft ? `${entry.text}\n${shared.draft}` : entry.text,
              pending: removePending(shared.pending, entry.key)
            }));
            if (updated) textarea.focus();
          },
          onDismiss: () => {
            void updateSharedState((shared) => ({
              ...shared,
              pending: removePending(shared.pending, entry.key)
            }));
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
    const request = interactionsGate.begin();
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
      if (disposed || !interactionsGate.isCurrent(request)) return;
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
   * Projects the wire messages into the same turns the Mac app shows: one user message, one
   * collapsed work log, then the answer. Identical newest pages are rejected before this function,
   * so it never signs or scans the retained multi-page history twice.
   */
  function paintMessages(messages, { animateTail = true } = {}) {
    if (!messages.length) {
      disclosureStates.clear();
      renderedMessageNodes.clear();
      previousProjectedItems = [];
      mount(messagesEl, h("div", { class: "empty-state" }, h("p", { class: "empty-body" }, "No messages yet. Send the first one below.")));
      renderedCount = 0;
      return true;
    }
    const items = preserveWorkKeys(
      previousProjectedItems,
      projectTranscript(messages, { running: thread?.running === true })
    );
    for (const key of settledDisclosureKeys(previousProjectedItems, items)) disclosureStates.set(key, false);
    previousProjectedItems = items;
    // Only genuinely new trailing rows animate in; a plain refresh of the same turn must not
    // flash the whole transcript.
    const firstNew = animateTail && renderedCount && items.length > renderedCount ? renderedCount : items.length;
    const occurrences = new Map();
    const next = new Map();
    const nodes = items.map((item, index) => {
      const count = occurrences.get(item.key) || 0;
      occurrences.set(item.key, count + 1);
      const key = `${item.key}:${count}`;
      const signature = JSON.stringify(item);
      const existing = renderedMessageNodes.get(key);
      const node = existing?.signature === signature
        ? existing.node
        : renderItem(item, index >= firstNew);
      next.set(key, { signature, node });
      return node;
    });
    patchMessageChildren(messagesEl, nodes);
    disclosureStates.retain(new Set(
      Array.from(messagesEl.querySelectorAll("details[data-disclosure-key]"), (element) =>
        element.getAttribute("data-disclosure-key")
      )
    ));
    renderedMessageNodes = next;
    renderedCount = items.length;
    tickElapsed();
    return true;
  }

  function patchMessageChildren(container, nodes) {
    const current = Array.from(container.children);
    let prefix = 0;
    while (prefix < current.length && prefix < nodes.length && current[prefix] === nodes[prefix]) {
      prefix += 1;
    }
    if (prefix === current.length) {
      container.append(...nodes.slice(prefix));
      return;
    }
    if (prefix === nodes.length) {
      for (let index = current.length - 1; index >= prefix; index -= 1) current[index].remove();
      return;
    }
    const currentSet = new Set(current);
    const replacementsAreNew = nodes.every((node, index) =>
      node === current[index] || !currentSet.has(node)
    );
    if (current.length === nodes.length && replacementsAreNew) {
      for (let index = 0; index < nodes.length; index += 1) {
        if (container.children[index] !== nodes[index]) {
          container.replaceChild(nodes[index], container.children[index]);
        }
      }
      return;
    }
    container.replaceChildren(...nodes);
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
  function disclosure(key, className, summaryChildren, body, initiallyOpen = false) {
    const isOpen = disclosureStates.has(key) ? disclosureStates.get(key) : initiallyOpen;
    const node = h(
      "details",
      {
        class: className,
        open: isOpen,
        "data-disclosure-key": key,
        ontoggle: () => {
          disclosureStates.set(key, node.open);
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
      persistViewState();
      disposed = true;
      messagesGate.invalidate();
      interactionsGate.invalidate();
      runtimeGate.invalidate();
      closeLightbox?.();
      imageObserver?.disconnect();
      if (refetchTimer) clearTimeout(refetchTimer);
      if (interactionRetryTimer) clearTimeout(interactionRetryTimer);
      if (draftPersistTimer) clearTimeout(draftPersistTimer);
      if (livePollTimer) clearInterval(livePollTimer);
      if (liveClockTimer) clearInterval(liveClockTimer);
      for (const [timer, retry] of submissionRetryTimers) {
        clearTimeout(timer);
        void updateSharedPending((sharedPending) => markFailed(
          sharedPending,
          retry.key,
          "The message is still being processed. Retry checks the same protected submission.",
          "sameSubmission"
        ));
      }
      submissionRetryTimers.clear();
      unsubscribeViewState();
    },
    onStateChange(next) {
      if (next.authoritativeGeneration !== lastAuthoritativeGeneration) {
        lastAuthoritativeGeneration = next.authoritativeGeneration;
        interactionAttempt = 0;
        runtimeUnavailable = false;
        loadMessages();
        loadInteractions();
        loadRuntime();
      }

      // A dropped tunnel is exactly when a poll fails and a dialog is answered on the Mac
      // instead. Coming back online re-reads the authoritative list rather than trusting
      // whatever survived the outage.
      if (next.connection === "online" && lastConnection !== "online") {
        interactionAttempt = 0;
        loadInteractions();
        refreshPendingRuns();
      }
      lastConnection = next.connection;

      const run = next.lastRunEvent;
      const runSignature = runPresentationSignature(run);
      const runMatches = run?.threadPath
        ? run.threadPath === threadId
        : !!thread && run?.threadId === thread.id
          && next.threads.filter((candidate) => candidate.id === thread.id).length === 1;
      const pendingRunMatches = !!run?.id && pending.some((entry) => entry.runId === run.id);
      if (run && (runMatches || pendingRunMatches) && runSignature !== lastRunSignature) {
        lastRunSignature = runSignature;
        rememberRun(recentRuns, run);
        // A run event is matched by id as well as by thread: a steer answers with the *live* run,
        // whose `threadId` is already known here, and a brand-new thread's run reports its id
        // before the thread event lands.
        void updateSharedState((shared) => {
          const memo = new Map(shared.recentRuns || []);
          rememberRun(memo, run);
          return {
            ...shared,
            pending: applyRunEvent(shared.pending, run),
            recentRuns: [...memo.entries()]
          };
        });
        // Only patch a thread that has actually loaded. Spreading over `null` used to invent a
        // nameless thread object, which repainted the header as "Untitled" until the next fetch.
        if (runMatches && thread) {
          thread = { ...thread, running: isActiveRunStatus(run.status) };
          paintHeader();
          scheduleRefetch();
        } else if (runMatches) {
          scheduleRefetch();
        }
        if (runMatches && ["ok", "failed", "skipped", "timeout", "interrupted"].includes(run.status)) {
          loadRuntime();
        }
      }

      if (next.lastInteractionEvent && next.lastInteractionEvent !== lastInteraction) {
        lastInteraction = next.lastInteractionEvent;
        loadInteractions();
      }

      if (next.lastActivityEvent !== handledActivityEvent) {
        handledActivityEvent = next.lastActivityEvent;
        const updated = findThreadByReference(next.threads, threadId);
        if (updated && thread?.running !== updated.running) {
          thread = thread ? { ...thread, running: updated.running } : updated;
          paintHeader();
          scheduleRefetch();
        }
      }

      const event = next.lastThreadEvent;
      if (event === handledThreadEvent) return;
      handledThreadEvent = event;
      if (!event || (event.path !== threadId && event.path !== thread?.path)) return;
      const wasUpdatedAt = thread?.updatedAt;
      thread = event;
      paintHeader();
      if (event.updatedAt !== wasUpdatedAt) scheduleRefetch();
    }
  };
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
  const header = [
    item.active ? h("span", { class: "dot dot-green", "aria-hidden": "true" }) : null,
    h("span", { class: "work-headline" }, item.headline),
    elapsed,
    settledDuration,
    item.answerFailed ? h("span", { class: "work-failed" }, "\u00b7 failed") : null
  ];
  const details = item.entries.length
    ? disclosure(
        item.key,
        "work",
        header,
        h("div", { class: "work-body" }, item.entries.map((entry) => renderWorkEntry(entry, threadId, view, disclosure)))
      )
    : h("div", { class: "work work-static", role: "status" }, header);
  // `details`/`summary` announces expanded state on its own; this only names the row, and keeps
  // the live status in the label rather than replacing it with a generic "working".
  const summary = details.querySelector("summary");
  if (summary) summary.setAttribute("aria-label", item.active ? `Agent is working: ${item.headline}` : item.title);
  else details.setAttribute("aria-label", `Agent is working: ${item.headline}`);

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
    message.isError ? h("div", { class: "work-label" }, "Agent error") : null,
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
    h("div", { class: "step-detail" }, detail),
    step.failed
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
function renderPendingMessage(entry, { onRetry, onReview, onDismiss }) {
  const failed = entry.status === "failed";
  const reviewOnly = entry.retryMode === "review";
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
      failed && !reviewOnly ? h("button", { class: "link-btn", type: "button", onclick: onRetry }, "Retry") : null,
      failed && reviewOnly ? h("button", { class: "link-btn", type: "button", onclick: onReview }, "Review") : null,
      failed ? h("button", { class: "link-btn", type: "button", onclick: onDismiss }, "Dismiss") : null
    )
  );
}

function roleLabel(role) {
  return { user: "You", assistant: "Pi", toolResult: "Tool", system: "System" }[role] || role;
}
