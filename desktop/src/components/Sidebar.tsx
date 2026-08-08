import { useEffect, useMemo, useState } from "react";
import { store, useApi, useApp, useAppSelector, useWorkspaces } from "../lib/store";
import { create, join, switchTo } from "../lib/session";
import { hasUnseen, useSeen } from "../lib/unread";
import { Avatar, Field, Modal, useNavigation } from "./common";
import { Menu, MenuButton } from "./ui";
import {
  AgentIcon,
  AutomationIcon,
  CheckIcon,
  ChevronIcon,
  FolderIcon,
  HashIcon,
  InboxIcon,
  KeyboardIcon,
  MembersIcon,
  PlusIcon,
  SearchIcon,
  SettingsIcon,
  Spinner,
  TasksIcon,
} from "./icons";
import type { Channel, Id, Member } from "@client/types";
import type { View as NavView } from "./common";

export type Creatable =
  | "task"
  | "channel"
  | "section"
  | "agent"
  | "project"
  | "invite";

/// The main sidebar stays small: Inbox, Tasks, the channels grouped into
/// sections, and direct messages. Everything else — automations, agents,
/// projects, members, settings — lives in the drop-up behind your own name at
/// the bottom, next to the workspace you are in. Everything you can *create*
/// lives behind one plus, so "how do I add a channel / a section / a project"
/// has a single answer.
export function Sidebar({
  onHelp,
  onSearch,
  onResize,
  onCreate,
  onSignOut,
  rail = false,
}: {
  onHelp: () => void;
  onSearch: () => void;
  onResize: (width: number) => void;
  onCreate: (what: Creatable, sectionId?: Id) => void;
  onSignOut: () => void;
  /// Narrow enough that only the icons fit. Everything is still here, and
  /// every row keeps its tooltip; the words are what goes.
  rail?: boolean;
}) {
  // Deliberately not `useApp`: the sidebar is on screen the whole time, so a
  // subscription to everything means it redraws for every message body an
  // agent streams into a conversation you are not even looking at.
  const app = useAppSelector((data) => ({
    workspace: data.workspace,
    me: data.me,
    members: data.members,
    sections: data.sections,
    channels: data.channels,
    tasks: data.tasks,
    inbox: data.inbox,
    automations: data.automations,
  }));
  const api = useApi();
  const seen = useSeen();
  const { view, go } = useNavigation();
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [menuFor, setMenuFor] = useState<{ channel: Channel; x: number; y: number } | null>(null);

  const unread = app.inbox.filter((item) => !item.read_at).length;
  const openTasks = app.tasks.filter((task) => task.status !== "done").length;
  const liveAutomations = app.automations.filter((a) => a.enabled).length;
  const failingAutomations = app.automations.filter(
    (a) => a.enabled && a.failure_count > 0,
  ).length;

  // Things actually addressed to you, per conversation. This is the number
  // worth colouring; plain activity gets a dot and nothing more.
  const waiting = useMemo(() => {
    const counts: Record<Id, number> = {};
    for (const item of app.inbox) {
      if (item.read_at || !item.channel_id) continue;
      counts[item.channel_id] = (counts[item.channel_id] ?? 0) + 1;
    }
    return counts;
  }, [app.inbox]);

  const grouped = useMemo(() => {
    const bySection = new Map<string, Channel[]>();
    for (const channel of app.channels) {
      if (channel.kind !== "channel") continue;
      const key = channel.section_id ?? "";
      bySection.set(key, [...(bySection.get(key) ?? []), channel]);
    }
    for (const list of bySection.values()) {
      list.sort((a, b) => a.position - b.position || a.name.localeCompare(b.name));
    }
    return bySection;
  }, [app.channels]);

  const dms = useMemo(
    () =>
      app.channels
        .filter((channel) => channel.kind === "dm")
        .sort((a, b) => b.last_message_at - a.last_message_at),
    [app.channels],
  );

  const isActive = (candidate: NavView) =>
    view.kind === candidate.kind &&
    ("id" in candidate ? (view as { id?: string }).id === candidate.id : true);

  const partnerOf = (channel: Channel): Member | undefined =>
    app.members.find(
      (member) => channel.member_ids.includes(member.id) && member.id !== app.me?.id,
    );

  const unstartedAgents = app.members.filter(
    (member) =>
      member.kind === "agent" &&
      member.agent?.dm_enabled !== false &&
      !dms.some((channel) => channel.member_ids.includes(member.id)),
  );

  const signals = (channel: Channel) => {
    const active = isActive({ kind: "channel", id: channel.id });
    return {
      active,
      unseen: !active && hasUnseen(channel, seen),
      waiting: waiting[channel.id] ?? 0,
    };
  };

  return (
    <aside className={`sidebar${rail ? " rail" : ""}`}>
      <div className="sidebar-top" data-tauri-drag-region="deep">
        {!rail && (
          <span className="workspace-title">
            {app.workspace?.name ?? "Patchwork"}
          </span>
        )}
        <span className="spacer" />
        <button className="icon-button" onClick={onSearch} title="Search (⌘K)">
          <SearchIcon size={17} />
        </button>
        <MenuButton
          align="right"
          title="Create"
          header="Create"
          items={[
            {
              key: "task",
              label: "Task",
              hint: "Work an agent or a person owns",
              shortcut: "⌘N",
              onSelect: () => onCreate("task"),
            },
            {
              key: "channel",
              label: "Channel",
              hint: "A room for a topic",
              shortcut: "⌘⇧N",
              onSelect: () => onCreate("channel"),
            },
            {
              key: "section",
              label: "Section",
              hint: "A heading to group channels under",
              onSelect: () => onCreate("section"),
            },
            "separator",
            {
              key: "agent",
              label: "Agent",
              hint: "A teammate with a runtime",
              onSelect: () => onCreate("agent"),
            },
            {
              key: "project",
              label: "Project",
              hint: "A repository or folder agents work in",
              onSelect: () => onCreate("project"),
            },
            {
              key: "invite",
              label: "Invite a person",
              onSelect: () => onCreate("invite"),
            },
          ]}
        >
          <PlusIcon size={17} />
        </MenuButton>
      </div>

      <div className="sidebar-scroll">
        <button
          className={`nav-item${isActive({ kind: "inbox" }) ? " active" : ""}`}
          title="Inbox"
          onClick={() => go({ kind: "inbox" })}
        >
          <InboxIcon />
          <span className="label">Inbox</span>
          {unread > 0 && <span className="badge">{unread}</span>}
        </button>
        <button
          className={`nav-item${isActive({ kind: "tasks" }) ? " active" : ""}`}
          title="Tasks"
          onClick={() => go({ kind: "tasks" })}
        >
          <TasksIcon />
          <span className="label">Tasks</span>
          {openTasks > 0 && <span className="count">{openTasks}</span>}
        </button>
        <button
          className={`nav-item${isActive({ kind: "automations" }) ? " active" : ""}`}
          title="Automations"
          onClick={() => go({ kind: "automations" })}
        >
          <AutomationIcon />
          <span className="label">Automations</span>
          {failingAutomations > 0 ? (
            <span className="badge danger">{failingAutomations}</span>
          ) : (
            liveAutomations > 0 && <span className="count">{liveAutomations}</span>
          )}
        </button>

        {app.sections.map((section) => {
          const list = grouped.get(section.id) ?? [];
          const isCollapsed = collapsed[section.id];
          const hiddenUnseen =
            isCollapsed && list.some((channel) => hasUnseen(channel, seen));
          return (
            <div className="sidebar-group" key={section.id}>
              <div className="group-head">
                <button
                  className={`group-label${isCollapsed ? " collapsed" : ""}`}
                  onClick={() =>
                    setCollapsed({ ...collapsed, [section.id]: !isCollapsed })
                  }
                >
                  <ChevronIcon size={13} />
                  <span>{sentenceCase(section.name)}</span>
                  {hiddenUnseen && <span className="dot unread" />}
                </button>
                <button
                  className="icon-button small group-add"
                  title={`New channel in ${sentenceCase(section.name)}`}
                  onClick={() => onCreate("channel", section.id)}
                >
                  <PlusIcon size={14} />
                </button>
              </div>
              {!isCollapsed &&
                (list.length > 0 ? (
                  list.map((channel) => (
                    <ChannelRow
                      key={channel.id}
                      channel={channel}
                      {...signals(channel)}
                      onClick={() => go({ kind: "channel", id: channel.id })}
                      onMenu={(x, y) => setMenuFor({ channel, x, y })}
                    />
                  ))
                ) : (
                  <div className="group-empty">Nothing filed here yet</div>
                ))}
            </div>
          );
        })}

        {(grouped.get("") ?? []).length > 0 && (
          <div className="sidebar-group">
            <div className="group-head">
              <button
                className={`group-label${collapsed.channels ? " collapsed" : ""}`}
                onClick={() =>
                  setCollapsed({ ...collapsed, channels: !collapsed.channels })
                }
              >
                <ChevronIcon size={13} />
                <span>Channels</span>
              </button>
              <button
                className="icon-button small group-add"
                title="New channel"
                onClick={() => onCreate("channel")}
              >
                <PlusIcon size={14} />
              </button>
            </div>
            {!collapsed.channels &&
              (grouped.get("") ?? []).map((channel) => (
                <ChannelRow
                  key={channel.id}
                  channel={channel}
                  {...signals(channel)}
                  onClick={() => go({ kind: "channel", id: channel.id })}
                  onMenu={(x, y) => setMenuFor({ channel, x, y })}
                />
              ))}
          </div>
        )}

        {(dms.length > 0 || unstartedAgents.length > 0) && (
          <div className="sidebar-group">
            <div className="group-head">
              <button
                className={`group-label${collapsed.dms ? " collapsed" : ""}`}
                onClick={() => setCollapsed({ ...collapsed, dms: !collapsed.dms })}
              >
                <ChevronIcon size={13} />
                <span>DMs</span>
              </button>
            </div>
            {!collapsed.dms && dms.map((channel) => {
              const partner = partnerOf(channel);
              return (
                <MemberRow
                  key={channel.id}
                  member={partner}
                  fallback={channel.name}
                  {...signals(channel)}
                  onClick={() => go({ kind: "channel", id: channel.id })}
                />
              );
            })}
            {!collapsed.dms &&
              unstartedAgents.map((member) => (
              <MemberRow
                key={member.id}
                member={member}
                active={false}
                unseen={false}
                waiting={0}
                onClick={async () => {
                  const channel = await api.openDm(member.id);
                  go({ kind: "channel", id: channel.id });
                }}
              />
            ))}
          </div>
        )}
      </div>

      <div className="sidebar-footer">
        <MoreMenu
          me={app.me}
          onCreate={onCreate}
          onHelp={onHelp}
          onSignOut={onSignOut}
        />
        <WorkspaceSwitcher />
      </div>

      {menuFor && (
        <ChannelMenu
          channel={menuFor.channel}
          at={menuFor}
          onClose={() => setMenuFor(null)}
        />
      )}

      <SidebarResizer onResize={onResize} />
    </aside>
  );
}

/// Everything that is not a conversation, one click from your own name.
function MoreMenu({
  me,
  onCreate,
  onHelp,
  onSignOut,
}: {
  me?: Member;
  onCreate: (what: Creatable, sectionId?: Id) => void;
  onHelp: () => void;
  onSignOut: () => void;
}) {
  const { go } = useNavigation();

  return (
    <MenuButton
      className="footer-button grow"
      align="left"
      title="You, and everything else"
      items={[
        {
          key: "agents",
          label: "Agents",
          icon: <AgentIcon />,
          onSelect: () => go({ kind: "agents" }),
        },
        {
          key: "projects",
          label: "Projects and machines",
          icon: <FolderIcon />,
          onSelect: () => go({ kind: "projects" }),
        },
        {
          key: "members",
          label: "Members",
          icon: <MembersIcon />,
          onSelect: () => go({ kind: "members" }),
        },
        {
          key: "settings",
          label: "Settings",
          icon: <SettingsIcon />,
          onSelect: () => go({ kind: "settings" }),
        },
        "separator",
        {
          key: "invite",
          label: "Invite a person",
          icon: <PlusIcon />,
          onSelect: () => onCreate("invite"),
        },
        {
          key: "shortcuts",
          label: "Keyboard shortcuts",
          icon: <KeyboardIcon />,
          shortcut: "\u2318/",
          onSelect: onHelp,
        },
        "separator",
        {
          key: "sign-out",
          label: "Sign out of every workspace",
          danger: true,
          onSelect: onSignOut,
        },
      ]}
    >
      <Avatar member={me} size={24} presence />
      <span className="who">{me?.display_name}</span>
      <ChevronIcon size={13} />
    </MenuButton>
  );
}

/// Which workspace the window is showing. The others stay connected, so this
/// is a change of view and not a reconnection: agents keep working in all of
/// them, and switching back is instant.
function WorkspaceSwitcher() {
  const workspaces = useWorkspaces();
  const { toast } = useNavigation();
  const [adding, setAdding] = useState<"join" | "create" | null>(null);
  const active = workspaces.find((workspace) => workspace.active);
  const elsewhere = workspaces
    .filter((workspace) => !workspace.active)
    .reduce((total, workspace) => total + workspace.unread, 0);

  return (
    <>
      <MenuButton
        className="footer-button workspace-chip"
        align="right"
        header="Workspaces"
        title={active ? `${active.name} \u2014 switch workspace` : "Workspaces"}
        items={[
          ...workspaces.map((workspace) => ({
            key: workspace.id,
            label: workspace.name,
            hint: workspace.unread
              ? `${workspace.unread} waiting`
              : workspace.live
                ? undefined
                : "connecting\u2026",
            icon: workspace.active ? <CheckIcon size={15} /> : undefined,
            onSelect: () => void switchTo(workspace.id),
          })),
          "separator" as const,
          {
            key: "new",
            label: "New workspace",
            hint: "On this relay",
            icon: <PlusIcon />,
            onSelect: () => setAdding("create"),
          },
          {
            key: "join",
            label: "Join with an invite code",
            onSelect: () => setAdding("join"),
          },
        ]}
      >
        <span className="workspace-initial">
          {(active?.name ?? "?").trim().charAt(0).toUpperCase()}
        </span>
        {elsewhere > 0 && <span className="dot unread" />}
        <ChevronIcon size={13} />
      </MenuButton>
      {adding === "create" && (
        <NewWorkspaceModal
          onClose={() => setAdding(null)}
          onDone={(name) => toast(`Switched to ${name}`)}
        />
      )}
      {adding === "join" && (
        <JoinWorkspaceModal
          onClose={() => setAdding(null)}
          onDone={() => toast("Joined")}
        />
      )}
    </>
  );
}

function NewWorkspaceModal({
  onClose,
  onDone,
}: {
  onClose: () => void;
  onDone: (name: string) => void;
}) {
  const [name, setName] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  return (
    <Modal
      title="New workspace"
      subtitle="A separate workspace on the same relay: its own channels, tasks, agents and members. You will be its first admin."
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            disabled={busy || !name.trim()}
            onClick={async () => {
              setBusy(true);
              setError("");
              try {
                await create(name.trim());
                onDone(name.trim());
                onClose();
              } catch (err) {
                setError(String((err as Error).message ?? err));
                setBusy(false);
              }
            }}
          >
            {busy ? "Creating\u2026" : "Create"}
          </button>
        </>
      }
    >
      <Field label="Name" value={name} onChange={setName} autoFocus placeholder="Acme" />
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

function JoinWorkspaceModal({
  onClose,
  onDone,
}: {
  onClose: () => void;
  onDone: () => void;
}) {
  const app = useApp();
  const [relayUrl, setRelayUrl] = useState(relayRoot);
  const [code, setCode] = useState("");
  const [displayName, setDisplayName] = useState(app.me?.display_name ?? "");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  return (
    <Modal
      title="Join a workspace"
      subtitle="Any relay, including this one. Both workspaces stay connected."
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            disabled={busy || !code.trim() || !displayName.trim()}
            onClick={async () => {
              setBusy(true);
              setError("");
              try {
                await join({
                  relay_url: relayUrl,
                  invite_code: code.trim(),
                  display_name: displayName.trim(),
                });
                onDone();
                onClose();
              } catch (err) {
                setError(String((err as Error).message ?? err));
                setBusy(false);
              }
            }}
          >
            {busy ? "Joining\u2026" : "Join"}
          </button>
        </>
      }
    >
      <Field label="Relay URL" value={relayUrl} onChange={setRelayUrl} />
      <Field label="Invite code" value={code} onChange={setCode} autoFocus />
      <Field label="Your name" value={displayName} onChange={setDisplayName} />
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

/// The relay the current workspace is on, so joining a second one on the same
/// relay does not mean typing the URL again.
function relayRoot() {
  return store.api?.baseUrl.replace(/\/w\/[^/]+$/, "") ?? "";
}

/// Where a channel gets filed. Moving one between sections was impossible from
/// the UI even though the relay has always supported it.
function ChannelMenu({
  channel,
  at,
  onClose,
}: {
  channel: Channel;
  at: { x: number; y: number };
  onClose: () => void;
}) {
  const app = useApp();
  const api = useApi();
  const { toast } = useNavigation();

  return (
      <Menu
        at={at}
        header={`#${channel.name}`}
        onClose={onClose}
        items={[
          ...app.sections
            .filter((section) => section.id !== channel.section_id)
            .map((section) => ({
              key: section.id,
              label: `Move to ${sentenceCase(section.name)}`,
              onSelect: () =>
                void api.updateChannel(channel.id, { section_id: section.id }),
            })),
          ...(channel.section_id
            ? [
                {
                  key: "ungrouped",
                  label: "Move out of its section",
                  onSelect: () =>
                    void api.updateChannel(channel.id, { section_id: "" }),
                },
              ]
            : []),
          "separator" as const,
          {
            key: "archive",
            label: "Archive channel",
            danger: true,
            onSelect: async () => {
              try {
                await api.archiveChannel(channel.id);
                toast(`#${channel.name} archived`);
              } catch (err) {
                toast(String((err as Error).message ?? err));
              }
            },
          },
        ]}
      />
  );
}

export const SIDEBAR_MIN = 190;
export const SIDEBAR_MAX = 400;
/// Below this the labels have nowhere to go, so the sidebar becomes a rail.
export const SIDEBAR_RAIL = 60;

function SidebarResizer({ onResize }: { onResize: (width: number) => void }) {
  const [dragging, setDragging] = useState(false);

  useEffect(() => {
    if (!dragging) return;
    const onMove = (event: MouseEvent) => {
      const width = Math.min(SIDEBAR_MAX, event.clientX);
      // A gap between the two widths, so a drag settles on one or the other
      // instead of hovering somewhere neither works.
      onResize(width < SIDEBAR_MIN - 20 ? SIDEBAR_RAIL : Math.max(SIDEBAR_MIN, width));
    };
    const onUp = () => setDragging(false);
    document.body.classList.add("resizing");
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    return () => {
      document.body.classList.remove("resizing");
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
  }, [dragging, onResize]);

  return (
    <div
      className={`sidebar-resizer${dragging ? " dragging" : ""}`}
      onMouseDown={(event) => {
        event.preventDefault();
        setDragging(true);
      }}
      onDoubleClick={() => onResize(248)}
      title="Drag to resize, double-click to reset"
    />
  );
}

interface RowSignals {
  active: boolean;
  /// Something was said here since you last looked.
  unseen: boolean;
  /// Inbox items pointing here: a mention, a reply, a question.
  waiting: number;
}

function ChannelRow({
  channel,
  active,
  unseen,
  waiting,
  onClick,
  onMenu,
}: RowSignals & {
  channel: Channel;
  onClick: () => void;
  onMenu: (x: number, y: number) => void;
}) {
  return (
    <button
      className={`nav-item${active ? " active" : ""}${unseen ? " unseen" : ""}`}
      onClick={onClick}
      title={`#${channel.name}`}
      onContextMenu={(event) => {
        event.preventDefault();
        onMenu(event.clientX, event.clientY);
      }}
    >
      <HashIcon />
      <span className="label">{channel.name}</span>
      {waiting > 0 ? (
        <span className="badge">{waiting}</span>
      ) : unseen ? (
        <span className="dot unread" />
      ) : null}
    </button>
  );
}

/// A DM row carries a second line, because "what is this teammate doing right
/// now" is exactly what you want from the sidebar.
function MemberRow({
  member,
  fallback,
  active,
  unseen,
  waiting,
  onClick,
}: RowSignals & {
  member?: Member;
  fallback?: string;
  onClick: () => void;
}) {
  // One line. The second line used to spell out the runtime and the presence
  // in words, which doubled the height of the whole list to say something the
  // dot already says — and the runtime is a property of the agent, not news.
  const busy = member?.presence === "working" || member?.presence === "thinking";
  return (
    <button
      className={`nav-item${active ? " active" : ""}${unseen ? " unseen" : ""}`}
      onClick={onClick}
      title={member ? `${member.display_name} · ${presenceWord(member)}` : fallback}
    >
      {/* Presence rides on the avatar. On the right it sat where unread dots
          live and read as "something new here", which is a different claim. */}
      <Avatar member={member} size={20} presence />
      <span className="label">{member?.display_name ?? fallback}</span>
      <span className="trailing">
        {busy && <Spinner size={12} />}
        {waiting > 0 ? (
          <span className="badge">{waiting}</span>
        ) : unseen ? (
          <span className="dot unread" />
        ) : null}
      </span>
    </button>
  );
}

function presenceWord(member: Member) {
  switch (member.presence) {
    case "working":
      return "working";
    case "thinking":
      return "thinking";
    case "waiting":
      return "waiting for you";
    case "online":
      return member.kind === "agent"
        ? `ready · ${member.agent?.runtime ?? ""}`.trim()
        : "online";
    default:
      return member.kind === "agent"
        ? `offline · ${member.agent?.runtime ?? ""}`.trim()
        : "offline";
  }
}

/// `MARKETING` reads as shouting; the benchmark uses quiet sentence case.
function sentenceCase(value: string) {
  const lowered = value.toLocaleLowerCase();
  return lowered.charAt(0).toLocaleUpperCase() + lowered.slice(1);
}
