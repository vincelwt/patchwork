import assert from "node:assert/strict";
import test from "node:test";

import { pullRequestLabel, relative } from "./format.ts";

test("relative time works without Intl.RelativeTimeFormat", () => {
  const now = 1_800_000_000_000;
  assert.equal(relative(now - 5_000, now), "now");
  assert.equal(relative(now - 120_000, now), "2 minutes ago");
  assert.equal(relative(now + 3_600_000, now), "in 1 hour");
  assert.equal(relative(undefined, now), "");
});

test("pull request labels prefer synced state", () => {
  assert.equal(
    pullRequestLabel({
      pr_url: "https://github.com/acme/app/pull/42",
      pr_state: {
        number: 42,
        title: "Ship it",
        state: "OPEN",
        checks: "passing",
        review: "approved",
        updated_at: 1,
      },
    }),
    "PR #42 · open",
  );
});

test("pull request labels fall back to the URL number", () => {
  assert.equal(
    pullRequestLabel({ pr_url: "https://github.com/acme/app/pull/123/files" }),
    "PR #123",
  );
  assert.equal(
    pullRequestLabel({ pr_url: "https://example.com/review/current" }),
    "Pull request",
  );
});
