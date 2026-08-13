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
  const reviews = Array.from({ length: 6 }, (_, index) =>
    item(`review-${index}`, "review_ready", index, { task_id: "task-118" }),
  );
  const rows = [
    ...reviews,
    item("reply", "reply", 7, { task_id: "task-118" }),
    item("question-1", "question", 8, { channel_id: "channel-1" }),
    item("question-2", "question", 9, { channel_id: "channel-1" }),
    item("failure-1", "automation_failed", 10, { automation_id: "automation-1" }),
    item("failure-2", "automation_failed", 11, { automation_id: "automation-1" }),
    item("mention-1", "mention", 12, { channel_id: "channel-2" }),
    item("mention-2", "mention", 13, { channel_id: "channel-2" }),
  ];

  const groups = groupInbox(rows);
  const task = groups.find((group) => group.key === "task-118");
  assert.equal(task?.items.length, 7);
  assert.equal(task?.unread, 7);
  assert.equal(task?.latest.id, "reply");
  assert.equal(task?.lead, "review_ready");
  assert.equal(groups.length, 6);
  assert.equal(groups.find((group) => group.key === "channel-2")?.items.length, 2);
  const readOnly = item("read-only", "mention", 14, {
    channel_id: "read-channel",
    read_at: 14,
  });
  assert.equal(groupInbox([...rows, readOnly]).length, 7);
  assert.equal(unreadInboxCount([...rows, readOnly]), 6);
  assert.equal(unreadInboxCount(rows.map((row) => ({ ...row, read_at: 12 }))), 0);
});
