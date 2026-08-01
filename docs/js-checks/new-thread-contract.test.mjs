import test from "node:test";
import assert from "node:assert/strict";
import { AGENTS } from "../../Sources/PatchworkWeb/Site/js/agents.mjs";
import { createCreationIntentStore } from "../../Sources/PatchworkWeb/Site/js/creationIntent.mjs";
import {
  FIRST_MESSAGE_REQUIRED_ERROR,
  firstMessagePresentation,
  firstMessageValidationError,
  requiresFirstMessage,
  supportsProtectedThreadCreation
} from "../../Sources/PatchworkWeb/Site/js/newThreadContract.mjs";

class MemoryStorage {
  values = new Map();
  getItem(key) { return this.values.get(key) ?? null; }
  setItem(key, value) { this.values.set(key, String(value)); }
  removeItem(key) { this.values.delete(key); }
}

test("only Claude requires a first message", () => {
  for (const agent of AGENTS) {
    assert.equal(requiresFirstMessage(agent.id), agent.id === "claude");
  }
  assert.equal(requiresFirstMessage("future-agent"), false);
});

test("the first-message presentation clearly follows the selected agent", () => {
  assert.deepEqual(firstMessagePresentation("claude"), {
    required: true,
    label: "First message (required)",
    placeholder: "Describe what you want Claude to do",
    hint: "Claude starts the thread with this message."
  });
  assert.equal(firstMessagePresentation("pi").required, false);
  assert.match(firstMessagePresentation("pi").placeholder, /idle thread/);
});

test("a required first message rejects empty and whitespace-only values", () => {
  assert.equal(firstMessageValidationError("claude", ""), FIRST_MESSAGE_REQUIRED_ERROR);
  assert.equal(firstMessageValidationError("claude", "  \n\t"), FIRST_MESSAGE_REQUIRED_ERROR);
  assert.equal(firstMessageValidationError("claude", "Start here"), null);
  for (const agent of AGENTS.filter((candidate) => candidate.id !== "claude")) {
    assert.equal(firstMessageValidationError(agent.id, ""), null);
  }
});

test("protected creation support must be explicitly advertised", () => {
  assert.equal(supportsProtectedThreadCreation(), false);
  assert.equal(supportsProtectedThreadCreation({}), false);
  assert.equal(supportsProtectedThreadCreation({ threadCreationIdempotency: false }), false);
  assert.equal(supportsProtectedThreadCreation({ threadCreationIdempotency: true }), true);
});

test("a protected creation reservation includes its durable client id in the API body", async () => {
  const store = createCreationIntentStore({
    storage: new MemoryStorage(),
    idFactory: () => "web-create-contract-test"
  });
  const intent = await store.begin({ cwd: "/tmp/project", agent: "pi" }, {
    replayProtected: true
  });
  assert.equal(intent.replayProtected, true);
  assert.equal(intent.clientId, "web-create-contract-test");
  assert.equal(intent.body.clientId, intent.clientId);
});
