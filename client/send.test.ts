import assert from "node:assert/strict";
import test from "node:test";

import { beginSend, parseSendAttempt, sendAttempt } from "./send.ts";

test("a slow send accepts one action until it finishes", () => {
  const lock = { current: false };
  assert.equal(beginSend(lock), true);
  assert.equal(beginSend(lock), false);
  lock.current = false;
  assert.equal(beginSend(lock), true);
});

test("an unchanged retry keeps its idempotency key", () => {
  const first = sendAttempt("same draft", undefined, () => "first");
  assert.equal(sendAttempt("same draft", first, () => "unused"), first);
  assert.deepEqual(sendAttempt("edited draft", first, () => "second"), {
    fingerprint: "edited draft",
    clientId: "second",
  });
  assert.deepEqual(parseSendAttempt(JSON.stringify(first)), first);
  assert.equal(parseSendAttempt("not json"), undefined);
});
