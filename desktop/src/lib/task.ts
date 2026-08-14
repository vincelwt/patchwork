// What a task needs next.
//
// The board has one column per status because a board needs columns, but "Planned" is
// not an instruction. At any moment a task is in exactly one *situation*, and
// each situation has one obvious next move — assign it, start it, answer it,
// look at it, close it. Deriving that in one place means the task page, the
// board card and the inspector all offer the same next move, and none of them
// can quietly disagree about what is going on.

import { isTerminalTaskStatus } from "@client/types";
import type { Member, Question, Run, Task } from "@client/types";
import { dayLabel, timeOfDay } from "./format";

export type Situation =
  | "unassigned"
  | "ready"
  | "queued"
  | "working"
  | "continuing"
  | "asking"
  | "failed"
  | "blocked"
  | "review"
  | "waiting-on-person"
  | "done"
  | "canceled";

export interface NextAction {
  /// What the button says. Imperative, and names the actor where it helps.
  label: string;
  kind:
    | "start"
    | "stop"
    | "answer"
    | "retry"
    | "assign"
    | "approve"
    | "complete"
    | "reopen";
  tone: "primary" | "normal" | "quiet";
}

export interface TaskState {
  situation: Situation;
  /// One line, in plain language, about where this task actually is.
  headline: string;
  detail?: string;
  /// The run to look at first: the newest one still going, or the last one to
  /// have left a mark. Never the only run on the task.
  run?: Run;
  /// Every run still going on this task, oldest first. Agents share a task's
  /// worktree rather than queue behind it, so this is a list.
  activeRuns: Run[];
  /// The agents behind `activeRuns`, one entry each and in the same order.
  agents: Member[];
  question?: Question;
  owner?: Member;
  action?: NextAction;
  /// The secondary move, when there is a sensible one.
  secondary?: NextAction;
}

const ACTIVE_RUN = ["queued", "dispatched", "running", "waiting"];

/// A run nobody is waiting on has finished. Several unfinished runs can belong
/// to one task at the same time.
export function isRunActive(run: Run): boolean {
  return ACTIVE_RUN.includes(run.status);
}

/// A Stop that ends more than one agent's work has to say so before it is
/// pressed, not after.
function stopLabel(live: Run[]): string {
  return live.length > 1 ? "Stop all" : "Stop";
}

export function readTask(
  task: Task,
  members: Member[],
  runs: Record<string, Run>,
  questions: Record<string, Question>,
): TaskState {
  // Oldest first, so an agent keeps its place in the row when another one
  // starts or stops beside it.
  const live = Object.values(runs)
    .filter((run) => run.task_id === task.id && isRunActive(run))
    .sort((a, b) => a.created_at - b.created_at);
  // One face per agent, even when the same agent has two runs on the task.
  const agents: Member[] = [];
  for (const run of live) {
    const agent = members.find((member) => member.id === run.agent_id);
    if (agent && !agents.includes(agent)) agents.push(agent);
  }
  return {
    ...describe(task, members, runs, questions, live, agents),
    activeRuns: live,
    agents,
  };
}

function describe(
  task: Task,
  members: Member[],
  runs: Record<string, Run>,
  questions: Record<string, Question>,
  live: Run[],
  agents: Member[],
): Omit<TaskState, "activeRuns" | "agents"> {
  const owner = members.find((member) => member.id === task.owner_id);
  const ownerIsAgent = owner?.kind === "agent";
  const current = task.current_run_id ? runs[task.current_run_id] : undefined;
  // `current_run_id` is the newest run worth looking at, not the only one on
  // the task: prefer it while it is going, then the newest that still is, and
  // otherwise whatever ran last.
  const run =
    current && isRunActive(current) ? current : (live[live.length - 1] ?? current);
  const question = Object.values(questions).find(
    (candidate) =>
      candidate.status === "open" &&
      (candidate.task_id === task.id ||
        candidate.run_id === run?.id ||
        live.some((entry) => entry.id === candidate.run_id)),
  );

  // Closed work cannot keep asking for attention because of a stale question,
  // run, or review signal left over from before it was closed.
  if (isTerminalTaskStatus(task.status)) {
    const canceled = task.status === "canceled";
    return {
      situation: canceled ? "canceled" : "done",
      headline: canceled ? "Canceled" : "Done",
      detail: !canceled && task.pr_state ? `Pull request #${task.pr_state.number}` : undefined,
      run,
      owner,
      action: { label: "Reopen", kind: "reopen", tone: "quiet" },
    };
  }

  // Something being asked of a person outranks everything else: it is the only
  // state where the task cannot progress without the reader.
  if (question) {
    // Whoever asked, which is not always the agent the task belongs to.
    const asking = members.find((member) => member.id === question.agent_id);
    return {
      situation: "asking",
      headline: `${asking?.display_name ?? owner?.display_name ?? "The agent"} needs an answer`,
      detail: question.headline || question.items[0]?.question,
      run,
      question,
      owner,
      action: { label: "Answer", kind: "answer", tone: "primary" },
      secondary: run
        ? { label: stopLabel(live), kind: "stop", tone: "quiet" }
        : undefined,
    };
  }

  if (live.length > 0 && run) {
    // Queued is only the honest word while none of them has started.
    const queued = live.every(
      (entry) => entry.status === "queued" || entry.status === "dispatched",
    );
    const several = live.length > 1;
    return {
      situation: queued ? "queued" : "working",
      headline: several
        ? `${live.length} agents are ${queued ? "queued" : "working"}`
        : queued
          ? `Waiting for a machine to pick this up`
          : run.headline || `${owner?.display_name ?? "An agent"} is working`,
      detail: several
        ? agents.map((agent) => agent.display_name).join(" · ")
        : queued
          ? `Queued for ${owner?.display_name ?? "an agent"}`
          : undefined,
      run,
      owner,
      action: { label: stopLabel(live), kind: "stop", tone: "normal" },
    };
  }

  if (task.status === "review") {
    return {
      situation: "review",
      headline: task.review_action ? "Waiting for your approval" : "Ready for you to look at",
      detail: task.pr_state
        ? `#${task.pr_state.number} · ${task.pr_state.state.toLowerCase()}`
        : run?.headline,
      run,
      owner,
      action: task.review_action
        ? { label: task.review_action, kind: "approve", tone: "primary" }
        : { label: "Mark done", kind: "complete", tone: "primary" },
      secondary: { label: "Back to planning", kind: "reopen", tone: "quiet" },
    };
  }

  const continuation = task.active_continuation;
  if (continuation) {
    const deadline = `Deadline ${dayLabel(continuation.deadline_at)} at ${timeOfDay(continuation.deadline_at)}`;
    if (continuation.status === "waiting") {
      const next = continuation.next_check_at
        ? `Next check ${dayLabel(continuation.next_check_at)} at ${timeOfDay(continuation.next_check_at)}`
        : undefined;
      return {
        situation: "continuing",
        headline: continuation.summary,
        detail: [next, deadline].filter(Boolean).join(" · "),
        run,
        owner,
      };
    }
    if (continuation.status === "ready") {
      return {
        situation: "continuing",
        headline: "External work is ready; starting a fresh run",
        detail: continuation.summary,
        run,
        owner,
      };
    }
    if (continuation.status === "action_required") {
      return {
        situation: "blocked",
        headline: "Action required",
        detail: continuation.summary,
        run,
        owner,
        action: ownerIsAgent
          ? { label: "Try again", kind: "retry", tone: "primary" }
          : { label: "Assign", kind: "assign", tone: "normal" },
      };
    }
    return {
      situation: "failed",
      headline: "External work failed",
      detail: continuation.summary,
      run,
      owner,
      action: ownerIsAgent
        ? { label: "Try again", kind: "retry", tone: "primary" }
        : { label: "Assign", kind: "assign", tone: "normal" },
    };
  }

  if (run?.status === "failed") {
    return {
      situation: "failed",
      headline: `${owner?.display_name ?? "The run"} stopped on an error`,
      detail: run.error,
      run,
      owner,
      action: ownerIsAgent
        ? { label: "Try again", kind: "retry", tone: "primary" }
        : undefined,
    };
  }

  if (task.status === "blocked") {
    return {
      situation: "blocked",
      headline: "Blocked",
      detail: run?.error ?? "Nothing is moving this forward right now.",
      run,
      owner,
      action: ownerIsAgent
        ? { label: `Try again`, kind: "retry", tone: "primary" }
        : { label: "Assign", kind: "assign", tone: "normal" },
    };
  }

  if (!owner) {
    return {
      situation: "unassigned",
      headline: "Nobody owns this yet",
      detail: "Pick an agent to run it, or a person to carry it.",
      owner,
      action: { label: "Assign and start", kind: "assign", tone: "primary" },
    };
  }

  if (ownerIsAgent) {
    return {
      situation: "ready",
      headline: `Ready for ${owner.display_name}`,
      detail: run ? "Ran before — starting again continues from where it left off." : undefined,
      run,
      owner,
      action: {
        label: run ? `Run ${owner.display_name} again` : `Start ${owner.display_name}`,
        kind: "start",
        tone: "primary",
      },
    };
  }

  return {
    situation: "waiting-on-person",
    headline: `With ${owner.display_name}`,
    run,
    owner,
    action: { label: "Hand to an agent", kind: "assign", tone: "normal" },
    secondary: { label: "Mark done", kind: "complete", tone: "quiet" },
  };
}

/// The rail on the task page. Deliberately four steps, not five: "blocked" is
/// something that happens *to* a step rather than a step of its own.
export const TASK_STEPS = [
  { key: "planned", label: "Planned" },
  { key: "running", label: "In progress" },
  { key: "review", label: "Review" },
  { key: "done", label: "Done" },
] as const;

export function stepIndex(task: Task): number {
  switch (task.status) {
    case "planned":
      return 0;
    case "running":
    case "blocked":
      return 1;
    case "review":
      return 2;
    case "done":
      return 3;
    case "canceled":
      return -1;
  }
}

export function situationTone(situation: Situation): string {
  switch (situation) {
    case "working":
    case "continuing":
    case "queued":
      return "accent";
    case "asking":
      return "caution";
    case "failed":
    case "blocked":
      return "danger";
    case "review":
      return "caution";
    case "done":
      return "positive";
    case "canceled":
      return "";
    default:
      return "";
  }
}
