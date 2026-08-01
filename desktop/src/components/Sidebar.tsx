import { useMemo, useState } from "react";
import { useApi, useApp } from "../lib/store";
import { Avatar, PresenceDot, useNavigation } from "./common";
import type { Channel, Member } from "../lib/types";
import type { View as NavView } from "./common";

/// The main sidebar stays small: Inbox, Tasks, the channels grouped into
/// sections, and direct messages. Everything else lives in the workspace menu.
export function Sidebar({ onOpenMenu }: { onOpenMenu: () => void }) {
  const app = useApp();
  const api = useApi();
  const { view, go } = useNavigation();
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [creating, setCreating] = useState(false);
  const [newChannel, setNewChannel] = useState("");

  const unread = app.inbox.filter((item) => !item.read_at).length;

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

  const dmPartner = (channel: Channel): Member | undefined =>
    app.members.find(
      (member) => channel.member_ids.includes(member.id) && member.id !== app.me?.id,
    );

  async function createChannel(name: string, sectionId?: string) {
    const section = app.sections.find((s) => s.id === sectionId);
    const channel = await api.createChannel({
      name,
      section_name: section?.name,
    });
    go({ kind: "channel", id: channel.id });
  }

  return (
    <aside className="sidebar">
      <div className="sidebar-top">
        <span className="sidebar-brand">{app.workspace?.name ?? "Patchwork"}</span>
      </div>

      <div className="sidebar-scroll">
        <button
          className={`nav-item${isActive({ kind: "inbox" }) ? " active" : ""}`}
          onClick={() => go({ kind: "inbox" })}
        >
          <span className="label">Inbox</span>
          {unread > 0 && <span className="count badge">{unread}</span>}
        </button>
        <button
          className={`nav-item${isActive({ kind: "tasks" }) ? " active" : ""}`}
          onClick={() => go({ kind: "tasks" })}
        >
          <span className="label">Tasks</span>
          <span className="count">
            {app.tasks.filter((task) => task.status !== "done").length || ""}
          </span>
        </button>

        {app.sections.map((section) => {
          const list = grouped.get(section.id) ?? [];
          const isCollapsed = collapsed[section.id];
          return (
            <div className="sidebar-group" key={section.id}>
              <div
                className={`sidebar-heading${isCollapsed ? " collapsed" : ""}`}
                onClick={() =>
                  setCollapsed({ ...collapsed, [section.id]: !isCollapsed })
                }
              >
                <span className="chevron">▾</span>
                <span>{section.name}</span>
              </div>
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

        <div className="sidebar-group">
          <div className="sidebar-heading">
            <span>Direct messages</span>
          </div>
          {dms.map((channel) => {
            const partner = dmPartner(channel);
            return (
              <button
                key={channel.id}
                className={`nav-item${isActive({ kind: "channel", id: channel.id }) ? " active" : ""}`}
                onClick={() => go({ kind: "channel", id: channel.id })}
              >
                <PresenceDot presence={partner?.presence ?? "offline"} />
                <span className="label">{partner?.display_name ?? channel.name}</span>
              </button>
            );
          })}
          {app.members
            .filter(
              (member) =>
                member.kind === "agent" &&
                member.agent?.dm_enabled !== false &&
                !dms.some((channel) => channel.member_ids.includes(member.id)),
            )
            .map((member) => (
              <button
                key={member.id}
                className="nav-item"
                onClick={async () => {
                  const channel = await api.openDm(member.id);
                  go({ kind: "channel", id: channel.id });
                }}
              >
                <PresenceDot presence={member.presence} />
                <span className="label">{member.display_name}</span>
              </button>
            ))}
        </div>

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
                  await createChannel(newChannel.trim());
                  setNewChannel("");
                  setCreating(false);
                } else if (event.key === "Escape") {
                  setCreating(false);
                }
              }}
            />
          ) : (
            <button className="nav-item" onClick={() => setCreating(true)}>
              <span className="label">+ New channel</span>
            </button>
          )}
        </div>
      </div>

      <div className="sidebar-footer">
        <Avatar member={app.me} size={22} />
        <span className="who">{app.me?.display_name}</span>
        <button className="icon-button" onClick={onOpenMenu} title="Workspace">
          ⋯
        </button>
      </div>
    </aside>
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
      <span style={{ color: "var(--text-faint)" }}>#</span>
      <span className="label">{channel.name}</span>
    </button>
  );
}
