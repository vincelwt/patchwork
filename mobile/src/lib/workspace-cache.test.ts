import assert from "node:assert/strict";
import test from "node:test";

import { isWorkspaceCacheKey, workspaceCacheKey } from "./workspace-cache.ts";

test("workspace caches are isolated by credential digest", () => {
  const base = "https://relay.patchwork.sh/w/acme/";
  const first = workspaceCacheKey(base, "first-digest");
  const second = workspaceCacheKey(base, "second-digest");

  assert.notEqual(first, second);
  assert.equal(first, workspaceCacheKey(base.slice(0, -1), "first-digest"));
  assert.equal(isWorkspaceCacheKey(first), true);
  assert.equal(isWorkspaceCacheKey("unrelated"), false);
});
