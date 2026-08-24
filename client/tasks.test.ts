import assert from "node:assert/strict";
import test from "node:test";

import { visibleOnTaskBoard } from "./tasks.ts";
import type { TaskStatus } from "./types";

const statuses: TaskStatus[] = [
  "planned",
  "running",
  "blocked",
  "review",
  "done",
  "canceled",
];

test("background tasks only join the board when they need attention", () => {
  assert.deepEqual(
    statuses.filter((status) => visibleOnTaskBoard({ background: true, status })),
    ["blocked", "review"],
  );
  assert.ok(statuses.every((status) => visibleOnTaskBoard({ background: false, status })));
});
