// What a task needs next.
//
// The board has five columns because a board needs columns, but "Planned" is
// not an instruction. At any moment a task is in exactly one *situation*, and
// each situation has one obvious next move — assign it, start it, answer it,
// look at it, close it. Deriving that in one place means the task page, the
// board card and the inspector all offer the same next move, and none of them
// can quietly disagree about what is going on.

import type { Member, Question, Run, Task } from "./types";

export type Situation =
  | "unassigned"
  | "ready"
  | "queued"
  | "working"
  | "asking"
  | "failed"
  | "blocked"
  | "review"
  | "waiting-on-person"
  | "done";

export interface NextAction {
  /// What the button says. Imperative, and names the actor where it helps.
  label: string;
  kind: "start" | "stop" | "answer" | "retry" | "assign" | "complete" | "reopen";
  tone: "primary" | "normal" | "quiet";
}

export interface TaskState {
  situation: Situation;
  /// One line, in plain language, about where this task actually is.
  headline: string;
  detail?: string;
  run?: Run;
  question?: Question;
  owner?: Member;
  action?: NextAction;
  /// The secondary move, when there is a sensible one.
  secondary?: NextAction;
}

const ACTIVE_RUN = ["queued", "dispatched", "running", "waiting"];

export function readTask(
  task: Task,
  members: Member[],
  runs: Record<string, Run>,
  questions: Record<string, Question>,
): TaskState {
  const owner = members.find((member) => member.id === task.owner_id);
  const ownerIsAgent = owner?.kind === "agent";
  const run = task.current_run_id ? runs[task.current_run_id] : undefined;
  const active = run && ACTIVE_RUN.includes(run.status);
  const question = Object.values(questions).find(
    (candidate) =>
      candidate.status === "open" &&
      (candidate.task_id === task.id || (run && candidate.run_id === run.id)),
  );

  // Something being asked of a person outranks everything else: it is the only
  // state where the task cannot progress without the reader.
  if (question) {
    return {
      situation: "asking",
      headline: `${owner?.display_name ?? "The agent"} needs an answer`,
      detail: question.headline || question.items[0]?.question,
      run,
      question,
      owner,
      action: { label: "Answer", kind: "answer", tone: "primary" },
      secondary: run ? { label: "Stop", kind: "stop", tone: "quiet" } : undefined,
    };
  }

  if (active && run) {
    const queued = run.status === "queued" || run.status === "dispatched";
    return {
      situation: queued ? "queued" : "working",
      headline: queued
        ? `Waiting for a machine to pick this up`
        : run.headline || `${owner?.display_name ?? "An agent"} is working`,
      detail: queued ? `Queued for ${owner?.display_name ?? "an agent"}` : undefined,
      run,
      owner,
      action: { label: "Stop", kind: "stop", tone: "normal" },
    };
  }

  if (task.status === "done") {
    return {
      situation: "done",
      headline: "Done",
      detail: task.pr_state ? `Pull request #${task.pr_state.number}` : undefined,
      run,
      owner,
      action: { label: "Reopen", kind: "reopen", tone: "quiet" },
    };
  }

  if (task.status === "review") {
    return {
      situation: "review",
      headline: "Ready for you to look at",
      detail: task.pr_state
        ? `#${task.pr_state.number} · ${task.pr_state.state.toLowerCase()}`
        : run?.headline,
      run,
      owner,
      // No "Send back": a button cannot say what was wrong with the work, and
      // an empty run only wastes a turn finding out. Changes are asked for in
      // the task conversation, which starts the agent with the reason in hand.
      action: { label: "Mark done", kind: "complete", tone: "primary" },
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
  }
}

export function situationTone(situation: Situation): string {
  switch (situation) {
    case "working":
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
    default:
      return "";
  }
}
