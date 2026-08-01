import { h, mount } from "../dom.js";
import { api, describeError } from "../api.js";
import {
  createRequestGate,
  protectedMutationDisposition
} from "../liveSync.mjs";
import {
  scheduleCreationIntents,
  scheduleCreationScope,
  scheduleRunIntents
} from "../scheduleIntent.mjs";
import { triggerSummary } from "../trigger.mjs";
import { relativeTime } from "../time.mjs";

/** The Schedules tab: list + live updates, same "repaint the body only" pattern as threadList. */
export function renderSchedules(state, actions) {
  let latestState = state;
  let disposed = false;
  let reviewedSchedules = null;
  let creationReviewReadyID = null;
  let creationReviewActive = false;
  let creationReviewError = null;
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

  function repaint() {
    if (disposed) return;
    const visibleState = reviewedSchedules
      ? { ...latestState, schedules: reviewedSchedules, schedulesLoading: false, schedulesError: null }
      : latestState;
    paint(listBody, visibleState, actions, {
      readyID: creationReviewReadyID,
      active: creationReviewActive,
      error: creationReviewError,
      refresh: refreshCreationReview,
      acknowledge: acknowledgeCreationReview
    });
  }

  async function refreshCreationReview(clientID) {
    if (creationReviewActive) return;
    creationReviewActive = true;
    creationReviewError = null;
    creationReviewReadyID = null;
    repaint();
    try {
      const response = await api.schedules();
      if (disposed) return;
      const pending = scheduleCreationIntents.pending(scheduleCreationScope);
      if (pending?.clientId !== clientID || pending.disposition !== "review") return;
      reviewedSchedules = Array.isArray(response?.schedules) ? response.schedules : [];
      creationReviewReadyID = clientID;
    } catch (err) {
      creationReviewError = `${describeError(err)} Review is still required.`;
    } finally {
      creationReviewActive = false;
      repaint();
    }
  }

  async function acknowledgeCreationReview(clientID) {
    if (creationReviewActive || creationReviewReadyID !== clientID) return;
    const pending = scheduleCreationIntents.pending(scheduleCreationScope);
    if (pending?.clientId !== clientID || pending.disposition !== "review") return;
    creationReviewActive = true;
    creationReviewError = null;
    repaint();
    try {
      const marked = await scheduleCreationIntents.markReview(
        scheduleCreationScope, clientID, "user_reviewed_schedule_list"
      );
      if (!marked || !(await scheduleCreationIntents.discard(
        scheduleCreationScope, clientID
      ))) {
        throw new Error(scheduleCreationIntents.error || "The saved request could not be cleared.");
      }
      reviewedSchedules = null;
      creationReviewReadyID = null;
      actions.refreshSchedules();
    } catch (err) {
      creationReviewError = `${describeError(err)} Review is still required.`;
    } finally {
      creationReviewActive = false;
      repaint();
    }
  }

  function intentChanged() {
    const pending = scheduleCreationIntents.pending(scheduleCreationScope);
    if (creationReviewReadyID && pending?.clientId !== creationReviewReadyID) {
      reviewedSchedules = null;
      creationReviewReadyID = null;
    }
    repaint();
  }

  repaint();
  actions.refreshSchedules();
  const unsubscribeCreation = scheduleCreationIntents.subscribe(intentChanged);
  const unsubscribeRuns = scheduleRunIntents.subscribe(repaint);

  return {
    node,
    dispose() {
      disposed = true;
      unsubscribeCreation();
      unsubscribeRuns();
    },
    onStateChange(next) {
      latestState = next;
      repaint();
    }
  };
}

function paint(container, state, actions, review) {
  const recovery = renderRecovery(actions, review);
  // Same rule as the thread list: a failed refresh never wipes a list that is already on screen.
  container.setAttribute("aria-busy", String(state.schedulesLoading));
  if (state.schedulesError && !state.schedules.length) {
    mount(
      container,
      [...recovery, h(
        "div",
        { class: "error-block" },
        h("div", { class: "inline-error", role: "alert" }, state.schedulesError),
        h("button", { class: "btn", type: "button", onclick: () => actions.refreshSchedules() }, "Try again")
      )]
    );
    return;
  }
  if (!state.schedules.length) {
    mount(
      container,
      [...recovery, state.schedulesLoading
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
          )]
    );
    return;
  }
  mount(container, [
    ...recovery,
    state.schedulesError ? h("div", { class: "banner banner-error", role: "status" }, state.schedulesError) : null,
    ...state.schedules.map((schedule) => renderRow(schedule, actions))
  ]);
}

function renderRecovery(actions, review) {
  const nodes = [];
  const creation = scheduleCreationIntents.pending(scheduleCreationScope);
  if (creation) {
    const attempting = creation.disposition === "attempting";
    const ready = creation.disposition === "review" && review.readyID === creation.clientId;
    nodes.push(h(
      "div",
      { class: "banner", role: "status" },
      h("p", null, attempting
        ? "A schedule creation request is still being attempted in another tab."
        : creation.disposition === "replayable"
          ? "A schedule creation request is ready to retry safely."
          : ready
            ? "The refreshed schedule list is shown below."
            : "A schedule creation request needs review."),
      creation.disposition === "replayable"
        ? h("button", {
            class: "btn", type: "button", onclick: () => actions.navigate("/schedules/new")
          }, "Open saved creation")
        : creation.disposition === "review"
          ? h("button", {
              class: "btn", type: "button", disabled: review.active,
              onclick: () => ready
                ? review.acknowledge(creation.clientId)
                : review.refresh(creation.clientId)
            }, review.active
              ? "Refreshing\u2026"
              : ready ? "I reviewed these schedules" : "Refresh schedule list")
          : null,
      review.error ? h("div", { class: "inline-error", role: "alert" }, review.error) : null
    ));
  }

  const runs = scheduleRunIntents.list();
  if (runs.length) {
    nodes.push(h(
      "div",
      { class: "banner", role: "status" },
      h("p", null, runs.length === 1
        ? "One manual run request needs attention."
        : `${runs.length} manual run requests need attention.`),
      h("div", { class: "runs-list" }, runs.map((intent) => h(
        "button",
        {
          class: "btn btn-block",
          type: "button",
          onclick: () => actions.navigate(`/schedules/${encodeURIComponent(intent.scope)}`)
        },
        intent.disposition === "attempting"
          ? "Open run in progress"
          : intent.disposition === "replayable" ? "Open saved run" : "Review saved run"
      )))
    ));
  }
  return nodes;
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
  let disposed = false;
  let lastAuthoritativeGeneration = state.authoritativeGeneration;
  let lastScheduleEvent = state.lastScheduleEvent;
  let lastRunEvent = state.lastRunEvent;
  let runError = null;
  let runActive = false;
  let reviewActive = false;
  let runReviewReadyID = null;
  let pauseActive = false;
  let deleteActive = false;
  let refreshTimer = null;
  const detailGate = createRequestGate();
  const unsubscribeRunIntent = scheduleRunIntents.subscribe(() => {
    const pending = scheduleRunIntents.pending(scheduleId);
    if (runReviewReadyID && (pending?.clientId !== runReviewReadyID
        || pending.disposition !== "review")) {
      runReviewReadyID = null;
    }
    if (!disposed && schedule) paint();
  });

  load();

  function load() {
    const request = detailGate.begin();
    return api
      .schedule(scheduleId)
      .then(({ schedule: fresh, runs: freshRuns }) => {
        if (disposed || !detailGate.isCurrent(request)) return false;
        schedule = fresh;
        runs = freshRuns || [];
        titleEl.textContent = schedule.name;
        paint();
        return true;
      })
      .catch(async (err) => {
        if (disposed || !detailGate.isCurrent(request)) return false;
        if (err?.status === 404) {
          const pending = scheduleRunIntents.pending(scheduleId);
          if (pending && !(await scheduleRunIntents.complete(
            scheduleId, pending.clientId
          ))) {
            mount(body, h(
              "div",
              { class: "inline-error", role: "alert" },
              scheduleRunIntents.error
                || "This schedule no longer exists, but its saved run recovery could not be cleared."
            ));
            return false;
          }
          actions.navigate("/schedules", { replace: true });
          return false;
        }
        mount(body, h("div", { class: "inline-error", role: "alert" }, describeError(err)));
        return false;
      });
  }

  function paint() {
    const pendingRun = scheduleRunIntents.pending(scheduleId);
    const runNeedsReview = pendingRun?.disposition === "review";
    const runCanRetry = pendingRun?.disposition === "replayable";
    const runAttempting = pendingRun?.disposition === "attempting";
    const runReviewReady = runNeedsReview && runReviewReadyID === pendingRun.clientId;
    const pauseBtn = h(
      "button",
      {
        class: "btn btn-block", type: "button", onclick: onPause,
        disabled: pauseActive || deleteActive || runActive || reviewActive
      },
      pauseActive ? "Saving\u2026" : schedule.enabled ? "Pause" : "Resume"
    );
    const runBtn = h(
      "button",
      {
        class: "btn btn-block",
        type: "button",
        onclick: onRunNow,
        disabled: runActive || runNeedsReview || runAttempting
          || pauseActive || deleteActive || reviewActive
      },
      runActive
        ? "Starting\u2026"
        : runAttempting ? "Run starting in another tab" : runCanRetry ? "Retry saved run" : "Run now"
    );
    const deleteBtn = h(
      "button",
      {
        class: "btn btn-block btn-danger", type: "button", onclick: onDelete,
        disabled: deleteActive || pauseActive || runActive || reviewActive
      },
      deleteActive ? "Deleting\u2026" : "Delete"
    );
    const reviewRunBtn = runNeedsReview
      ? h(
          "button",
          {
            class: "btn btn-block", type: "button",
            onclick: runReviewReady ? onAcknowledgeRun : onRefreshRunHistory,
            disabled: reviewActive || deleteActive || pauseActive || runActive
          },
          reviewActive
            ? "Refreshing\u2026"
            : runReviewReady ? "I reviewed run history" : "Refresh run history"
        )
      : null;

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
      reviewRunBtn ? h("div", { class: "field" }, reviewRunBtn) : null,
      runError ? h("div", { class: "inline-error", role: "alert" }, runError) : null,
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

  async function onPause() {
    if (pauseActive || deleteActive || !schedule) return;
    pauseActive = true;
    runError = null;
    paint();
    try {
      await actions.pauseSchedule(scheduleId, schedule.enabled);
      await load();
    } catch (err) {
      runError = describeError(err);
    } finally {
      pauseActive = false;
      if (!disposed) paint();
    }
  }

  async function onRunNow() {
    const pending = scheduleRunIntents.pending(scheduleId);
    if (runActive || deleteActive || pending?.disposition === "review"
        || pending?.disposition === "attempting") return;
    runActive = true;
    runError = null;
    paint();
    let health;
    try {
      health = await api.health();
    } catch (err) {
      runError = `${describeError(err)} The run was not started.`;
      runActive = false;
      if (!disposed) paint();
      return;
    }
    const replaySafe = health?.scheduleRunIdempotency === true;
    const reserved = await scheduleRunIntents.reserve(
      scheduleId, { scheduleId }, { replayProtected: replaySafe }
    );
    if (!reserved) {
      runError = scheduleRunIntents.error || "This saved run request needs review.";
      runActive = false;
      if (!disposed) paint();
      return;
    }
    paint();
    try {
      await actions.runScheduleNow(
        scheduleId,
        reserved.replayProtected ? { clientId: reserved.clientId } : {}
      );
      if (!(await scheduleRunIntents.complete(scheduleId, reserved.clientId))) {
        throw new Error(scheduleRunIntents.error || "The saved run request could not be cleared.");
      }
      if (!disposed) paint();
      if (refreshTimer) window.clearTimeout(refreshTimer);
      refreshTimer = window.setTimeout(() => {
        refreshTimer = null;
        if (!disposed) load();
      }, 500);
    } catch (err) {
      const disposition = protectedMutationDisposition(err, {
        replaySafe,
        reviewCodes: ["schedule_run_outcome_unknown", "run_id_conflict"]
      });
      if (disposition === "reset") {
        await scheduleRunIntents.complete(scheduleId, reserved.clientId);
      } else if (disposition === "review") {
        await scheduleRunIntents.markReview(
          scheduleId, reserved.clientId, err?.code || "outcome_unknown"
        );
      } else {
        await scheduleRunIntents.markReplayable(
          scheduleId, reserved.clientId, err?.code || "retryable_failure"
        );
      }
      runError = disposition === "retry"
        ? `${describeError(err)} Retry uses the same protected run request.`
        : disposition === "review"
          ? `${describeError(err)} Review recent runs before trying again.`
          : describeError(err);
    } finally {
      runActive = false;
      if (!disposed) paint();
    }
  }

  async function onRefreshRunHistory() {
    const pending = scheduleRunIntents.pending(scheduleId);
    if (reviewActive || !pending || pending.disposition !== "review") return;
    reviewActive = true;
    runError = "Refreshing authoritative run history\u2026";
    paint();
    try {
      if (!(await load())) {
        runError = "Run history could not be refreshed. Review is still required.";
        return;
      }
      runReviewReadyID = pending.clientId;
      runError = null;
    } catch (err) {
      runError = `${describeError(err)} Review is still required.`;
    } finally {
      reviewActive = false;
      if (!disposed) paint();
    }
  }

  async function onAcknowledgeRun() {
    const pending = scheduleRunIntents.pending(scheduleId);
    if (reviewActive || !pending || pending.disposition !== "review"
        || runReviewReadyID !== pending.clientId) return;
    reviewActive = true;
    paint();
    try {
      if (!(await scheduleRunIntents.markReview(
        scheduleId, pending.clientId, "user_reviewed_run_history"
      )) || !(await scheduleRunIntents.discard(scheduleId, pending.clientId))) {
        throw new Error(scheduleRunIntents.error || "The saved run request could not be cleared.");
      }
      runReviewReadyID = null;
      runError = null;
    } catch (err) {
      runError = `${describeError(err)} Review is still required.`;
    } finally {
      reviewActive = false;
      if (!disposed) paint();
    }
  }

  async function onDelete() {
    if (deleteActive || pauseActive || runActive || !schedule) return;
    if (!window.confirm(`Delete "${schedule.name}"? This cannot be undone.`)) return;
    deleteActive = true;
    runError = null;
    paint();
    try {
      await actions.deleteSchedule(scheduleId);
      const pending = scheduleRunIntents.pending(scheduleId);
      if (pending && !(await scheduleRunIntents.complete(scheduleId, pending.clientId))) {
        throw new Error(
          scheduleRunIntents.error
            || "The schedule was deleted, but its saved run recovery could not be cleared."
        );
      }
      actions.navigate("/schedules", { replace: true });
    } catch (err) {
      runError = describeError(err);
      deleteActive = false;
      if (!disposed) paint();
    }
  }

  return {
    node,
    dispose() {
      disposed = true;
      detailGate.invalidate();
      unsubscribeRunIntent();
      if (refreshTimer) window.clearTimeout(refreshTimer);
    },
    onStateChange(next) {
      if (next.authoritativeGeneration !== lastAuthoritativeGeneration) {
        lastAuthoritativeGeneration = next.authoritativeGeneration;
        runReviewReadyID = null;
        load();
      }

      if (next.lastScheduleEvent && next.lastScheduleEvent !== lastScheduleEvent) {
        lastScheduleEvent = next.lastScheduleEvent;
        if (lastScheduleEvent.id === scheduleId && lastScheduleEvent.deleted) {
          actions.navigate("/schedules", { replace: true });
          return;
        }
        if (lastScheduleEvent.id === scheduleId) {
          runReviewReadyID = null;
          load();
        }
      }
      if (next.lastRunEvent && next.lastRunEvent !== lastRunEvent) {
        lastRunEvent = next.lastRunEvent;
        if (lastRunEvent.scheduleId === scheduleId) {
          runReviewReadyID = null;
          load();
        }
      }
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
