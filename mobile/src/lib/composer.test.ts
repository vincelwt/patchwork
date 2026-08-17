import assert from "node:assert/strict";
import test from "node:test";

import { composerKey } from "./composer.ts";

test("each channel and thread gets its own composer", () => {
  assert.equal(composerKey("channel-a"), "channel-a");
  assert.equal(composerKey("channel-a", "message-a"), "thread:message-a");
  assert.notEqual(composerKey("channel-a"), composerKey("channel-b"));
  assert.notEqual(
    composerKey("channel-a", "message-a"),
    composerKey("channel-a", "message-b"),
  );
});
