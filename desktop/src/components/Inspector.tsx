import { memo, useCallback, useEffect, useMemo, useState } from "react";
import { store, useApi, useApp, useAppSelector } from "../lib/store";
import { duration, relative, statusLabel, statusTone } from "../lib/format";
import { Avatar, Chip, proseText, useNavigation } from "./common";
import { Empty } from "./ui";
import { Card } from "./Cards";
import { Markdown } from "./Markdown";
import { useBottomAnchor } from "../lib/scroll";
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
import {
  AttachButton,
  Composer,
  DropZone,
  MessageRow,
  useAttachments,
  useHandles,
} from "./Chat";
import type { Id, Member, Run, RunEvent } from "@client/types";

/// An optional side panel — threads, run detail, task detail. The layout never
/// forces a permanent third column.
export function Inspector() {
  const { inspector, inspect } = useNavigation();
  if (!inspector) return null;

  return (
    <aside className="inspector">
      <div className="inspector-head" data-tauri-drag-region="deep">
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
  const handles = useHandles();
  const [dropped, setDropped] = useState<File[]>([]);
  const clearDropped = useCallback(() => setDropped([]), []);
  const replies = app.threads[messageId];
  // Flattening every loaded channel to find one message is a lot of work to
  // repeat on each event; the answer only changes when the messages do.
  const root = useMemo(() => {
    for (const list of Object.values(app.messages)) {
      const hit = list.find((message) => message.id === messageId);
      if (hit) return hit;
    }
    return undefined;
  }, [app.messages, messageId]);
  const channel = app.channels.find(
    (candidate) => candidate.id === root?.channel_id,
  );
  const authorOf = (id: Id) => app.members.find((member) => member.id === id);
  const { scrollerRef, contentRef, updatePinned } = useBottomAnchor(messageId, 60);

  useEffect(() => {
    void store.loadThread(messageId);
  }, [messageId]);

  if (!root || !channel) return <Empty title="That message is gone" />;

  return (
    <DropZone className="thread-pane" onFiles={setDropped}>
      <div className="inspector-body" ref={scrollerRef} onScroll={updatePinned}>
        <div ref={contentRef}>
          <MessageRow
            message={root}
            grouped={false}
            author={authorOf(root.author_id)}
            handles={handles}
          />
          <div style={{ height: 10 }} />
          {(replies ?? []).map((reply) => (
            <MessageRow
              key={reply.id}
              message={reply}
              grouped={false}
              author={authorOf(reply.author_id)}
              handles={handles}
            />
          ))}
        </div>
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
  // A live run appends to this log several times a second, so the panel reads
  // only what it draws — otherwise every unrelated message in the workspace
  // redraws the whole activity list.
  const { run, events, agent, host, question } = useAppSelector((data) => {
    const run = data.runs[runId];
    return {
      run,
      events: data.runEvents[runId],
      agent: data.members.find((member) => member.id === run?.agent_id),
      host: data.hosts.find((candidate) => candidate.id === run?.host_id),
      question: Object.values(data.questions).find(
        (candidate) => candidate.run_id === runId && candidate.status === "open",
      ),
    };
  });
  const api = useApi();
  const { scrollerRef, contentRef, updatePinned } = useBottomAnchor(runId, 60);

  useEffect(() => {
    void store.loadRun(runId);
  }, [runId]);

  if (!run) return <Empty title="Loading the run" />;
  const active = !["succeeded", "failed", "cancelled"].includes(run.status);

  return (
    <>
      <div
        className={embedded ? "" : "inspector-body"}
        ref={embedded ? undefined : scrollerRef}
        onScroll={embedded ? undefined : updatePinned}
      >
        <div ref={embedded ? undefined : contentRef}>
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
          {!events?.length && <div className="card-sub">Nothing recorded yet.</div>}
          {events?.map((event) => (
            <RunEventRow key={event.id} event={event} />
          ))}
        </div>
      </div>
      {active && <SteerBox run={run} agent={agent} />}
    </>
  );
}

/// Talking to a run while it is still running.
///
/// The task conversation is where feedback belongs when it is also a record.
/// This is the direct line for whoever is watching the log: queue a note for
/// the end of the current turn, or interrupt and say it now.
function SteerBox({ run, agent }: { run: Run; agent?: Member }) {
  const api = useApi();
  const [text, setText] = useState("");
  const [dropped, setDropped] = useState<File[]>([]);
  const clearDropped = useCallback(() => setDropped([]), []);
  const files = useAttachments({
    incoming: dropped,
    onConsumed: clearDropped,
    taskId: run.task_id,
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const empty = !text.trim() && files.pending.length === 0;

  const send = async (mode: "queue" | "interrupt") => {
    if (empty || busy || files.uploading > 0) return;
    setBusy(true);
    setError("");
    try {
      await api.steerRun(run.id, {
        prompt: text.trim(),
        mode,
        attachment_ids: files.pending.map((attachment) => attachment.id),
      });
      setText("");
      files.clear();
    } catch (err) {
      setError(String((err as Error).message ?? err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <DropZone className="run-steer" onFiles={setDropped}>
      {/* Which agent, and which of the two things it can hear. A control box
          that does not name its target is a message sent into the dark. */}
      <div className="steer-target">
        Straight to {agent?.display_name ?? "this agent"} in this run
      </div>
      <div className="composer">
        {files.strip}
        <textarea
          rows={1}
          {...proseText}
          spellCheck
          placeholder={`Tell ${agent?.display_name ?? "the agent"} something…`}
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== "Enter" || event.shiftKey) return;
            event.preventDefault();
            void send(event.metaKey || event.ctrlKey ? "interrupt" : "queue");
          }}
          onPaste={(event) => {
            const pasted = Array.from(event.clipboardData.files);
            if (pasted.length === 0) return;
            event.preventDefault();
            void files.attach(pasted);
          }}
        />
        <div className="composer-row">
          <AttachButton onFiles={(picked) => void files.attach(picked)} />
          <span className="spacer" />
          <button
            className="button quiet"
            disabled={busy || empty || files.uploading > 0}
            title="Stop what it is doing and hand it this now"
            onClick={() => void send("interrupt")}
          >
            Interrupt
          </button>
          <button
            className="button primary"
            disabled={busy || empty || files.uploading > 0}
            title="Wait for the end of the current turn"
            onClick={() => void send("queue")}
          >
            Queue
          </button>
        </div>
      </div>
      {error && <div className="error-text">{error}</div>}
    </DropZone>
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

/// A log line never changes once written, so appending the next one should not
/// re-render — or re-parse the markdown of — every line above it.
const RunEventRow = memo(function RunEventRow({ event }: { event: RunEvent }) {
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
});

function TaskPanel({ taskId }: { taskId: Id }) {
  const { task, owner } = useAppSelector((data) => {
    const task = data.tasks.find((candidate) => candidate.id === taskId);
    return {
      task,
      owner: data.members.find((member) => member.id === task?.owner_id),
    };
  });
  const { go } = useNavigation();
  if (!task) return <Empty title="That task is gone" />;

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
