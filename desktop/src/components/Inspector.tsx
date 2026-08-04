import { useCallback, useEffect, useRef, useState } from "react";
import { store, useApi, useApp } from "../lib/store";
import { duration, relative, statusLabel, statusTone } from "../lib/format";
import { Avatar, Chip, useNavigation } from "./common";
import { Empty } from "./ui";
import { Card } from "./Cards";
import { Markdown } from "./Markdown";
import {
  CheckIcon,
  CloseIcon,
  EventIcon,
  FileIcon,
  PulseIcon,
  QuestionIcon,
  ShieldIcon,
  Spinner,
  TasksIcon,
  TerminalIcon,
  ThreadIcon,
  WarningIcon,
} from "./icons";
import { Composer, DropZone, MessageRow } from "./Chat";
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
  const [dropped, setDropped] = useState<File[]>([]);
  const clearDropped = useCallback(() => setDropped([]), []);
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
    <DropZone className="thread-pane" onFiles={setDropped}>
      <div className="inspector-body">
        <MessageRow message={root} grouped={false} />
        <div style={{ height: 10 }} />
        {(replies ?? []).map((reply) => (
          <MessageRow key={reply.id} message={reply} grouped={false} />
        ))}
      </div>
      <Composer
        channel={channel}
        parentId={messageId}
        placeholder="Reply…"
        incoming={dropped}
        onConsumed={clearDropped}
      />
    </DropZone>
  );
}

export function RunPanel({
  runId,
  embedded,
}: {
  runId: Id;
  /// Already inside somebody else's scroller — don't open a second one.
  embedded?: boolean;
}) {
  const app = useApp();
  const api = useApi();
  const run = app.runs[runId];
  const events = app.runEvents[runId] ?? [];
  const log = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);

  useEffect(() => {
    void store.loadRun(runId);
  }, [runId]);

  // A live run should scroll itself, but only while the reader has not gone
  // back to look at something earlier.
  useEffect(() => {
    const element = log.current;
    if (element && pinned.current) element.scrollTop = element.scrollHeight;
  }, [events.length]);

  if (!run) return <Empty title="Loading the run" />;
  const agent = app.members.find((member) => member.id === run.agent_id);
  const host = app.hosts.find((candidate) => candidate.id === run.host_id);
  const active = !["succeeded", "failed", "cancelled"].includes(run.status);
  const question = Object.values(app.questions).find(
    (candidate) => candidate.run_id === run.id && candidate.status === "open",
  );

  return (
    <div
      className={embedded ? "" : "inspector-body"}
      ref={embedded ? undefined : log}
      onScroll={
        embedded
          ? undefined
          : (event) => {
              const element = event.currentTarget;
              pinned.current =
                element.scrollHeight - element.scrollTop - element.clientHeight < 60;
            }
      }
    >
      {!embedded && (
        <>
          <div className="run-summary">
            <Avatar member={agent} size={30} />
            <span className="grow">
              <span className="name">{agent?.display_name}</span>
              <span className="sub">{run.headline || statusLabel(run.status)}</span>
            </span>
            {active && (
              <button className="button quiet" onClick={() => api.cancelRun(run.id)}>
                Stop
              </button>
            )}
          </div>
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
        </>
      )}
      {run.error && (
        <div className="error-text" style={{ whiteSpace: "pre-wrap" }}>
          {run.error}
        </div>
      )}

      {/* The question belongs where the person looking at the run is, not only
          in a transcript they may have scrolled away from. */}
      {question && <Card card={{ type: "question", question_id: question.id }} />}

      <div className="section-head">
        <span className="section-title">Activity</span>
        {active && <Spinner size={12} />}
      </div>
      {events.length === 0 && <div className="card-sub">Nothing recorded yet.</div>}
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

/// An agent writes markdown even in its log. Prose kinds get rendered; the
/// mechanical ones (a command, a path) stay verbatim, because a file called
/// `**init**.py` is not bold.
const PROSE: RunEvent["kind"][] = ["message", "plan", "thought", "lifecycle"];

function RunEventRow({ event }: { event: RunEvent }) {
  return (
    <div className={`run-event ${event.kind}`}>
      {eventIcon(event.kind)}
      <div className="text">
        {PROSE.includes(event.kind) ? (
          <Markdown body={event.text} compact />
        ) : (
          event.text
        )}
      </div>
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
