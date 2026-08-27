import assert from "node:assert/strict";
import test from "node:test";

import {
  applyBootstrap,
  applyEnvelope,
  dropOutbox,
  emptyWorkspaceData,
  fromCache,
  MAX_CACHED_MESSAGES,
  nextOutbox,
  outboxFor,
  patchOutbox,
  queueOutbox,
  retryableFailure,
  toCache,
  touchChannel,
} from "./mobile-store-reducer.ts";
import type { OutboxMessage } from "./mobile-store-reducer.ts";
import type { Bootstrap, Envelope, Message } from "./types";

const bootstrap: Bootstrap = {
  workspace: {
    id: "w1",
    name: "Workspace",
    task_prefix: "PW",
    autonomy: "",
    created_at: 1,
    task_seq: 1,
  },
  me: {
    id: "me",
    kind: "human",
    handle: "me",
    display_name: "Me",
    is_admin: true,
    created_at: 1,
    presence: "online",
  },
  members: [],
  sections: [],
  channels: [],
  skills: [],
  projects: [],
  hosts: [],
  tasks: [],
  inbox: [],
  automations: [],
  open_asks: [],
  active_runs: [],
  previews: [],
  seq: 10,
};

function message(index: number): Message {
  return {
    id: `m${index}`,
    channel_id: "c1",
    author_id: "me",
    kind: "text",
    body: String(index),
    reply_count: 0,
    last_reply_at: 0,
    mentions: [],
    attachments: [],
    reactions: [],
    created_at: index,
  };
}

function queued(id: string, over: Partial<OutboxMessage> = {}): OutboxMessage {
  return {
    id,
    channelId: "c1",
    body: id,
    attachmentIds: [],
    createdAt: 1,
    status: "queued",
    attempts: 0,
    ...over,
  };
}

test("queued messages survive a restart and keep their place in the queue", () => {
  let state = applyBootstrap(touchChannel(emptyWorkspaceData(), "c1"), bootstrap);
  state = queueOutbox(state, queued("a"));
  state = queueOutbox(state, queued("b", { parentId: "m1" }));
  state = queueOutbox(state, queued("c", { channelId: "c2" }));

  // One composer sees only its own conversation, and a thread is not its channel.
  assert.deepEqual(outboxFor(state, "c1").map((entry) => entry.id), ["a"]);
  assert.deepEqual(outboxFor(state, "c1", "m1").map((entry) => entry.id), ["b"]);

  // A refusal stops being tried; the queue moves on to the next message.
  assert.equal(nextOutbox(state)?.id, "a");
  state = patchOutbox(state, "a", { status: "failed", attempts: 1, error: "nothing to post" });
  assert.equal(nextOutbox(state)?.id, "b");

  state = patchOutbox(state, "b", { status: "saving" });
  state = patchOutbox(state, "c", { status: "sending" });
  const restored = fromCache(JSON.parse(JSON.stringify(toCache(state))));
  assert.ok(restored);
  // The refusal stays visible; accepted and in-flight sends are retried.
  assert.deepEqual(
    restored.data.outbox.map((entry) => [entry.id, entry.status]),
    [["a", "failed"], ["b", "queued"], ["c", "queued"]],
  );
  assert.equal(restored.data.outbox[0].error, "nothing to post");

  // A cache written before there was an outbox restores as an empty one.
  const legacy = fromCache({ ...toCache(state), outbox: undefined });
  assert.deepEqual(legacy?.data.outbox, []);

  assert.deepEqual(dropOutbox(state, "b").outbox.map((entry) => entry.id), ["a", "c"]);
});

test("only a failure that may pass later is retried automatically", () => {
  for (const status of [undefined, 408, 429, 500, 503]) {
    assert.equal(retryableFailure(status), true, `${status} should retry`);
  }
  for (const status of [400, 403, 404, 413, 422]) {
    assert.equal(retryableFailure(status), false, `${status} should not retry`);
  }
});

test("a message sent while its first page loads is kept", () => {
  let state = touchChannel(applyBootstrap(emptyWorkspaceData(), bootstrap), "c1");
  state = applyEnvelope(state, {
    seq: 11,
    at: 2,
    kind: "message_created",
    message: message(2),
  } as Envelope);

  assert.deepEqual(state.messages.c1, [message(2)]);
});

test("inline replies stay in the channel timeline", () => {
  let state = touchChannel(applyBootstrap(emptyWorkspaceData(), bootstrap), "c1");
  state = { ...state, messages: { c1: [] } };
  const reply = { ...message(2), reply_to_id: "m1" };

  state = applyEnvelope(state, {
    seq: 11,
    at: 2,
    kind: "message_created",
    message: reply,
  } as Envelope);

  assert.deepEqual(state.messages.c1, [reply]);
  assert.deepEqual(state.threads, {});
});

test("an acknowledged thread reply is not counted again by realtime", () => {
  const root = message(1);
  let state = applyBootstrap(emptyWorkspaceData(), bootstrap);
  state = {
    ...state,
    messages: { c1: [root] },
    threads: { [root.id]: [] },
  };
  const reply = { ...message(2), parent_id: root.id };

  state = applyEnvelope(state, {
    seq: 0,
    at: 2,
    kind: "message_created",
    message: reply,
  } as Envelope);
  state = applyEnvelope(state, {
    seq: 11,
    at: 2,
    kind: "message_created",
    message: reply,
  } as Envelope);

  assert.equal(state.messages.c1[0].reply_count, 1);
  assert.deepEqual(state.threads[root.id], [reply]);
});

test("workspace skills stay current in bootstrap state", () => {
  const state = applyEnvelope(applyBootstrap(emptyWorkspaceData(), bootstrap), {
    seq: 11,
    at: 11,
    kind: "workspace_skills_updated",
    skills: [
      {
        id: "skill-1",
        name: "Release checks",
        description: "Before shipping",
        instructions: "Run the smoke test.",
        created_at: 1,
        updated_at: 1,
      },
    ],
  } as Envelope);

  assert.equal(state.bootstrap?.skills[0]?.name, "Release checks");
});

test("task updates replace the visible durable obligation", () => {
  const task = {
    id: "t1",
    key: "PW-1",
    title: "Ship build",
    outcome: "Build reaches testers",
    status: "running" as const,
    discussion_channel_id: "c1",
    created_by: "me",
    created_at: 1,
    updated_at: 1,
    position: 1,
  };
  let state = applyBootstrap(emptyWorkspaceData(), { ...bootstrap, tasks: [task] });
  state = applyEnvelope(state, {
    seq: 11,
    at: 2,
    kind: "task_updated",
    task: {
      ...task,
      updated_at: 2,
      active_continuation: {
        id: "continuation",
        status: "waiting",
        summary: "Build is processing",
        next_check_at: 3,
        deadline_at: 100,
        updated_at: 2,
      },
    },
  } as Envelope);

  assert.equal(
    state.bootstrap?.tasks[0]?.active_continuation?.summary,
    "Build is processing",
  );
});

test("events stay monotonic and the restart cache stays bounded", () => {
  let state = touchChannel(applyBootstrap(emptyWorkspaceData(), bootstrap), "c1");
  state = {
    ...state,
    messages: { c1: Array.from({ length: 65 }, (_, index) => message(index)) },
  };

  const created = {
    seq: 11,
    at: 11,
    kind: "message_created",
    message: message(65),
  } as Envelope;
  state = applyEnvelope(state, created);
  const duplicate = applyEnvelope(state, {
    ...created,
    message: { ...message(65), body: "duplicate" },
  } as Envelope);

  assert.equal(duplicate, state);
  assert.equal(state.seq, 11);
  assert.equal(state.messages.c1.at(-1)?.body, "65");

  state = applyBootstrap(state, { ...bootstrap, seq: 9 });
  assert.equal(state.seq, 11);

  const cache = toCache(state, 123);
  assert.ok(cache);
  assert.equal(cache.messages.c1.length, MAX_CACHED_MESSAGES);
  assert.equal("runDetails" in cache, false);

  const restored = fromCache(JSON.parse(JSON.stringify(cache)));
  assert.ok(restored);
  assert.equal(restored.data.seq, 11);
  assert.equal(restored.data.messages.c1[0].id, "m6");
  assert.equal(restored.lastSyncAt, 123);
});
