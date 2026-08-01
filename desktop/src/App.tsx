import { useCallback, useEffect, useState } from "react";
import { store, useApi, useApp } from "./lib/store";
import { desktopInfo, joinWorkspace } from "./lib/desktop";
import type { DesktopSettings } from "./lib/desktop";
import { Sidebar } from "./components/Sidebar";
import { ChatView } from "./components/Chat";
import { Inspector } from "./components/Inspector";
import { InboxView } from "./components/Inbox";
import { NewTaskModal, TaskPage, TasksBoard } from "./components/Tasks";
import {
  AgentsPage,
  AutomationDebugPage,
  AutomationsPage,
  MembersPage,
  ProjectsPage,
  SettingsPage,
} from "./components/Pages";
import {
  Chip,
  Field,
  Modal,
  NavigationContext,
  useNavigation,
} from "./components/common";
import type { Inspector as InspectorState, View } from "./components/common";
import type { SearchResults } from "./lib/types";

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
  const [relayUrl, setRelayUrl] = useState("http://127.0.0.1:7717");
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

  const go = useCallback((next: View) => {
    setView(next);
    setInspector(null);
  }, []);

  const showToast = useCallback((message: string) => {
    setToast(message);
    window.setTimeout(() => setToast(undefined), 2600);
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "k") {
        event.preventDefault();
        setSearchOpen(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (app.status === "loading") {
    return <div className="empty">Connecting to the relay…</div>;
  }
  if (app.status === "error") {
    return (
      <div className="onboarding">
        <div className="onboarding-card">
          <h1>Can't reach the relay</h1>
          <p>{app.error}</p>
          <button
            className="button"
            style={{ marginTop: 14 }}
            onClick={() => window.location.reload()}
          >
            Try again
          </button>
          <button className="button quiet" style={{ marginTop: 8 }} onClick={onSignOut}>
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
      <div className="shell">
        <Sidebar onOpenMenu={() => setMenuOpen(true)} />
        <div className="main">
          {!app.live && <div className="offline-banner">Reconnecting…</div>}
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
        />
      )}
      {searchOpen && <SearchModal onClose={() => setSearchOpen(false)} />}
      {toast && <div className="toast">{toast}</div>}
    </NavigationContext.Provider>
  );
}

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
  const [creatingTask, setCreatingTask] = useState(false);
  const channel = app.channels.find((candidate) => candidate.id === channelId);
  if (!channel) return <div className="empty">This conversation is gone.</div>;

  const partner =
    channel.kind === "dm"
      ? app.members.find(
          (member) =>
            channel.member_ids.includes(member.id) && member.id !== app.me?.id,
        )
      : undefined;

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">
          {channel.kind === "channel" ? `#${channel.name}` : partner?.display_name}
        </span>
        <span className="subtitle">{channel.topic}</span>
        <span className="spacer" />
        {partner?.kind === "agent" && (
          <Chip tone={partner.presence === "working" ? "accent" : ""}>
            {partner.presence}
          </Chip>
        )}
        <button className="button quiet" onClick={() => setCreatingTask(true)}>
          New task
        </button>
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

function WorkspaceMenu({
  onClose,
  onPick,
}: {
  onClose: () => void;
  onPick: (view: View) => void;
}) {
  const entries: { label: string; view: View }[] = [
    { label: "Automations", view: { kind: "automations" } },
    { label: "Agents", view: { kind: "agents" } },
    { label: "Projects and execution machines", view: { kind: "projects" } },
    { label: "Members", view: { kind: "members" } },
    { label: "Settings", view: { kind: "settings" } },
  ];

  return (
    <Modal title="Workspace" onClose={onClose}>
      <div className="stack" style={{ marginTop: 10 }}>
        {entries.map((entry) => (
          <button
            key={entry.label}
            className="row"
            style={{ width: "100%" }}
            onClick={() => onPick(entry.view)}
          >
            <span className="grow name">{entry.label}</span>
          </button>
        ))}
      </div>
    </Modal>
  );
}

function SearchModal({ onClose }: { onClose: () => void }) {
  const { go } = useNavigation();
  const [query, setQuery] = useState("");

  return (
    <Modal title="Search" onClose={onClose}>
      <Field
        label="Conversations, tasks and outcomes"
        value={query}
        onChange={setQuery}
        autoFocus
      />
      <button
        className="button primary"
        style={{ marginTop: 12 }}
        disabled={!query.trim()}
        onClick={() => {
          go({ kind: "search", query: query.trim() });
          onClose();
        }}
      >
        Search
      </button>
    </Modal>
  );
}

function SearchPage({ query }: { query: string }) {
  const api = useApi();
  const { go } = useNavigation();
  const [results, setResults] = useState<SearchResults>();

  useEffect(() => {
    void api.search(query).then(setResults);
  }, [query, api]);

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">Search</span>
        <span className="subtitle">{query}</span>
      </div>
      <div className="page">
        <div className="page-inner">
          {!results && <div className="empty">Searching…</div>}
          {results?.tasks.length ? <div className="section-title">Tasks</div> : null}
          {results?.tasks.map((task) => (
            <button
              key={task.id}
              className="row"
              style={{ width: "100%" }}
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
            <div className="section-title">Messages</div>
          ) : null}
          {results?.messages.map((hit) => (
            <button
              key={hit.message.id}
              className="row"
              style={{ width: "100%" }}
              onClick={() => go({ kind: "channel", id: hit.message.channel_id })}
            >
              <span className="grow">
                <span className="name">
                  {hit.author_name} in {hit.channel_name}
                </span>
                <span className="sub">{hit.snippet}</span>
              </span>
            </button>
          ))}
          {results && !results.messages.length && !results.tasks.length && (
            <div className="empty">Nothing matched.</div>
          )}
        </div>
      </div>
    </div>
  );
}
