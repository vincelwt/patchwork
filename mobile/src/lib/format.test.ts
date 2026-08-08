import assert from "node:assert/strict";
import test from "node:test";

import { relative } from "./format.ts";

test("relative time works without Intl.RelativeTimeFormat", () => {
  const now = 1_800_000_000_000;
  assert.equal(relative(now - 5_000, now), "now");
  assert.equal(relative(now - 120_000, now), "2 minutes ago");
  assert.equal(relative(now + 3_600_000, now), "in 1 hour");
  assert.equal(relative(undefined, now), "");
});
