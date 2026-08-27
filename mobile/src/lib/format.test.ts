import assert from "node:assert/strict";
import test from "node:test";

import type { Automation, Message } from "../../../client/types.ts";
import { isSameTurn, relative, watchHealth } from "./format.ts";

test("relative time works without Intl.RelativeTimeFormat", () => {
  const now = 1_800_000_000_000;
  assert.equal(relative(now - 5_000, now), "now");
  assert.equal(relative(now - 120_000, now), "2 minutes ago");
  assert.equal(relative(now + 3_600_000, now), "in 1 hour");
  assert.equal(relative(undefined, now), "");
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
  assert.deepEqual(
    watchHealth(
      watch({ blocked_reason: "host offline", retry_at: now + 60_000, overdue_since: now - 60_000 }),
      now,
    ),
    { tone: "danger", text: "Blocked · retry in 1 minute" },
  );
  assert.deepEqual(
    watchHealth(watch({ overdue_since: now - 60_000, failure_count: 3 }), now),
    { tone: "danger", text: "Overdue 1 minute ago" },
  );
});
