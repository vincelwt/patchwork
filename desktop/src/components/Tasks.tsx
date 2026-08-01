import { useMemo, useState } from "react";
import { useApi, useApp } from "../lib/store";
import { relative, statusLabel, statusTone } from "../lib/format";
import { Avatar, Chip, Field, Modal, Select, useNavigation } from "./common";
import { ChatView } from "./Chat";
import { RunPanel } from "./Inspector";
import { openExternal } from "../lib/desktop";
import { TASK_STATUSES } from "../lib/types";
import type { Task, TaskStatus } from "../lib/types";

/// The board makes concurrent agent work obvious: one column per state, and
/// every card says who owns it and whether something is running right now.
export function TasksBoard() {
  const app = useApp();
  const api = useApi();
  const { go } = useNavigation();
  const [filterOwner, setFilterOwner] = useState("");
  const [filterProject, setFilterProject] = useState("");
  const [dragging, setDragging] = useState<string | null>(null);
  const [dropColumn, setDropColumn] = useState<TaskStatus | null>(null);
  const [creating, setCreating] = useState(false);

  const tasks = useMemo(
    () =>
      app.tasks.filter(
        (task) =>
          (!filterOwner || task.owner_id === filterOwner) &&
          (!filterProject || task.project_id === filterProject),
      ),
    [app.tasks, filterOwner, filterProject],
  );

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">Tasks</span>
        <span className="spacer" />
        <select
          className="field"
          style={{ width: 160 }}
          value={filterOwner}
          onChange={(event) => setFilterOwner(event.target.value)}
        >
          <option value="">Anyone</option>
          {app.members.map((member) => (
            <option key={member.id} value={member.id}>
              {member.display_name}
            </option>
          ))}
        </select>
        <select
          className="field"
          style={{ width: 160 }}
          value={filterProject}
          onChange={(event) => setFilterProject(event.target.value)}
        >
          <option value="">Any project</option>
          {app.projects.map((project) => (
            <option key={project.id} value={project.id}>
              {project.name}
            </option>
          ))}
        </select>
        <button className="button primary" onClick={() => setCreating(true)}>
          New task
        </button>
      </div>

      <div className="board">
        {TASK_STATUSES.map((status) => {
          const column = tasks.filter((task) => task.status === status);
          return (
            <div
              key={status}
              className={`board-column${dropColumn === status ? " drop-target" : ""}`}
              onDragOver={(event) => {
                event.preventDefault();
                setDropColumn(status);
              }}
              onDragLeave={() => setDropColumn(null)}
              onDrop={async () => {
                setDropColumn(null);
                if (dragging) await api.moveTask(dragging, status);
                setDragging(null);
              }}
            >
              <div className="board-column-head">
                <span>{statusLabel(status)}</span>
                <span className="count">{column.length}</span>
              </div>
              <div className="board-column-body">
                {column.map((task) => (
                  <TaskCard
                    key={task.id}
                    task={task}
                    onDragStart={() => setDragging(task.id)}
                    onClick={() => go({ kind: "task", id: task.id })}
                  />
                ))}
              </div>
            </div>
          );
        })}
      </div>

      {creating && <NewTaskModal onClose={() => setCreating(false)} />}
    </div>
  );
}

function TaskCard({
  task,
  onClick,
  onDragStart,
}: {
  task: Task;
  onClick: () => void;
  onDragStart: () => void;
}) {
  const app = useApp();
  const owner = app.members.find((member) => member.id === task.owner_id);
  const project = app.projects.find((candidate) => candidate.id === task.project_id);
  const run = task.current_run_id ? app.runs[task.current_run_id] : undefined;

  return (
    <div
      className="task-card"
      draggable
      onDragStart={onDragStart}
      onClick={onClick}
    >
      <div className="key">{task.key}</div>
      <div className="title">{task.title}</div>
      <div className="meta">
        {owner && <Avatar member={owner} size={18} />}
        {project && <Chip>{project.name}</Chip>}
        {run && <Chip tone="accent">{run.headline || "running"}</Chip>}
        {task.pr_state && <Chip>PR #{task.pr_state.number}</Chip>}
      </div>
    </div>
  );
}

export function NewTaskModal({
  onClose,
  sourceChannelId,
}: {
  onClose: () => void;
  sourceChannelId?: string;
}) {
  const app = useApp();
  const api = useApi();
  const { go } = useNavigation();
  const [title, setTitle] = useState("");
  const [outcome, setOutcome] = useState("");
  const [owner, setOwner] = useState("");
  const [project, setProject] = useState("");
  const [start, setStart] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const create = async () => {
    setBusy(true);
    setError("");
    try {
      const task = await api.createTask({
        title,
        outcome,
        owner_id: owner || undefined,
        project_id: project || undefined,
        source_channel_id: sourceChannelId,
        start: start && !!owner,
      });
      onClose();
      go({ kind: "task", id: task.id });
    } catch (err) {
      setError(String((err as Error).message ?? err));
      setBusy(false);
    }
  };

  const ownerIsAgent =
    app.members.find((member) => member.id === owner)?.kind === "agent";

  return (
    <Modal
      title="New task"
      subtitle="A durable outcome someone — or some agent — owns."
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            disabled={!title.trim() || busy}
            onClick={create}
          >
            Create
          </button>
        </>
      }
    >
      <Field label="Title" value={title} onChange={setTitle} autoFocus />
      <Field
        label="Expected result"
        value={outcome}
        onChange={setOutcome}
        textarea
        placeholder="What has to be true when this is done?"
      />
      <Select
        label="Owner"
        value={owner}
        onChange={setOwner}
        options={[
          { value: "", label: "Nobody yet" },
          ...app.members.map((member) => ({
            value: member.id,
            label: `${member.display_name}${member.kind === "agent" ? " (agent)" : ""}`,
          })),
        ]}
      />
      <Select
        label="Project"
        value={project}
        onChange={setProject}
        options={[
          { value: "", label: "No code folder" },
          ...app.projects.map((candidate) => ({
            value: candidate.id,
            label: candidate.name,
          })),
        ]}
      />
      {ownerIsAgent && (
        <label className="form-row" style={{ flexDirection: "row", gap: 8 }}>
          <input
            type="checkbox"
            checked={start}
            onChange={(event) => setStart(event.target.checked)}
          />
          <span>Start the agent now</span>
        </label>
      )}
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

/// A task page keeps the discussion primary; execution detail opens beside it.
export function TaskPage({ taskId }: { taskId: string }) {
  const app = useApp();
  const api = useApi();
  const { inspect } = useNavigation();
  const task = app.tasks.find((candidate) => candidate.id === taskId);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showDetail, setShowDetail] = useState(false);

  if (!task) return <div className="empty">Task not found.</div>;

  const owner = app.members.find((member) => member.id === task.owner_id);
  const project = app.projects.find((candidate) => candidate.id === task.project_id);
  const run = task.current_run_id ? app.runs[task.current_run_id] : undefined;
  const previews = Object.values(app.previews).filter(
    (preview) => preview.task_id === task.id && preview.status === "live",
  );

  const runAgent = async () => {
    setBusy(true);
    setError("");
    try {
      const started = await api.runTask(task.id);
      inspect({ kind: "run", runId: started.id });
    } catch (err) {
      setError(String((err as Error).message ?? err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">{task.title}</span>
        <span className="subtitle">{task.key}</span>
        <span className="spacer" />
        <select
          className="field"
          style={{ width: 130 }}
          value={task.status}
          onChange={(event) =>
            api.updateTask(task.id, { status: event.target.value })
          }
        >
          {TASK_STATUSES.map((status) => (
            <option key={status} value={status}>
              {statusLabel(status)}
            </option>
          ))}
        </select>
        <select
          className="field"
          style={{ width: 150 }}
          value={task.owner_id ?? ""}
          onChange={(event) =>
            api.updateTask(task.id, { owner_id: event.target.value })
          }
        >
          <option value="">Unassigned</option>
          {app.members.map((member) => (
            <option key={member.id} value={member.id}>
              {member.display_name}
            </option>
          ))}
        </select>
        {owner?.kind === "agent" && (
          <button className="button primary" disabled={busy} onClick={runAgent}>
            {run ? "Run again" : "Run"}
          </button>
        )}
        <button className="button quiet" onClick={() => setShowDetail(!showDetail)}>
          {showDetail ? "Hide detail" : "Detail"}
        </button>
      </div>

      <div className="card-row" style={{ padding: "0 24px 6px", maxWidth: 980 }}>
        <Chip tone={statusTone(task.status)}>{statusLabel(task.status)}</Chip>
        {project && <Chip>{project.name}</Chip>}
        {run && <Chip tone="accent">{run.headline}</Chip>}
        {task.pr_url && (
          <button className="chip" onClick={() => openExternal(task.pr_url!)}>
            {task.pr_state ? `PR #${task.pr_state.number} · ${task.pr_state.state}` : "Pull request"}
          </button>
        )}
        {previews.map((preview) => (
          <button
            key={preview.id}
            className="chip accent"
            onClick={() =>
              openExternal(
                preview.local_only
                  ? `http://127.0.0.1:${preview.port}`
                  : preview.url,
              )
            }
          >
            Preview: {preview.label}
          </button>
        ))}
        <span className="spacer" />
        <span className="composer-hint">updated {relative(task.updated_at)}</span>
      </div>
      {error && <div className="error-text" style={{ padding: "0 24px" }}>{error}</div>}

      {showDetail ? (
        <div className="content">
          <ChatView channelId={task.discussion_channel_id} />
          <aside className="inspector">
            <div className="inspector-head">Execution</div>
            <TaskDetailPanel taskId={task.id} />
          </aside>
        </div>
      ) : (
        <ChatView channelId={task.discussion_channel_id} />
      )}
    </div>
  );
}

function TaskDetailPanel({ taskId }: { taskId: string }) {
  const api = useApi();
  const app = useApp();
  const { inspect } = useNavigation();
  const [detail, setDetail] = useState<Awaited<ReturnType<typeof api.task>>>();

  useMemo(() => {
    void api.task(taskId).then(setDetail);
  }, [taskId, app.tasks, app.runs]);

  if (!detail) return <div className="inspector-body">Loading…</div>;

  return (
    <div className="inspector-body">
      {detail.worktree && (
        <>
          <div className="section-title">Worktree</div>
          <div className="card-sub" style={{ wordBreak: "break-all" }}>
            {detail.worktree.path}
          </div>
          <Chip>{detail.worktree.branch || "no branch"}</Chip>
        </>
      )}

      <div className="section-title">Runs</div>
      {detail.runs.length === 0 && <div className="card-sub">No runs yet.</div>}
      {detail.runs.map((run) => {
        const agent = app.members.find((member) => member.id === run.agent_id);
        return (
          <button
            key={run.id}
            className="row"
            style={{ width: "100%" }}
            onClick={() => inspect({ kind: "run", runId: run.id })}
          >
            <span className="grow">
              <span className="name">{agent?.display_name}</span>
              <span className="sub">{run.headline || run.error || ""}</span>
            </span>
            <Chip tone={statusTone(run.status)}>{statusLabel(run.status)}</Chip>
          </button>
        );
      })}

      {detail.attachments.length > 0 && (
        <>
          <div className="section-title">Evidence</div>
          {detail.attachments.map((attachment) => (
            <button
              key={attachment.id}
              className="row"
              style={{ width: "100%" }}
              onClick={() =>
                openExternal(
                  `${api.baseUrl.replace(/\/$/, "")}${attachment.url}`,
                )
              }
            >
              <span className="grow">
                <span className="name">{attachment.file_name}</span>
              </span>
            </button>
          ))}
        </>
      )}

      {detail.previews.length > 0 && (
        <>
          <div className="section-title">Previews</div>
          {detail.previews.map((preview) => (
            <div className="row" key={preview.id}>
              <span className="grow">
                <span className="name">{preview.label}</span>
                <span className="sub">port {preview.port}</span>
              </span>
              <Chip tone={preview.status === "live" ? "positive" : ""}>
                {preview.status}
              </Chip>
            </div>
          ))}
        </>
      )}

      {detail.task.current_run_id && (
        <>
          <div className="section-title">Current run</div>
          <RunPanel runId={detail.task.current_run_id} />
        </>
      )}
    </div>
  );
}
