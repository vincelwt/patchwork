import test from "node:test";
import assert from "node:assert/strict";
import { AGENTS, agentLabel, shouldShowAgentBadge } from "../../Sources/PatchworkWeb/Site/js/agents.mjs";

test("agentLabel: every agent this build ships has a label", () => {
  assert.deepEqual(AGENTS.map((agent) => agent.id), ["pi", "codex", "claude"]);
  for (const agent of AGENTS) {
    assert.equal(agentLabel(agent.id), agent.label);
  }
});

test("agentLabel: a missing agent reads as Pi, the historical default", () => {
  assert.equal(agentLabel(undefined), "Pi");
  assert.equal(agentLabel(null), "Pi");
  assert.equal(agentLabel(""), "Pi");
});

test("agentLabel: an agent from a newer daemon is shown, never hidden or mislabelled", () => {
  assert.equal(agentLabel("gemini"), "gemini");
  assert.notEqual(agentLabel("gemini"), "Pi");
});

test("agentLabel: an absurd agent name stays bounded", () => {
  const label = agentLabel("x".repeat(500));
  assert.ok(label.length <= 12, `expected a bounded label, got ${label.length} characters`);
});

test("agentLabel: a non-string agent does not throw", () => {
  assert.equal(typeof agentLabel(42), "string");
  assert.equal(typeof agentLabel({}), "string");
});

test("shouldShowAgentBadge: only non-Pi agents get a badge", () => {
  assert.equal(shouldShowAgentBadge("pi"), false);
  assert.equal(shouldShowAgentBadge(undefined), false);
  assert.equal(shouldShowAgentBadge("codex"), true);
  assert.equal(shouldShowAgentBadge("claude"), true);
  assert.equal(shouldShowAgentBadge("gemini"), true);
});

test("schedule form: agent is only sent for a new-thread target", async () => {
  // Mirrors the CLI rule: an existing thread already knows its agent, and the daemon reads it
  // from that thread at every fire, so sending one here could only ever disagree.
  const body = (useExisting, agent) => ({
    ...(useExisting
      ? { target: { kind: "existingThread", threadId: "t1" } }
      : { target: { kind: "newThread", cwd: "/tmp/p" } }),
    agent: useExisting ? undefined : agent || undefined
  });
  assert.equal(body(true, "claude").agent, undefined);
  assert.equal(body(false, "claude").agent, "claude");
  assert.equal(body(false, "").agent, undefined);
});
