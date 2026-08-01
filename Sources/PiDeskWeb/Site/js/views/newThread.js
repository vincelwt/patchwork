import { h, mount } from "../dom.js";
import { api, describeError } from "../api.js";
import { AGENTS } from "../agents.mjs";
import { createCreationIntentStore } from "../creationIntent.mjs";
import { threadIdentity } from "../folders.mjs";
import { protectedMutationDisposition } from "../liveSync.mjs";
import {
  PROTECTED_CREATION_REQUIRED_ERROR,
  firstMessagePresentation,
  firstMessageValidationError,
  supportsProtectedThreadCreation
} from "../newThreadContract.mjs";

const MODES = ["xfast", "fast", "smart", "ultra"];
const creationIntent = createCreationIntentStore();

/**
 * There is no "list recent folders" endpoint in docs/daemon-api.md, so "recent working
 * directory" is derived client-side from the `cwd` of already-known threads (most recently
 * updated first) — the picker is "recent, or type any path", which is what the documented
 * contract actually supports.
 */
function recentCwds(threads) {
  const seen = new Set();
  const ordered = [...threads].sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
  const result = [];
  for (const thread of ordered) {
    if (thread.cwd && !seen.has(thread.cwd)) {
      seen.add(thread.cwd);
      result.push(thread.cwd);
    }
  }
  return result.slice(0, 8);
}

function folderName(cwd) {
  const parts = cwd.split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : cwd;
}

export function renderNewThread(state, actions) {
  const retainedIntent = creationIntent.pending();
  const cwdInput = h("input", {
    type: "text",
    name: "cwd",
    id: "new-cwd",
    required: true,
    placeholder: "/Users/you/code/project",
    "aria-describedby": "new-cwd-hint"
  });
  if (retainedIntent?.body.cwd) cwdInput.value = retainedIntent.body.cwd;
  // A dedicated wrapper (not the chips themselves) so `paintChips` can freely replace its
  // contents — including going from "no chips yet" to populated once threads finish loading,
  // which happens on a direct/deep-link visit to this route before the list view has ever run.
  const chipRow = h("div", { class: "chip-row", role: "group", "aria-label": "Recent folders", hidden: true });

  // Existing git checkouts of whatever `cwd` names, so a thread can run in a worktree that is
  // already on the Mac. Read-only: nothing here creates or removes one. A folder that is not a
  // repository, or a daemon without the endpoint, simply hides this field.
  const worktreeSelect = h("select", { id: "new-worktree", "aria-describedby": "new-worktree-hint" });
  const worktreeField = h(
    "div",
    { class: "field", hidden: true },
    h("label", { for: "new-worktree" }, "Checkout"),
    worktreeSelect,
    h("div", { class: "field-hint", id: "new-worktree-hint" }, "Run in the main checkout or an existing worktree.")
  );
  let worktreeRequest = 0;

  function loadWorktrees() {
    const cwd = cwdInput.value.trim();
    const request = ++worktreeRequest;
    // Choices from the previous folder must not remain selectable while this lookup is in
    // flight. In particular, submitting immediately after editing `cwd` must use the typed path.
    worktreeField.hidden = true;
    if (!cwd) return;
    actions
      .worktrees(cwd)
      .then((response) => {
        // A slower answer for a folder the user has since changed must not repopulate the menu.
        if (request !== worktreeRequest) return;
        const worktrees = response?.worktrees || [];
        // One checkout is not a choice; the plain `cwd` field already covers it.
        worktreeField.hidden = worktrees.length < 2;
        // The typed path is always an option and always the preselected one. Without it, typing a
        // subdirectory of a repository would silently start the thread in the checkout root
        // instead. This menu picks a checkout; it never overrides what was asked for.
        const options = worktrees.some((worktree) => worktree.path === cwd)
          ? worktrees
          : [{ path: cwd, name: folderName(cwd) }, ...worktrees];
        mount(
          worktreeSelect,
          options.map((worktree) =>
            h("option", { value: worktree.path }, [worktree.name, worktree.branch, worktree.isMain ? "main checkout" : null]
              .filter(Boolean)
              .join(" \u00b7 "))
          )
        );
        worktreeSelect.value = cwd;
      })
      // Purely an aid: an older daemon or an unreadable repository leaves the typed path alone
      // rather than blocking thread creation with an error.
      .catch(() => {
        if (request === worktreeRequest) worktreeField.hidden = true;
      });
  }

  function paintChips(threads) {
    const recents = recentCwds(threads);
    chipRow.hidden = recents.length === 0;
    const chips = recents.map((cwd) =>
      h(
        "button",
        {
          type: "button",
          class: "chip",
          "aria-pressed": String(cwd === cwdInput.value),
          onclick: (event) => {
            cwdInput.value = cwd;
            chipRow.querySelectorAll(".chip").forEach((chip) => chip.setAttribute("aria-pressed", String(chip === event.currentTarget)));
            loadWorktrees();
          }
        },
        folderName(cwd)
      )
    );
    chipRow.replaceChildren(...chips);
    // Only pre-fill the most-recent folder while the field is still untouched, so data arriving
    // late never clobbers something the user already typed.
    if (!cwdInput.value && recents[0]) {
      cwdInput.value = recents[0];
      loadWorktrees();
    }
  }
  paintChips(state.threads);
  // Hide stale choices as soon as the path changes, but only run Git once the field is committed.
  cwdInput.addEventListener("input", () => {
    worktreeRequest += 1;
    worktreeField.hidden = true;
  });
  cwdInput.addEventListener("change", loadWorktrees);

  const modeButtons = MODES.map((mode) =>
    h(
      "button",
      {
        type: "button",
        "aria-pressed": "false",
        "data-mode": mode,
        onclick: (event) => {
          const willSelect = event.currentTarget.getAttribute("aria-pressed") !== "true";
          modeButtons.forEach((btn) => btn.setAttribute("aria-pressed", String(btn === event.currentTarget && willSelect)));
        }
      },
      mode
    )
  );

  // A plain select: the daemon validates the value and says plainly when it cannot drive an
  // agent, so this never has to know which agents are installed on the Mac.
  const agentSelect = h(
    "select",
    { id: "new-agent" },
    AGENTS.map((agent) => h("option", { value: agent.id }, agent.label))
  );
  const modeField = h(
    "div",
    { class: "field" },
    h("label", null, "Mode (optional)"),
    h("div", { class: "segmented", role: "group", "aria-label": "Mode" }, modeButtons)
  );
  function syncModeVisibility() {
    const supported = agentSelect.value === "pi";
    modeField.hidden = !supported;
    if (!supported) {
      modeButtons.forEach((button) => button.setAttribute("aria-pressed", "false"));
    }
  }
  const nameInput = h("input", { id: "new-name", type: "text", name: "name", placeholder: "Untitled", autocomplete: "off" });
  const messageInput = h("textarea", {
    id: "new-message",
    name: "message",
    rows: "3",
    "aria-describedby": "new-message-hint"
  });
  const messageLabel = h("label", { for: "new-message" });
  const messageHint = h("div", { class: "field-hint", id: "new-message-hint" });
  function syncFirstMessageRequirement() {
    const presentation = firstMessagePresentation(agentSelect.value);
    messageLabel.textContent = presentation.label;
    messageHint.textContent = presentation.hint;
    messageInput.placeholder = presentation.placeholder;
    messageInput.toggleAttribute("required", presentation.required);
    messageInput.setAttribute("aria-required", String(presentation.required));
    if (!presentation.required) messageInput.removeAttribute("aria-invalid");
  }
  agentSelect.addEventListener("change", () => {
    syncModeVisibility();
    syncFirstMessageRequirement();
  });
  nameInput.value = retainedIntent?.body.name || "";
  messageInput.value = retainedIntent?.body.message || "";
  agentSelect.value = retainedIntent?.body.agent || "pi";
  if (retainedIntent?.body.mode) {
    modeButtons.forEach((button) => button.setAttribute(
      "aria-pressed", String(button.dataset.mode === retainedIntent.body.mode)
    ));
  }
  syncModeVisibility();
  syncFirstMessageRequirement();
  if (retainedIntent?.body.cwd) loadWorktrees();
  const errorBox = h("div", { class: "inline-error", role: "alert", hidden: true });
  function showFirstMessageError(message) {
    errorBox.hidden = false;
    errorBox.dataset.validation = "first-message";
    errorBox.textContent = message;
    messageInput.setAttribute("aria-invalid", "true");
    messageInput.focus();
  }
  function clearFirstMessageErrorIfResolved() {
    if (firstMessageValidationError(agentSelect.value, messageInput.value)) return;
    messageInput.removeAttribute("aria-invalid");
    if (errorBox.dataset.validation === "first-message") {
      delete errorBox.dataset.validation;
      errorBox.hidden = true;
      errorBox.textContent = "";
    }
  }
  messageInput.addEventListener("input", clearFirstMessageErrorIfResolved);
  agentSelect.addEventListener("change", clearFirstMessageErrorIfResolved);
  messageInput.addEventListener("invalid", (event) => {
    const validationError = firstMessageValidationError(agentSelect.value, messageInput.value);
    if (!validationError) return;
    event.preventDefault();
    showFirstMessageError(validationError);
  });
  const reviewIntent = h("button", {
    class: "btn", type: "button", hidden: true,
    onclick: async () => {
      await actions.refreshThreads?.();
      actions.navigate("/");
    }
  }, "Review threads");
  const resetIntent = h("button", {
    class: "btn", type: "button", hidden: true,
    onclick: async () => {
      if (await creationIntent.abandon()) {
        syncRecoveryControls(null);
        errorBox.hidden = true;
      }
    }
  }, "Reset after review");
  const openCreatedThread = h("button", {
    class: "btn", type: "button", hidden: true
  }, "Open created thread");
  const submit = h("button", { class: "btn btn-primary btn-block", type: "submit" }, "Create thread");

  function syncRecoveryControls(pendingIntent = creationIntent.pending()) {
    const reviewOnly = pendingIntent?.expired || pendingIntent?.disposition === "review";
    const attempting = pendingIntent?.disposition === "attempting";
    reviewIntent.hidden = !reviewOnly;
    resetIntent.hidden = !reviewOnly;
    submit.disabled = Boolean(reviewOnly || attempting);
  }

  if (retainedIntent) {
    errorBox.hidden = false;
    errorBox.textContent = retainedIntent.disposition === "attempting"
      ? "This thread creation request is still being attempted in another tab."
      : retainedIntent.expired || retainedIntent.disposition === "review"
      ? "This unresolved request is review-only. Review the thread list, then reset it before creating another thread."
      : "An unresolved thread request was restored. Retrying unchanged uses the same protected request.";
  }
  syncRecoveryControls(retainedIntent);

  const form = h(
    "form",
    {
      class: "content-pad",
      onsubmit: async (event) => {
        event.preventDefault();
        // The selected checkout *is* the working directory Pi runs in, so the daemon needs no
        // separate field: it already validates that `cwd` exists.
        const cwd = (worktreeField.hidden ? "" : worktreeSelect.value) || cwdInput.value.trim();
        if (!cwd) return;
        const mode = modeButtons.find((btn) => btn.getAttribute("aria-pressed") === "true");
        const message = messageInput.value.trim();
        const validationError = firstMessageValidationError(agentSelect.value, message);
        if (validationError) {
          showFirstMessageError(validationError);
          return;
        }
        messageInput.removeAttribute("aria-invalid");
        delete errorBox.dataset.validation;
        errorBox.hidden = true;
        submit.disabled = true;
        submit.textContent = "Creating\u2026";
        let intent;
        const replayProtected = true;
        try {
          const health = await api.health();
          if (!supportsProtectedThreadCreation(health)) {
            errorBox.hidden = false;
            errorBox.textContent = PROTECTED_CREATION_REQUIRED_ERROR;
            syncRecoveryControls();
            submit.textContent = "Create thread";
            return;
          }
          intent = await creationIntent.begin({
              cwd,
              name: nameInput.value.trim() || undefined,
              message: message || undefined,
              mode: mode ? mode.dataset.mode : undefined,
              agent: agentSelect.value || undefined,
              desktopManaged: true
            }, { replayProtected: true });
        } catch (err) {
          errorBox.hidden = false;
          errorBox.textContent = `${describeError(err)} Thread creation was not attempted.`;
          syncRecoveryControls();
          submit.textContent = "Create thread";
          return;
        }
        if (!intent) {
          errorBox.hidden = false;
          errorBox.textContent = creationIntent.error
            || "This thread request could not be saved safely. Free browser storage and try again.";
          syncRecoveryControls();
          submit.textContent = "Create thread";
          return;
        }
        try {
          const created = await actions.createThread(intent.body);
          await creationIntent.complete(intent.clientId);
          syncRecoveryControls(null);
          if (created?.firstMessageRecoveryError) {
            errorBox.hidden = false;
            errorBox.textContent = created.firstMessageRecoveryError;
            openCreatedThread.hidden = false;
            openCreatedThread.onclick = () => actions.navigate(
              `/thread/${encodeURIComponent(threadIdentity(created))}`
            );
          }
        } catch (err) {
          errorBox.hidden = false;
          const disposition = protectedMutationDisposition(err, {
            replaySafe: replayProtected,
            reviewCodes: ["creation_outcome_unknown", "creation_id_conflict"]
          });
          if (disposition === "review") {
            await creationIntent.markReview(intent.clientId);
            errorBox.textContent = `${describeError(err)} Review the thread list before creating another thread.`;
          } else if (disposition === "reset") {
            await creationIntent.complete(intent.clientId);
            errorBox.textContent = describeError(err);
          } else {
            await creationIntent.markReplayable(intent.clientId);
            errorBox.textContent = `${describeError(err)} Retry uses the same protected creation request.`;
          }
          syncRecoveryControls();
        } finally {
          syncRecoveryControls();
          submit.textContent = "Create thread";
        }
      }
    },
    h(
      "div",
      { class: "field" },
      h("label", { for: "new-cwd" }, "Working directory"),
      chipRow,
      cwdInput,
      h("div", { class: "field-hint", id: "new-cwd-hint" }, "Pick a recent folder or type any path on the Mac.")
    ),
    worktreeField,
    h("div", { class: "field" }, h("label", { for: "new-agent" }, "Agent"), agentSelect),
    h("div", { class: "field" }, h("label", { for: "new-name" }, "Name (optional)"), nameInput),
    modeField,
    h("div", { class: "field" }, messageLabel, messageInput, messageHint),
    errorBox,
    h("div", { class: "form-actions" }, reviewIntent, resetIntent, openCreatedThread),
    submit
  );

  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h("button", { class: "icon-btn icon-btn-back", type: "button", "aria-label": "Back", onclick: () => actions.navigate("/") }, "\u2039"),
      h("h1", { tabindex: "-1" }, "New thread")
    ),
    h("div", { class: "scroll" }, form)
  );

  const unsubscribeIntent = creationIntent.subscribe(() => syncRecoveryControls());
  return {
    node,
    dispose: unsubscribeIntent,
    onStateChange: (next) => paintChips(next.threads)
  };
}
