import type { Task } from "./types";

export function visibleOnTaskBoard(
  task: Pick<Task, "background" | "status">,
): boolean {
  return !task.background || task.status === "blocked" || task.status === "review";
}
