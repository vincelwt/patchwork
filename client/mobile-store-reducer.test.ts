import assert from "node:assert/strict";
import test from "node:test";

import {
  applyBootstrap,
  applyEnvelope,
  emptyWorkspaceData,
  fromCache,
  MAX_CACHED_MESSAGES,
  toCache,
  touchChannel,
} from "./mobile-store-reducer.ts";
import type { Bootstrap, Envelope, Message } from "./types";

const bootstrap: Bootstrap = {
  workspace: {
    id: "w1",
    name: "Workspace",
    task_prefix: "PW",
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
  projects: [],
  hosts: [],
  tasks: [],
  inbox: [],
  automations: [],
  open_questions: [],
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
