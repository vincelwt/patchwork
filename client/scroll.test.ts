import assert from "node:assert/strict";
import test from "node:test";

import { isNearScrollEnd } from "./scroll.ts";

test("a viewport at or just above the end stays anchored", () => {
  assert.equal(isNearScrollEnd(1_000, 600, 320), true);
  assert.equal(isNearScrollEnd(1_000, 599, 320), false);
  assert.equal(isNearScrollEnd(200, 0, 320), true);
});

test("the trailing-edge threshold can be tailored to the surface", () => {
  assert.equal(isNearScrollEnd(1_000, 640, 320, 40), true);
  assert.equal(isNearScrollEnd(1_000, 639, 320, 40), false);
});
