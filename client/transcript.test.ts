import assert from "node:assert/strict";
import test from "node:test";

import { foldTranscript } from "./transcript.ts";
import type { Message, MessageCard, MessageKind } from "./types";

let seq = 0;
function message(
  kind: MessageKind,
  body: string,
  extra: { run_id?: string; card?: MessageCard } = {},
): Message {
  seq += 1;
  return {
    id: `message-${seq}`,
    channel_id: "channel-1",
    author_id: "member-1",
    kind,
    body,
    reply_count: 0,
    last_reply_at: 0,
    mentions: [],
    attachments: [],
    reactions: [],
    created_at: seq * 100,
    ...extra,
  };
}

test("a run's status lines collapse to its latest, per run", () => {
  seq = 0;
  const first = message("status", "Cloning", { run_id: "run-a" });
  const other = message("status", "Reading", { run_id: "run-b" });
  const second = message("status", "Writing", { run_id: "run-a" });
  const latestB = message("status", "Testing", { run_id: "run-b" });
  const said = message("text", "Done.", { run_id: "run-a" });
  const event = message("system", "Task moved to review");
  const loose = message("status", "No run behind this one");
  const messages = [first, other, second, latestB, said, event, loose];

  const { superseded, traces } = foldTranscript(messages, false);

  assert.deepEqual([...superseded], [other.id, first.id]);
  assert.equal(traces.size, 0);
  // Nothing anyone said, and no workspace event, is ever folded away.
  for (const kept of [second, latestB, said, event, loose]) {
    assert.equal(superseded.has(kept.id), false, kept.body);
  }
});

test("show work keeps every status and traces each run exactly once", () => {
  seq = 0;
  const card = message("card", "", { card: { type: "run", run_id: "run-a" } });
  const again = message("card", "", { card: { type: "run", run_id: "run-a" } });
  const otherRun = message("card", "", { card: { type: "run", run_id: "run-b" } });
  const task = message("card", "", { card: { type: "task", task_id: "task-1" } });
  const messages = [
    message("status", "Cloning", { run_id: "run-a" }),
    message("status", "Writing", { run_id: "run-a" }),
    card,
    again,
    otherRun,
    task,
  ];

  const { superseded, traces } = foldTranscript(messages, true);

  assert.equal(superseded.size, 0);
  assert.deepEqual(
    [...traces],
    [
      [card.id, "run-a"],
      [otherRun.id, "run-b"],
    ],
  );
});
