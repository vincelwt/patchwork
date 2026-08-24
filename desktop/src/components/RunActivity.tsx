import { memo, useEffect, useMemo, useState } from "react";
import { store, useAppSelector } from "../lib/store";
import { duration, timeOfDay } from "../lib/format";
import { Markdown } from "./Markdown";
import {
  CheckIcon,
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
import { projectRunActivity, toolOutput } from "@client/run-activity";
import type { ToolActivity } from "@client/run-activity";
import type { Id, RunEvent } from "@client/types";

/// What an agent actually did, as a list.
///
/// The run panel and the inline chat trace are the same log read in two
/// places, so they are the same component reading the same projection. Only
/// the surroundings differ: the panel adds the run's metadata and the box for
/// talking to it, the transcript adds nothing.
export function RunActivityList({
  events,
  active,
}: {
  events?: RunEvent[];
  /// A run still going gets a spinner in the heading.
  active: boolean;
}) {
  const activity = useMemo(() => projectRunActivity(events ?? []), [events]);
  const summary = [
    `${activity.toolCount} tool${activity.toolCount === 1 ? "" : "s"}`,
    activity.fileCount
      ? `${activity.fileCount} file${activity.fileCount === 1 ? "" : "s"}`
      : "",
    activity.warningCount
      ? `${activity.warningCount} warning${activity.warningCount === 1 ? "" : "s"}`
      : "",
  ].filter(Boolean).join(" · ");

  return (
    <>
      <div className="section-head run-activity-head">
        <span className="section-title">Activity</span>
        <span className="spacer" />
        {events?.length ? <span className="run-activity-stats">{summary}</span> : null}
        {active && <Spinner size={12} />}
      </div>
      {!events?.length && <div className="card-sub">Nothing recorded yet.</div>}
      {activity.items.map((item) =>
        item.type === "tool" ? (
          <ToolActivityRow key={item.call.id} tool={item} />
        ) : item.type === "thought" ? (
          <ThoughtActivityRow key={item.id} text={item.text} />
        ) : (
          <RunEventRow key={item.event.id} event={item.event} />
        ),
      )}
      {activity.debug.length > 0 && (
        <RunEventDisclosure
          key="debug"
          label={`Debug events (${activity.debug.length})`}
          events={activity.debug}
        />
      )}
      {!!events?.length && (
        <RunEventDisclosure
          key="raw"
          label={`Show raw events (${events.length})`}
          events={events}
        />
      )}
    </>
  );
}

/// The same log, inline in the transcript under the run it belongs to.
///
/// Loading is the panel's loader and the events are the panel's events —
/// there is one projection of a run, not one per surface.
export function RunTrace({ runId }: { runId: Id }) {
  const { events, active } = useAppSelector((data) => ({
    events: data.runEvents[runId],
    active: !["succeeded", "failed", "cancelled"].includes(
      data.runs[runId]?.status ?? "",
    ),
  }));

  useEffect(() => {
    void store.loadRun(runId);
  }, [runId]);

  return (
    <div className="chat-run-trace">
      <RunActivityList events={events} active={active} />
    </div>
  );
}

function elapsed(from: number, to: number) {
  const milliseconds = Math.max(0, to - from);
  if (milliseconds < 100) return "<0.1s";
  if (milliseconds < 10_000) return `${(milliseconds / 1000).toFixed(1)}s`;
  return duration(from, to);
}

function displayValue(value: unknown) {
  if (typeof value === "string") return value.trimEnd();
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function ToolField({ label, value }: { label: string; value?: unknown }) {
  if (value === undefined || value === "") return null;
  return (
    <div className="run-tool-field">
      <div className="run-tool-label">{label}</div>
      <pre className="code-block">{displayValue(value)}</pre>
    </div>
  );
}

const ToolActivityRow = memo(function ToolActivityRow({ tool }: { tool: ToolActivity }) {
  const failed = tool.status === "failed";
  const working = ["pending", "in_progress"].includes(tool.status);
  const [open, setOpen] = useState(failed);

  useEffect(() => {
    if (failed) setOpen(true);
  }, [failed]);

  const exit = [
    tool.exitCode === undefined ? "" : `exit ${tool.exitCode}`,
    tool.signal ?? "",
  ].filter(Boolean).join(" · ");

  return (
    <details
      className={`run-tool ${tool.status}`}
      open={open}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>
        <span className="run-tool-icon">
          {failed ? (
            <WarningIcon size={15} />
          ) : working ? (
            <Spinner size={14} />
          ) : (
            <CheckIcon size={15} />
          )}
        </span>
        <span className="run-tool-title">{tool.title}</span>
        <span className="run-tool-status">{tool.status.replaceAll("_", " ")}</span>
        <span className="run-tool-duration">{elapsed(tool.startedAt, tool.endedAt)}</span>
      </summary>
      {open && (
        <div className="run-tool-detail">
          <div className="run-tool-timing">
            {timeOfDay(tool.startedAt)}
            {tool.updates.length > 0 ? ` → ${timeOfDay(tool.endedAt)}` : ""}
            {exit ? ` · ${exit}` : ""}
          </div>
          <ToolField label="Paths" value={tool.paths.length ? tool.paths.join("\n") : undefined} />
          <ToolField label="Working directory" value={tool.cwd} />
          <ToolField label="Input" value={tool.input} />
          <ToolField label="Output" value={toolOutput(tool.updates)} />
        </div>
      )}
    </details>
  );
});

const ThoughtActivityRow = memo(function ThoughtActivityRow({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  const summary = text.replace(/\s+/g, " ").trim();
  const preview = summary.length > 90 ? `${summary.slice(0, 89)}…` : summary;
  return (
    <details
      className="run-thought"
      open={open}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>
        <PulseIcon size={15} />
        <span className="run-thought-title">Thinking</span>
        {preview && <span className="run-thought-preview">· {preview}</span>}
      </summary>
      {open && (
        <div className="run-thought-body">
          <Markdown body={text} compact />
        </div>
      )}
    </details>
  );
});

const RunEventDisclosure = memo(function RunEventDisclosure({
  label,
  events,
}: {
  label: string;
  events: RunEvent[];
}) {
  const [open, setOpen] = useState(false);
  return (
    <details
      className="run-log-disclosure"
      open={open}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>{label}</summary>
      {open && (
        <div className="run-log-events">
          {events.map((event) => (
            <RunEventRow key={event.id} event={event} />
          ))}
        </div>
      )}
    </details>
  );
});

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
    // A status is the agent saying what it is doing right now; the transcript
    // keeps only the last one, so the log is where the whole story is.
    case "status":
    case "thought":
      return <PulseIcon size={15} />;
    default:
      return <EventIcon size={15} />;
  }
}

/// An agent writes markdown even in its log. Prose kinds get rendered; the
/// mechanical ones (a command, a path) stay verbatim, because a file called
/// `**init**.py` is not bold.
const PROSE: RunEvent["kind"][] = [
  "message",
  "plan",
  "status",
  "thought",
  "lifecycle",
];

/// A log line never changes once written, so appending the next one should not
/// re-render — or re-parse the markdown of — every line above it.
const RunEventRow = memo(function RunEventRow({ event }: { event: RunEvent }) {
  const warning = event.kind === "lifecycle" && /warn|error|failed|could not|denied/i.test(event.text);
  return (
    <div className={`run-event ${event.kind}${warning ? " warning" : ""}`}>
      {warning ? <WarningIcon size={15} /> : eventIcon(event.kind)}
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
