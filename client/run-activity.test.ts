import assert from "node:assert/strict";
import test from "node:test";

import { projectRunActivity, toolOutput } from "./run-activity.ts";
import type { RunEvent, RunEventKind } from "./types";

let seq = 0;
function event(kind: RunEventKind, text: string, data?: unknown): RunEvent {
  seq += 1;
  return {
    id: `event-${seq}`,
    run_id: "run-1",
    seq,
    kind,
    text,
    data,
    created_at: seq * 100,
  };
}

test("run activity folds protocol events into useful rows", () => {
  seq = 0;
  const oldPlan = event("plan", "[ ] First plan");
  const events = [
    event("lifecycle", "session_info_update", { sessionUpdate: "session_info_update" }),
    event("permission", "Allowed: read (allow_always)"),
    oldPlan,
    event("thought", "Check the event stream."),
    event("lifecycle", "agent_thought_chunk", { sessionUpdate: "agent_thought_chunk" }),
    event("thought", "The updates share an id."),
    event("tool_call", "write — pending", {
      toolCallId: "tool-1",
      title: "write",
      status: "pending",
      kind: "edit",
      locations: [{ path: "/repo/src/Inspector.tsx" }],
      rawInput: { path: "/repo/src/Inspector.tsx" },
      _meta: { terminal_info: { cwd: "/repo" } },
    }),
    event("tool_result", "tool — in_progress", {
      toolCallId: "tool-1",
      status: "in_progress",
      _meta: { terminal_output: { data: "failed output" } },
    }),
    event("tool_result", "tool — failed", {
      toolCallId: "tool-1",
      status: "failed",
      _meta: { terminal_exit: { exit_code: 2, signal: "SIGTERM" } },
      rawOutput: { ignored: "terminal output is more useful" },
    }),
    event("plan", "[x] Final plan"),
    event("file_change", " M src/Inspector.tsx\n?? src/new.ts\n… and 2 more"),
    event("permission", "Denied: deploy"),
    event("tool_result", "orphaned tool — failed", { status: "failed" }),
  ];

  const activity = projectRunActivity(events);
  assert.deepEqual(activity.items.map((item) => item.type), [
    "thought",
    "tool",
    "event",
    "event",
    "event",
    "event",
  ]);
  assert.equal(activity.items[0].type === "thought" && activity.items[0].text,
    "Check the event stream.\n\nThe updates share an id.");

  const tool = activity.items[1];
  assert.equal(tool.type, "tool");
  if (tool.type !== "tool") return;
  assert.equal(tool.title, "Write Inspector.tsx");
  assert.equal(tool.status, "failed");
  assert.equal(toolOutput(tool.updates), "failed output");
  assert.equal(tool.exitCode, 2);
  assert.equal(tool.signal, "SIGTERM");
  assert.equal(tool.cwd, "/repo");
  assert.deepEqual(tool.paths, ["/repo/src/Inspector.tsx"]);

  assert.deepEqual(activity.debug.map((item) => item.id), [events[0].id, events[1].id, oldPlan.id, events[4].id]);
  assert.equal(activity.toolCount, 1);
  assert.equal(activity.fileCount, 4);
  assert.equal(activity.warningCount, 3);
  assert.equal(
    activity.items[2].type === "event" && activity.items[2].event.text,
    "[x] Final plan",
  );
  assert.equal(
    activity.items[4].type === "event" && activity.items[4].event.text,
    "Denied: deploy",
  );
  assert.equal(
    activity.items[5].type === "event" && activity.items[5].event.text,
    "orphaned tool — failed",
  );
});
