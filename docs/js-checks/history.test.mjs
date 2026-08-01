import test from "node:test";
import assert from "node:assert/strict";
import {
  boundedNextOffset,
  latestPageSignature,
  mergeLatestPage,
  mergeOlderPage,
  scrollTopAfterPrepend
} from "../../Sources/PatchworkWeb/Site/js/history.mjs";

const messages = (from, through, text = (id) => `message ${id}`) =>
  Array.from({ length: through - from + 1 }, (_, index) => {
    const id = from + index;
    return { id: `m${id}`, role: "assistant", text: text(id) };
  });
const ids = (list) => list.map((message) => message.id);

test("older pages prepend in order without duplicates", () => {
  let loaded = messages(101, 150);
  loaded = mergeOlderPage(loaded, messages(51, 100));
  loaded = mergeOlderPage(loaded, messages(1, 50));
  assert.deepEqual(ids(loaded), ids(messages(1, 150)));
});

test("overlap from live appends adds only missing older rows", () => {
  const loaded = mergeOlderPage(messages(101, 150), messages(91, 140));
  assert.deepEqual(ids(loaded), ids(messages(91, 150)));
});

test("a refreshed latest page updates streaming content and retains history", () => {
  const current = messages(1, 100);
  const latest = messages(76, 101, (id) => (id === 100 ? "finished" : `message ${id}`));
  const merged = mergeLatestPage(current, latest);
  assert.deepEqual(ids(merged), ids(messages(1, 101)));
  assert.equal(merged.find((message) => message.id === "m100").text, "finished");
});

test("offset and retained history stay bounded", () => {
  assert.equal(boundedNextOffset(5000), 5000);
  assert.equal(boundedNextOffset(5050), null);
  assert.equal(mergeLatestPage(messages(1, 550), messages(551, 600)).length, 550);
  assert.equal(mergeOlderPage(messages(51, 600), messages(1, 50)).length, 550);
  const large = messages(1, 200, () => "x".repeat(100_000));
  assert.ok(mergeLatestPage([], large).length < large.length);
  assert.equal(mergeLatestPage([], large).at(-1).id, "m200");
});

test("prepending preserves the same visible reading position", () => {
  assert.equal(scrollTopAfterPrepend(240, 1200, 1900), 940);
});

test("newest-page signatures notice streaming text and running state without retained history", () => {
  const page = messages(1, 50);
  const original = latestPageSignature(page, true);
  assert.equal(latestPageSignature(page.map((message) => ({ ...message })), true), original);
  assert.notEqual(
    latestPageSignature(page.map((message, index) => index === 49 ? { ...message, text: "streamed" } : message), true),
    original
  );
  assert.notEqual(latestPageSignature(page, false), original);
});
