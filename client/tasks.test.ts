import assert from "node:assert/strict";
import test from "node:test";

import { taskGroup } from "./tasks.ts";
import type { Ask, Task } from "./types";

const now = 1_700_000_000_000;
const day = 24 * 60 * 60 * 1000;

const ask = { id: "a", kind: "review", status: "open" } as Ask;

function task(fields: Partial<Task>): Task {
  return { status: "planned", updated_at: now, ...fields } as Task;
}

test("only an open ask, live work, or recent news reaches a person", () => {
  assert.equal(taskGroup(task({ ask }), now), "needs-you");
  // An ask outranks the run it is holding up.
  assert.equal(taskGroup(task({ ask, status: "running" }), now), "needs-you");
  assert.equal(taskGroup(task({ status: "running" }), now), "in-flight");
  // Quiet work nobody is waiting on stays off the board entirely.
  assert.equal(taskGroup(task({ status: "planned" }), now), null);
});

test("finished work stops being news after a week", () => {
  assert.equal(taskGroup(task({ status: "done" }), now), "recently-done");
  assert.equal(taskGroup(task({ status: "canceled" }), now), "recently-done");
  assert.equal(taskGroup(task({ status: "done", updated_at: now - 8 * day }), now), null);
  // Closed work cannot beg for attention with an ask left over from before.
  assert.equal(
    taskGroup(task({ status: "done", ask, updated_at: now - 8 * day }), now),
    null,
  );
});
