import assert from "node:assert/strict";
import test from "node:test";

import { alignScrollEnd, isNearScrollEnd } from "./scroll.ts";

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
