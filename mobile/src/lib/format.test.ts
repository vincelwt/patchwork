import assert from "node:assert/strict";
import test from "node:test";

import type { Message } from "../../../client/types.ts";
import { isSameTurn, pullRequestLabel, relative } from "./format.ts";

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

test("consecutive lines from one author collapse into a single turn", () => {
  const at = 1_800_000_000_000;
  const line = (over: Partial<Message>): Message =>
    ({ id: "m", channel_id: "c", author_id: "vince", kind: "message", created_at: at, ...over }) as Message;

  const first = line({});
  assert.equal(isSameTurn(first, line({ created_at: at + 30_000 })), true);
  assert.equal(isSameTurn(undefined, first), false);
  assert.equal(isSameTurn(first, line({ author_id: "claude" })), false);
  assert.equal(isSameTurn(first, line({ created_at: at + 6 * 60_000 })), false);
  assert.equal(isSameTurn(first, line({ kind: "status" })), false);
  // A reply or an agent run belongs to its own message, headers and all.
  assert.equal(isSameTurn(first, line({ reply_to_id: "earlier" })), false);
  assert.equal(isSameTurn(first, line({ run_id: "run" })), false);
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
