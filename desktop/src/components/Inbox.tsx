import { useMemo, useState } from "react";
import { useApi, useApp } from "../lib/store";
import { relative } from "../lib/format";
import { markSeen } from "../lib/unread";
import { Avatar, Chip, useNavigation } from "./common";
import { Empty, Page } from "./ui";
import { CheckIcon } from "./icons";
import type { Channel, InboxItem, InboxKind, Task } from "@client/types";

const LABELS: Record<InboxKind, string> = {
  mention: "Mention",
  reply: "Reply",
  direct_message: "Direct message",
  question: "Question",
  task_assigned: "Assigned",
  task_blocked: "Blocked",
  task_due: "Due",
  review_ready: "Ready for review",
  automation_failed: "Automation failed",
};

const TONES: Partial<Record<InboxKind, string>> = {
  question: "caution",
  task_due: "caution",
  task_blocked: "danger",
  review_ready: "positive",
  automation_failed: "danger",
};

/// Some things are blocking somebody; a chatty channel is not. Ordering puts
/// what is stuck first, whatever the timestamps say.
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

interface Group {
  key: string;
  items: InboxItem[];
  latest: InboxItem;
  /// The most pressing kind in the group — what the row is really about.
  lead: InboxKind;
  unread: number;
}

/// Inbox is a view onto things that need attention. Opening an item always
/// lands in the original conversation or task, never a parallel thread.
///
/// One row per conversation, not one per message: six mentions in the same
/// channel are one thing to go and deal with, and listing them six times buries
/// the question somebody asked an hour ago.
export function InboxView() {
  const app = useApp();
  const api = useApi();
  const { go } = useNavigation();
  const [showRead, setShowRead] = useState(false);

  const groups = useMemo(() => {
    const source = showRead ? app.inbox : app.inbox.filter((item) => !item.read_at);
    const byConversation = new Map<string, InboxItem[]>();
    for (const item of source) {
      // A question or a failed automation is about that specific thing, so it
      // keeps its own row even when it shares a channel with ordinary chatter.
      const standalone = item.kind === "question" || item.kind === "automation_failed";
      const key = standalone
        ? item.id
        : (item.task_id ?? item.channel_id ?? item.automation_id ?? item.id);
      byConversation.set(key, [...(byConversation.get(key) ?? []), item]);
    }

    const out: Group[] = [];
    for (const [key, items] of byConversation) {
      const sorted = [...items].sort((a, b) => b.created_at - a.created_at);
      const lead = [...items].sort((a, b) => URGENCY[a.kind] - URGENCY[b.kind])[0]
        .kind;
      out.push({
        key,
        items: sorted,
        latest: sorted[0],
        lead,
        unread: items.filter((item) => !item.read_at).length,
      });
    }

    return out.sort(
      (a, b) =>
        URGENCY[a.lead] - URGENCY[b.lead] ||
        b.latest.created_at - a.latest.created_at,
    );
  }, [app.inbox, showRead]);

  const open = async (group: Group) => {
    const item = group.latest;
    await Promise.all(
      group.items
        .filter((each) => !each.read_at)
        .map((each) => api.markRead(each.id)),
    );
    if (item.channel_id) markSeen(item.channel_id);
    if (item.task_id) {
      go({ kind: "task", id: item.task_id });
      return;
    }
    if (item.channel_id) {
      go({ kind: "channel", id: item.channel_id });
      return;
    }
    if (item.automation_id) go({ kind: "automation", id: item.automation_id });
  };

  const unread = app.inbox.filter((item) => !item.read_at).length;

  return (
    <Page
      title="Inbox"
      subtitle={unread > 0 ? `${unread} unread` : "all caught up"}
      actions={
        <>
          <button className="button quiet" onClick={() => setShowRead(!showRead)}>
            {showRead ? "Only unread" : "Show all"}
          </button>
          {unread > 0 && (
            <button className="button quiet" onClick={() => api.markAllRead()}>
              <CheckIcon size={15} />
              Mark all read
            </button>
          )}
        </>
      }
    >
      {groups.length === 0 && (
        <Empty
          title="Nothing needs you right now"
          hint="Mentions, agent questions, blocked tasks and work ready for review land here."
        />
      )}
      {groups.map((group) => (
        <InboxRow
          key={group.key}
          group={group}
          where={conversationLabel(group, app.channels, app.tasks)}
          onOpen={() => void open(group)}
        />
      ))}
    </Page>
  );
}

function conversationLabel(
  group: Group,
  channels: Channel[],
  tasks: Task[],
): string | undefined {
  const item = group.latest;
  if (item.task_id) {
    const task = tasks.find((candidate) => candidate.id === item.task_id);
    return task ? `${task.key} · ${task.title}` : undefined;
  }
  if (item.channel_id) {
    const channel = channels.find((candidate) => candidate.id === item.channel_id);
    if (!channel) return undefined;
    return channel.kind === "channel" ? `#${channel.name}` : channel.name;
  }
  return undefined;
}

function InboxRow({
  group,
  where,
  onOpen,
}: {
  group: Group;
  where?: string;
  onOpen: () => void;
}) {
  const app = useApp();
  const item = group.latest;
  const actor = app.members.find((member) => member.id === item.actor_id);
  const read = group.unread === 0;
  const extra = group.items.length - 1;

  return (
    <button className={`inbox-row${read ? " read" : ""}`} onClick={onOpen}>
      <Avatar member={actor} size={30} />
      <span className="grow">
        <span className="top">
          <span className="name">{item.title}</span>
          <Chip tone={TONES[group.lead] ?? ""}>{LABELS[group.lead]}</Chip>
          {extra > 0 && (
            <span className="more">
              +{extra} more {extra === 1 ? "message" : "messages"}
            </span>
          )}
        </span>
        <span className="sub">{item.preview}</span>
        {where && <span className="where">{where}</span>}
      </span>
      <span className="when">{relative(item.created_at)}</span>
      {!read && <span className="dot unread" />}
    </button>
  );
}
