import assert from "node:assert/strict";
import test from "node:test";

import { TASK_KEY, matchTasks } from "./mentions.ts";
import type { Task, TaskStatus } from "./types.ts";

const task = (key: string, title: string, status: TaskStatus, updated: number) =>
  ({
    id: `id-${key}`,
    key,
    title,
    outcome: "",
    status,
    discussion_channel_id: "c1",
    created_by: "u1",
    created_at: 0,
    updated_at: updated,
    position: 0,
  }) as Task;

const tasks = [
  task("PW-1", "Ship the relay", "done", 300),
  task("PW-42", "Allow mentioning tasks", "planned", 100),
  task("ACME-7", "Cache the pricing endpoint", "running", 200),
];

test("open work is offered before finished work, newest first", () => {
  assert.deepEqual(
    matchTasks(tasks, "").map((found) => found.key),
    ["ACME-7", "PW-42", "PW-1"],
  );
});

test("a key or a word from the title finds the task", () => {
  assert.deepEqual(
    matchTasks(tasks, "pw-4").map((found) => found.key),
    ["PW-42"],
  );
  assert.deepEqual(
    matchTasks(tasks, "pricing").map((found) => found.key),
    ["ACME-7"],
  );
  assert.deepEqual(matchTasks(tasks, "nothing here"), []);
});

test("a key is recognised in prose but not inside a longer token", () => {
  const find = (text: string) => text.match(new RegExp(TASK_KEY.source))?.[1];
  assert.equal(find("landed in PW-42, see above"), "PW-42");
  assert.equal(find("ACME-7"), "ACME-7");
  assert.equal(find("v2-1024-beta"), undefined);
  assert.equal(find("plain words"), undefined);
});
