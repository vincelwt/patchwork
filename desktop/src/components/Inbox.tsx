import { useMemo, useState } from "react";
import { useApi, useApp } from "../lib/store";
import { relative } from "../lib/format";
import { markSeen } from "../lib/unread";
import { Avatar, Chip, useNavigation } from "./common";
import { Empty, Page } from "./ui";
import { CheckIcon } from "./icons";
import { TaskRow } from "./Tasks";
import { groupInbox, unreadInboxCount } from "@client/inbox";
import type { InboxGroup } from "@client/inbox";
import { taskGroup } from "@client/tasks";
import type { Channel, InboxKind, Task } from "@client/types";

const LABELS: Record<InboxKind, string> = {
  mention: "Mention",
  ask: "Needs you",
  automation_failed: "Automation failed",
};

const TONES: Partial<Record<InboxKind, string>> = {
  ask: "caution",
  automation_failed: "danger",
};

/// Home: what is waiting on you, then what is going on.
///
/// One page rather than an Inbox and a Tasks board, because they were two
/// answers to the same question and neither was complete on its own. The top
/// is everything addressed to you, in `groupInbox`'s order: an ask before a
/// failed automation before a mention. Below it, work that is moving and work
/// that just finished. A task nobody is waiting on appears nowhere, which is
/// the point: silence is what "it is handled" looks like.
export function Home() {
  const app = useApp();
  const api = useApi();
  const { go } = useNavigation();
  const [showRead, setShowRead] = useState(false);

  const groups = useMemo(
    () => groupInbox(showRead ? app.inbox : app.inbox.filter((item) => !item.read_at)),
    [app.inbox, showRead],
  );

  const { needsYou, inFlight, recentlyDone } = useMemo(() => {
    const now = Date.now();
    const sorted = [...app.tasks].sort(
      (a, b) =>
        (a.due_at ?? Number.MAX_SAFE_INTEGER) - (b.due_at ?? Number.MAX_SAFE_INTEGER) ||
        b.updated_at - a.updated_at,
    );
    return {
      needsYou: sorted.filter((task) => taskGroup(task, now) === "needs-you"),
      inFlight: sorted.filter((task) => taskGroup(task, now) === "in-flight"),
      recentlyDone: sorted.filter((task) => taskGroup(task, now) === "recently-done"),
    };
  }, [app.tasks]);

  // A task with an open ask that also reached you as an Inbox item is one
  // thing to deal with, and listing it twice makes the page longer without
  // making it say more.
  const claimed = new Set(groups.map((group) => group.latest.task_id));
  const unclaimed = needsYou.filter((task) => !claimed.has(task.id));
  const unread = unreadInboxCount(app.inbox);
  const quiet =
    groups.length === 0 &&
    unclaimed.length === 0 &&
    inFlight.length === 0 &&
    recentlyDone.length === 0;

  const open = async (group: InboxGroup) => {
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

  return (
    <Page
      title="Home"
      subtitle={unread > 0 ? `${unread} waiting` : "all caught up"}
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
          <button className="button quiet" onClick={() => go({ kind: "tasks" })}>
            Board
          </button>
        </>
      }
    >
      {quiet && (
        <Empty
          title="Nothing needs you right now"
          hint="Mentions, and anything an agent is waiting on you for, land here."
        />
      )}

      {(groups.length > 0 || unclaimed.length > 0) && (
        <Group title="Needs you">
          {groups.map((group) => (
            <InboxRow
              key={group.key}
              group={group}
              where={conversationLabel(group, app.channels, app.tasks)}
              onOpen={() => void open(group)}
            />
          ))}
          {unclaimed.map((task) => (
            <TaskRow key={task.id} task={task} />
          ))}
        </Group>
      )}

      {inFlight.length > 0 && (
        <Group title="In flight">
          {inFlight.map((task) => (
            <TaskRow key={task.id} task={task} />
          ))}
        </Group>
      )}

      {recentlyDone.length > 0 && (
        <Group title="Recently done">
          {recentlyDone.map((task) => (
            <TaskRow key={task.id} task={task} />
          ))}
        </Group>
      )}
    </Page>
  );
}

/// A heading and its rows. No collapse, no count, no create button: three
/// groups do not need managing.
function Group({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <>
      <div className="section-head">
        <span className="section-title">{title}</span>
      </div>
      {children}
    </>
  );
}

function conversationLabel(
  group: InboxGroup,
  channels: Channel[],
  tasks: Task[],
): string | undefined {
  const item = group.latest;
  if (item.task_id) {
    const task = tasks.find((candidate) => candidate.id === item.task_id);
    return task?.title;
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
  group: InboxGroup;
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
