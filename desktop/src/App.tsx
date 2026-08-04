import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { store, useApi, useApp } from "./lib/store";
import { desktopInfo, joinWorkspace } from "./lib/desktop";
import type { DesktopSettings } from "./lib/desktop";
import { markSeen } from "./lib/unread";
import { chord, combo, isTyping } from "./lib/shortcuts";
import type { Shortcut } from "./lib/shortcuts";
import { Sidebar } from "./components/Sidebar";
import type { Creatable } from "./components/Sidebar";
import { ChatView, useHandles } from "./components/Chat";
import { Inspector } from "./components/Inspector";
import { InboxView } from "./components/Inbox";
import { NewTaskModal, TaskPage, TasksBoard } from "./components/Tasks";
import {
  AgentModal,
  AgentsPage,
  AutomationDebugPage,
  AutomationsPage,
  InviteModal,
  MembersPage,
  ProjectModal,
  ProjectsPage,
  SettingsPage,
} from "./components/Pages";
import {
  Avatar,
  Chip,
  Field,
  Modal,
  NavigationContext,
  useNavigation,
} from "./components/common";
import { Empty, KeyHint, Menu, MenuButton, Page } from "./components/ui";
import { Markdown } from "./components/Markdown";
import {
  AgentIcon,
  AutomationIcon,
  FolderIcon,
  HashIcon,
  InboxIcon,
  KeyboardIcon,
  MembersIcon,
  MoreIcon,
  PlusIcon,
  SearchIcon,
  SettingsIcon,
  Spinner,
  TasksIcon,
} from "./components/icons";
import type { Inspector as InspectorState, View } from "./components/common";
import type { Channel, Id, SearchResults } from "./lib/types";

export default function App() {
  const [settings, setSettings] = useState<DesktopSettings>();
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    void desktopInfo().then((info) => {
      setSettings(info.settings);
      setLoading(false);
      if (info.settings.relay_url && info.settings.token) {
        void store.connect(info.settings.relay_url, info.settings.token);
      }
    });
  }, []);

  if (loading) return <div className="empty">Starting Patchwork…</div>;

  if (!settings?.relay_url || !settings.token) {
    return (
      <Onboarding
        onJoined={(joined) => {
          setSettings(joined);
          void store.connect(joined.relay_url, joined.token);
        }}
      />
    );
  }

  return (
    <Workspace
      onSignOut={() => {
        store.disconnect();
        setSettings(undefined);
      }}
    />
  );
}

function Onboarding({ onJoined }: { onJoined: (settings: DesktopSettings) => void }) {
  const [relayUrl, setRelayUrl] = useState("http://127.0.0.1:7727");
  const [inviteCode, setInviteCode] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const join = async () => {
    setBusy(true);
    setError("");
    try {
      onJoined(
        await joinWorkspace({
          relay_url: relayUrl,
          invite_code: inviteCode,
          display_name: displayName,
        }),
      );
    } catch (err) {
      setError(String((err as Error).message ?? err));
      setBusy(false);
    }
  };

  return (
    <div className="onboarding">
      <div className="onboarding-card">
        <h1>Join a workspace</h1>
        <p>
          Your relay prints an invite code the first time it starts. Paste both
          here.
        </p>
        <Field label="Relay URL" value={relayUrl} onChange={setRelayUrl} />
        <Field
          label="Invite code"
          value={inviteCode}
          onChange={setInviteCode}
          autoFocus
        />
        <Field label="Your name" value={displayName} onChange={setDisplayName} />
        {error && <div className="error-text">{error}</div>}
        <button
          className="button primary"
          style={{ marginTop: 16, width: "100%", justifyContent: "center" }}
          disabled={busy || !inviteCode.trim() || !displayName.trim()}
          onClick={join}
        >
          {busy ? "Joining…" : "Join"}
        </button>
      </div>
    </div>
  );
}

function Workspace({ onSignOut }: { onSignOut: () => void }) {
  const app = useApp();
  const [view, setView] = useState<View>({ kind: "inbox" });
  const [inspector, setInspector] = useState<InspectorState>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [toast, setToast] = useState<string>();
  const [searchOpen, setSearchOpen] = useState(false);
  const [helpOpen, setHelpOpen] = useState(false);
  const [creating, setCreating] = useState<{
    what: Creatable;
    sectionId?: Id;
  } | null>(null);
  const [sidebarWidth, setSidebarWidth] = useState(
    () => Number(localStorage.getItem("patchwork.sidebarWidth")) || 248,
  );

  const resizeSidebar = useCallback((width: number) => {
    setSidebarWidth(width);
    localStorage.setItem("patchwork.sidebarWidth", String(width));
  }, []);

  const go = useCallback((next: View) => {
    setView(next);
    setInspector(null);
  }, []);

  const showToast = useCallback((message: string) => {
    setToast(message);
    window.setTimeout(() => setToast(undefined), 2600);
  }, []);

  const create = useCallback((what: Creatable, sectionId?: Id) => {
    setCreating({ what, sectionId });
  }, []);

  // Opening a conversation is what "I have seen this" means. Keeping the mark
  // in an effect on the channel *and* its newest message means a channel you
  // are sitting in never accumulates a phantom unread badge.
  const activeChannel = view.kind === "channel" ? view.id : undefined;
  const activeTaskChannel =
    view.kind === "task"
      ? app.tasks.find((task) => task.id === view.id)?.discussion_channel_id
      : undefined;
  const watching = activeChannel ?? activeTaskChannel;
  const watchingLastMessage = watching
    ? app.channels.find((channel) => channel.id === watching)?.last_message_at
    : undefined;

  useEffect(() => {
    if (watching) markSeen(watching, Math.max(Date.now(), watchingLastMessage ?? 0));
  }, [watching, watchingLastMessage]);

  // Reading the mention where it was written is reading it. Leaving the Inbox
  // item unread would put a badge on the very conversation you are looking at.
  const inboxHere = app.inbox.filter(
    (item) => !item.read_at && item.channel_id === watching,
  );
  useEffect(() => {
    if (!watching || inboxHere.length === 0) return;
    const timer = window.setTimeout(() => {
      for (const item of inboxHere) void store.api?.markRead(item.id);
    }, 700);
    return () => window.clearTimeout(timer);
  }, [watching, inboxHere]);

  const shortcuts = useShortcuts({
    go,
    create,
    openSearch: () => setSearchOpen(true),
    openHelp: () => setHelpOpen(true),
    closeInspector: () => setInspector(null),
  });

  if (app.status === "loading") {
    return (
      <div className="onboarding">
        <div className="onboarding-card" style={{ textAlign: "center" }}>
          <Spinner size={18} />
        </div>
      </div>
    );
  }
  if (app.status === "error") {
    return (
      <div className="onboarding">
        <div className="onboarding-card">
          <h1>Can't reach the relay</h1>
          <p>{app.error}</p>
          <p style={{ marginTop: 10, display: "flex", alignItems: "center", gap: 8 }}>
            <Spinner size={13} />
            Retrying…
          </p>
          <button className="button quiet" style={{ marginTop: 16 }} onClick={onSignOut}>
            Use a different workspace
          </button>
        </div>
      </div>
    );
  }

  return (
    <NavigationContext.Provider
      value={{ view, go, inspector, inspect: setInspector, toast: showToast }}
    >
      <div
        className="shell"
        style={{ "--sidebar-width": `${sidebarWidth}px` } as React.CSSProperties}
      >
        <Sidebar
          onOpenMenu={() => setMenuOpen(true)}
          onSearch={() => setSearchOpen(true)}
          onResize={resizeSidebar}
          onCreate={create}
        />
        <div className="main">
          {!app.live && (
            <div className="offline-banner">
              <Spinner size={12} />
              Reconnecting to the relay
            </div>
          )}
          <div className="content">
            <MainView view={view} onSignOut={onSignOut} />
            <Inspector />
          </div>
        </div>
      </div>

      {menuOpen && (
        <WorkspaceMenu
          onClose={() => setMenuOpen(false)}
          onPick={(next) => {
            setMenuOpen(false);
            go(next);
          }}
          onHelp={() => {
            setMenuOpen(false);
            setHelpOpen(true);
          }}
        />
      )}
      {searchOpen && (
        <CommandPalette
          shortcuts={shortcuts}
          onClose={() => setSearchOpen(false)}
        />
      )}
      {helpOpen && (
        <ShortcutsSheet shortcuts={shortcuts} onClose={() => setHelpOpen(false)} />
      )}
      {creating && (
        <CreateSomething
          what={creating.what}
          sectionId={creating.sectionId}
          onClose={() => setCreating(null)}
        />
      )}
      {toast && <div className="toast">{toast}</div>}
    </NavigationContext.Provider>
  );
}

// --- keyboard ---------------------------------------------------------------

/// Every shortcut in the app, registered once. Returning the list — rather than
/// just installing handlers — is what lets the help sheet and the palette stay
/// honest about what exists.
function useShortcuts(actions: {
  go: (view: View) => void;
  create: (what: Creatable, sectionId?: Id) => void;
  openSearch: () => void;
  openHelp: () => void;
  closeInspector: () => void;
}): Shortcut[] {
  const { go, create, openSearch, openHelp, closeInspector } = actions;

  const shortcuts = useMemo<Shortcut[]>(
    () => [
      {
        id: "search",
        keys: "⌘K",
        label: "Search and commands",
        group: "Do",
        match: combo("k"),
        run: openSearch,
      },
      {
        id: "help",
        keys: "⌘/",
        label: "Keyboard shortcuts",
        group: "Do",
        // `code` as well as `key`, because on several layouts the slash only
        // reaches us as a physical key once a modifier is held.
        match: (event) =>
          ((event.metaKey || event.ctrlKey) &&
            (event.key === "/" || event.key === "?" || event.code === "Slash")) ||
          (!event.metaKey && !event.ctrlKey && event.key === "?"),
        run: openHelp,
      },
      {
        id: "new-task",
        keys: "⌘N",
        label: "New task",
        group: "Create",
        match: combo("n"),
        run: () => create("task"),
      },
      {
        id: "new-channel",
        keys: "⌘⇧N",
        label: "New channel",
        group: "Create",
        match: combo("n", { shift: true }),
        run: () => create("channel"),
      },
      {
        id: "go-inbox",
        keys: "G then I",
        label: "Inbox",
        group: "Go to",
        chord: "g",
        match: chord("g", "i"),
        run: () => go({ kind: "inbox" }),
      },
      {
        id: "go-tasks",
        keys: "G then T",
        label: "Tasks",
        group: "Go to",
        chord: "g",
        match: chord("g", "t"),
        run: () => go({ kind: "tasks" }),
      },
      {
        id: "go-agents",
        keys: "G then A",
        label: "Agents",
        group: "Go to",
        chord: "g",
        match: chord("g", "a"),
        run: () => go({ kind: "agents" }),
      },
      {
        id: "go-projects",
        keys: "G then P",
        label: "Projects and machines",
        group: "Go to",
        chord: "g",
        match: chord("g", "p"),
        run: () => go({ kind: "projects" }),
      },
      {
        id: "go-members",
        keys: "G then M",
        label: "Members",
        group: "Go to",
        chord: "g",
        match: chord("g", "m"),
        run: () => go({ kind: "members" }),
      },
      {
        id: "go-automations",
        keys: "G then U",
        label: "Automations",
        group: "Go to",
        chord: "g",
        match: chord("g", "u"),
        run: () => go({ kind: "automations" }),
      },
      {
        id: "go-settings",
        keys: "G then S",
        label: "Settings",
        group: "Go to",
        chord: "g",
        match: chord("g", "s"),
        run: () => go({ kind: "settings" }),
      },
      {
        id: "close-panel",
        keys: "Esc",
        label: "Close the side panel",
        group: "View",
        match: (event) => event.key === "Escape",
        run: closeInspector,
      },
    ],
    [go, create, openSearch, openHelp, closeInspector],
  );

  const pending = useRef("");
  const pendingTimer = useRef<number | undefined>(undefined);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const typing = isTyping(event.target);
      const modified = event.metaKey || event.ctrlKey;

      // A bare letter while you are writing a sentence is a letter.
      if (typing && !modified) {
        pending.current = "";
        return;
      }

      for (const shortcut of shortcuts) {
        if (shortcut.match(event, pending.current)) {
          event.preventDefault();
          pending.current = "";
          shortcut.run();
          return;
        }
      }

      // Arm a chord, but only from a resting state.
      if (!typing && !modified && /^[a-z]$/.test(event.key.toLowerCase())) {
        const isLead = shortcuts.some(
          (shortcut) => shortcut.chord === event.key.toLowerCase(),
        );
        pending.current = isLead ? event.key.toLowerCase() : "";
        window.clearTimeout(pendingTimer.current);
        if (isLead) {
          pendingTimer.current = window.setTimeout(() => {
            pending.current = "";
          }, 1200);
        }
      }
    };

    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [shortcuts]);

  return shortcuts;
}

// --- creating ---------------------------------------------------------------

/// One dispatcher for everything the create menu can make, so the plus button,
/// the sidebar section headers and ⌘N all land in the same code.
function CreateSomething({
  what,
  sectionId,
  onClose,
}: {
  what: Creatable;
  sectionId?: Id;
  onClose: () => void;
}) {
  switch (what) {
    case "task":
      return <NewTaskModal onClose={onClose} />;
    case "channel":
      return <NewChannelModal sectionId={sectionId} onClose={onClose} />;
    case "section":
      return <NewSectionModal onClose={onClose} />;
    case "agent":
      return <AgentModal agent={null} onClose={onClose} />;
    case "project":
      return <ProjectModal project={null} onClose={onClose} />;
    case "invite":
      return <InviteModal onClose={onClose} />;
  }
}

function NewChannelModal({
  sectionId,
  onClose,
}: {
  sectionId?: Id;
  onClose: () => void;
}) {
  const app = useApp();
  const api = useApi();
  const { go } = useNavigation();
  const [name, setName] = useState("");
  const [topic, setTopic] = useState("");
  const [section, setSection] = useState(sectionId ?? "");
  const [error, setError] = useState("");

  const create = async () => {
    setError("");
    try {
      const channel = await api.createChannel({
        name: name.trim(),
        topic: topic.trim() || undefined,
        section_id: section || undefined,
      });
      onClose();
      go({ kind: "channel", id: channel.id });
    } catch (err) {
      setError(String((err as Error).message ?? err));
    }
  };

  return (
    <Modal
      title="New channel"
      subtitle="A room for one topic. Agents can be given standing instructions per channel."
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            disabled={!name.trim()}
            onClick={create}
          >
            Create
          </button>
        </>
      }
    >
      <Field label="Name" value={name} onChange={setName} autoFocus placeholder="design" />
      <Field
        label="What it is for"
        value={topic}
        onChange={setTopic}
        placeholder="Optional. Shown at the top of the channel."
      />
      {app.sections.length > 0 && (
        <div className="form-row">
          <label>Section</label>
          <select
            className="field"
            value={section}
            onChange={(event) => setSection(event.target.value)}
          >
            <option value="">No section</option>
            {app.sections.map((entry) => (
              <option key={entry.id} value={entry.id}>
                {entry.name}
              </option>
            ))}
          </select>
        </div>
      )}
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

function NewSectionModal({ onClose }: { onClose: () => void }) {
  const api = useApi();
  const { toast } = useNavigation();
  const [name, setName] = useState("");
  const [error, setError] = useState("");

  return (
    <Modal
      title="New section"
      subtitle="A heading in the sidebar. Channels are filed under it; right-click a channel to move it."
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            disabled={!name.trim()}
            onClick={async () => {
              try {
                await api.createSection(name.trim());
                toast(`Section “${name.trim()}” created`);
                onClose();
              } catch (err) {
                setError(String((err as Error).message ?? err));
              }
            }}
          >
            Create
          </button>
        </>
      }
    >
      <Field
        label="Name"
        value={name}
        onChange={setName}
        autoFocus
        placeholder="Product"
      />
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

// --- routing ----------------------------------------------------------------

function MainView({ view, onSignOut }: { view: View; onSignOut: () => void }) {
  switch (view.kind) {
    case "inbox":
      return <InboxView />;
    case "tasks":
      return <TasksBoard />;
    case "channel":
      return <ChannelView channelId={view.id} />;
    case "task":
      return <TaskPage taskId={view.id} />;
    case "agents":
      return <AgentsPage />;
    case "projects":
      return <ProjectsPage />;
    case "members":
      return <MembersPage />;
    case "automations":
      return <AutomationsPage />;
    case "automation":
      return <AutomationDebugPage automationId={view.id} />;
    case "settings":
      return <SettingsPage onSignOut={onSignOut} />;
    case "search":
      return <SearchPage query={view.query} />;
  }
}

function ChannelView({ channelId }: { channelId: string }) {
  const app = useApp();
  const api = useApi();
  const { toast } = useNavigation();
  const [creatingTask, setCreatingTask] = useState(false);
  const channel = app.channels.find((candidate) => candidate.id === channelId);
  if (!channel) return <Empty title="This conversation is gone" />;

  const partner =
    channel.kind === "dm"
      ? app.members.find(
          (member) =>
            channel.member_ids.includes(member.id) && member.id !== app.me?.id,
        )
      : undefined;

  const others = app.members.filter(
    (member) => channel.member_ids.includes(member.id) && member.id !== app.me?.id,
  );

  return (
    <div className="column">
      <div className="topbar">
        {channel.kind === "dm" ? (
          <Avatar member={partner} size={22} presence />
        ) : (
          <span className="topbar-hash">
            <HashIcon size={17} />
          </span>
        )}
        <span className="title">
          {channel.kind === "channel" ? channel.name : partner?.display_name}
        </span>
        {channel.kind === "channel" && (
          <ChannelTopic channel={channel} />
        )}
        {channel.kind === "dm" && partner?.kind === "agent" && (
          <span className="subtitle">
            {partner.agent?.description || partner.agent?.runtime}
          </span>
        )}
        <span className="spacer" />
        {channel.kind === "channel" && others.length > 0 && (
          <span className="facepile" title={others.map((m) => m.display_name).join(", ")}>
            {others.slice(0, 4).map((member) => (
              <Avatar key={member.id} member={member} size={22} />
            ))}
            {others.length > 4 && <span className="more">+{others.length - 4}</span>}
          </span>
        )}
        {partner?.kind === "agent" && (
          <Chip tone={partner.presence === "working" ? "accent" : ""}>
            {partner.presence}
          </Chip>
        )}
        <button className="button quiet" onClick={() => setCreatingTask(true)}>
          <PlusIcon size={15} />
          New task
        </button>
        <MenuButton
          align="right"
          title="More"
          items={[
            {
              key: "task",
              label: "Turn this into a task",
              onSelect: () => setCreatingTask(true),
            },
            ...(channel.kind === "channel"
              ? [
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
                ]
              : []),
          ]}
        >
          <MoreIcon size={17} />
        </MenuButton>
      </div>
      <ChatView channelId={channelId} />
      {creatingTask && (
        <NewTaskModal
          sourceChannelId={channelId}
          onClose={() => setCreatingTask(false)}
        />
      )}
    </div>
  );
}

/// The topic is one sentence about why the room exists, and it should be
/// changeable by the person who notices it is wrong.
function ChannelTopic({ channel }: { channel: Channel }) {
  const api = useApi();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(channel.topic);

  useEffect(() => setDraft(channel.topic), [channel.topic]);

  if (editing) {
    return (
      <input
        className="topic-input"
        autoFocus
        value={draft}
        placeholder="What is this channel for?"
        onChange={(event) => setDraft(event.target.value)}
        onBlur={() => {
          setEditing(false);
          if (draft !== channel.topic) {
            void api.updateChannel(channel.id, { topic: draft });
          }
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter") event.currentTarget.blur();
          if (event.key === "Escape") {
            setDraft(channel.topic);
            setEditing(false);
          }
        }}
      />
    );
  }

  return (
    <button
      className="subtitle editable-topic"
      title="Click to set the topic"
      onClick={() => setEditing(true)}
    >
      {channel.topic || "Add a topic"}
    </button>
  );
}

// --- workspace menu, palette, help ------------------------------------------

function WorkspaceMenu({
  onClose,
  onPick,
  onHelp,
}: {
  onClose: () => void;
  onPick: (view: View) => void;
  onHelp: () => void;
}) {
  const app = useApp();
  const entries: { label: string; hint: string; icon: ReactNode; view: View }[] = [
    {
      label: "Automations",
      hint: "When agents act on their own",
      icon: <AutomationIcon />,
      view: { kind: "automations" },
    },
    {
      label: "Agents",
      hint: "Identities, runtimes and where they run",
      icon: <AgentIcon />,
      view: { kind: "agents" },
    },
    {
      label: "Projects and machines",
      hint: "Repositories, folders and execution hosts",
      icon: <FolderIcon />,
      view: { kind: "projects" },
    },
    {
      label: "Members",
      hint: "People and invitations",
      icon: <MembersIcon />,
      view: { kind: "members" },
    },
    {
      label: "Settings",
      hint: "Workspace, machines, relay",
      icon: <SettingsIcon />,
      view: { kind: "settings" },
    },
  ];

  return (
      <Menu
        at={{ x: 74, y: 44 }}
        header={app.workspace?.name ?? "Workspace"}
        onClose={onClose}
        items={[
          ...entries.map((entry) => ({
            key: entry.label,
            label: entry.label,
            hint: entry.hint,
            icon: entry.icon,
            onSelect: () => onPick(entry.view),
          })),
          "separator",
          {
            key: "shortcuts",
            label: "Keyboard shortcuts",
            icon: <KeyboardIcon />,
            shortcut: "⌘/",
            onSelect: onHelp,
          },
        ]}
      />
  );
}

interface Entry {
  key: string;
  group: string;
  label: string;
  hint?: string;
  icon?: ReactNode;
  shortcut?: string;
  run: () => void;
}

/// ⌘K is one box that does everything: jump to a conversation, open a task,
/// run a command, or search every message. What it offers depends on what you
/// have typed, and it never makes you choose a mode first.
function CommandPalette({
  shortcuts,
  onClose,
}: {
  shortcuts: Shortcut[];
  onClose: () => void;
}) {
  const { go } = useNavigation();
  const app = useApp();
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const needle = query.trim().toLowerCase();

  const open = useCallback(
    (view: View) => {
      go(view);
      onClose();
    },
    [go, onClose],
  );

  const entries = useMemo<Entry[]>(() => {
    const out: Entry[] = [];
    const matches = (text: string) => !needle || text.toLowerCase().includes(needle);

    for (const channel of app.channels) {
      if (channel.kind === "task") continue;
      const partner =
        channel.kind === "dm"
          ? app.members.find(
              (member) =>
                channel.member_ids.includes(member.id) && member.id !== app.me?.id,
            )
          : undefined;
      const label = channel.kind === "channel" ? `#${channel.name}` : partner?.display_name ?? channel.name;
      if (!matches(label)) continue;
      out.push({
        key: channel.id,
        group: channel.kind === "channel" ? "Channels" : "People and agents",
        label,
        hint: channel.topic || partner?.agent?.runtime,
        icon: channel.kind === "channel" ? <HashIcon size={16} /> : <Avatar member={partner} size={18} />,
        run: () => open({ kind: "channel", id: channel.id }),
      });
    }

    for (const task of app.tasks) {
      if (!matches(`${task.key} ${task.title}`)) continue;
      out.push({
        key: task.id,
        group: "Tasks",
        label: `${task.key} · ${task.title}`,
        hint: task.status,
        icon: <TasksIcon size={16} />,
        run: () => open({ kind: "task", id: task.id }),
      });
    }

    for (const shortcut of shortcuts) {
      if (shortcut.group === "View") continue;
      if (!matches(shortcut.label)) continue;
      out.push({
        key: shortcut.id,
        group: shortcut.group === "Create" ? "Create" : "Commands",
        label: shortcut.label,
        shortcut: shortcut.keys,
        icon:
          shortcut.group === "Create" ? <PlusIcon size={16} /> : <InboxIcon size={16} />,
        run: () => {
          onClose();
          shortcut.run();
        },
      });
    }

    if (needle) {
      out.push({
        key: "full-text",
        group: "Search",
        label: `Search every message for “${query.trim()}”`,
        icon: <SearchIcon size={16} />,
        run: () => open({ kind: "search", query: query.trim() }),
      });
    }

    return out.slice(0, 40);
  }, [app, needle, query, shortcuts, open, onClose]);

  useEffect(() => setActive(0), [needle]);

  const grouped = useMemo(() => {
    const map = new Map<string, Entry[]>();
    for (const entry of entries) {
      map.set(entry.group, [...(map.get(entry.group) ?? []), entry]);
    }
    return [...map.entries()];
  }, [entries]);

  return (
    <div className="modal-backdrop" onMouseDown={onClose}>
      <div
        className="palette"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="palette-input">
          <SearchIcon size={17} />
          <input
            autoFocus
            spellCheck={false}
            autoCorrect="off"
            autoCapitalize="off"
            placeholder="Jump to a channel, a task, or type a command…"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "ArrowDown") {
                event.preventDefault();
                setActive((index) => Math.min(index + 1, entries.length - 1));
              } else if (event.key === "ArrowUp") {
                event.preventDefault();
                setActive((index) => Math.max(index - 1, 0));
              } else if (event.key === "Enter") {
                event.preventDefault();
                entries[active]?.run();
              } else if (event.key === "Escape") {
                onClose();
              }
            }}
          />
          <KeyHint keys="Esc" />
        </div>
        <div className="palette-list">
          {entries.length === 0 && (
            <div className="palette-empty">Nothing matches that.</div>
          )}
          {grouped.map(([group, items]) => (
            <div key={group}>
              <div className="palette-group">{group}</div>
              {items.map((entry) => {
                const index = entries.indexOf(entry);
                return (
                  <button
                    key={entry.key}
                    className={`palette-item${index === active ? " active" : ""}`}
                    onMouseEnter={() => setActive(index)}
                    onClick={entry.run}
                  >
                    <span className="palette-icon">{entry.icon}</span>
                    <span className="grow">
                      <span className="name">{entry.label}</span>
                      {entry.hint && <span className="sub">{entry.hint}</span>}
                    </span>
                    {entry.shortcut && <KeyHint keys={entry.shortcut} />}
                  </button>
                );
              })}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function ShortcutsSheet({
  shortcuts,
  onClose,
}: {
  shortcuts: Shortcut[];
  onClose: () => void;
}) {
  const groups = ["Go to", "Create", "Do", "View"] as const;
  return (
    <Modal
      title="Keyboard shortcuts"
      subtitle="Chords like “G then I” work when you are not typing."
      onClose={onClose}
      actions={
        <button className="button primary" onClick={onClose}>
          Done
        </button>
      }
    >
      {groups.map((group) => {
        const items = shortcuts.filter((shortcut) => shortcut.group === group);
        if (items.length === 0) return null;
        return (
          <div key={group} className="shortcut-group">
            <div className="section-title">{group}</div>
            {items.map((shortcut) => (
              <div className="shortcut-row" key={shortcut.id}>
                <span className="grow">{shortcut.label}</span>
                <KeyHint keys={shortcut.keys} />
              </div>
            ))}
          </div>
        );
      })}
      <div className="shortcut-group">
        <div className="section-title">In the composer</div>
        <div className="shortcut-row">
          <span className="grow">Send</span>
          <KeyHint keys="↵" />
        </div>
        <div className="shortcut-row">
          <span className="grow">New line</span>
          <KeyHint keys="⇧↵" />
        </div>
        <div className="shortcut-row">
          <span className="grow">Mention someone</span>
          <KeyHint keys="@" />
        </div>
      </div>
    </Modal>
  );
}

function SearchPage({ query }: { query: string }) {
  const api = useApi();
  const { go } = useNavigation();
  const handles = useHandles();
  const [results, setResults] = useState<SearchResults>();

  useEffect(() => {
    setResults(undefined);
    void api.search(query).then(setResults);
  }, [query, api]);

  return (
    <Page title="Search" subtitle={query}>
      {!results && <Empty title="Searching" />}
      {results?.tasks.length ? (
        <div className="section-head">
          <span className="section-title">Tasks</span>
        </div>
      ) : null}
      {results?.tasks.map((task) => (
        <button
          key={task.id}
          className="row"
          onClick={() => go({ kind: "task", id: task.id })}
        >
          <span className="grow">
            <span className="name">
              {task.key} — {task.title}
            </span>
            <span className="sub">{task.outcome}</span>
          </span>
          <Chip>{task.status}</Chip>
        </button>
      ))}
      {results?.messages.length ? (
        <div className="section-head">
          <span className="section-title">Messages</span>
        </div>
      ) : null}
      {results?.messages.map((hit) => (
        <button
          key={hit.message.id}
          className="row"
          onClick={() => go({ kind: "channel", id: hit.message.channel_id })}
        >
          <span className="grow">
            <span className="name">
              {hit.author_name} in {hit.channel_name}
            </span>
            <span className="sub">
              <Markdown body={hit.snippet} handles={handles} compact />
            </span>
          </span>
        </button>
      ))}
      {results && !results.messages.length && !results.tasks.length && (
        <Empty title="Nothing matched" hint={`No conversation or task mentions “${query}”.`} />
      )}
    </Page>
  );
}
