import test from "node:test";
import assert from "node:assert/strict";
import {
  classifyTool,
  compactionOf,
  durationSeconds,
  formatDuration,
  preserveWorkKeys,
  projectTranscript,
  settledDisclosureKeys
} from "../../Sources/PatchworkWeb/Site/js/transcript.mjs";

let seq = 0;
const at = (seconds) => new Date(Date.UTC(2026, 0, 1, 0, 0, seconds)).toISOString();

const user = (text, seconds = 0) => ({ id: `u${++seq}`, role: "user", text, at: at(seconds) });
const assistant = (blocks, extra = {}) => ({
  id: `a${++seq}`,
  role: "assistant",
  text: blocks.map((b) => b.text || "").join("\n"),
  at: at(extra.seconds ?? 1),
  blocks,
  ...extra
});
const toolResult = (callId, text, extra = {}) => ({
  id: `t${++seq}`,
  role: "toolResult",
  text,
  at: at(extra.seconds ?? 2),
  toolCallId: callId,
  ...extra
});

const text = (value) => ({ type: "text", text: value });
const thinking = (value) => ({ type: "thinking", text: value });
const call = (callId, name, args = "") => ({ type: "toolCall", callId, name, arguments: args });

const kinds = (items) => items.map((item) => item.kind);
const work = (items) => items.find((item) => item.kind === "work");

test("a turn folds into user message, one work log, then the answer", () => {
  const items = projectTranscript([
    user("run the tests"),
    assistant([thinking("check the suite"), text("Running them now."), call("c1", "bash", '{"command":"swift test"}')]),
    toolResult("c1", "42 tests passed"),
    assistant([text("All 42 tests pass.")], { seconds: 3, stopReason: "stop" })
  ]);

  assert.deepEqual(kinds(items), ["message", "work", "message"]);
  assert.equal(items[2].message.text, "All 42 tests pass.");

  const log = work(items);
  assert.deepEqual(log.entries.map((e) => e.kind), ["thinking", "note", "activity"]);
  assert.equal(log.entries[1].message.text, "Running them now.", "pre-tool narration is log, not answer");
  assert.equal(log.stepCount, 1);
  assert.equal(log.entries[2].steps[0].category, "Ran commands");
  assert.equal(log.entries[2].steps[0].complete, true);
  assert.equal(log.entries[2].steps[0].result.text, "42 tests passed");
  assert.equal(log.active, false);
  assert.equal(log.title, "Worked for 3s");
  assert.equal(log.headline, "Worked for 3s", "a settled turn reads as a count, not the last thought");
});

test("routine tool traffic never reaches the top level", () => {
  const items = projectTranscript([
    user("look around"),
    assistant([call("c1", "read"), call("c2", "grep")]),
    toolResult("c1", "file contents"),
    toolResult("c2", "3 matches"),
    assistant([text("Found it.")], { stopReason: "stop" })
  ]);

  assert.deepEqual(kinds(items), ["message", "work", "message"]);
  const group = work(items).entries[0];
  assert.equal(group.kind, "activity");
  assert.deepEqual(group.steps.map((s) => s.category), ["Read files", "Read files"]);
  assert.ok(group.steps.every((s) => s.complete));
});

test("a live turn shows its latest thought and stays collapsible", () => {
  const items = projectTranscript(
    [user("dig in"), assistant([thinking("**first** pass"), thinking("**earlier line**\n\n**second pass**"), call("c1", "bash")])],
    { running: true }
  );

  const log = work(items);
  assert.equal(log.active, true);
  assert.equal(log.showsStatus, true);
  assert.equal(log.headline, "second pass", "the newest thought is the collapsed status");
  assert.equal(log.entries.at(-1).steps[0].complete, false, "an unanswered call is still running");
  assert.equal(items.at(-1).kind, "work", "nothing is presented as an answer yet");
});

test("a running turn is visible before the first agent event", () => {
  const prompt = user("start");
  const items = projectTranscript([prompt], { running: true });

  assert.deepEqual(kinds(items), ["message", "work"]);
  const log = work(items);
  assert.equal(log.active, true);
  assert.equal(log.headline, "Thinking");
  assert.equal(log.key, `work:waiting:${prompt.id}`);
  assert.deepEqual(log.entries, []);
});

test("tool-use narration is active work and supplies the collapsed headline", () => {
  const items = projectTranscript(
    [user("inspect"), assistant([text("Inspecting files")], { stopReason: "toolUse" })],
    { running: true }
  );

  assert.deepEqual(kinds(items), ["message", "work"]);
  const log = work(items);
  assert.equal(log.active, true);
  assert.equal(log.headline, "Inspecting files");
  assert.equal(log.entries[0].kind, "note");
});

test("work identity survives history prepends and first progress", () => {
  const prompt = user("go");
  const waiting = projectTranscript([prompt], { running: true });
  const progressed = preserveWorkKeys(
    waiting,
    projectTranscript([prompt, assistant([thinking("Checking")])], { running: true })
  );
  assert.equal(work(progressed).key, work(waiting).key, "first progress keeps the waiting row identity");

  const recent = projectTranscript([
    prompt,
    assistant([text("Reading"), call("c1", "read")]),
    toolResult("c1", "ok")
  ]);
  const withOlderSeam = projectTranscript([
    assistant([thinking("Earlier thought")]),
    prompt,
    assistant([text("Reading"), call("c1", "read")]),
    toolResult("c1", "ok")
  ]);
  const preserved = preserveWorkKeys(recent, withOlderSeam);
  const priorWork = work(recent);
  const overlapping = preserved.find((item) =>
    item.kind === "work" && item.entries.some((entry) => priorWork.entries.some((prior) => prior.key === entry.key))
  );
  assert.equal(overlapping.key, priorWork.key);
});

test("a live activity disclosure settles closed on completion", () => {
  const prompt = user("run");
  const live = projectTranscript(
    [prompt, assistant([call("settling", "bash")])],
    { running: true }
  );
  const settled = preserveWorkKeys(
    live,
    projectTranscript([prompt, assistant([call("settling", "bash")]), toolResult("settling", "ok")])
  );
  assert.deepEqual(
    settledDisclosureKeys(live, settled),
    [work(live).key, work(live).entries[0].key]
  );
  assert.deepEqual(settledDisclosureKeys(settled, settled), []);
});

test("a failed tool step does not flag the turn's answer as failed", () => {
  const items = projectTranscript([
    user("build"),
    assistant([call("c1", "bash")]),
    toolResult("c1", "compile error", { isError: true }),
    assistant([text("Fixed and building.")], { stopReason: "stop" })
  ]);

  const log = work(items);
  assert.equal(log.hasFailure, true);
  assert.equal(log.entries[0].steps[0].failed, true);
  assert.equal(log.answerFailed, false);
  assert.equal(log.showsStatus, false, "a retried failure is routine mid-turn noise");
});

test("a retried model error stays inside the work log", () => {
  const items = projectTranscript([
    user("go"),
    assistant([text("stream interrupted")], { isError: true }),
    assistant([text("Here is the answer.")], { seconds: 4, stopReason: "stop" })
  ]);

  assert.deepEqual(kinds(items), ["message", "work", "message"]);
  const log = work(items);
  assert.equal(log.answerFailed, false, "the turn's own answer came back");
  assert.equal(log.entries[0].message.text, "stream interrupted");
});

test("a turn whose answer failed says so", () => {
  const items = projectTranscript([
    user("go"),
    assistant([text("provider refused\n\ninternal retry detail")], { isError: true })
  ]);
  const log = work(items);
  assert.equal(log.answerFailed, true);
  assert.equal(log.showsStatus, true);
  assert.equal(log.headline, "Agent error: provider refused");
});

test("compaction folds into the log and keeps its title", () => {
  const compaction = {
    id: "s1",
    role: "system",
    text: "Context compacted: dropped the middle",
    at: at(2),
    blocks: [text("Context compacted"), text("dropped the middle")]
  };
  const items = projectTranscript([user("hi"), assistant([call("c1", "bash")]), toolResult("c1", "ok"), compaction]);

  const log = work(items);
  assert.equal(log.entries.at(-1).compaction.title, "Context compacted");
  assert.equal(log.entries.at(-1).compaction.summary, "dropped the middle");
  assert.equal(log.headline, "Context compacted");

  // A daemon that predates `blocks` sends only the flattened line.
  assert.deepEqual(compactionOf({ role: "system", text: "Branch summary: forked here" }), {
    title: "Branch summary",
    summary: "forked here"
  });
  assert.equal(compactionOf({ role: "assistant", text: "Context compacted: no" }), null);
});

test("an orphan tool result is shown rather than dropped", () => {
  const items = projectTranscript([toolResult("gone", "output from a call outside this window", { toolName: "read" })]);
  const log = work(items);
  assert.equal(log.stepCount, 1);
  assert.equal(log.entries[0].steps[0].category, "Read files");
  assert.equal(log.entries[0].steps[0].complete, true);
});

test("content this build does not know still appears", () => {
  const items = projectTranscript([{ id: "x1", role: "somethingNew", text: "from a newer Pi", at: at(1) }]);
  assert.deepEqual(kinds(items), ["message"], "an unknown role stands alone when no turn is in flight");

  const midTurn = projectTranscript([
    user("hi"),
    assistant([call("c1", "bash")]),
    { id: "x2", role: "somethingNew", text: "mid-turn", at: at(2) }
  ]);
  assert.deepEqual(kinds(midTurn), ["message", "work"]);
  const note = work(midTurn).entries.find((entry) => entry.kind === "note");
  assert.equal(note.message.text, "mid-turn", "folded into the log instead of dumped at top level");

  const futureBlock = projectTranscript([
    user("show it"),
    assistant([{ type: "videoClip" }], { stopReason: "stop" })
  ]);
  assert.equal(futureBlock.at(-1).message.text, "Unsupported content \u00b7 videoClip");
});

test("a daemon without blocks still yields readable turns", () => {
  const items = projectTranscript([
    { id: "u9", role: "user", text: "hello", at: at(0) },
    { id: "a9", role: "assistant", text: "[thinking] hmm\n[tool: bash]", at: at(1) },
    { id: "t9", role: "toolResult", text: "done", at: at(2) },
    { id: "a10", role: "assistant", text: "All good.", at: at(3) }
  ]);

  // Without block structure the first assistant message is prose; the orphan result opens the
  // work log under it, and the later prose is the answer.
  assert.equal(items[0].message.text, "hello");
  assert.equal(items.at(-1).message.text, "All good.");
  assert.ok(items.some((item) => item.kind === "work"), "the tool result is folded, not top-level");
});

test("answers keep their images while tool-result images surface beside the log", () => {
  const items = projectTranscript([
    user("screenshot it"),
    assistant([call("c1", "chrome_js")]),
    toolResult("c1", "captured", { images: [{ id: "1-c0", status: "ok", byteCount: 10 }] }),
    assistant([text("Here it is.")], { stopReason: "stop", images: [{ id: "2-c0", status: "ok", byteCount: 20 }] })
  ]);

  assert.deepEqual(work(items).images.map((i) => i.id), ["1-c0"]);
  assert.deepEqual(items.at(-1).message.images.map((i) => i.id), ["2-c0"]);
});

test("keys are stable across repaints of the same transcript", () => {
  const messages = [user("hi"), assistant([thinking("t"), call("c1", "bash")]), toolResult("c1", "ok")];
  const first = projectTranscript(messages).map((item) => item.key);
  const second = projectTranscript(messages).map((item) => item.key);
  assert.deepEqual(first, second);
  assert.equal(new Set(first).size, first.length, "keys are unique");
});

test("tool classification and duration match the Mac app's own labels", () => {
  assert.equal(classifyTool("bash"), "Ran commands");
  assert.equal(classifyTool("Edit"), "Edited files");
  assert.equal(classifyTool("web_search"), "Searched web");
  assert.equal(classifyTool("chrome_devtools"), "Used browser");
  assert.equal(classifyTool("get_subagent_result"), "Ran agents");
  assert.equal(classifyTool("ask_user_question"), "Asked question");
  assert.equal(classifyTool("something_new"), "Used tool");

  assert.equal(formatDuration(9), "9s");
  assert.equal(formatDuration(75), "1m 15s");
  assert.equal(formatDuration(3700), "1h 1m");
  assert.equal(durationSeconds(at(0), at(5)), 5);
  assert.equal(durationSeconds(at(5), at(0)), null, "a nonsensical pair reports no duration");
  assert.equal(durationSeconds("0001-01-01T00:00:00.000Z", at(5)), null, "a missing wire timestamp reports no duration");
  assert.equal(durationSeconds(null, at(5)), null);
});
