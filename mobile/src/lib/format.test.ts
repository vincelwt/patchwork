import assert from "node:assert/strict";
import test from "node:test";

import type { Automation, Message } from "../../../client/types.ts";
import { isSameTurn, pullRequestLabel, relative, watchHealth, watchNeedsTest } from "./format.ts";

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

test("a watch reads as healthy from its last successful check, not its last attempt", () => {
  const now = 1_800_000_000_000;
  const watch = (over: Partial<Automation>): Automation =>
    ({
      trigger: { type: "watch", command: "check", every_seconds: 60 },
      failure_count: 0,
      ...over,
    }) as Automation;

  // A command that has been failing all week still has a fresh last_run_at.
  assert.deepEqual(
    watchHealth(watch({ last_run_at: now, failure_count: 3, last_error_at: now - 120_000 }), now),
    { tone: "danger", text: "3 failed checks · 2 minutes ago" },
  );
  assert.deepEqual(watchHealth(watch({ last_success_at: now - 60_000 }), now), {
    tone: "positive",
    text: "Checked 1 minute ago",
  });
  assert.deepEqual(watchHealth(watch({ last_run_at: now }), now), {
    tone: "caution",
    text: "Never tested",
  });
});

test("only a watch command that already passed skips the test before enabling", () => {
  const validated = {
    trigger: { type: "watch", command: "check", every_seconds: 60 },
    last_validated_at: 1,
    failure_count: 0,
  } as Automation;

  assert.equal(watchNeedsTest(validated, { type: "watch", command: "check" }), false);
  assert.equal(watchNeedsTest(validated, { type: "watch", command: "check --new" }), true);
  assert.equal(watchNeedsTest(undefined, { type: "watch", command: "check" }), true);
  assert.equal(watchNeedsTest(undefined, { type: "cron" }), false);
  assert.equal(
    watchNeedsTest({ ...validated, last_validated_at: undefined }, { type: "watch", command: "check" }),
    true,
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
