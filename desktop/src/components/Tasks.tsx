import { useEffect, useState } from "react";
import { useApi, useApp, useAppSelector } from "../lib/store";
import {
  dateInputToMillis,
  dateInputValue,
  dayLabel,
  dueLabel,
  pullRequestStatus,
  pullRequestTone,
  relative,
  statusLabel,
  statusTone,
  timeOfDay,
} from "../lib/format";
import { isRunActive, readTask, situationTone } from "../lib/task";
import { Avatar, Chip, memberOption, useNavigation } from "./common";
import {
  Dropdown,
  EditableText,
  MenuButton,
  Section,
  type MenuItem,
} from "./ui";
import {
  BranchIcon,
  CheckIcon,
  CloseIcon,
  ExternalIcon,
  MoreIcon,
  QuestionIcon,
  Spinner,
  TrashIcon,
  WarningIcon,
} from "./icons";
import { ChatView } from "./Chat";
import { RunPanel } from "./Inspector";
import { openExternal } from "../lib/desktop";
import { TASK_STATUSES } from "@client/types";
import type { Member, Task } from "@client/types";

/// Who is on this task right now, when that is more than one agent. A single
/// agent stays the single avatar it has always been, wherever it already sat.
function AgentStack({ members, size }: { members: Member[]; size: number }) {
  return (
    <span
      className="agent-stack"
      title={members.map((member) => member.display_name).join(", ")}
    >
      {members.map((member) => (
        <Avatar key={member.id} member={member} size={size} />
      ))}
    </span>
  );
}

const PULL_REQUEST_ICONS = {
  OPEN: BranchIcon,
  DRAFT: BranchIcon,
  MERGED: CheckIcon,
  CLOSED: CloseIcon,
  PENDING: Spinner,
  SUCCESS: CheckIcon,
  FAILURE: WarningIcon,
};

function PullRequestStatusIcon({
  state,
  checks,
  size,
}: {
  state?: string;
  checks?: string;
  size: number;
}) {
  const status = pullRequestStatus(state, checks);
  const Icon = PULL_REQUEST_ICONS[status as keyof typeof PULL_REQUEST_ICONS] ?? ExternalIcon;
  return <Icon size={size} />;
}

// --- rows -------------------------------------------------------------------

/// One task, anywhere it is listed: what it is called and where it stands.
///
/// The key, the status and the outcome used to sit here as well. The brief
/// says all three in a sentence, and a row that has to be decoded is a row
/// nobody reads.
export function TaskRow({ task }: { task: Task }) {
  const { members, runs, projects } = useAppSelector((data) => ({
    members: data.members,
    runs: data.runs,
    projects: data.projects,
  }));
  const { go } = useNavigation();
  const state = readTask(task, members, runs);
  const due = dueLabel(task.due_at);
  // A workspace with one project puts the same word on every row, which is
  // the same as putting it on none of them.
  const project =
    projects.length > 1
      ? projects.find((candidate) => candidate.id === task.project_id)
      : undefined;

  return (
    <button
      className="row hoverable"
      title={task.key}
      onClick={() => go({ kind: "task", id: task.id })}
    >
      <span className="grow">
        <span className="name">{task.title}</span>
        <span className="sub">{state.headline}</span>
      </span>
      {due && state.situation !== "done" && state.situation !== "canceled" && (
        <Chip tone={due.overdue ? "danger" : "caution"}>{due.text}</Chip>
      )}
      {project && <Chip>{project.name}</Chip>}
      {state.agents.length > 1 ? (
        <AgentStack members={state.agents} size={20} />
      ) : state.owner ? (
        <Avatar member={state.owner} size={20} />
      ) : null}
    </button>
  );
}

// --- the board --------------------------------------------------------------

/// The old kanban, kept for the people who read work as columns. It cannot
/// move a task any more: the relay derives the status from the runs and the
/// open ask, so dragging a card between columns would be a lie the moment it
/// landed.
export function TasksBoard() {
  const app = useApp();
  const { go } = useNavigation();
  const [filterOwner, setFilterOwner] = useState("");
  const [filterProject, setFilterProject] = useState("");

  const owners = app.members.filter((member) =>
    app.tasks.some((task) => task.owner_id === member.id),
  );
  const tasks = app.tasks.filter(
    (task) =>
      (!filterOwner || task.owner_id === filterOwner) &&
      (!filterProject || task.project_id === filterProject),
  );

  return (
    <div className="column">
      <div className="topbar" data-tauri-drag-region="deep">
        <span className="title">Board</span>
        <span className="spacer" />
        {/* A filter that can only ever say "anyone" is a control that does
            nothing but take up the width it needs to say so. */}
        {owners.length > 1 && (
          <Dropdown
            quiet
            align="right"
            value={filterOwner}
            onChange={setFilterOwner}
            options={[{ value: "", label: "Anyone" }, ...owners.map(memberOption)]}
          />
        )}
        {app.projects.length > 1 && (
          <Dropdown
            quiet
            align="right"
            value={filterProject}
            onChange={setFilterProject}
            options={[
              { value: "", label: "Any project" },
              ...app.projects.map((project) => ({
                value: project.id,
                label: project.name,
              })),
            ]}
          />
        )}
        <button className="button quiet" onClick={() => go({ kind: "inbox" })}>
          Home
        </button>
      </div>

      <div className="board">
        {TASK_STATUSES.map((status) => {
          const column = tasks.filter((task) => task.status === status);
          return (
            <div key={status} className="board-column">
              <div className="board-column-head">
                <span className={`column-dot ${status}`} />
                <span>{statusLabel(status)}</span>
                {column.length > 0 && <span className="count">{column.length}</span>}
              </div>
              <div className="board-column-body">
                {column.map((task) => (
                  <TaskCard key={task.id} task={task} />
                ))}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function TaskCard({ task }: { task: Task }) {
  const app = useApp();
  const { go } = useNavigation();
  const state = readTask(task, app.members, app.runs);
  const due = dueLabel(task.due_at);

  return (
    <div
      className={`task-card ${state.situation}`}
      // A card is a button in everything but tag name: reachable by keyboard,
      // and opened by Enter like every other row in the app.
      role="button"
      tabIndex={0}
      title={task.key}
      onClick={() => go({ kind: "task", id: task.id })}
      onKeyDown={(event) => {
        if (event.key === "Enter" && event.target === event.currentTarget) {
          event.preventDefault();
          go({ kind: "task", id: task.id });
        }
      }}
    >
      <div className="title">{task.title}</div>
      {task.brief && (
        <div className={`situation ${situationTone(state.situation)}`}>
          <span className="line">{task.brief}</span>
        </div>
      )}
      <div className="meta">
        {due && <Chip tone={due.overdue ? "danger" : "caution"}>{due.text}</Chip>}
        <span className="spacer" />
        {state.agents.length > 1 ? (
          <AgentStack members={state.agents} size={18} />
        ) : state.owner ? (
          <Avatar member={state.owner} size={18} />
        ) : null}
      </div>
    </div>
  );
}

/// Closing and deleting, which are the only two things a person still decides
/// about a task's state. Everything else follows from the runs and the ask.
function taskManagementItems(
  task: Task,
  api: ReturnType<typeof useApi>,
  onDelete: () => void,
): (MenuItem | "separator")[] {
  const closed = task.status === "done" || task.status === "canceled";
  return [
    {
      key: "done",
      label: closed ? "Reopen" : "Mark done",
      icon: <CheckIcon size={15} />,
      onSelect: () =>
        void api.updateTask(task.id, { status: closed ? "planned" : "done" }),
    },
    {
      key: "cancel",
      label: "Cancel this task",
      disabled: closed,
      onSelect: () => void api.moveTask(task.id, "canceled"),
    },
    "separator",
    {
      key: "delete",
      label: "Delete task",
      icon: <TrashIcon size={15} />,
      danger: true,
      onSelect: onDelete,
    },
  ];
}

// --- the task page ----------------------------------------------------------

/// A task page is the conversation, with one line pinned above it saying where
/// the task stands and, when something is being asked of you, one button.
///
/// Everything that used to compete with the discussion, a status rail, a row
/// of facts, an evidence gallery, is either gone or behind Details. The
/// transcript is where the work happened, so it is where the work is read.
export function TaskPage({ taskId }: { taskId: string }) {
  const app = useApp();
  const api = useApi();
  const { go, toast } = useNavigation();
  const task = app.tasks.find((candidate) => candidate.id === taskId);
  const [details, setDetails] = useState(false);
  const [answering, setAnswering] = useState(false);

  if (!task) {
    return (
      <div className="column">
        <div className="empty">
          <div className="empty-title">That task is gone</div>
        </div>
      </div>
    );
  }

  const state = readTask(task, app.members, app.runs);
  const ask = state.ask;

  return (
    <div className="column">
      <div className="topbar" data-tauri-drag-region="deep">
        <button className="button quiet" onClick={() => go({ kind: "inbox" })}>
          ‹ Home
        </button>
        <span className="spacer" />
        <button
          className={`button quiet${details ? " active" : ""}`}
          onClick={() => setDetails(!details)}
        >
          Details
        </button>
        <MenuButton
          align="right"
          title="More"
          items={taskManagementItems(task, api, async () => {
            try {
              await api.deleteTask(task.id);
              go({ kind: "inbox" });
            } catch (err) {
              toast(String((err as Error).message ?? err));
            }
          })}
        >
          <MoreIcon size={17} />
        </MenuButton>
      </div>

      <div className="task-header">
        {/* The key is how a person cites the task to an agent, not something
            to read every time the page opens. */}
        <EditableText
          className="task-title"
          value={task.title}
          title={task.key}
          onCommit={(title) => void api.updateTask(task.id, { title })}
        />

        <div className={`task-situation ${situationTone(state.situation)}`}>
          {(state.situation === "working" || state.situation === "queued") && (
            <Spinner size={14} />
          )}
          {state.situation === "asking" && <QuestionIcon size={15} />}
          {state.situation === "blocked" && <WarningIcon size={15} />}
          {state.agents.length > 1 && (
            <AgentStack members={state.agents} size={20} />
          )}
          <span className="grow">
            <span className="line">{state.headline}</span>
          </span>
          {/* Only an approval can be given from up here: it is one word and one
              press. An ask with options is answered on its own card in the
              conversation, where the options are. */}
          {ask?.action && (
            <button
              className="button primary"
              disabled={answering}
              onClick={async () => {
                setAnswering(true);
                try {
                  await api.answerAsk(ask.id, [ask.action!]);
                } catch (err) {
                  toast(String((err as Error).message ?? err));
                } finally {
                  setAnswering(false);
                }
              }}
            >
              {ask.action}
            </button>
          )}
        </div>
      </div>

      <div className="content">
        <ChatView channelId={task.discussion_channel_id} />
        {details && (
          <aside className="inspector task-side-panel">
            <div className="inspector-head">
              <span>Details</span>
              <span className="spacer" />
              <button
                className="icon-button"
                onClick={() => setDetails(false)}
                title="Close"
                aria-label="Close details"
              >
                ×
              </button>
            </div>
            <TaskDetails task={task} />
          </aside>
        )}
      </div>
    </div>
  );
}

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <span className="fact">
      <span className="fact-label">{label}</span>
      {children}
    </span>
  );
}

/// Who owns it, where it lives, when it is due, and what has run. None of it
/// is news, which is why none of it is on the page by default.
function TaskDetails({ task }: { task: Task }) {
  const api = useApi();
  const app = useApp();
  const { inspect } = useNavigation();
  const [detail, setDetail] = useState<Awaited<ReturnType<typeof api.task>>>();

  // What actually makes this panel stale: this task moving, or one of its runs
  // changing state. Watching the whole tasks and runs maps meant refetching
  // the detail over HTTP on every run event in the workspace — several times a
  // second while any agent is working, most of it for other people's tasks.
  const signature = useAppSelector((data) => {
    const current = data.tasks.find((candidate) => candidate.id === task.id);
    const runs = Object.values(data.runs)
      .filter((run) => run.task_id === task.id)
      .map((run) => `${run.id}:${run.status}`)
      .sort()
      .join(",");
    return `${current?.status ?? ""}|${current?.updated_at ?? ""}|${runs}`;
  });

  useEffect(() => {
    void api.task(task.id).then(setDetail);
  }, [task.id, signature, api]);

  const due = dueLabel(task.due_at);
  // Several agents can be inside this task at once. Each one gets its own
  // thinking below, because "what is happening" is a different answer per
  // agent — and one of them stops without stopping the others.
  const live = (detail?.runs ?? []).filter(isRunActive);
  const currentRunId = live[0]?.id ?? task.current_run_id;

  return (
    <div className="inspector-body">
      {task.outcome && <div className="card-sub">{task.outcome}</div>}

      <div className="task-facts">
        <Fact label="Owner">
          <Dropdown
            quiet
            value={task.owner_id ?? ""}
            onChange={(owner_id) => void api.updateTask(task.id, { owner_id })}
            options={[
              { value: "", label: "Unassigned", icon: <Avatar size={18} /> },
              ...app.members.map(memberOption),
            ]}
          />
        </Fact>
        {app.projects.length > 1 && (
          <Fact label="Project">
            <Dropdown
              quiet
              value={task.project_id ?? ""}
              onChange={(project_id) => void api.updateTask(task.id, { project_id })}
              options={[
                { value: "", label: "None" },
                ...app.projects.map((candidate) => ({
                  value: candidate.id,
                  label: candidate.name,
                })),
              ]}
            />
          </Fact>
        )}
        <Fact label="Due">
          <input
            className="date-input"
            type="date"
            value={dateInputValue(task.due_at)}
            onChange={(event) =>
              void api.updateTask(task.id, {
                due_at: dateInputToMillis(event.target.value),
              })
            }
          />
          {due && <Chip tone={due.overdue ? "danger" : "caution"}>{due.text}</Chip>}
        </Fact>
        {task.pr_url && (
          <Fact label="Pull request">
            <button
              className={`chip ${pullRequestTone(
                task.pr_state?.state,
                task.pr_state?.checks,
              )}`.trim()}
              onClick={() => openExternal(task.pr_url!)}
            >
              <PullRequestStatusIcon
                state={task.pr_state?.state}
                checks={task.pr_state?.checks}
                size={12}
              />
              {task.pr_state
                ? `#${task.pr_state.number} · ${task.pr_state.state.toLowerCase()}`
                : "Open"}
            </button>
          </Fact>
        )}
        <span className="spacer" />
        <span className="composer-hint">updated {relative(task.updated_at)}</span>
      </div>

      {!detail ? (
        <Spinner size={14} />
      ) : (
        <>
          {detail.worktree && (
            <Section title="Worktree">
              <div className="card-sub" style={{ wordBreak: "break-all" }}>
                {detail.worktree.path}
              </div>
              <Chip>{detail.worktree.branch || "no branch"}</Chip>
            </Section>
          )}

          {task.active_continuation && (
            <Section title="Waiting on something outside">
              <div className="card-sub">{task.active_continuation.summary}</div>
              <div className="card-sub">
                Deadline {dayLabel(task.active_continuation.deadline_at)} at{" "}
                {timeOfDay(task.active_continuation.deadline_at)}
              </div>
            </Section>
          )}

          <Section title="Runs">
            {detail.runs.length === 0 && (
              <div className="card-sub">Nothing has run yet.</div>
            )}
            {detail.runs.map((run) => {
              const agent = app.members.find((member) => member.id === run.agent_id);
              return (
                <button
                  key={run.id}
                  className="row"
                  onClick={() => inspect({ kind: "run", runId: run.id })}
                >
                  <span className="grow">
                    <span className="name">{agent?.display_name}</span>
                    <span className="sub">
                      {run.headline || run.error || relative(run.created_at)}
                    </span>
                  </span>
                  <Chip tone={statusTone(run.status)}>{statusLabel(run.status)}</Chip>
                </button>
              );
            })}
          </Section>

          {detail.previews.length > 0 && (
            <Section title="Previews">
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
            </Section>
          )}

          {currentRunId && (
            <Section title="Current run">
              <RunPanel runId={currentRunId} embedded />
            </Section>
          )}
        </>
      )}
    </div>
  );
}
