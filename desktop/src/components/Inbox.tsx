import { useState } from "react";
import { useApi, useApp } from "../lib/store";
import { relative } from "../lib/format";
import { Avatar, Chip, useNavigation } from "./common";
import type { InboxItem, InboxKind } from "../lib/types";

const LABELS: Record<InboxKind, string> = {
  mention: "Mention",
  reply: "Reply",
  direct_message: "Direct message",
  question: "Question",
  task_assigned: "Assigned",
  task_blocked: "Blocked",
  review_ready: "Ready for review",
  automation_failed: "Automation failed",
};

const TONES: Partial<Record<InboxKind, string>> = {
  question: "caution",
  task_blocked: "danger",
  review_ready: "positive",
  automation_failed: "danger",
};

/// Inbox is a view onto things that need attention. Opening an item always
/// lands in the original conversation, task or run — never a parallel thread.
export function InboxView() {
  const app = useApp();
  const api = useApi();
  const { go, inspect } = useNavigation();
  const [showRead, setShowRead] = useState(false);

  const items = showRead
    ? app.inbox
    : app.inbox.filter((item) => !item.read_at);
  const sorted = [...items].sort((a, b) => b.created_at - a.created_at);

  const open = async (item: InboxItem) => {
    await api.markRead(item.id);
    if (item.task_id) {
      go({ kind: "task", id: item.task_id });
      if (item.run_id) inspect({ kind: "run", runId: item.run_id });
      return;
    }
    if (item.channel_id) {
      go({ kind: "channel", id: item.channel_id });
      return;
    }
    if (item.automation_id) {
      go({ kind: "automation", id: item.automation_id });
    }
  };

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">Inbox</span>
        <span className="spacer" />
        <button className="button quiet" onClick={() => setShowRead(!showRead)}>
          {showRead ? "Only unread" : "Show all"}
        </button>
        <button className="button quiet" onClick={() => api.markAllRead()}>
          Mark all read
        </button>
      </div>

      <div className="page">
        <div className="page-inner">
          {sorted.length === 0 && (
            <div className="empty">Nothing needs you right now.</div>
          )}
          {sorted.map((item) => {
            const actor = app.members.find((member) => member.id === item.actor_id);
            return (
              <button
                key={item.id}
                className="row"
                style={{ width: "100%", opacity: item.read_at ? 0.55 : 1 }}
                onClick={() => open(item)}
              >
                <Avatar member={actor} size={24} />
                <span className="grow">
                  <span className="name">{item.title}</span>
                  <span className="sub">{item.preview}</span>
                </span>
                <Chip tone={TONES[item.kind] ?? ""}>{LABELS[item.kind]}</Chip>
                <span className="composer-hint">{relative(item.created_at)}</span>
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
