import { h } from "../dom.js";
import { api, describeError } from "../api.js";
import { AGENTS } from "../agents.mjs";
import { protectedMutationDisposition } from "../liveSync.mjs";
import {
  scheduleCreationIntents,
  scheduleCreationScope
} from "../scheduleIntent.mjs";
import { buildTrigger, parseDurationToSeconds } from "../trigger.mjs";

const MODES = ["xfast", "fast", "smart", "ultra"];
const TRIGGER_KINDS = [
  { kind: "once", label: "Once" },
  { kind: "interval", label: "Every" },
  { kind: "cron", label: "Cron" },
  { kind: "heartbeat", label: "When idle" }
];

function isoLocalNow(offsetMinutes = 60) {
  const d = new Date(Date.now() + offsetMinutes * 60000);
  d.setSeconds(0, 0);
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}

/** The schedule creation form: target, prompt, one of the four trigger kinds, and policy. */
export function renderScheduleForm(state, actions) {
  let triggerKind = "interval";
  let creationActive = false;

  // --- Target ---
  // Options are populated by `paintThreadOptions`, called both now and from `onStateChange`,
  // because a direct/deep-link visit to this route can arrive before the thread list has
  // finished loading (see the identical fix in newThread.js).
  const targetExisting = h("select", { id: "target-thread" });
  function paintThreadOptions(threads) {
    const previous = targetExisting.value;
    targetExisting.replaceChildren(
      ...threads.map((t) => h("option", { value: t.id }, `${t.name || "Untitled"} \u2014 ${t.folder || t.cwd}`))
    );
    if (previous) targetExisting.value = previous;
  }
  paintThreadOptions(state.threads);
  const targetCwd = h("input", { type: "text", id: "sched-cwd", placeholder: "/Users/you/code/project" });
  const targetNamePattern = h("input", { type: "text", id: "sched-name-pattern", placeholder: "Triage {date}" });
  // Only meaningful for a new-thread target: an existing thread already knows its own agent, and
  // the daemon reads it from that thread at every fire rather than from the schedule.
  const agentSelect = h(
    "select",
    { id: "sched-agent" },
    AGENTS.map((agent) => h("option", { value: agent.id }, agent.label))
  );
  const targetKindButtons = ["existingThread", "newThread"].map((kind, i) =>
    h(
      "button",
      {
        type: "button",
        "aria-pressed": String(i === 0),
        onclick: (e) => {
          targetKindButtons.forEach((b) => b.setAttribute("aria-pressed", String(b === e.currentTarget)));
          paintTarget();
          paintModeVisibility();
        }
      },
      kind === "existingThread" ? "Existing thread" : "New thread"
    )
  );
  const targetBody = h("div");
  function paintTarget() {
    const useExisting = targetKindButtons[0].getAttribute("aria-pressed") === "true";
    targetBody.replaceChildren(
      useExisting
        ? h("div", { class: "field" }, h("label", { for: "target-thread" }, "Thread"), targetExisting)
        : h(
            "div",
            null,
            h("div", { class: "field" }, h("label", { for: "sched-cwd" }, "Working directory"), targetCwd),
            h("div", { class: "field" }, h("label", { for: "sched-name-pattern" }, "Name pattern (optional)"), targetNamePattern),
            h("div", { class: "field" }, h("label", { for: "sched-agent" }, "Agent"), agentSelect)
          )
    );
  }
  paintTarget();

  // --- Trigger ---
  const onceInput = h("input", { type: "datetime-local", id: "trigger-once-input", value: isoLocalNow() });
  const intervalInput = h("input", { type: "text", id: "sched-interval", placeholder: "15m", value: "1h" });
  const cronInput = h("input", { type: "text", id: "sched-cron", placeholder: "0 9 * * 1-5" });
  const cronTz = h("input", { type: "text", id: "sched-cron-tz", value: Intl.DateTimeFormat().resolvedOptions().timeZone });
  const heartbeatInput = h("input", { type: "text", id: "sched-heartbeat", placeholder: "15m", value: "15m" });

  const triggerKindButtons = TRIGGER_KINDS.map((entry, i) =>
    h(
      "button",
      {
        type: "button",
        "aria-pressed": String(i === 1),
        onclick: (e) => {
          triggerKind = entry.kind;
          triggerKindButtons.forEach((b) => b.setAttribute("aria-pressed", String(b === e.currentTarget)));
          paintTrigger();
        }
      },
      entry.label
    )
  );
  const triggerBody = h("div");
  function paintTrigger() {
    const fields = {
      once: () => h("div", { class: "field" }, h("label", { for: "trigger-once-input" }, "Date and time"), onceInput),
      interval: () =>
        h(
          "div",
          { class: "field" },
          h("label", { for: "sched-interval" }, "Repeat every"),
          intervalInput,
          h("div", { class: "field-hint" }, "e.g. 15m, 2h, 1d")
        ),
      cron: () =>
        h(
          "div",
          null,
          h("div", { class: "field" }, h("label", { for: "sched-cron" }, "Cron expression"), cronInput, h("div", { class: "field-hint" }, "5 fields: minute hour day month weekday")),
          h("div", { class: "field" }, h("label", { for: "sched-cron-tz" }, "Time zone"), cronTz)
        ),
      heartbeat: () =>
        h(
          "div",
          { class: "field" },
          h("label", { for: "sched-heartbeat" }, "Check every"),
          heartbeatInput,
          h("div", { class: "field-hint" }, "Only fires while the thread is idle; never stacks runs.")
        )
    };
    triggerBody.replaceChildren(fields[triggerKind]());
  }
  paintTrigger();

  // --- Basics ---
  const nameInput = h("input", { type: "text", id: "sched-name", required: true, placeholder: "Morning triage" });
  const promptInput = h("textarea", { id: "sched-prompt", rows: "3", required: true, placeholder: "Check overnight CI failures and summarise" });
  const modeButtons = MODES.map((mode) =>
    h(
      "button",
      {
        type: "button",
        "aria-pressed": "false",
        "data-mode": mode,
        onclick: (e) => {
          const willSelect = e.currentTarget.getAttribute("aria-pressed") !== "true";
          modeButtons.forEach((b) => b.setAttribute("aria-pressed", String(b === e.currentTarget && willSelect)));
        }
      },
      mode
    )
  );
  const modeField = h(
    "div",
    { class: "field" },
    h("label", null, "Mode (optional)"),
    h("div", { class: "segmented", role: "group", "aria-label": "Mode" }, modeButtons)
  );
  function paintModeVisibility() {
    const useExisting = targetKindButtons[0].getAttribute("aria-pressed") === "true";
    const selected = useExisting
      ? state.threads.find((thread) => thread.id === targetExisting.value)
      : null;
    const agent = useExisting ? selected?.agent : agentSelect.value;
    const supported = agent === "pi";
    modeField.hidden = !supported;
    if (!supported) modeButtons.forEach((button) => button.setAttribute("aria-pressed", "false"));
  }
  targetExisting.addEventListener("change", paintModeVisibility);
  agentSelect.addEventListener("change", paintModeVisibility);

  // --- Advanced policy ---
  const skipIfRunning = h("input", { type: "checkbox", id: "policy-skip", checked: true });
  const timeoutInput = h("input", { type: "text", id: "sched-timeout", placeholder: "1h" });
  // A single visible "Quiet hours" label describes this pair, but a <label for> can only target
  // one control, so each input also gets its own accessible name for screen readers.
  const quietFrom = h("input", { type: "time", "aria-label": "Quiet hours start", value: "" });
  const quietTo = h("input", { type: "time", "aria-label": "Quiet hours end", value: "" });

  const errorBox = h("div", { class: "inline-error", role: "alert", hidden: true });
  const submitBtn = h("button", { class: "btn btn-primary btn-block", type: "submit" }, "Create schedule");
  const retryBtn = h("button", {
    class: "btn btn-primary btn-block", type: "button", hidden: true,
    onclick: () => {
      const pending = scheduleCreationIntents.pending(scheduleCreationScope);
      if (pending?.disposition === "replayable") submitRequest(pending.body);
    }
  }, "Retry saved creation");
  const reviewBtn = h("button", {
    class: "btn btn-block", type: "button", hidden: true,
    onclick: () => actions.navigate("/schedules")
  }, "Review schedule list");
  const pendingStatus = h("div", { class: "banner", role: "status", hidden: true });

  const form = h(
    "form",
    { class: "content-pad", onsubmit: onSubmit },
    h("div", { class: "field" }, h("label", { for: "sched-name" }, "Name"), nameInput),
    h("div", { class: "field" }, h("label", null, "Target"), h("div", { class: "segmented", role: "group", "aria-label": "Target kind" }, targetKindButtons), targetBody),
    h("div", { class: "field" }, h("label", { for: "sched-prompt" }, "Prompt"), promptInput),
    modeField,
    h("div", { class: "field" }, h("label", null, "Trigger"), h("div", { class: "segmented", role: "group", "aria-label": "Trigger kind" }, triggerKindButtons), triggerBody),
    h(
      "details",
      { class: "advanced" },
      h("summary", null, "Advanced"),
      h("div", { class: "checkbox-row" }, skipIfRunning, h("label", { for: "policy-skip" }, "Skip if the thread is already running")),
      h("div", { class: "field" }, h("label", { for: "sched-timeout" }, "Timeout (optional)"), timeoutInput, h("div", { class: "field-hint" }, "e.g. 30m, 1h")),
      h(
        "div",
        { class: "field" },
        h("label", null, "Quiet hours (optional)"),
        h("div", { style: "display:flex; gap:8px;" }, quietFrom, quietTo)
      )
    ),
    errorBox,
    pendingStatus,
    retryBtn,
    reviewBtn,
    submitBtn
  );
  paintModeVisibility();
  syncRecoveryControls();

  async function onSubmit(event) {
    event.preventDefault();
    if (creationActive || scheduleCreationIntents.pending(scheduleCreationScope)) return;
    const name = nameInput.value.trim();
    const prompt = promptInput.value.trim();
    if (!name || !prompt) return;

    const useExisting = targetKindButtons[0].getAttribute("aria-pressed") === "true";
    const target = useExisting
      ? { kind: "existingThread", threadId: targetExisting.value }
      : { kind: "newThread", cwd: targetCwd.value.trim(), namePattern: targetNamePattern.value.trim() || undefined };
    if (useExisting && !target.threadId) return showError("Pick a thread.");
    if (!useExisting && !target.cwd) return showError("Enter a working directory.");

    const triggerResult = buildTrigger(triggerKind, {
      at: onceInput.value,
      every: triggerKind === "heartbeat" ? heartbeatInput.value : intervalInput.value,
      expression: cronInput.value,
      timeZone: cronTz.value
    });
    if (triggerResult.error) return showError(triggerResult.error);

    const policy = { skipIfRunning: skipIfRunning.checked };
    if (timeoutInput.value.trim()) {
      const timeoutSeconds = parseDurationToSeconds(timeoutInput.value);
      if (!timeoutSeconds) return showError("Timeout must look like 30m or 1h.");
      policy.timeoutSeconds = timeoutSeconds;
    }
    if (quietFrom.value && quietTo.value) {
      policy.quietHours = { from: quietFrom.value, to: quietTo.value, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone };
    }

    const mode = modeButtons.find((b) => b.getAttribute("aria-pressed") === "true");

    const request = {
      name,
      enabled: true,
      target,
      prompt,
      mode: mode ? mode.dataset.mode : undefined,
      agent: useExisting ? undefined : agentSelect.value || undefined,
      trigger: triggerResult.trigger,
      policy
    };
    await submitRequest(request);
  }

  async function submitRequest(request) {
    if (creationActive) return;
    creationActive = true;
    syncRecoveryControls();
    let health;
    try {
      health = await api.health();
    } catch (err) {
      showError(`${describeError(err)} Schedule creation was not attempted.`);
      creationActive = false;
      syncRecoveryControls();
      return;
    }
    const replaySafe = health?.scheduleIdempotency === true;
    const reserved = await scheduleCreationIntents.reserve(
      scheduleCreationScope, request, { replayProtected: replaySafe }
    );
    if (!reserved) {
      showError(scheduleCreationIntents.error || "This saved creation request needs review.");
      creationActive = false;
      syncRecoveryControls();
      return;
    }

    errorBox.hidden = true;
    syncRecoveryControls();
    try {
      await actions.createSchedule(
        reserved.replayProtected
          ? { ...reserved.body, idempotencyKey: reserved.clientId }
          : reserved.body
      );
      if (!(await scheduleCreationIntents.complete(
        scheduleCreationScope, reserved.clientId
      ))) {
        throw new Error(scheduleCreationIntents.error || "The saved creation request could not be cleared.");
      }
      actions.navigate("/schedules", { replace: true });
    } catch (err) {
      const disposition = protectedMutationDisposition(err, {
        replaySafe,
        reviewCodes: ["schedule_creation_outcome_unknown", "idempotency_conflict"]
      });
      if (disposition === "reset") {
        await scheduleCreationIntents.complete(scheduleCreationScope, reserved.clientId);
      } else if (disposition === "review") {
        await scheduleCreationIntents.markReview(
          scheduleCreationScope, reserved.clientId, err?.code || "outcome_unknown"
        );
      } else {
        await scheduleCreationIntents.markReplayable(
          scheduleCreationScope, reserved.clientId, err?.code || "retryable_failure"
        );
      }
      showError(disposition === "retry"
        ? `${describeError(err)} Retry uses the same protected creation request.`
        : disposition === "review"
          ? `${describeError(err)} Review the schedule list before trying again.`
          : describeError(err));
    } finally {
      creationActive = false;
      syncRecoveryControls();
    }
  }

  function syncRecoveryControls() {
    const pending = scheduleCreationIntents.pending(scheduleCreationScope);
    const retryable = pending?.disposition === "replayable";
    const needsReview = pending?.disposition === "review";
    const attempting = pending?.disposition === "attempting";
    retryBtn.hidden = !retryable;
    retryBtn.disabled = creationActive;
    reviewBtn.hidden = !needsReview;
    reviewBtn.disabled = creationActive;
    pendingStatus.hidden = !attempting;
    pendingStatus.textContent = attempting
      ? "This schedule creation request is still being attempted in another tab."
      : "";
    submitBtn.disabled = creationActive || !!pending;
    submitBtn.textContent = creationActive ? "Creating\u2026" : "Create schedule";
  }

  function showError(message) {
    errorBox.hidden = false;
    errorBox.textContent = message;
  }

  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h("button", { class: "icon-btn icon-btn-back", type: "button", "aria-label": "Back", onclick: () => actions.navigate("/schedules") }, "\u2039"),
      h("h1", { tabindex: "-1" }, "New schedule")
    ),
    h("div", { class: "scroll" }, form)
  );
  const unsubscribeIntent = scheduleCreationIntents.subscribe(syncRecoveryControls);

  return {
    node,
    dispose: unsubscribeIntent,
    onStateChange: (next) => {
      paintThreadOptions(next.threads);
      paintModeVisibility();
    }
  };
}
