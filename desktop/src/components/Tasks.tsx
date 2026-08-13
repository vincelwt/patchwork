import { useEffect, useMemo, useRef, useState } from "react";
import { useApi, useApp, useAppSelector } from "../lib/store";
import {
  dateInputToMillis,
  dateInputValue,
  dueLabel,
  pullRequestTone,
  relative,
  statusLabel,
  statusTone,
} from "../lib/format";
import {
  isRunActive,
  readTask,
  situationTone,
  stepIndex,
  TASK_STEPS,
} from "../lib/task";
import type { NextAction, TaskState } from "../lib/task";
import {
  Avatar,
  Chip,
  Field,
  memberOption,
  Modal,
  proseText,
  useNavigation,
} from "./common";
import {
  Dropdown,
  EditableText,
  FormSelect,
  Menu,
  MenuButton,
  Section,
  type MenuItem,
  Toggle,
} from "./ui";
import {
  AgentIcon,
  AttachIcon,
  BranchIcon,
  ChevronIcon,
  CheckIcon,
  CloseIcon,
  ExternalIcon,
  MoreIcon,
  PlayIcon,
  PlusIcon,
  QuestionIcon,
  Spinner,
  StopIcon,
  TrashIcon,
  WarningIcon,
} from "./icons";
import { Attached, ChatView, DictateButton } from "./Chat";
import { Lightbox, TextEvidence } from "./Evidence";
import { evidenceKind, isTextEvidence } from "@client/evidence";
import { RunPanel } from "./Inspector";
import { openExternal } from "../lib/desktop";
import { useFileUrl, useGrantedFileUrl, usePreviewUrl } from "../lib/file";
import { isTerminalTaskStatus, TASK_STATUSES } from "@client/types";
import type {
  Attachment,
  Id,
  Member,
  Preview,
  Task,
  TaskDetail,
  TaskStatus,
} from "@client/types";

/// Everything that can be done to a task, in one place. The task page, the
/// board card and the inspector all call this, so "Start" means the same thing
/// and does the same thing wherever you press it.
function useTaskActions(task: Task) {
  const api = useApi();
  const { inspect, toast } = useNavigation();
  const [assigning, setAssigning] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const start = async (agentId?: Id, prompt?: string) => {
    setBusy(true);
    setError("");
    try {
      await api.runTask(task.id, { agent_id: agentId, prompt });
    } catch (err) {
      setError(String((err as Error).message ?? err));
    } finally {
      setBusy(false);
    }
  };

  const perform = async (action: NextAction, state: TaskState) => {
    setError("");
    try {
      switch (action.kind) {
        case "assign":
          setAssigning(true);
          break;
        case "start":
        case "retry":
          await start();
          break;
        case "stop": {
          // Stopping a task stops the task: every agent on it, not whichever
          // one happens to be newest. The label says "Stop all" when it is
          // more than one.
          const running = state.activeRuns.length
            ? state.activeRuns
            : state.run
              ? [state.run]
              : [];
          await Promise.all(running.map((run) => api.cancelRun(run.id)));
          break;
        }
        case "answer":
          if (state.question) inspect({ kind: "run", runId: state.question.run_id });
          else if (state.run) inspect({ kind: "run", runId: state.run.id });
          break;
        case "approve": {
          setBusy(true);
          try {
            await api.approveTask(task.id);
          } finally {
            setBusy(false);
          }
          break;
        }
        case "complete":
          await api.updateTask(task.id, { status: "done" });
          toast("Task closed");
          break;
        case "reopen":
          await api.updateTask(task.id, { status: "planned" });
          break;
      }
      return true;
    } catch (err) {
      setError(String((err as Error).message ?? err));
      return false;
    }
  };

  return { perform, start, busy, error, assigning, setAssigning };
}

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
};

function PullRequestStatusIcon({ state, size }: { state?: string; size: number }) {
  const Icon = PULL_REQUEST_ICONS[state?.toUpperCase() as keyof typeof PULL_REQUEST_ICONS] ?? ExternalIcon;
  return <Icon size={size} />;
}

function actionIcon(kind: NextAction["kind"]) {
  switch (kind) {
    case "start":
    case "retry":
      return <PlayIcon size={13} />;
    case "stop":
      return <StopIcon size={13} />;
    case "answer":
      return <QuestionIcon size={14} />;
    case "approve":
      return <CheckIcon size={14} />;
    default:
      return null;
  }
}

/// The default owner: the agent you gave work to last, because a workspace with
/// one working agent should not make you pick it every single time.
const LAST_OWNER = "patchwork.lastTaskOwner";
const LAST_AGENT = "patchwork.lastTaskAgent";
const COLLAPSED_STATUSES = "patchwork.collapsedTaskStatuses";
const LEGACY_DONE_COLLAPSED = "patchwork.tasksDoneCollapsed";
const TASK_DRAFT_PREFIX = "patchwork.taskDraft.";

function initialCollapsedStatuses(): TaskStatus[] {
  try {
    const saved = localStorage.getItem(COLLAPSED_STATUSES);
    if (saved) {
      const statuses = JSON.parse(saved);
      return Array.isArray(statuses)
        ? TASK_STATUSES.filter((status) => statuses.includes(status))
        : ["done"];
    }
  } catch {
    return ["done"];
  }
  return localStorage.getItem(LEGACY_DONE_COLLAPSED) === "false" ? [] : ["done"];
}

/// Who a new task should belong to: whoever you gave the last one to, and
/// yourself before you have given anyone anything. Guessing an agent for you
/// was wrong often enough to be worse than no guess at all — a task quietly
/// assigned to an agent starts it working.
function suggestedOwner(members: Member[], me?: Member): string {
  const remembered = localStorage.getItem(LAST_OWNER);
  if (remembered && members.some((member) => member.id === remembered)) {
    return remembered;
  }
  return me?.id ?? "";
}

/// Handing a task over is always to an agent, so the box opens on the agent
/// you used last — never on the person who is trying to hand it away.
function suggestedAgent(members: Member[], fallback?: string | null): string {
  const agents = members.filter((member) => member.kind === "agent");
  const remembered = localStorage.getItem(LAST_AGENT);
  if (remembered && agents.some((agent) => agent.id === remembered)) return remembered;
  if (fallback && agents.some((agent) => agent.id === fallback)) return fallback;
  return agents[0]?.id ?? fallback ?? "";
}

function rememberOwner(members: Member[], owner: string) {
  localStorage.setItem(LAST_OWNER, owner);
  const chosen = members.find((member) => member.id === owner);
  if (chosen?.kind === "agent") localStorage.setItem(LAST_AGENT, owner);
}

// --- board ------------------------------------------------------------------

/// The board makes concurrent agent work obvious: one column per state, and
/// every card says who owns it, what it is waiting on, and what pressing it
/// would do next.
export function TasksBoard() {
  const app = useApp();
  const api = useApi();
  const { go } = useNavigation();
  const [filterOwner, setFilterOwner] = useState("");
  const [filterProject, setFilterProject] = useState("");
  const [dragging, setDragging] = useState<string | null>(null);
  const [dropColumn, setDropColumn] = useState<TaskStatus | null>(null);
  const [creating, setCreating] = useState(false);
  const [menuFor, setMenuFor] = useState<{
    task: Task;
    x: number;
    y: number;
  } | null>(null);
  const [assigning, setAssigning] = useState<Task | null>(null);
  const [collapsedStatuses, setCollapsedStatuses] = useState(
    initialCollapsedStatuses,
  );
  // Two ways to look at the same tasks, remembered: a board is for moving work
  // along, a list is for reading it. Which one you want is a habit, not a
  // per-visit decision.
  const [layout, setLayout] = useState<"board" | "list">(
    () => (localStorage.getItem("patchwork.taskLayout") as "board" | "list") ?? "board",
  );
  const setLayoutAndRemember = (next: "board" | "list") => {
    setLayout(next);
    localStorage.setItem("patchwork.taskLayout", next);
  };
  const toggleStatus = (status: TaskStatus) => {
    const collapsed = collapsedStatuses.includes(status)
      ? collapsedStatuses.filter((item) => item !== status)
      : [...collapsedStatuses, status];
    setCollapsedStatuses(collapsed);
    localStorage.setItem(COLLAPSED_STATUSES, JSON.stringify(collapsed));
  };

  const tasks = useMemo(
    () =>
      app.tasks.filter(
        (task) =>
          (!filterOwner || task.owner_id === filterOwner) &&
          (!filterProject || task.project_id === filterProject),
      ),
    [app.tasks, filterOwner, filterProject],
  );

  const needsYou = tasks.filter((task) => {
    if (isTerminalTaskStatus(task.status)) return false;
    const state = readTask(task, app.members, app.runs, app.questions);
    return state.situation === "asking" || state.situation === "review";
  }).length;

  return (
    <div className="column">
      <div className="topbar" data-tauri-drag-region="deep">
        <span className="title">Tasks</span>
        {needsYou > 0 && <Chip tone="caution">{needsYou} waiting on you</Chip>}
        <span className="spacer" />
        <Dropdown
          quiet
          align="right"
          value={filterOwner}
          onChange={setFilterOwner}
          options={[
            { value: "", label: "Anyone" },
            ...app.members.map(memberOption),
          ]}
        />
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
        <div className="segmented compact">
          <button
            className={layout === "board" ? "active" : ""}
            onClick={() => setLayoutAndRemember("board")}
          >
            Board
          </button>
          <button
            className={layout === "list" ? "active" : ""}
            onClick={() => setLayoutAndRemember("list")}
          >
            List
          </button>
        </div>
        <button className="button" onClick={() => setCreating(true)}>
          <PlusIcon size={15} />
          New task
        </button>
      </div>

      {layout === "list" ? (
        <TaskList
          tasks={tasks}
          collapsedStatuses={collapsedStatuses}
          onToggleStatus={toggleStatus}
          onMenu={(task, x, y) => setMenuFor({ task, x, y })}
        />
      ) : (
      <div className="board">
        {TASK_STATUSES.map((status) => {
          const column = tasks.filter((task) => task.status === status);
          const collapsed = collapsedStatuses.includes(status);
          return (
            <div
              key={status}
              className={`board-column${collapsed ? " collapsed" : ""}${dropColumn === status ? " drop-target" : ""}`}
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
              <button
                className="board-column-head collapsible"
                aria-expanded={!collapsed}
                title={`${collapsed ? "Show" : "Hide"} ${statusLabel(status).toLowerCase()} tasks`}
                onClick={() => toggleStatus(status)}
              >
                <span className={`column-dot ${status}`} />
                <span>{statusLabel(status)}</span>
                {column.length > 0 && <span className="count">{column.length}</span>}
                <ChevronIcon size={13} open={!collapsed} />
              </button>
              {!collapsed && (
                <div className="board-column-body">
                  {column.map((task) => (
                    <TaskCard
                      key={task.id}
                      task={task}
                      onDragStart={() => setDragging(task.id)}
                      onClick={() => go({ kind: "task", id: task.id })}
                      onMenu={(x, y) => setMenuFor({ task, x, y })}
                    />
                  ))}
                  {column.length === 0 && (
                    <div className="board-empty">{emptyColumn(status)}</div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
      )}

      {creating && <NewTaskModal onClose={() => setCreating(false)} />}
      {menuFor && (
        <TaskContextMenu
          task={menuFor.task}
          at={menuFor}
          onClose={() => setMenuFor(null)}
          onAssign={() => setAssigning(menuFor.task)}
        />
      )}
      {assigning && (
        <AssignModal task={assigning} onClose={() => setAssigning(null)} />
      )}
    </div>
  );
}

/// The same tasks as rows, grouped by status, with the empty statuses left
/// out: a board shows you that Blocked is empty because the column is part of
/// the shape; a list saying "Blocked (0)" is just noise to scroll past.
function TaskList({
  tasks,
  collapsedStatuses,
  onToggleStatus,
  onMenu,
}: {
  tasks: Task[];
  collapsedStatuses: TaskStatus[];
  onToggleStatus: (status: TaskStatus) => void;
  onMenu: (task: Task, x: number, y: number) => void;
}) {
  const app = useApp();
  const { go } = useNavigation();

  const groups = TASK_STATUSES.map((status) => ({
    status,
    items: tasks
      .filter((task) => task.status === status)
      .sort(
        (a, b) =>
          (a.due_at ?? Number.MAX_SAFE_INTEGER) - (b.due_at ?? Number.MAX_SAFE_INTEGER) ||
          b.updated_at - a.updated_at,
      ),
  })).filter((group) => group.items.length > 0);

  if (groups.length === 0) {
    return (
      <div className="empty">
        <div className="empty-title">Nothing here yet</div>
      </div>
    );
  }

  return (
    <div className="task-list">
      {groups.map((group) => (
        <div key={group.status}>
          <button
            className="section-head collapsible"
            aria-expanded={!collapsedStatuses.includes(group.status)}
            onClick={() => onToggleStatus(group.status)}
          >
            <ChevronIcon
              size={13}
              open={!collapsedStatuses.includes(group.status)}
            />
            <span className={`column-dot ${group.status}`} />
            <span className="section-title">{statusLabel(group.status)}</span>
            <span className="count">{group.items.length}</span>
          </button>
          {!collapsedStatuses.includes(group.status) && group.items.map((task) => {
            const state = readTask(task, app.members, app.runs, app.questions);
            const project = app.projects.find(
              (candidate) => candidate.id === task.project_id,
            );
            const due = dueLabel(task.due_at);
            return (
              <button
                key={task.id}
                className="row hoverable"
                onClick={() => go({ kind: "task", id: task.id })}
                onContextMenu={(event) => {
                  event.preventDefault();
                  onMenu(task, event.clientX, event.clientY);
                }}
              >
                <span className="task-key">{task.key}</span>
                <span className="grow">
                  <span className="name">{task.title}</span>
                  <span className="sub">{state.headline}</span>
                </span>
                {due && !isTerminalTaskStatus(task.status) && (
                  <Chip tone={due.overdue ? "danger" : "caution"}>{due.text}</Chip>
                )}
                {project && <Chip>{project.name}</Chip>}
                {state.agents.length > 1 ? (
                  <AgentStack members={state.agents} size={20} />
                ) : state.owner ? (
                  <Avatar member={state.owner} size={20} />
                ) : (
                  <span className="unowned">unassigned</span>
                )}
              </button>
            );
          })}
        </div>
      ))}
    </div>
  );
}

function emptyColumn(status: TaskStatus) {
  switch (status) {
    case "planned":
      return "Nothing queued";
    case "running":
      return "No agent is working";
    case "blocked":
      return "Nothing is stuck";
    case "review":
      return "Nothing to review";
    case "canceled":
      return "Nothing canceled";
    default:
      return "Nothing finished yet";
  }
}

function TaskCard({
  task,
  onClick,
  onDragStart,
  onMenu,
}: {
  task: Task;
  onClick: () => void;
  onDragStart: () => void;
  onMenu: (x: number, y: number) => void;
}) {
  const app = useApp();
  const project = app.projects.find((candidate) => candidate.id === task.project_id);
  const state = readTask(task, app.members, app.runs, app.questions);
  const actions = useTaskActions(task);
  const due = dueLabel(task.due_at);

  // Only the situations that say something get a line of their own. A card that
  // is simply planned and owned needs no commentary.
  const noteworthy = ["working", "queued", "asking", "failed", "blocked"].includes(
    state.situation,
  );

  return (
    <div
      className={`task-card ${state.situation}`}
      draggable
      // A card is a button in everything but tag name: reachable by keyboard,
      // and opened by Enter like every other row in the app.
      role="button"
      tabIndex={0}
      onDragStart={onDragStart}
      onClick={onClick}
      onKeyDown={(event) => {
        if (event.key === "Enter" && event.target === event.currentTarget) {
          event.preventDefault();
          onClick();
        }
      }}
      onContextMenu={(event) => {
        event.preventDefault();
        onMenu(event.clientX, event.clientY);
      }}
    >
      <div className="head">
        <span className="key">{task.key}</span>
        <span className="spacer" />
        {state.agents.length > 1 ? (
          <AgentStack members={state.agents} size={18} />
        ) : state.owner ? (
          <Avatar member={state.owner} size={18} />
        ) : (
          <span className="unowned">unassigned</span>
        )}
      </div>
      <div className="title">{task.title}</div>

      {noteworthy && (
        <div className={`situation ${situationTone(state.situation)}`}>
          {state.situation === "working" || state.situation === "queued" ? (
            <Spinner size={11} />
          ) : state.situation === "asking" ? (
            <QuestionIcon size={12} />
          ) : (
            <WarningIcon size={12} />
          )}
          <span className="line">{state.headline}</span>
        </div>
      )}

      <div className="meta">
        {due && !isTerminalTaskStatus(task.status) && (
          <Chip tone={due.overdue ? "danger" : "caution"}>{due.text}</Chip>
        )}
        {project && <Chip>{project.name}</Chip>}
        {task.pr_state && (
          <Chip tone={pullRequestTone(task.pr_state.state)}>
            <PullRequestStatusIcon state={task.pr_state.state} size={11} />
            #{task.pr_state.number}
          </Chip>
        )}
        <span className="spacer" />
        {state.action && state.action.kind !== "reopen" && (
          <button
            className="card-action"
            title={state.action.label}
            onClick={(event) => {
              event.stopPropagation();
              void actions.perform(state.action!, state);
            }}
          >
            {actionIcon(state.action.kind) ?? <PlusIcon size={13} />}
          </button>
        )}
      </div>

      {actions.assigning && (
        <div onClick={(event) => event.stopPropagation()}>
          <AssignModal task={task} onClose={() => actions.setAssigning(false)} />
        </div>
      )}
    </div>
  );
}

function taskManagementItems(
  task: Task,
  api: ReturnType<typeof useApi>,
  onAssign: () => void,
  onDelete: () => void,
  movePrefix = "",
): (MenuItem | "separator")[] {
  return [
    ...TASK_STATUSES.map((status) => ({
      key: status,
      label: `${movePrefix}${statusLabel(status)}`,
      disabled: status === task.status,
      onSelect: () => void api.updateTask(task.id, { status }),
    })),
    "separator",
    {
      key: "assign",
      label: "Reassign…",
      icon: <AgentIcon size={15} />,
      onSelect: onAssign,
    },
    {
      key: "delete",
      label: "Delete task",
      icon: <TrashIcon size={15} />,
      danger: true,
      onSelect: onDelete,
    },
  ];
}

function TaskContextMenu({
  task,
  at,
  onClose,
  onAssign,
}: {
  task: Task;
  at: { x: number; y: number };
  onClose: () => void;
  onAssign: () => void;
}) {
  const api = useApi();
  const { go, toast } = useNavigation();

  return (
    <Menu
      at={at}
      header={task.key}
      onClose={onClose}
      items={[
        {
          key: "open",
          label: "Open task",
          onSelect: () => go({ kind: "task", id: task.id }),
        },
        "separator",
        ...taskManagementItems(
          task,
          api,
          onAssign,
          async () => {
            try {
              await api.deleteTask(task.id);
            } catch (err) {
              toast(String((err as Error).message ?? err));
            }
          },
          "Move to ",
        ),
      ]}
    />
  );
}

// --- creating ---------------------------------------------------------------

/// The task composer: one big box you type into, with everything else
/// underneath it.
///
/// A task is a sentence and sometimes a screenshot. Owner and project are
/// answers to questions the sentence raises, so they sit below it as
/// small controls rather than as a form the sentence has to get through.
export function NewTaskModal({
  onClose,
  sourceChannelId,
}: {
  onClose: () => void;
  sourceChannelId?: string;
}) {
  const app = useApp();
  const api = useApi();
  const { go, toast } = useNavigation();
  const draftKey = `${TASK_DRAFT_PREFIX}${app.workspace?.id ?? ""}.${
    app.me?.id ?? ""
  }.${sourceChannelId ?? ""}`;
  const [outcome, setOutcome] = useState(
    () => localStorage.getItem(draftKey) ?? "",
  );
  const [owner, setOwner] = useState(() => suggestedOwner(app.members, app.me));
  const [project, setProject] = useState(() => {
    const agent = app.members.find((member) => member.id === owner);
    return agent?.agent?.default_project_id ?? app.projects[0]?.id ?? "";
  });
  const [start, setStart] = useState(true);
  // Held, not uploaded: there is no task to attach them to until you save,
  // and a dialog you close should leave nothing behind.
  const [images, setImages] = useState<File[]>([]);
  const [dropping, setDropping] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [justCreated, setJustCreated] = useState("");
  const outcomeField = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (outcome) localStorage.setItem(draftKey, outcome);
    else localStorage.removeItem(draftKey);
  }, [draftKey, outcome]);

  const add = (files: FileList | File[] | null | undefined) => {
    const picked = [...(files ?? [])].filter((file) => file.size > 0);
    if (picked.length > 0) setImages((held) => [...held, ...picked]);
    return picked.length > 0;
  };

  /// Linear's habit: most tasks arrive in threes. `another` keeps the box
  /// open with the owner and project you just chose.
  const create = async (after: "open" | "dismiss" | "another" = "open") => {
    setBusy(true);
    setError("");
    try {
      rememberOwner(app.members, owner);
      // Uploaded before the task exists, then handed over on create: the relay
      // writes the request message with its screenshots already attached, so
      // the agent's first read is the whole question rather than half of it.
      const attachmentIds: Id[] = [];
      for (const file of images) attachmentIds.push((await api.upload(file)).id);
      const task = await api.createTask({
        outcome,
        owner_id: owner || undefined,
        project_id: project || undefined,
        source_channel_id: sourceChannelId,
        attachment_ids: attachmentIds,
        // The relay writes the first message; the agent starts after it exists.
        start: false,
      });
      if (start && owner && ownerIsAgent) {
        await api.runTask(task.id, { agent_id: owner });
      }
      localStorage.removeItem(draftKey);
      if (after === "another") {
        setOutcome("");
        setImages([]);
        setBusy(false);
        setJustCreated(task.key);
        outcomeField.current?.focus();
        return;
      }
      onClose();
      if (after === "dismiss") {
        toast(`${task.key} created`, {
          label: "Open",
          onClick: () => go({ kind: "task", id: task.id }),
        });
      } else {
        go({ kind: "task", id: task.id });
      }
    } catch (err) {
      setError(String((err as Error).message ?? err));
      setBusy(false);
    }
  };

  const ownerIsAgent =
    app.members.find((member) => member.id === owner)?.kind === "agent";

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (
        event.key === "Enter" &&
        (event.metaKey || event.ctrlKey)
      ) {
        event.preventDefault();
        event.stopPropagation();
        // Modal listens on window too. Stop its primary-button shortcut so one
        // keypress cannot take both the in-place and open-task paths.
        event.stopImmediatePropagation();
        if (outcome.trim() && !busy) {
          void create(event.shiftKey ? "another" : "dismiss");
        }
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  });

  return (
    <Modal wide onClose={onClose}>
      <div
        className={`task-composer${dropping ? " dropping" : ""}`}
        onDragOver={(event) => {
          event.preventDefault();
          setDropping(true);
        }}
        onDragLeave={() => setDropping(false)}
        onDrop={(event) => {
          event.preventDefault();
          setDropping(false);
          add(event.dataTransfer?.files);
        }}
      >
        <textarea
          className="task-composer-text"
          {...proseText}
          ref={outcomeField}
          autoFocus
          value={outcome}
          placeholder="What has to be true when this is done?"
          onChange={(event) => setOutcome(event.target.value)}
          onPaste={(event) => {
            if (add(event.clipboardData?.files)) event.preventDefault();
          }}
        />

        <DictateButton value={outcome} onText={setOutcome} />

        {images.length > 0 && (
          <div className="task-composer-files">
            {images.map((file, at) => (
              <PendingImage
                key={`${file.name}-${at}`}
                file={file}
                onRemove={() =>
                  setImages(images.filter((_, index) => index !== at))
                }
              />
            ))}
          </div>
        )}

        <div className="task-composer-attributes">
          <div className="task-composer-fields">
            <Dropdown
              quiet
              value={owner}
              onChange={setOwner}
              placeholder="Nobody yet"
              options={[
                { value: "", label: "Nobody yet", icon: <Avatar size={18} /> },
                ...app.members.map(memberOption),
              ]}
            />
            <Dropdown
              quiet
              value={project}
              onChange={setProject}
              placeholder="No project"
              options={[
                { value: "", label: "No project" },
                ...app.projects.map((candidate) => ({
                  value: candidate.id,
                  label: candidate.name,
                })),
              ]}
            />
            <label className="attach-button" title="Attach evidence">
              <AttachIcon size={15} />
              <input
                type="file"
                multiple
                hidden
                onChange={(event) => {
                  add(event.target.files);
                  event.target.value = "";
                }}
              />
            </label>
          </div>
          <div className="task-composer-actions">
            {justCreated && (
              <span className="composer-hint">{justCreated} created</span>
            )}
            {ownerIsAgent && (
              <Toggle checked={start} onChange={setStart} label="Start now" />
            )}
            <button
              className="button quiet"
              disabled={!outcome.trim() || busy}
              title="Create this one and keep the box open (⌘⇧↵)"
              onClick={() => void create("another")}
            >
              Another
            </button>
            <button
              className="button primary"
              disabled={!outcome.trim() || busy}
              onClick={() => void create("open")}
            >
              {ownerIsAgent && start ? "Create and start" : "Create"}
            </button>
          </div>
        </div>
      </div>
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

/// An image waiting for the task to exist.
function PendingImage({ file, onRemove }: { file: File; onRemove: () => void }) {
  // Made inside the effect, not beside it: a URL created during render is
  // revoked by StrictMode's second pass and the thumbnail is born broken.
  const [url, setUrl] = useState("");
  useEffect(() => {
    const made = URL.createObjectURL(file);
    setUrl(made);
    return () => URL.revokeObjectURL(made);
  }, [file]);

  return (
    <span className="pending-image">
      {file.type.startsWith("image/") ? (
        <img src={url} alt={file.name} />
      ) : (
        <span className="attachment-chip">{file.name}</span>
      )}
      <button className="remove" title="Remove" onClick={onRemove}>
        ×
      </button>
    </span>
  );
}

/// Screenshots and other evidence pinned to a task.
///
/// Files arrive through the discussion composer, which uploads them against
/// the task as well as the message: one upload, evidence in both places, and
/// on the machine that runs the task as a file the agent opens by path. So
/// this strip only has to keep up with the conversation.
function TaskFiles({ taskId, channelId }: { taskId: Id; channelId: Id }) {
  const api = useApi();
  const [files, setFiles] = useState<Attachment[]>([]);
  const messageCount = useAppSelector(
    (data) => data.messages[channelId]?.length ?? 0,
  );

  useEffect(() => {
    void api.task(taskId).then((detail) => setFiles(detail.attachments));
  }, [api, taskId, messageCount]);

  if (files.length === 0) return null;

  return (
    <div className="task-files">
      {files.map((attachment) => (
        <Attached key={attachment.id} attachment={attachment} />
      ))}
    </div>
  );
}

/// Assigning is nearly always "and start it", so the two are one step with one
/// optional extra: what to tell the agent beyond the task itself.
export function AssignModal({ task, onClose }: { task: Task; onClose: () => void }) {
  const app = useApp();
  const api = useApi();
  const [owner, setOwner] = useState(() => suggestedAgent(app.members, task.owner_id));
  const [instruction, setInstruction] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const chosen = app.members.find((member) => member.id === owner);
  const isAgent = chosen?.kind === "agent";

  const submit = async (andStart: boolean) => {
    setBusy(true);
    setError("");
    try {
      if (owner !== task.owner_id) {
        rememberOwner(app.members, owner);
        await api.updateTask(task.id, { owner_id: owner });
      }
      if (andStart && isAgent) {
        await api.runTask(task.id, {
          agent_id: owner,
          prompt: instruction.trim() || undefined,
        });
      }
      onClose();
    } catch (err) {
      setError(String((err as Error).message ?? err));
      setBusy(false);
    }
  };

  return (
    <Modal
      title="Assign this task"
      subtitle={task.title}
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button"
            disabled={!owner || busy}
            onClick={() => submit(false)}
          >
            Assign only
          </button>
          <button
            className="button primary"
            disabled={!owner || busy || !isAgent}
            onClick={() => submit(true)}
          >
            {busy ? "Starting…" : "Assign and start"}
          </button>
        </>
      }
    >
      <FormSelect
        label="Owner"
        value={owner}
        onChange={setOwner}
        options={app.members.map(memberOption)}
      />
      {isAgent && (
        <Field
          label="Anything to add"
          value={instruction}
          onChange={setInstruction}
          textarea
          placeholder="Optional. The agent already has the title and the expected result."
        />
      )}
      {!isAgent && owner && (
        <div className="notice">
          People are not started by a button — assigning puts this in their Inbox.
        </div>
      )}
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

type ReviewItem =
  | { kind: "attachment"; attachment: Attachment }
  | { kind: "preview"; preview: Preview };

function ReviewPanel({ task }: { task: Task }) {
  const api = useApi();
  const signal = useAppSelector((app) => ({
    messages: app.messages[task.discussion_channel_id]?.length ?? 0,
    previews: Object.values(app.previews)
      .filter((preview) => preview.task_id === task.id)
      .map((preview) => `${preview.id}:${preview.status}`)
      .join(","),
  }));
  const [detail, setDetail] = useState<TaskDetail>();
  const [selected, setSelected] = useState("");

  useEffect(() => {
    let cancelled = false;
    void api
      .task(task.id)
      .then((next) => {
        if (!cancelled) setDetail(next);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [api, task.id, signal.messages, signal.previews]);

  const items: ReviewItem[] = [
    ...(detail?.previews ?? [])
      .filter((preview) => preview.status === "live")
      .map((preview) => ({ kind: "preview" as const, preview })),
    ...(detail?.attachments ?? []).map((attachment) => ({
      kind: "attachment" as const,
      attachment,
    })),
  ];
  const idOf = (item: ReviewItem) =>
    item.kind === "preview" ? item.preview.id : item.attachment.id;

  useEffect(() => {
    if (items.length > 0 && !items.some((item) => idOf(item) === selected)) {
      setSelected(idOf(items[0]));
    }
  }, [items.map(idOf).join(","), selected]);

  const chosen = items.find((item) => idOf(item) === selected);
  if (!detail) return <div className="inspector-body"><Spinner size={14} /></div>;
  if (!chosen) {
    return (
      <div className="inspector-body">
        <div className="empty-title">No visual evidence yet</div>
        <div className="card-sub">
          Screenshots, videos, and live previews posted by the run appear here.
        </div>
      </div>
    );
  }

  return (
    <div className="review-panel">
      <div className="review-picker">
        {items.map((item) => {
          const id = idOf(item);
          const label =
            item.kind === "preview"
              ? item.preview.label
              : item.attachment.caption || item.attachment.file_name;
          return (
            <button
              key={`${item.kind}:${id}`}
              className={`review-pick${id === selected ? " active" : ""}`}
              onClick={() => setSelected(id)}
              title={label}
            >
              <span>
                {item.kind === "preview"
                  ? statusLabel(item.preview.status as never)
                  : evidenceLabel(item.attachment)}
              </span>
              <strong>{label}</strong>
            </button>
          );
        })}
      </div>
      <ReviewViewer item={chosen} />
    </div>
  );
}

function ReviewViewer({ item }: { item: ReviewItem }) {
  return item.kind === "preview" ? (
    <PreviewViewer preview={item.preview} />
  ) : (
    <AttachmentViewer attachment={item.attachment} />
  );
}

function PreviewViewer({ preview }: { preview: Preview }) {
  const api = useApi();
  const live = preview.status === "live";
  const url = usePreviewUrl(preview.id, live);

  return (
    <div className="review-viewer">
      <div className="review-toolbar">
        <span className="grow">
          <span className="name">{preview.label}</span>
          <span className="sub">port {preview.port} · {statusLabel(preview.status as never)}</span>
        </span>
        {url && <button className="button" onClick={() => openExternal(url)}>Open</button>}
        {live && (
          <button className="button quiet" onClick={() => void api.stopPreview(preview.id)}>
            Stop
          </button>
        )}
      </div>
      {url ? (
        <iframe
          className="review-frame"
          src={url}
          title={preview.label}
          sandbox="allow-downloads allow-forms allow-modals allow-popups allow-same-origin allow-scripts"
          referrerPolicy="no-referrer"
        />
      ) : (
        <div className="review-unavailable">
          {live ? <Spinner size={14} /> : `Preview is ${preview.status}.`}
        </div>
      )}
    </div>
  );
}

const EVIDENCE_LABELS: Record<string, string> = {
  image: "Image",
  video: "Video",
  markdown: "Markdown",
  html: "Page",
  csv: "Table",
  text: "Text",
  file: "File",
};

function evidenceLabel(attachment: Attachment) {
  return EVIDENCE_LABELS[evidenceKind(attachment.mime, attachment.file_name)];
}

function AttachmentViewer({ attachment }: { attachment: Attachment }) {
  const api = useApi();
  const kind = evidenceKind(attachment.mime, attachment.file_name);
  const image = kind === "image";
  const video = kind === "video";
  // Only a video needs a URL the media element can fetch on its own; text is
  // read through the authenticated client and images are already blobs.
  const grantedUrl = useGrantedFileUrl(video ? attachment.id : undefined);
  const imageUrl = useFileUrl(image ? attachment.url : "");
  const url = image ? imageUrl : grantedUrl;
  const [zoomed, setZoomed] = useState(false);

  return (
    <div className="review-viewer">
      <div className="review-toolbar">
        <span className="grow">
          <span className="name">{attachment.caption || attachment.file_name}</span>
          {attachment.caption && <span className="sub">{attachment.file_name}</span>}
        </span>
        <button
          className="button"
          onClick={() => void api.downloadFile(attachment.url, attachment.file_name)}
        >
          Download
        </button>
      </div>
      {isTextEvidence(kind) ? (
        <TextEvidence attachment={attachment} />
      ) : !url ? (
        <div className="review-unavailable"><Spinner size={14} /></div>
      ) : image ? (
        <button className="review-image" title="Zoom" onClick={() => setZoomed(true)}>
          <img src={url} alt={attachment.caption || attachment.file_name} />
        </button>
      ) : video ? (
        <video className="review-video" src={url} controls preload="metadata" />
      ) : (
        <div className="review-unavailable">Open the attached file to review it.</div>
      )}
      {zoomed && url && (
        <Lightbox
          url={url}
          alt={attachment.caption || attachment.file_name}
          onClose={() => setZoomed(false)}
        />
      )}
    </div>
  );
}

// --- the task page ----------------------------------------------------------

/// A task page keeps the discussion primary: the conversation is where the work
/// actually happens. Above it sits exactly one line about where the task is,
/// and one button for what to do about it.
export function TaskPage({ taskId }: { taskId: string }) {
  const app = useApp();
  const api = useApi();
  const { go, toast } = useNavigation();
  const task = app.tasks.find((candidate) => candidate.id === taskId);
  const [panel, setPanel] = useState<"review" | "activity" | null>(null);
  const previewCount = Object.values(app.previews).filter(
    (preview) => preview.task_id === taskId,
  ).length;
  const previousPreviewCount = useRef(previewCount);
  const openedReview = useRef(false);
  const actions = useTaskActions(task ?? ({ id: taskId } as Task));

  useEffect(() => {
    if (previewCount > previousPreviewCount.current) setPanel("review");
    previousPreviewCount.current = previewCount;
  }, [previewCount]);

  useEffect(() => {
    if (task?.status === "review" && !openedReview.current) {
      openedReview.current = true;
      setPanel("review");
    }
  }, [task?.status]);

  if (!task) {
    return (
      <div className="column">
        <div className="empty">
          <div className="empty-title">That task is gone</div>
        </div>
      </div>
    );
  }

  const state = readTask(task, app.members, app.runs, app.questions);
  const previews = Object.values(app.previews).filter(
    (preview) => preview.task_id === task.id && preview.status === "live",
  );
  const step = stepIndex(task);
  const due = dueLabel(task.due_at);
  const performTopAction = async (action: NextAction) => {
    const succeeded = await actions.perform(action, state);
    if (
      !succeeded ||
      task.status !== "review" ||
      !["approve", "complete", "reopen"].includes(action.kind)
    ) {
      return;
    }
    const index = app.tasks.findIndex((candidate) => candidate.id === task.id);
    const next = [...app.tasks.slice(index + 1), ...app.tasks.slice(0, index)].find(
      (candidate) => candidate.status === "review",
    );
    go(next ? { kind: "task", id: next.id } : { kind: "tasks" });
  };

  return (
    <div className="column">
      <div className="topbar" data-tauri-drag-region="deep">
        <button className="button quiet" onClick={() => go({ kind: "tasks" })}>
          ‹ Tasks
        </button>
        <span className="subtitle">{task.key}</span>
        <span className="spacer" />
        <button
          className={`button quiet${panel === "review" ? " active" : ""}`}
          onClick={() => setPanel(panel === "review" ? null : "review")}
        >
          Review
        </button>
        <button
          className={`button quiet${panel === "activity" ? " active" : ""}`}
          onClick={() => setPanel(panel === "activity" ? null : "activity")}
        >
          Activity
        </button>
        <MenuButton
          align="right"
          title="More"
          header="Move to"
          items={taskManagementItems(
            task,
            api,
            () => actions.setAssigning(true),
            async () => {
              try {
                await api.deleteTask(task.id);
                go({ kind: "tasks" });
              } catch (err) {
                toast(String((err as Error).message ?? err));
              }
            },
          )}
        >
          <MoreIcon size={17} />
        </MenuButton>
      </div>

      <div className="task-header">
        <EditableText
          className="task-title"
          value={task.title}
          title="Click to rename"
          onCommit={(title) => void api.updateTask(task.id, { title })}
        />

        <TaskFiles taskId={task.id} channelId={task.discussion_channel_id} />

        <div className="task-rail">
          {TASK_STEPS.map((entry, index) => (
            <button
              key={entry.key}
              className={`rail-step${index === step ? " current" : ""}${
                index < step ? " past" : ""
              }${task.status === "blocked" && index === step ? " blocked" : ""}`}
              title={`Move to ${entry.label}`}
              onClick={() =>
                void api.updateTask(task.id, { status: entry.key as TaskStatus })
              }
            >
              {task.status === "blocked" && entry.key === "running"
                ? "Blocked"
                : entry.label}
            </button>
          ))}
        </div>

        <div className={`task-situation ${situationTone(state.situation)}`}>
          {(state.situation === "working" || state.situation === "queued") && (
            <Spinner size={14} />
          )}
          {state.situation === "asking" && <QuestionIcon size={15} />}
          {(state.situation === "failed" || state.situation === "blocked") && (
            <WarningIcon size={15} />
          )}
          {state.agents.length > 1 && (
            <AgentStack members={state.agents} size={20} />
          )}
          <span className="grow">
            <span className="line">{state.headline}</span>
            {state.detail && <span className="detail">{state.detail}</span>}
          </span>
          {state.secondary && (
            <button
              className="button quiet"
              onClick={() => void performTopAction(state.secondary!)}
            >
              {state.secondary.label}
            </button>
          )}
          {state.action && (
            <button
              className={`button${
                state.action.tone === "primary"
                  ? " primary"
                  : state.action.tone === "quiet"
                    ? " quiet"
                    : ""
              }`}
              disabled={actions.busy}
              onClick={() => void performTopAction(state.action!)}
            >
              {actionIcon(state.action.kind)}
              {state.action.label}
            </button>
          )}
        </div>

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
            {due && !isTerminalTaskStatus(task.status) && (
              <Chip tone={due.overdue ? "danger" : "caution"}>{due.text}</Chip>
            )}
          </Fact>
          {task.pr_url && (
            <Fact label="Pull request">
              <button
                className={`chip ${pullRequestTone(task.pr_state?.state)}`.trim()}
                onClick={() => openExternal(task.pr_url!)}
              >
                <PullRequestStatusIcon state={task.pr_state?.state} size={12} />
                {task.pr_state
                  ? `#${task.pr_state.number} · ${task.pr_state.state.toLowerCase()}`
                  : "Open"}
              </button>
            </Fact>
          )}
          {previews.map((preview) => (
            <PreviewFact key={preview.id} preview={preview} onOpenReview={() => setPanel("review")} />
          ))}
          <span className="spacer" />
          <span className="composer-hint">updated {relative(task.updated_at)}</span>
        </div>
      </div>

      {actions.error && (
        <div className="error-text" style={{ padding: "0 28px" }}>
          {actions.error}
        </div>
      )}

      <div className="content">
        <ChatView channelId={task.discussion_channel_id} />
        {panel && (
          <aside className="inspector task-side-panel">
            <div className="inspector-head">
              <button
                className={panel === "review" ? "active" : ""}
                onClick={() => setPanel("review")}
              >
                Review
              </button>
              <button
                className={panel === "activity" ? "active" : ""}
                onClick={() => setPanel("activity")}
              >
                Activity
              </button>
              <span className="spacer" />
              <button
                className="icon-button"
                onClick={() => setPanel(null)}
                title="Close"
                aria-label="Close review panel"
              >
                ×
              </button>
            </div>
            {panel === "review" ? (
              <ReviewPanel task={task} />
            ) : (
              <TaskDetailPanel taskId={task.id} />
            )}
          </aside>
        )}
      </div>

      {actions.assigning && (
        <AssignModal task={task} onClose={() => actions.setAssigning(false)} />
      )}
    </div>
  );
}

function PreviewFact({ preview, onOpenReview }: { preview: Preview; onOpenReview: () => void }) {
  return (
    <Fact label="Preview">
      <button className="chip accent" onClick={onOpenReview}>
        {preview.label}
      </button>
    </Fact>
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

function TaskDetailPanel({ taskId }: { taskId: string }) {
  const api = useApi();
  const { inspect } = useNavigation();
  const [detail, setDetail] = useState<Awaited<ReturnType<typeof api.task>>>();

  // What actually makes this panel stale: this task moving, or one of its runs
  // changing state. Watching the whole tasks and runs maps meant refetching
  // the detail over HTTP on every run event in the workspace — several times a
  // second while any agent is working, most of it for other people's tasks.
  const members = useAppSelector((data) => data.members);
  const signature = useAppSelector((data) => {
    const task = data.tasks.find((candidate) => candidate.id === taskId);
    const runs = Object.values(data.runs)
      .filter((run) => run.task_id === taskId)
      .map((run) => `${run.id}:${run.status}`)
      .sort()
      .join(",");
    return `${task?.status ?? ""}|${task?.updated_at ?? ""}|${runs}`;
  });

  useEffect(() => {
    void api.task(taskId).then(setDetail);
  }, [taskId, signature, api]);

  if (!detail) return <div className="inspector-body">Loading…</div>;

  // Several agents can be inside this task at once. Each one gets its own
  // thinking below, because "what is happening" is a different answer per
  // agent — and one of them stops without stopping the others.
  const live = detail.runs.filter(isRunActive);
  const currentRunId = live[0]?.id ?? detail.task.current_run_id;

  return (
    <div className="inspector-body">
      {detail.worktree && (
        <Section title="Worktree">
          <div className="card-sub" style={{ wordBreak: "break-all" }}>
            {detail.worktree.path}
          </div>
          <Chip>{detail.worktree.branch || "no branch"}</Chip>
        </Section>
      )}

      <Section title="Runs">
        {detail.runs.length === 0 && (
          <div className="card-sub">Nothing has run yet.</div>
        )}
        {detail.runs.map((run) => {
          const agent = members.find((member) => member.id === run.agent_id);
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

      {detail.attachments.length > 0 && (
        <Section title="Evidence">
          {detail.attachments.map((attachment) => (
            <button
              key={attachment.id}
              className="row"
              onClick={() => void api.openFile(attachment.url)}
            >
              <span className="grow">
                <span className="name">{attachment.file_name}</span>
              </span>
            </button>
          ))}
        </Section>
      )}

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

      {live.length > 1 ? (
        live.map((run) => (
          <Section
            key={run.id}
            title={
              members.find((member) => member.id === run.agent_id)?.display_name ??
              "Run"
            }
            action={
              <button
                className="button quiet"
                onClick={() => void api.cancelRun(run.id)}
              >
                Stop
              </button>
            }
          >
            <RunPanel runId={run.id} embedded />
          </Section>
        ))
      ) : currentRunId ? (
        <Section title="Current run">
          <RunPanel runId={currentRunId} embedded />
        </Section>
      ) : null}
    </div>
  );
}
