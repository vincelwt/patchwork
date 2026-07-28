import { h, mount } from "../dom.js";
import { api, describeError } from "../api.js";
import { triggerSummary } from "../trigger.mjs";
import { relativeTime } from "../time.mjs";

/** The Schedules tab: list + live updates, same "repaint the body only" pattern as threadList. */
export function renderSchedules(state, actions) {
  const listBody = h("div", { id: "schedule-list-body" });
  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h("h1", { tabindex: "-1" }, "Schedules"),
      h("button", { class: "icon-btn", type: "button", "aria-label": "Refresh schedules", onclick: () => actions.refreshSchedules() }, "\u21bb"),
      h("button", { class: "icon-btn", type: "button", "aria-label": "New schedule", onclick: () => actions.navigate("/schedules/new") }, "+")
    ),
    h("div", { class: "scroll" }, listBody)
  );

  paint(listBody, state, actions);
  actions.refreshSchedules();

  return { node, onStateChange: (next) => paint(listBody, next, actions) };
}

function paint(container, state, actions) {
  // Same rule as the thread list: a failed refresh never wipes a list that is already on screen.
  container.setAttribute("aria-busy", String(state.schedulesLoading));
  if (state.schedulesError && !state.schedules.length) {
    mount(
      container,
      h(
        "div",
        { class: "error-block" },
        h("div", { class: "inline-error", role: "alert" }, state.schedulesError),
        h("button", { class: "btn", type: "button", onclick: () => actions.refreshSchedules() }, "Try again")
      )
    );
    return;
  }
  if (!state.schedules.length) {
    mount(
      container,
      state.schedulesLoading
        ? Array.from({ length: 4 }, () =>
            h(
              "div",
              { class: "skeleton-row", "aria-hidden": "true" },
              h("div", { class: "skeleton skeleton-title" }),
              h("div", { class: "skeleton skeleton-sub" })
            )
          )
        : h(
            "div",
            { class: "empty-state" },
            h("div", { class: "empty-glyph", "aria-hidden": "true" }, "\u23f0"),
            h("p", { class: "empty-title" }, "No schedules yet"),
            h("p", { class: "empty-body" }, "Schedule a prompt to run once, on a timer, or when Pi goes idle."),
            h("button", { class: "btn btn-primary", type: "button", onclick: () => actions.navigate("/schedules/new") }, "New schedule")
          )
    );
    return;
  }
  mount(container, [
    state.schedulesError ? h("div", { class: "banner banner-error", role: "status" }, state.schedulesError) : null,
    ...state.schedules.map((schedule) => renderRow(schedule, actions))
  ]);
}

function renderRow(schedule, actions) {
  return h(
    "button",
    {
      class: "row",
      type: "button",
      "aria-label": [schedule.name, triggerSummary(schedule.trigger), schedule.enabled ? null : "paused"].filter(Boolean).join(", "),
      onclick: () => actions.navigate(`/schedules/${encodeURIComponent(schedule.id)}`)
    },
    h(
      "div",
      { class: "row-main", "aria-hidden": "true" },
      h(
        "div",
        { class: "row-title-line" },
        h("span", { class: `dot ${schedule.enabled ? "" : "dot-paused"}`.trim(), "aria-hidden": "true" }),
        h("span", { class: "row-title" }, schedule.name),
        schedule.nextRunAt ? h("span", { class: "row-time" }, relativeTime(schedule.nextRunAt)) : null
      ),
      h("div", { class: "row-sub" }, `${triggerSummary(schedule.trigger)}${schedule.enabled ? "" : " \u00b7 paused"}`)
    )
  );
}

/** Schedule detail: full info, recent runs, pause/resume/run-now/delete — see docs/daemon-api.md. */
export function renderScheduleDetail(state, actions, scheduleId) {
  const titleEl = h("h1", { tabindex: "-1" }, "Schedule");
  const body = h("div", { class: "content-pad" });
  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h(
        "button",
        { class: "icon-btn icon-btn-back", type: "button", "aria-label": "Back to schedules", onclick: () => actions.navigate("/schedules") },
        "\u2039"
      ),
      titleEl
    ),
    h("div", { class: "scroll" }, body)
  );

  let schedule = null;
  let runs = [];

  load();

  function load() {
    return api
      .schedule(scheduleId)
      .then(({ schedule: fresh, runs: freshRuns }) => {
        schedule = fresh;
        runs = freshRuns || [];
        titleEl.textContent = schedule.name;
        paint();
      })
      .catch((err) => {
        mount(body, h("div", { class: "inline-error", role: "alert" }, describeError(err)));
      });
  }

  function paint() {
    const pauseBtn = h(
      "button",
      { class: "btn btn-block", type: "button", onclick: onPause },
      schedule.enabled ? "Pause" : "Resume"
    );
    const runBtn = h("button", { class: "btn btn-block", type: "button", onclick: onRunNow }, "Run now");
    const deleteBtn = h("button", { class: "btn btn-block btn-danger", type: "button", onclick: onDelete }, "Delete");

    mount(body, [
      h("div", { class: "field" }, h("label", null, "Trigger"), h("p", null, triggerSummary(schedule.trigger))),
      h("div", { class: "field" }, h("label", null, "Target"), h("p", null, describeTarget(schedule.target))),
      h("div", { class: "field" }, h("label", null, "Prompt"), h("p", null, schedule.prompt)),
      schedule.lastRunAt
        ? h(
            "div",
            { class: "field" },
            h("label", null, "Last run"),
            h("p", { class: `status-${schedule.lastStatus || ""}` }, `${schedule.lastStatus || "unknown"} \u00b7 ${relativeTime(schedule.lastRunAt)}`)
          )
        : null,
      schedule.nextRunAt ? h("div", { class: "field" }, h("label", null, "Next run"), h("p", null, relativeTime(schedule.nextRunAt))) : null,
      h("div", { class: "field" }, pauseBtn),
      h("div", { class: "field" }, runBtn),
      h("div", { class: "field" }, deleteBtn),
      runs.length
        ? h(
            "div",
            { class: "field" },
            h("label", null, "Recent runs"),
            h("div", { class: "runs-list" }, runs.map(renderRun))
          )
        : null
    ]);
  }

  function onPause() {
    actions.pauseSchedule(scheduleId, schedule.enabled).then(load);
  }
  function onRunNow() {
    actions.runScheduleNow(scheduleId).then(() => window.setTimeout(load, 500));
  }
  function onDelete() {
    if (!window.confirm(`Delete "${schedule.name}"? This cannot be undone.`)) return;
    actions.deleteSchedule(scheduleId).then(() => actions.navigate("/schedules", { replace: true }));
  }

  return {
    node,
    onStateChange(next) {
      const scheduleHit = next.lastScheduleEvent && next.lastScheduleEvent.id === scheduleId;
      const runHit = next.lastRunEvent && next.lastRunEvent.scheduleId === scheduleId;
      if (scheduleHit || runHit) load();
    }
  };
}

function renderRun(run) {
  return h(
    "div",
    { class: "run-row" },
    h("span", { class: `status-${run.status}` }, run.status),
    h("span", null, relativeTime(run.startedAt))
  );
}

function describeTarget(target) {
  if (!target) return "";
  if (target.kind === "existingThread") return `Existing thread \u2022 ${target.threadId}`;
  if (target.kind === "newThread") return `New thread in ${target.cwd}${target.namePattern ? ` \u2014 "${target.namePattern}"` : ""}`;
  return target.kind || "Unknown target";
}
