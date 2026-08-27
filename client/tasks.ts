import type { Task } from "./types";

/// Which of Home's three groups a task belongs to, or `null` for the tasks
/// nobody needs to see. Shared so the desktop and the phone cannot quietly
/// disagree about what is waiting on you.
export type TaskGroup = "needs-you" | "in-flight" | "recently-done";

/// How long a finished task stays visible before it stops being news.
const RECENTLY_DONE_MS = 7 * 24 * 60 * 60 * 1000;

export function taskGroup(task: Task, now: number): TaskGroup | null {
  if (task.status === "done" || task.status === "canceled") {
    return now - task.updated_at < RECENTLY_DONE_MS ? "recently-done" : null;
  }
  // An open ask is the only thing that makes a task somebody's problem right
  // now. Without one, work in progress is activity and everything else is
  // silence, which is the point: a task nobody is waiting on does not surface.
  if (task.ask) return "needs-you";
  return task.status === "running" ? "in-flight" : null;
}

export function needsYou(task: Task): boolean {
  return taskGroup(task, task.updated_at) === "needs-you";
}
