// Where a task stands, read rather than decided.
//
// The relay derives the status from the runs and the open ask, and writes the
// brief at every transition, so a client that computes its own ladder is a
// second opinion nobody asked for. This reads what is already there: the open
// ask if there is one, then live runs, and the brief as the line to show.

import { isTerminalTaskStatus } from "@client/types";
import type { Ask, Member, Run, Task } from "@client/types";

export type Situation =
  | "asking"
  | "review"
  | "blocked"
  | "working"
  | "queued"
  | "done"
  | "canceled"
  | "open";

export interface TaskState {
  situation: Situation;
  /// One line about where this task is, in the relay's words when it has any.
  headline: string;
  /// The run to look at first: the newest one still going, or the last one to
  /// have left a mark.
  run?: Run;
  /// Every run still going on this task, oldest first. Agents share a task's
  /// worktree rather than queue behind it, so this is a list.
  activeRuns: Run[];
  /// The agents behind `activeRuns`, one entry each and in the same order.
  agents: Member[];
  /// The one thing being asked of a person. At most one is ever open.
  ask?: Ask;
  owner?: Member;
}

const ACTIVE_RUN = ["queued", "dispatched", "running", "waiting"];

/// A run nobody is waiting on has finished. Several unfinished runs can belong
/// to one task at the same time.
export function isRunActive(run: Run): boolean {
  return ACTIVE_RUN.includes(run.status);
}

/// What an ask wants is what the task is waiting on.
function askSituation(ask: Ask): Situation {
  if (ask.kind === "review") return "review";
  if (ask.kind === "unblock") return "blocked";
  return "asking";
}

export function readTask(
  task: Task,
  members: Member[],
  runs: Record<string, Run>,
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
  const current = task.current_run_id ? runs[task.current_run_id] : undefined;
  const run =
    current && isRunActive(current) ? current : (live[live.length - 1] ?? current);
  const ask = task.ask?.status === "open" ? task.ask : undefined;
  const situation = situationOf(task, ask, live);

  return {
    situation,
    headline: task.brief || fallbackLine(situation, ask, agents),
    run,
    activeRuns: live,
    agents,
    ask,
    owner: members.find((member) => member.id === task.owner_id),
  };
}

/// Closed first, so that a stale ask left over from before cannot make
/// finished work beg for attention. It is the order `taskGroup` uses, which is
/// what keeps Home and the task page from disagreeing about the same task.
function situationOf(task: Task, ask: Ask | undefined, live: Run[]): Situation {
  if (isTerminalTaskStatus(task.status)) {
    return task.status === "canceled" ? "canceled" : "done";
  }
  if (ask) return askSituation(ask);
  if (live.length > 0) {
    const started = live.some(
      (run) => run.status !== "queued" && run.status !== "dispatched",
    );
    return started ? "working" : "queued";
  }
  return "open";
}

/// Only until the relay has written a brief. Every one of these is a sentence
/// the brief itself would say better.
function fallbackLine(situation: Situation, ask?: Ask, agents: Member[] = []): string {
  switch (situation) {
    case "asking":
    case "review":
    case "blocked":
      return ask?.text ?? "Waiting on you";
    case "working":
      return agents.length > 1 ? `${agents.length} agents are working` : "Working";
    case "queued":
      return "Waiting for a machine to pick this up";
    case "done":
      return "Done";
    case "canceled":
      return "Canceled";
    default:
      return "Nothing is moving this forward right now";
  }
}

export function situationTone(situation: Situation): string {
  switch (situation) {
    case "working":
    case "queued":
      return "accent";
    case "asking":
    case "review":
      return "caution";
    case "blocked":
      return "danger";
    case "done":
      return "positive";
    default:
      return "";
  }
}
