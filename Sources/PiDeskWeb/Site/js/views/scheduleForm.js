import { h } from "../dom.js";
import { describeError } from "../api.js";
import { AGENTS } from "../agents.mjs";
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

  // --- Advanced policy ---
  const skipIfRunning = h("input", { type: "checkbox", id: "policy-skip", checked: true });
  const timeoutInput = h("input", { type: "text", id: "sched-timeout", placeholder: "1h" });
  // A single visible "Quiet hours" label describes this pair, but a <label for> can only target
  // one control, so each input also gets its own accessible name for screen readers.
  const quietFrom = h("input", { type: "time", "aria-label": "Quiet hours start", value: "" });
  const quietTo = h("input", { type: "time", "aria-label": "Quiet hours end", value: "" });

  const errorBox = h("div", { class: "inline-error", role: "alert", hidden: true });
  const submitBtn = h("button", { class: "btn btn-primary btn-block", type: "submit" }, "Create schedule");

  const form = h(
    "form",
    { class: "content-pad", onsubmit: onSubmit },
    h("div", { class: "field" }, h("label", { for: "sched-name" }, "Name"), nameInput),
    h("div", { class: "field" }, h("label", null, "Target"), h("div", { class: "segmented", role: "group", "aria-label": "Target kind" }, targetKindButtons), targetBody),
    h("div", { class: "field" }, h("label", { for: "sched-prompt" }, "Prompt"), promptInput),
    h("div", { class: "field" }, h("label", null, "Mode (optional)"), h("div", { class: "segmented", role: "group", "aria-label": "Mode" }, modeButtons)),
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
    submitBtn
  );

  function onSubmit(event) {
    event.preventDefault();
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

    errorBox.hidden = true;
    submitBtn.disabled = true;
    submitBtn.textContent = "Creating\u2026";
    actions
      .createSchedule({
        name,
        enabled: true,
        target,
        prompt,
        mode: mode ? mode.dataset.mode : undefined,
        agent: useExisting ? undefined : agentSelect.value || undefined,
        trigger: triggerResult.trigger,
        policy
      })
      .catch((err) => showError(describeError(err)))
      .finally(() => {
        submitBtn.disabled = false;
        submitBtn.textContent = "Create schedule";
      });
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

  return { node, onStateChange: (next) => paintThreadOptions(next.threads) };
}
