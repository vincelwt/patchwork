import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import type { ReactNode } from "react";
import { store, useApi, useApp, useAppSelector, useWorkspaces } from "./lib/store";
import {
  boot,
  canHostRelay,
  hostRelayHere,
  join,
  signOutOfEverything,
  switchTo,
  useSettings,
} from "./lib/session";
import { markSeen } from "./lib/unread";
import { toggleDictation } from "./lib/dictation";
import { inTauri, parseInviteDetails } from "./lib/desktop";
import logo from "./assets/logo.png";
import { chord, combo, isTyping } from "./lib/shortcuts";
import type { Shortcut } from "./lib/shortcuts";
import { Sidebar, SIDEBAR_RAIL } from "./components/Sidebar";
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
  proseText,
  useNavigation,
} from "./components/common";
import { Empty, KeyHint, MenuButton, Page } from "./components/ui";
import { Markdown } from "./components/Markdown";
import {
  HashIcon,
  InboxIcon,
  MoreIcon,
  PlusIcon,
  SearchIcon,
  Spinner,
  TasksIcon,
} from "./components/icons";
import type {
  Inspector as InspectorState,
  ToastAction,
  View,
} from "./components/common";
import type { Channel, Id, SearchResults } from "@client/types";

export default function App() {
  const settings = useSettings();
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Connect first: the relay round trip is the long pole, and starting it
    // before React has re-rendered means the shell and its contents arrive
    // together rather than one after the other.
    void boot().then(() => setLoading(false));
  }, []);

  const content = loading ? (
    <div className="empty">Starting Patchwork…</div>
  ) : !settings?.workspaces.length ? (
    <Onboarding />
  ) : (
    <Workspace onSignOut={() => void signOutOfEverything()} />
  );

  return (
    <>
      <UnreadBadge />
      {content}
    </>
  );
}

/// Two ways in, and the first one needs no server: this machine can *be* the
/// relay, since the app already contains one. Joining somebody else's relay
/// is the other tab.
export function Onboarding() {
  const [mode, setMode] = useState<"here" | "join">(
    canHostRelay ? "here" : "join",
  );
  const [relayUrl, setRelayUrl] = useState("");
  const [inviteCode, setInviteCode] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [workspaceName, setWorkspaceName] = useState("Patchwork");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    setError("");
    try {
      await action();
    } catch (err) {
      setError(String((err as Error).message ?? err));
      setBusy(false);
    }
  };

  return (
    <div className="onboarding">
      <div className="onboarding-card">
        <img className="brand" src={logo} alt="" width={72} height={72} />
        {canHostRelay && (
          <div className="segmented">
            <button
              className={mode === "here" ? "active" : ""}
              onClick={() => setMode("here")}
            >
              Start a workspace
            </button>
            <button
              className={mode === "join" ? "active" : ""}
              onClick={() => setMode("join")}
            >
              Join with invite
            </button>
          </div>
        )}

        {mode === "here" ? (
          <>
            <h1>Start your workspace</h1>
            <p>
              Patchwork runs everything on this machine and gives it a secure
              public connection through Patchwork Relay. Phones and teammates
              can join without domains, certificates, or port forwarding.
            </p>
            <Field
              label="Workspace name"
              value={workspaceName}
              onChange={setWorkspaceName}
            />
            <Field
              label="Your name"
              value={displayName}
              onChange={setDisplayName}
              autoFocus
            />
            {error && <div className="error-text">{error}</div>}
            <button
              className="button primary"
              style={{ marginTop: 16, width: "100%", justifyContent: "center" }}
              disabled={busy || !displayName.trim()}
              onClick={() =>
                run(() =>
                  hostRelayHere({
                    workspace_name: workspaceName.trim(),
                    display_name: displayName.trim(),
                  }),
                )
              }
            >
              {busy ? "Starting…" : "Start"}
            </button>
          </>
        ) : (
          <>
            <h1>Join a workspace</h1>
            <p>
              Paste the relay URL and invite code shared by a workspace admin.
              Your copy stays connected alongside every workspace you join.
            </p>
            <Field label="Relay URL" value={relayUrl} onChange={setRelayUrl} placeholder="https://relay.patchwork.sh/r/…" />
            <Field
              label="Invite code or copied invitation"
              value={inviteCode}
              onChange={(value) => {
                const invite = parseInviteDetails(value);
                if (invite) {
                  setRelayUrl(invite.relayUrl);
                  setInviteCode(invite.code);
                } else {
                  setInviteCode(value);
                }
              }}
              autoFocus
            />
            <Field
              label="Your name"
              value={displayName}
              onChange={setDisplayName}
            />
            {error && <div className="error-text">{error}</div>}
            <button
              className="button primary"
              style={{ marginTop: 16, width: "100%", justifyContent: "center" }}
              disabled={busy || !relayUrl.trim() || !inviteCode.trim() || !displayName.trim()}
              onClick={() =>
                run(() =>
                  join({
                    relay_url: relayUrl,
                    invite_code: inviteCode,
                    display_name: displayName,
                  }),
                )
              }
            >
              {busy ? "Joining…" : "Join"}
            </button>
          </>
        )}
      </div>
    </div>
  );
}

function Workspace({ onSignOut }: { onSignOut: () => void }) {
  // The root of the tree, so what it subscribes to decides how often
  // everything below it redraws. Only the connection state belongs here;
  // anything derived from workspace content is read where it is used.
  const app = useAppSelector((data) => ({
    status: data.status,
    error: data.error,
    live: data.live,
  }));
  const [view, setView] = useState<View>({ kind: "inbox" });
  const [inspector, setInspector] = useState<InspectorState>(null);
  const [toast, setToast] = useState<{
    message: string;
    action?: ToastAction;
  }>();
  const toastTimer = useRef<number>(undefined);
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

  // A narrow window has no room for two columns of words. Rather than refuse
  // to be resized, the sidebar becomes a rail on its own and gives the main
  // column everything it has.
  const narrow = useMediaQuery("(max-width: 720px)");
  const rail = narrow || sidebarWidth <= SIDEBAR_RAIL;

  const go = useCallback((next: View) => {
    setView(next);
    setInspector(null);
  }, []);

  useRememberedView(view, setView, setInspector);

  const dismissToast = useCallback(() => {
    window.clearTimeout(toastTimer.current);
    setToast(undefined);
  }, []);

  const showToast = useCallback((message: string, action?: ToastAction) => {
    window.clearTimeout(toastTimer.current);
    setToast({ message, action });
    toastTimer.current = window.setTimeout(
      () => setToast(undefined),
      action ? 5000 : 2600,
    );
  }, []);

  useEffect(() => () => window.clearTimeout(toastTimer.current), []);

  const create = useCallback((what: Creatable, sectionId?: Id) => {
    setCreating({ what, sectionId });
  }, []);

  const shortcuts = useShortcuts({
    go,
    create,
    openSearch: () => setSearchOpen(true),
    openHelp: () => setHelpOpen(true),
    closeInspector: () => setInspector(null),
  });

  // A fresh object here would re-render every consumer of the context — which
  // is most of the app — on any state change in this component, including the
  // ones that only move a menu.
  const navigation = useMemo(
    () => ({ view, go, inspector, inspect: setInspector, toast: showToast }),
    [view, go, inspector, showToast],
  );

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
    <NavigationContext.Provider value={navigation}>
      <MarkAsSeen view={view} />
      <div
        className="shell"
        style={
          {
            "--sidebar-width": `${rail ? SIDEBAR_RAIL : sidebarWidth}px`,
          } as React.CSSProperties
        }
      >
        <Sidebar
          rail={rail}
          onHelp={() => setHelpOpen(true)}
          onSearch={() => setSearchOpen(true)}
          onResize={resizeSidebar}
          onCreate={create}
          onSignOut={onSignOut}
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
      {toast && (
        <div className="toast">
          <span role="status" aria-live="polite">
            {toast.message}
          </span>
          {toast.action && (
            <button
              className="toast-action"
              onClick={() => {
                const action = toast.action;
                if (!action) return;
                dismissToast();
                action.onClick();
              }}
            >
              {toast.action.label}
            </button>
          )}
        </div>
      )}
    </NavigationContext.Provider>
  );
}

function useMediaQuery(query: string) {
  const [matches, setMatches] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const media = window.matchMedia(query);
    const onChange = () => setMatches(media.matches);
    onChange();
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }, [query]);
  return matches;
}

/// Each workspace keeps the page you were on. Channel and task ids mean
/// nothing in another workspace, so switching cannot simply carry the view
/// across — and coming back to "wherever I was" is the whole point of the
/// connections staying up.
function useRememberedView(
  view: View,
  setView: (view: View) => void,
  setInspector: (inspector: InspectorState) => void,
) {
  const workspaceId = useSyncExternalStore(
    store.subscribe,
    () => store.activeWorkspaceId,
  );
  const remembered = useRef<Record<string, View>>({});
  const previous = useRef(workspaceId);

  useEffect(() => {
    if (previous.current === workspaceId) return;
    if (previous.current) remembered.current[previous.current] = view;
    previous.current = workspaceId;
    setInspector(null);
    setView(
      (workspaceId && remembered.current[workspaceId]) || { kind: "inbox" },
    );
  }, [workspaceId, view, setView, setInspector]);
}

/// The number on the app icon: everything waiting for you, in every workspace
/// you have joined, not just the one on screen.
///
/// Its own component and drawing nothing, for the same reason as `MarkAsSeen`:
/// it watches counts that move on every event, and the root of the tree must
/// not.
function UnreadBadge() {
  const total = useWorkspaces().reduce(
    (sum, workspace) => sum + workspace.unread,
    0,
  );

  useEffect(() => {
    if (!inTauri) return;
    let cancelled = false;
    void import("@tauri-apps/api/window")
      .then(({ getCurrentWindow }) => {
        if (!cancelled) return getCurrentWindow().setBadgeCount(total || undefined);
      })
      .catch((error) => console.warn("Could not update the app badge", error));
    return () => {
      cancelled = true;
    };
  }, [total]);

  return null;
}

/// Opening a conversation is what "I have seen this" means.
///
/// Its own component, drawing nothing, because these effects need to watch the
/// message list and the inbox — and having the root of the tree watch those
/// would redraw the entire app every time either moved.
function MarkAsSeen({ view }: { view: View }) {
  const { watching, watchingLastMessage, inboxHere } = useAppSelector((data) => {
    const watching =
      view.kind === "channel"
        ? view.id
        : view.kind === "task"
          ? data.tasks.find((task) => task.id === view.id)?.discussion_channel_id
          : undefined;
    return {
      watching,
      watchingLastMessage: watching
        ? data.channels.find((channel) => channel.id === watching)?.last_message_at
        : undefined,
      // A count, not the items: the array is rebuilt on every event and only
      // its emptiness decides whether there is anything to do.
      inboxHere: watching
        ? data.inbox.filter((item) => !item.read_at && item.channel_id === watching)
            .length
        : 0,
    };
  });

  // Keeping the mark on the channel *and* its newest message means a channel
  // you are sitting in never accumulates a phantom unread badge.
  useEffect(() => {
    if (watching) markSeen(watching, Math.max(Date.now(), watchingLastMessage ?? 0));
  }, [watching, watchingLastMessage]);

  // Reading the mention where it was written is reading it. Leaving the Inbox
  // item unread would put a badge on the very conversation you are looking at.
  useEffect(() => {
    if (!watching || inboxHere === 0) return;
    const timer = window.setTimeout(() => {
      for (const item of store.getSnapshot().inbox) {
        if (!item.read_at && item.channel_id === watching) {
          void store.api?.markRead(item.id);
        }
      }
    }, 700);
    return () => window.clearTimeout(timer);
  }, [watching, inboxHere]);

  return null;
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

  // The system-wide chord is registered natively, so it arrives as an event
  // instead of a key press. Same action, and it brings the window forward
  // first, so the words land somewhere you can see them.
  useEffect(() => {
    if (!inTauri) return;
    let stop: (() => void) | undefined;
    void (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      stop = await listen("dictate", () => toggleDictation());
    })();
    return () => stop?.();
  }, []);

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
        id: "dictate",
        keys: "⌘D",
        label: "Dictate into the box you are in",
        group: "Do",
        match: combo("d"),
        run: toggleDictation,
      },
      {
        id: "dictate-anywhere",
        keys: "⌘⇧D",
        label: "Dictate from whatever app you are in",
        group: "Do",
        // Registered with the system, so it normally never reaches the window
        // at all. Matching it here as well costs a line and covers the window
        // being in front when the system chord was refused.
        match: combo("d", { shift: true }),
        run: toggleDictation,
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
        keys: "C",
        label: "New task",
        group: "Create",
        // A bare letter, the way Linear does it, plus ⌘N for the muscle memory
        // every other app has trained. Both mean the same thing.
        match: (event) =>
          combo("n")(event) ||
          (!event.metaKey &&
            !event.ctrlKey &&
            !event.altKey &&
            event.key.toLowerCase() === "c"),
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
      // The realtime event can arrive after navigation. Reconcile the HTTP
      // result immediately so the sidebar and channel view render together.
      store.upsertChannel(channel);
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
      <div className="topbar" data-tauri-drag-region="deep">
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
        {...proseText}
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
  const workspaces = useWorkspaces();
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const list = useRef<HTMLDivElement>(null);
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

    for (const workspace of workspaces) {
      if (!matches(workspace.name)) continue;
      out.push({
        key: `workspace-${workspace.id}`,
        group: "Workspaces",
        label: workspace.name,
        hint: workspace.active
          ? "Current workspace"
          : workspace.unread
            ? `${workspace.unread} waiting`
            : workspace.live
              ? "Connected"
              : "Offline",
        run: () => {
          onClose();
          if (!workspace.active) void switchTo(workspace.id);
        },
      });
    }

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
  }, [app, needle, query, shortcuts, workspaces, open, onClose]);

  // Arrow keys must walk the list the way it is *drawn*. Grouping reorders
  // everything — two channels either side of a task end up adjacent — so the
  // flat navigation order has to be derived from the grouped order, not from
  // the order the entries happened to be collected in. Getting this backwards
  // is what made the selection jump around.
  const grouped = useMemo(() => {
    const map = new Map<string, Entry[]>();
    for (const entry of entries) {
      map.set(entry.group, [...(map.get(entry.group) ?? []), entry]);
    }
    return [...map.entries()];
  }, [entries]);

  const ordered = useMemo(() => grouped.flatMap(([, items]) => items), [grouped]);

  // A shorter list must never leave the cursor pointing past the end.
  useEffect(() => {
    setActive((at) => (at >= ordered.length ? Math.max(0, ordered.length - 1) : at));
  }, [ordered.length]);
  useEffect(() => setActive(0), [needle]);
  useEffect(() => {
    list.current
      ?.querySelector<HTMLElement>(`[data-palette-index="${active}"]`)
      ?.scrollIntoView({ block: "nearest" });
  }, [active]);

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
                setActive((index) => Math.min(index + 1, ordered.length - 1));
              } else if (event.key === "ArrowUp") {
                event.preventDefault();
                setActive((index) => Math.max(index - 1, 0));
              } else if (event.key === "Enter") {
                event.preventDefault();
                ordered[active]?.run();
              } else if (event.key === "Escape") {
                onClose();
              }
            }}
          />
          <KeyHint keys="Esc" />
        </div>
        <div ref={list} className="palette-list">
          {entries.length === 0 && (
            <div className="palette-empty">Nothing matches that.</div>
          )}
          {grouped.map(([group, items]) => (
            <div key={group}>
              <div className="palette-group">{group}</div>
              {items.map((entry) => {
                const index = ordered.indexOf(entry);
                return (
                  <button
                    key={entry.key}
                    data-palette-index={index}
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
