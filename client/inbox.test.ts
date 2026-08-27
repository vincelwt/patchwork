import assert from "node:assert/strict";
import test from "node:test";

import { groupInbox, unreadInboxCount } from "./inbox.ts";
import type { InboxItem, InboxKind } from "./types";

function item(
  id: string,
  kind: InboxKind,
  createdAt: number,
  links: Partial<InboxItem> = {},
): InboxItem {
  return {
    id,
    member_id: "me",
    kind,
    title: id,
    preview: "",
    created_at: createdAt,
    ...links,
  };
}

test("inbox groups notifications by destination and counts visible unread rows", () => {
  const rows = [
    // Chatter about one task collapses to a single row.
    ...Array.from({ length: 6 }, (_, index) =>
      item(`mention-${index}`, "mention", index, { task_id: "task-118" }),
    ),
    // An ask points at one specific answer, so it never merges with anything.
    item("ask-1", "ask", 8, { channel_id: "channel-1" }),
    item("ask-2", "ask", 9, { channel_id: "channel-1" }),
    item("failure-1", "automation_failed", 10, { automation_id: "automation-1" }),
    item("failure-2", "automation_failed", 11, { automation_id: "automation-1" }),
    item("chatter-1", "mention", 12, { channel_id: "channel-2" }),
    item("chatter-2", "mention", 13, { channel_id: "channel-2" }),
  ];

  const groups = groupInbox(rows);
  const task = groups.find((group) => group.key === "task-118");
  assert.equal(task?.items.length, 6);
  assert.equal(task?.unread, 6);
  assert.equal(task?.latest.id, "mention-5");
  assert.equal(task?.lead, "mention");
  // Two asks, two failures, one task row, one channel row.
  assert.equal(groups.length, 6);
  // Something asked of you comes first however recent the chatter is.
  assert.equal(groups[0].lead, "ask");
  assert.equal(groups.find((group) => group.key === "channel-2")?.items.length, 2);

  const readOnly = item("read-only", "mention", 14, {
    channel_id: "read-channel",
    read_at: 14,
  });
  assert.equal(groupInbox([...rows, readOnly]).length, 7);
  assert.equal(unreadInboxCount([...rows, readOnly]), 6);
  assert.equal(unreadInboxCount(rows.map((row) => ({ ...row, read_at: 12 }))), 0);
});
