import { useEffect, useMemo, useState } from "react";
import { useApi, useApp } from "../lib/store";
import { hasUnseen, useSeen } from "../lib/unread";
import { Avatar, useNavigation } from "./common";
import { Menu, MenuButton } from "./ui";
import {
  ChevronIcon,
  HashIcon,
  InboxIcon,
  PlusIcon,
  SearchIcon,
  Spinner,
  TasksIcon,
} from "./icons";
import type { Channel, Id, Member } from "../lib/types";
import type { View as NavView } from "./common";

export type Creatable =
  | "task"
  | "channel"
  | "section"
  | "agent"
  | "project"
  | "invite";

/// The main sidebar stays small: Inbox, Tasks, the channels grouped into
/// sections, and direct messages. Everything else lives behind the workspace
/// name at the top — and everything you can *create* lives behind one plus, so
/// "how do I add a channel / a section / a project" has a single answer.
export function Sidebar({
  onOpenMenu,
  onSearch,
  onResize,
  onCreate,
}: {
  onOpenMenu: () => void;
  onSearch: () => void;
  onResize: (width: number) => void;
  onCreate: (what: Creatable, sectionId?: Id) => void;
}) {
  const app = useApp();
  const api = useApi();
  const seen = useSeen();
  const { view, go } = useNavigation();
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [menuFor, setMenuFor] = useState<{ channel: Channel; x: number; y: number } | null>(null);

  const unread = app.inbox.filter((item) => !item.read_at).length;
  const openTasks = app.tasks.filter((task) => task.status !== "done").length;

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

  const channels = app.channels.filter((channel) => channel.kind === "channel");
  const grouped = useMemo(() => {
    const bySection = new Map<string, Channel[]>();
    for (const channel of channels) {
      const key = channel.section_id ?? "";
      bySection.set(key, [...(bySection.get(key) ?? []), channel]);
    }
    for (const list of bySection.values()) {
      list.sort((a, b) => a.position - b.position || a.name.localeCompare(b.name));
    }
    return bySection;
  }, [channels]);

  const dms = app.channels
    .filter((channel) => channel.kind === "dm")
    .sort((a, b) => b.last_message_at - a.last_message_at);

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
    <aside className="sidebar">
      <div className="sidebar-top">
        <button className="workspace-button" onClick={onOpenMenu} title="Workspace">
          <span className="name">{app.workspace?.name ?? "Patchwork"}</span>
          <ChevronIcon size={14} />
        </button>
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
          onClick={() => go({ kind: "inbox" })}
        >
          <InboxIcon />
          <span className="label">Inbox</span>
          {unread > 0 && <span className="badge">{unread}</span>}
        </button>
        <button
          className={`nav-item${isActive({ kind: "tasks" }) ? " active" : ""}`}
          onClick={() => go({ kind: "tasks" })}
        >
          <TasksIcon />
          <span className="label">Tasks</span>
          {openTasks > 0 && <span className="count">{openTasks}</span>}
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
              <div className="group-label plain">
                <span>Channels</span>
              </div>
              <button
                className="icon-button small group-add"
                title="New channel"
                onClick={() => onCreate("channel")}
              >
                <PlusIcon size={14} />
              </button>
            </div>
            {(grouped.get("") ?? []).map((channel) => (
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
              <div className="group-label plain">
                <span>Direct messages</span>
              </div>
            </div>
            {dms.map((channel) => {
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
            {unstartedAgents.map((member) => (
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
        <Avatar member={app.me} size={24} presence />
        <span className="who">{app.me?.display_name}</span>
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
    <div
      className="floating-menu"
      style={{ left: Math.min(at.x, window.innerWidth - 240), top: at.y }}
    >
      <Menu
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
    </div>
  );
}

export const SIDEBAR_MIN = 200;
export const SIDEBAR_MAX = 400;

function SidebarResizer({ onResize }: { onResize: (width: number) => void }) {
  const [dragging, setDragging] = useState(false);

  useEffect(() => {
    if (!dragging) return;
    const onMove = (event: MouseEvent) => {
      onResize(Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, event.clientX)));
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
  const busy = member?.presence === "working" || member?.presence === "thinking";
  return (
    <button
      className={`nav-item${active ? " active" : ""}${unseen ? " unseen" : ""}`}
      onClick={onClick}
    >
      <Avatar member={member} size={20} />
      <span className="lines">
        <span className="label">{member?.display_name ?? fallback}</span>
        <span className="sub">{secondLine(member)}</span>
      </span>
      <span className="trailing">
        {busy && <Spinner size={13} />}
        {waiting > 0 ? (
          <span className="badge">{waiting}</span>
        ) : member?.presence === "waiting" ? (
          <span className="dot waiting" />
        ) : unseen ? (
          <span className="dot unread" />
        ) : null}
      </span>
    </button>
  );
}

function secondLine(member?: Member) {
  if (!member) return "";
  switch (member.presence) {
    case "working":
      return "working";
    case "thinking":
      return "thinking";
    case "waiting":
      return "waiting for you";
    case "online":
      return member.kind === "agent" ? member.agent?.runtime ?? "ready" : "online";
    default:
      return member.kind === "agent" ? member.agent?.runtime ?? "" : "offline";
  }
}

/// `MARKETING` reads as shouting; the benchmark uses quiet sentence case.
function sentenceCase(value: string) {
  const lowered = value.toLocaleLowerCase();
  return lowered.charAt(0).toLocaleUpperCase() + lowered.slice(1);
}
