import { useEffect } from "react";
import { store, useApp } from "../lib/store";
import { duration, relative, statusLabel, statusTone } from "../lib/format";
import { Chip, useNavigation } from "./common";
import { Empty } from "./ui";
import {
  CheckIcon,
  CloseIcon,
  EventIcon,
  FileIcon,
  PulseIcon,
  QuestionIcon,
  ShieldIcon,
  TasksIcon,
  TerminalIcon,
  ThreadIcon,
  WarningIcon,
} from "./icons";
import { Composer, MessageRow } from "./Chat";
import type { Id, RunEvent } from "../lib/types";

/// An optional side panel — threads, run detail, task detail. The layout never
/// forces a permanent third column.
export function Inspector() {
  const { inspector, inspect } = useNavigation();
  if (!inspector) return null;

  return (
    <aside className="inspector">
      <div className="inspector-head">
        <span>
          {inspector.kind === "thread"
            ? "Thread"
            : inspector.kind === "run"
              ? "Run"
              : "Task"}
        </span>
        <span className="spacer" />
        <button className="icon-button" onClick={() => inspect(null)} title="Close">
          <CloseIcon size={15} />
        </button>
      </div>
      {inspector.kind === "thread" && <ThreadPanel messageId={inspector.messageId} />}
      {inspector.kind === "run" && <RunPanel runId={inspector.runId} />}
      {inspector.kind === "task" && <TaskPanel taskId={inspector.taskId} />}
    </aside>
  );
}

function ThreadPanel({ messageId }: { messageId: Id }) {
  const app = useApp();
  const replies = app.threads[messageId];
  const root = Object.values(app.messages)
    .flat()
    .find((message) => message.id === messageId);
  const channel = app.channels.find(
    (candidate) => candidate.id === root?.channel_id,
  );

  useEffect(() => {
    void store.loadThread(messageId);
  }, [messageId]);

  if (!root || !channel) return <Empty title="That message is gone" />;

  return (
    <>
      <div className="inspector-body">
        <MessageRow message={root} grouped={false} />
        <div style={{ height: 10 }} />
        {(replies ?? []).map((reply) => (
          <MessageRow key={reply.id} message={reply} grouped={false} />
        ))}
      </div>
      <Composer channel={channel} parentId={messageId} placeholder="Reply…" />
    </>
  );
}

export function RunPanel({ runId }: { runId: Id }) {
  const app = useApp();
  const run = app.runs[runId];
  const events = app.runEvents[runId] ?? [];

  useEffect(() => {
    void store.loadRun(runId);
  }, [runId]);

  if (!run) return <Empty title="Loading the run" />;
  const agent = app.members.find((member) => member.id === run.agent_id);
  const host = app.hosts.find((candidate) => candidate.id === run.host_id);

  return (
    <div className="inspector-body">
      <div className="card-title">{agent?.display_name}</div>
      <div className="card-sub">{run.headline}</div>
      <div className="card-row">
        <Chip tone={statusTone(run.status)}>{statusLabel(run.status)}</Chip>
        <Chip>{run.runtime}</Chip>
        {host && <Chip>{host.name}</Chip>}
        <Chip>{duration(run.started_at, run.ended_at)}</Chip>
      </div>
      {run.cwd && (
        <div className="card-sub" style={{ marginTop: 8, wordBreak: "break-all" }}>
          {run.cwd}
        </div>
      )}
      {run.error && (
        <div className="error-text" style={{ whiteSpace: "pre-wrap" }}>
          {run.error}
        </div>
      )}

      <div className="section-head">
        <span className="section-title">Activity</span>
      </div>
      {events.length === 0 && (
        <div className="card-sub">Nothing recorded yet.</div>
      )}
      {events.map((event) => (
        <RunEventRow key={event.id} event={event} />
      ))}
    </div>
  );
}

/// Each kind of activity gets the glyph that says what it is, so the log can be
/// skimmed instead of read.
function eventIcon(kind: RunEvent["kind"]) {
  switch (kind) {
    case "tool_call":
    case "command":
      return <TerminalIcon size={15} />;
    case "tool_result":
      return <CheckIcon size={15} />;
    case "file_change":
      return <FileIcon size={15} />;
    case "permission":
      return <ShieldIcon size={15} />;
    case "question":
      return <QuestionIcon size={15} />;
    case "error":
      return <WarningIcon size={15} />;
    case "plan":
      return <TasksIcon size={15} />;
    case "message":
      return <ThreadIcon size={15} />;
    case "thought":
      return <PulseIcon size={15} />;
    default:
      return <EventIcon size={15} />;
  }
}

function RunEventRow({ event }: { event: RunEvent }) {
  return (
    <div className={`run-event ${event.kind}`}>
      {eventIcon(event.kind)}
      <div className="text">{event.text}</div>
    </div>
  );
}

function TaskPanel({ taskId }: { taskId: Id }) {
  const app = useApp();
  const { go } = useNavigation();
  const task = app.tasks.find((candidate) => candidate.id === taskId);
  if (!task) return <Empty title="That task is gone" />;
  const owner = app.members.find((member) => member.id === task.owner_id);

  return (
    <div className="inspector-body">
      <div className="card-sub">{task.key}</div>
      <div className="card-title">{task.title}</div>
      {task.outcome && <div className="card-sub">{task.outcome}</div>}
      <div className="card-row">
        <Chip tone={statusTone(task.status)}>{statusLabel(task.status)}</Chip>
        {owner && <Chip>{owner.display_name}</Chip>}
        <Chip>{relative(task.updated_at)}</Chip>
      </div>
      <button
        className="button"
        style={{ marginTop: 12 }}
        onClick={() => go({ kind: "task", id: task.id })}
      >
        Open task
      </button>
    </div>
  );
}
