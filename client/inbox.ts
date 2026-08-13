import type { InboxItem, InboxKind } from "./types";

// Blocking work sorts ahead of chatty conversations, regardless of timestamp.
const URGENCY: Record<InboxKind, number> = {
  question: 0,
  task_blocked: 1,
  automation_failed: 1,
  task_due: 1,
  review_ready: 2,
  task_assigned: 3,
  direct_message: 4,
  mention: 5,
  reply: 6,
};

export interface InboxGroup {
  key: string;
  items: InboxItem[];
  latest: InboxItem;
  lead: InboxKind;
  unread: number;
}

/// One row per thing that needs attention, not one per notification about it.
export function groupInbox(items: readonly InboxItem[]): InboxGroup[] {
  const grouped = new Map<string, InboxItem[]>();
  for (const item of items) {
    // These point to one specific action, even when they share a conversation.
    const standalone = item.kind === "question" || item.kind === "automation_failed";
    const key = standalone
      ? item.id
      : (item.task_id ?? item.channel_id ?? item.automation_id ?? item.id);
    grouped.set(key, [...(grouped.get(key) ?? []), item]);
  }

  return [...grouped].map(([key, group]) => {
    const sorted = [...group].sort((a, b) => b.created_at - a.created_at);
    const lead = group.reduce(
      (current, item) => URGENCY[item.kind] < URGENCY[current] ? item.kind : current,
      group[0].kind,
    );
    return {
      key,
      items: sorted,
      latest: sorted[0],
      lead,
      unread: group.filter((item) => !item.read_at).length,
    };
  }).sort(
    (a, b) =>
      URGENCY[a.lead] - URGENCY[b.lead] ||
      b.latest.created_at - a.latest.created_at,
  );
}

export function unreadInboxCount(items: readonly InboxItem[]): number {
  return groupInbox(items.filter((item) => !item.read_at)).length;
}
