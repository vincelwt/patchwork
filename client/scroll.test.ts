import assert from "node:assert/strict";
import test from "node:test";

import {
  alignScrollEnd,
  isNearScrollEnd,
  rowOffsets,
  scrollTopAfterPrepend,
  visibleRange,
} from "./scroll.ts";

test("a viewport at or just above the end stays anchored", () => {
  assert.equal(isNearScrollEnd(1_000, 600, 320), true);
  assert.equal(isNearScrollEnd(1_000, 599, 320), false);
  assert.equal(isNearScrollEnd(200, 0, 320), true);
});

test("the trailing-edge threshold can be tailored to the surface", () => {
  assert.equal(isNearScrollEnd(1_000, 640, 320, 40), true);
  assert.equal(isNearScrollEnd(1_000, 639, 320, 40), false);
});

test("a settled viewport is not rewritten until new content moves its end", () => {
  let contentLength = 1_001;
  let offset = 680;
  let writes = 0;
  const viewport = {
    get scrollHeight() {
      return contentLength;
    },
    clientHeight: 320,
    get scrollTop() {
      return offset;
    },
    set scrollTop(value: number) {
      writes += 1;
      offset = Math.min(value, contentLength - this.clientHeight);
    },
  };

  alignScrollEnd(viewport);
  alignScrollEnd(viewport);
  assert.equal(writes, 0);

  contentLength += 40;
  alignScrollEnd(viewport);
  assert.equal(writes, 1);
  assert.equal(offset, 721);
});

test("a prepended page keeps the reader where they were reading", () => {
  // 600px of history arrives above a reader sitting 40px down.
  assert.equal(scrollTopAfterPrepend(1_000, 40, 1_600), 640);
  // A page that adds nothing must not move anybody.
  assert.equal(scrollTopAfterPrepend(1_000, 40, 1_000), 40);
  // Content can shrink faster than the reader had scrolled.
  assert.equal(scrollTopAfterPrepend(1_000, 40, 500), 0);
});

test("heights follow their own row when history is prepended", () => {
  const heights = new Map([
    ["b", 200],
    ["c", 300],
  ]);
  assert.deepEqual(rowOffsets(["b", "c"], heights, 84), [0, 200, 500]);

  // "a" is older history arriving above them, and is not measured yet. The two
  // known rows keep their own heights instead of inheriting by position.
  assert.deepEqual(rowOffsets(["a", "b", "c"], heights, 84), [0, 84, 284, 584]);
  assert.deepEqual(rowOffsets([], heights, 84), [0]);
});

test("the visible range covers the viewport and its overscan", () => {
  const offsets = rowOffsets(
    ["a", "b", "c", "d", "e", "f"],
    new Map(),
    100,
  );

  // Rows 2 and 3 are on screen; overscan of one keeps 1 and 4 mounted.
  assert.deepEqual(visibleRange(offsets, 250, 100, 1), {
    first: 2,
    start: 1,
    end: 5,
  });
  // A row boundary exactly at the viewport top belongs to the row below it.
  assert.deepEqual(visibleRange(offsets, 200, 100, 0), {
    first: 2,
    start: 2,
    end: 3,
  });
  // Clamped at both ends, and negative offsets are treated as the top.
  assert.deepEqual(visibleRange(offsets, -20, 100, 4), {
    first: 0,
    start: 0,
    end: 5,
  });
  assert.deepEqual(visibleRange([0], 0, 100, 4), { first: 0, start: 0, end: 0 });
});
