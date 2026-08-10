// Mentioning a task is just writing its key. `PW-42` in a message is the same
// reference everywhere — typed by a person, printed by an agent, or copied out
// of the CLI — so the composer only has to help find the key, and the renderer
// only has to recognise the keys that name a real task.

import type { Task } from "./types";

/// The shape of a key: the workspace prefix is configurable, so this matches
/// `ACME-7` as readily as `PW-42` and the caller decides which keys are real.
export const TASK_KEY = /(?<![\w-])([A-Za-z][A-Za-z0-9]*-\d+)(?![\w-])/;

const finished = (task: Task) => task.status === "done" || task.status === "canceled";

/// Tasks worth offering for what has been typed after `#`, open work first and
/// most recently touched before the rest.
export function matchTasks(tasks: Task[], query: string, limit = 6): Task[] {
  const needle = query.trim().toLowerCase();
  return tasks
    .filter(
      (task) =>
        task.key.toLowerCase().includes(needle) ||
        task.title.toLowerCase().includes(needle),
    )
    .sort(
      (a, b) =>
        Number(finished(a)) - Number(finished(b)) || b.updated_at - a.updated_at,
    )
    .slice(0, limit);
}
