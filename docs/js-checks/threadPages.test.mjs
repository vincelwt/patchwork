import test from "node:test";
import assert from "node:assert/strict";
import { loadThreadPages } from "../../Sources/PiDeskWeb/Site/js/threadPages.mjs";

test("thread pagination reads every sidebar page in order", async () => {
  const calls = [];
  const pages = new Map([
    [undefined, { threads: [{ id: "a" }, { id: "b" }], nextCursor: "2" }],
    ["2", { threads: [{ id: "c" }], nextCursor: null }]
  ]);

  const threads = await loadThreadPages(
    async (params) => {
      calls.push(params);
      return pages.get(params.cursor);
    },
    { archived: false, sidebar: true },
    { pageSize: 2, maxThreads: 5 }
  );

  assert.deepEqual(threads.map((thread) => thread.id), ["a", "b", "c"]);
  assert.deepEqual(calls, [
    { archived: false, sidebar: true, limit: 2, cursor: undefined },
    { archived: false, sidebar: true, limit: 2, cursor: "2" }
  ]);
});

test("thread pagination fails visibly instead of truncating or looping", async () => {
  await assert.rejects(
    loadThreadPages(
      async ({ cursor }) => ({ threads: [{ id: cursor || "first" }], nextCursor: "same" }),
      {},
      { pageSize: 1, maxThreads: 4 }
    ),
    /repeated cursor/
  );

  await assert.rejects(
    loadThreadPages(
      async ({ cursor }) => ({ threads: [{ id: cursor || "first" }], nextCursor: cursor ? "3" : "2" }),
      {},
      { pageSize: 1, maxThreads: 2 }
    ),
    /safety limit/
  );
});
