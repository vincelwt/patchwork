import { useEffect, useMemo, useState } from "react";
import { useApi, useApp } from "../lib/store";
import { Avatar, useNavigation } from "./common";
import {
  ChevronIcon,
  HashIcon,
  InboxIcon,
  PlusIcon,
  SearchIcon,
  Spinner,
  TasksIcon,
} from "./icons";
import type { Channel, Member } from "../lib/types";
import type { View as NavView } from "./common";

/// The main sidebar stays small: Inbox, Tasks, the channels grouped into
/// sections, and direct messages. Everything else lives behind the workspace
/// name at the top.
export function Sidebar({
  onOpenMenu,
  onSearch,
  onResize,
}: {
  onOpenMenu: () => void;
  onSearch: () => void;
  onResize: (width: number) => void;
}) {
  const app = useApp();
  const api = useApi();
  const { view, go } = useNavigation();
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [creating, setCreating] = useState(false);
  const [newChannel, setNewChannel] = useState("");

  const unread = app.inbox.filter((item) => !item.read_at).length;
  const openTasks = app.tasks.filter((task) => task.status !== "done").length;

  const channels = app.channels.filter((channel) => channel.kind === "channel");
  const grouped = useMemo(() => {
    const bySection = new Map<string, Channel[]>();
    for (const channel of channels) {
      const key = channel.section_id ?? "";
      bySection.set(key, [...(bySection.get(key) ?? []), channel]);
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
      </div>

      <div className="sidebar-scroll">
        <button
          className={`nav-item${isActive({ kind: "inbox" }) ? " active" : ""}`}
          onClick={() => go({ kind: "inbox" })}
        >
          <InboxIcon />
          <span className="label">Inbox</span>
          {unread > 0 && <span className="count badge">{unread}</span>}
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
          if (list.length === 0) return null;
          const isCollapsed = collapsed[section.id];
          return (
            <div className="sidebar-group" key={section.id}>
              <button
                className={`group-label${isCollapsed ? " collapsed" : ""}`}
                onClick={() =>
                  setCollapsed({ ...collapsed, [section.id]: !isCollapsed })
                }
              >
                <ChevronIcon size={13} />
                <span>{sentenceCase(section.name)}</span>
              </button>
              {!isCollapsed &&
                list.map((channel) => (
                  <ChannelRow
                    key={channel.id}
                    channel={channel}
                    active={isActive({ kind: "channel", id: channel.id })}
                    onClick={() => go({ kind: "channel", id: channel.id })}
                  />
                ))}
            </div>
          );
        })}

        {(grouped.get("") ?? []).length > 0 && (
          <div className="sidebar-group">
            <div className="group-label" style={{ cursor: "default" }}>
              <span style={{ marginLeft: 13 }}>Channels</span>
            </div>
            {(grouped.get("") ?? []).map((channel) => (
              <ChannelRow
                key={channel.id}
                channel={channel}
                active={isActive({ kind: "channel", id: channel.id })}
                onClick={() => go({ kind: "channel", id: channel.id })}
              />
            ))}
          </div>
        )}

        {(dms.length > 0 || unstartedAgents.length > 0) && (
          <div className="sidebar-group">
            <div className="group-label" style={{ cursor: "default" }}>
              <span style={{ marginLeft: 13 }}>Direct messages</span>
            </div>
            {dms.map((channel) => {
              const partner = partnerOf(channel);
              return (
                <MemberRow
                  key={channel.id}
                  member={partner}
                  fallback={channel.name}
                  active={isActive({ kind: "channel", id: channel.id })}
                  onClick={() => go({ kind: "channel", id: channel.id })}
                />
              );
            })}
            {unstartedAgents.map((member) => (
              <MemberRow
                key={member.id}
                member={member}
                active={false}
                onClick={async () => {
                  const channel = await api.openDm(member.id);
                  go({ kind: "channel", id: channel.id });
                }}
              />
            ))}
          </div>
        )}

        <div className="sidebar-group">
          {creating ? (
            <input
              className="field"
              autoFocus
              placeholder="channel name"
              value={newChannel}
              onChange={(event) => setNewChannel(event.target.value)}
              onBlur={() => setCreating(false)}
              onKeyDown={async (event) => {
                if (event.key === "Enter" && newChannel.trim()) {
                  const channel = await api.createChannel({ name: newChannel.trim() });
                  setNewChannel("");
                  setCreating(false);
                  go({ kind: "channel", id: channel.id });
                } else if (event.key === "Escape") {
                  setCreating(false);
                }
              }}
            />
          ) : (
            <button className="nav-item" onClick={() => setCreating(true)}>
              <PlusIcon />
              <span className="label" style={{ color: "var(--text-muted)" }}>
                New channel
              </span>
            </button>
          )}
        </div>
      </div>

      <div className="sidebar-footer">
        <Avatar member={app.me} size={24} />
        <span className="who">{app.me?.display_name}</span>
      </div>

      <SidebarResizer onResize={onResize} />
    </aside>
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

function ChannelRow({
  channel,
  active,
  onClick,
}: {
  channel: Channel;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button className={`nav-item${active ? " active" : ""}`} onClick={onClick}>
      <HashIcon />
      <span className="label">{channel.name}</span>
    </button>
  );
}

/// A DM row carries a second line, because "what is this teammate doing right
/// now" is exactly what you want from the sidebar.
function MemberRow({
  member,
  fallback,
  active,
  onClick,
}: {
  member?: Member;
  fallback?: string;
  active: boolean;
  onClick: () => void;
}) {
  const busy = member?.presence === "working" || member?.presence === "thinking";
  return (
    <button className={`nav-item${active ? " active" : ""}`} onClick={onClick}>
      <Avatar member={member} size={20} />
      <span className="lines">
        <span className="label">{member?.display_name ?? fallback}</span>
        <span className="sub">{secondLine(member)}</span>
      </span>
      <span className="trailing">
        {busy && <Spinner size={13} />}
        {member?.presence === "waiting" && <span className="dot waiting" />}
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
