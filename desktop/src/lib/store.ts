// A small observable store. The relay is the source of truth: every mutation
// goes over HTTP and comes back as a realtime event, so what the UI shows is
// always what the workspace actually agreed on.

import { useCallback, useRef, useSyncExternalStore } from "react";
import { Api } from "./api";
import type {
  Automation,
  Bootstrap,
  Channel,
  Envelope,
  Event,
  Host,
  Id,
  InboxItem,
  Member,
  Message,
  Preview,
  Project,
  Question,
  Run,
  RunEvent,
  Section,
  Task,
  Workspace,
} from "@client/types";

export interface AppData {
  status: "loading" | "ready" | "error" | "disconnected";
  error?: string;
  live: boolean;
  workspace?: Workspace;
  me?: Member;
  members: Member[];
  sections: Section[];
  channels: Channel[];
  projects: Project[];
  hosts: Host[];
  tasks: Task[];
  inbox: InboxItem[];
  automations: Automation[];
  questions: Record<Id, Question>;
  runs: Record<Id, Run>;
  runEvents: Record<Id, RunEvent[]>;
  previews: Record<Id, Preview>;
  messages: Record<Id, Message[]>;
  hasMore: Record<Id, boolean>;
  threads: Record<Id, Message[]>;
  typing: Record<Id, Record<Id, number>>;
  seq: number;
}

const EMPTY: AppData = {
  status: "loading",
  live: false,
  members: [],
  sections: [],
  channels: [],
  projects: [],
  hosts: [],
  tasks: [],
  inbox: [],
  automations: [],
  questions: {},
  runs: {},
  runEvents: {},
  previews: {},
  messages: {},
  hasMore: {},
  threads: {},
  typing: {},
  seq: 0,
};

type Listener = () => void;

/// One workspace's live connection and everything it knows.
///
/// A desktop keeps one of these per joined workspace, all connected at the
/// same time: switching what the window shows must never interrupt an agent
/// working in the workspace you looked away from, and coming back must not
/// cost a round trip.
class Session {
  private data: AppData = EMPTY;
  private listeners = new Set<Listener>();
  private socket?: WebSocket;
  private reconnectTimer?: number;
  private retryDelay = 1000;
  private loadingChannels = new Set<Id>();
  private notifying = false;
  /// Events that arrived on the socket before the bootstrap they belong after.
  private queued?: Envelope[];
  api?: Api;

  constructor(readonly id: Id) {}

  subscribe = (listener: Listener) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = () => this.data;

  // Applying one event often means more than one `set` — a message and its
  // parent's reply count, a run and its question. Each of those used to be a
  // separate render of every subscribed component. The snapshot is updated
  // synchronously, so anything reading it sees the truth immediately; only the
  // telling-everyone part waits for the end of the turn.
  private set(patch: Partial<AppData>) {
    this.data = { ...this.data, ...patch };
    if (this.notifying) return;
    this.notifying = true;
    queueMicrotask(() => {
      this.notifying = false;
      this.listeners.forEach((listener) => listener());
    });
  }

  async connect(baseUrl: string, token: string) {
    this.api = new Api(baseUrl, token);
    if (this.data.status !== "ready") {
      this.set({ status: "loading", error: undefined });
    }
    try {
      // The socket handshake and the bootstrap fetch do not depend on each
      // other, so they happen at the same time and the app is live a whole
      // round trip sooner. Anything the socket delivers in the meantime is
      // held back and replayed once the bootstrap it post-dates is in place.
      this.queued = [];
      this.openSocket();
      const bootstrap = await this.api.bootstrap();
      this.retryDelay = 1000;
      this.applyBootstrap(bootstrap);
      const pending = this.queued ?? [];
      this.queued = undefined;
      for (const envelope of pending) {
        if (envelope.seq === 0 || envelope.seq > bootstrap.seq) {
          this.applyEvent(envelope);
        }
      }
    } catch (err) {
      // A relay restart is routine — keep trying rather than stranding the app
      // behind a button nobody is there to press.
      this.queued = undefined;
      this.closeSocket();
      this.set({ status: "error", error: String((err as Error).message ?? err) });
      this.scheduleReconnect();
    }
  }

  disconnect() {
    if (this.reconnectTimer) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.queued = undefined;
    this.closeSocket();
    this.data = EMPTY;
    this.api = undefined;
    this.listeners.forEach((listener) => listener());
  }

  private applyBootstrap(bootstrap: Bootstrap) {
    const questions: Record<Id, Question> = {};
    bootstrap.open_questions.forEach((q) => (questions[q.id] = q));
    const runs: Record<Id, Run> = {};
    bootstrap.active_runs.forEach((r) => (runs[r.id] = r));
    const previews: Record<Id, Preview> = {};
    bootstrap.previews.forEach((p) => (previews[p.id] = p));

    this.set({
      status: "ready",
      workspace: bootstrap.workspace,
      me: bootstrap.me,
      members: bootstrap.members,
      sections: bootstrap.sections,
      channels: bootstrap.channels,
      projects: bootstrap.projects,
      hosts: bootstrap.hosts,
      tasks: bootstrap.tasks,
      inbox: bootstrap.inbox,
      automations: bootstrap.automations,
      questions,
      runs,
      previews,
      seq: bootstrap.seq,
    });
  }

  private openSocket() {
    if (!this.api) return;
    this.closeSocket();
    const url = new URL(
      this.api.baseUrl.replace(/^http/, "ws").replace(/\/$/, "") + "/ws",
    );
    url.searchParams.set("token", this.api.token);
    url.searchParams.set("since", String(this.data.seq));

    const socket = new WebSocket(url.toString());
    this.socket = socket;

    socket.onopen = () => this.set({ live: true });
    socket.onmessage = (event) => {
      const payload = JSON.parse(event.data as string);
      if (payload.t !== "event") return;
      const envelope = payload.envelope as Envelope;
      // Still waiting on the bootstrap this event comes after.
      if (this.queued) this.queued.push(envelope);
      else this.applyEvent(envelope);
    };
    socket.onclose = () => {
      this.set({ live: false });
      this.scheduleReconnect();
    };
    socket.onerror = () => socket.close();
  }

  /// Close a socket we are done with without it looking like a disconnection.
  private closeSocket() {
    const socket = this.socket;
    if (!socket) return;
    this.socket = undefined;
    socket.onclose = null;
    socket.onerror = null;
    socket.onmessage = null;
    socket.onopen = null;
    socket.close();
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) window.clearTimeout(this.reconnectTimer);
    const delay = this.retryDelay;
    this.retryDelay = Math.min(delay * 2, 15000);
    this.reconnectTimer = window.setTimeout(() => {
      if (!this.api) return;
      // Re-bootstrap: cheaper than replaying a long backlog, and guarantees
      // the shell is correct after a long sleep.
      void this.connect(this.api.baseUrl, this.api.token);
    }, delay);
  }

  private applyEvent(envelope: Envelope) {
    const event = envelope as unknown as Event;
    if (envelope.seq > 0) this.data = { ...this.data, seq: envelope.seq };

    switch (event.kind) {
      case "message_created": {
        this.upsertMessage(event.message);
        break;
      }
      case "message_updated": {
        this.upsertMessage(event.message, true);
        break;
      }
      case "message_deleted": {
        const list = this.data.messages[event.channel_id];
        if (list) {
          this.set({
            messages: {
              ...this.data.messages,
              [event.channel_id]: list.filter((m) => m.id !== event.message_id),
            },
          });
        }
        break;
      }
      case "channel_created":
      case "channel_updated":
        this.set({ channels: upsert(this.data.channels, event.channel) });
        break;
      case "channel_deleted":
        this.set({
          channels: this.data.channels.filter((c) => c.id !== event.channel_id),
        });
        break;
      case "sections_updated":
        this.set({ sections: event.sections });
        break;
      case "member_updated":
        this.set({ members: upsert(this.data.members, event.member) });
        break;
      case "member_removed":
        this.set({
          members: this.data.members.filter((m) => m.id !== event.member_id),
        });
        break;
      case "presence_changed":
        this.set({
          members: this.data.members.map((m) =>
            m.id === event.member_id ? { ...m, presence: event.presence } : m,
          ),
        });
        break;
      case "typing": {
        const channel = this.data.typing[event.channel_id] ?? {};
        this.set({
          typing: {
            ...this.data.typing,
            [event.channel_id]: { ...channel, [event.member_id]: Date.now() },
          },
        });
        break;
      }
      case "task_created":
      case "task_updated":
        this.set({ tasks: upsert(this.data.tasks, event.task) });
        break;
      case "task_deleted":
        this.set({ tasks: this.data.tasks.filter((t) => t.id !== event.task_id) });
        break;
      case "run_updated":
        this.set({ runs: { ...this.data.runs, [event.run.id]: event.run } });
        break;
      case "run_event_appended": {
        const list = this.data.runEvents[event.event.run_id];
        if (list) {
          this.set({
            runEvents: {
              ...this.data.runEvents,
              [event.event.run_id]: [...list, event.event],
            },
          });
        }
        break;
      }
      case "question_updated":
        this.set({
          questions: { ...this.data.questions, [event.question.id]: event.question },
        });
        break;
      case "inbox_item_created":
      case "inbox_item_updated":
        this.set({ inbox: upsert(this.data.inbox, event.item) });
        break;
      case "host_updated":
        this.set({ hosts: upsert(this.data.hosts, event.host) });
        break;
      case "project_updated":
        this.set({ projects: upsert(this.data.projects, event.project) });
        break;
      case "project_deleted":
        this.set({
          projects: this.data.projects.filter((p) => p.id !== event.project_id),
        });
        break;
      case "automation_updated":
        this.set({ automations: upsert(this.data.automations, event.automation) });
        break;
      case "automation_deleted":
        this.set({
          automations: this.data.automations.filter(
            (a) => a.id !== event.automation_id,
          ),
        });
        break;
      case "preview_updated":
        this.set({
          previews: { ...this.data.previews, [event.preview.id]: event.preview },
        });
        break;
      case "workspace_updated":
        this.set({ workspace: event.workspace });
        break;
      default:
        break;
    }
  }

  private upsertMessage(message: Message, replaceOnly = false) {
    if (message.parent_id) {
      const thread = this.data.threads[message.parent_id];
      if (thread) {
        this.set({
          threads: {
            ...this.data.threads,
            [message.parent_id]: upsert(thread, message),
          },
        });
      }
      // Keep the root's reply count honest without refetching.
      const list = this.data.messages[message.channel_id];
      if (list) {
        this.set({
          messages: {
            ...this.data.messages,
            [message.channel_id]: list.map((m) =>
              m.id === message.parent_id
                ? { ...m, reply_count: m.reply_count + (replaceOnly ? 0 : 1) }
                : m,
            ),
          },
        });
      }
      return;
    }

    const list = this.data.messages[message.channel_id];
    if (!list) return;
    this.set({
      messages: {
        ...this.data.messages,
        [message.channel_id]: upsert(list, message),
      },
    });
  }

  async loadChannel(channelId: Id, force = false) {
    if (!this.api) return;
    if (!force && (this.data.messages[channelId] || this.loadingChannels.has(channelId)))
      return;
    this.loadingChannels.add(channelId);
    try {
      const page = await this.api.messages(channelId);
      this.set({
        messages: { ...this.data.messages, [channelId]: page.messages },
        hasMore: { ...this.data.hasMore, [channelId]: page.has_more },
      });
    } finally {
      this.loadingChannels.delete(channelId);
    }
  }

  async loadOlder(channelId: Id) {
    if (!this.api) return;
    const list = this.data.messages[channelId];
    if (!list?.length) return;
    const page = await this.api.messages(channelId, list[0].id);
    this.set({
      messages: {
        ...this.data.messages,
        [channelId]: [...page.messages, ...list],
      },
      hasMore: { ...this.data.hasMore, [channelId]: page.has_more },
    });
  }

  async loadThread(messageId: Id) {
    if (!this.api) return;
    const replies = await this.api.thread(messageId);
    this.set({ threads: { ...this.data.threads, [messageId]: replies } });
  }

  async loadRun(runId: Id) {
    if (!this.api) return;
    const detail = await this.api.run(runId);
    this.set({
      runs: { ...this.data.runs, [runId]: detail.run },
      runEvents: { ...this.data.runEvents, [runId]: detail.events },
      questions: {
        ...this.data.questions,
        ...Object.fromEntries(detail.questions.map((q) => [q.id, q])),
      },
    });
  }

  async loadQuestion(questionId: Id) {
    if (!this.api || this.data.questions[questionId]) return;
    const question = await this.api.question(questionId);
    this.set({
      questions: { ...this.data.questions, [questionId]: question },
    });
  }

  async loadPreview(previewId: Id) {
    if (!this.api || this.data.previews[previewId]) return;
    const previews = await this.api.previews();
    this.set({
      previews: {
        ...this.data.previews,
        ...Object.fromEntries(previews.map((p) => [p.id, p])),
      },
    });
  }

  typing(channelId: Id) {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify({ t: "typing", channel_id: channelId }));
    }
  }
}

function upsert<T extends { id: string }>(list: T[], item: T): T[] {
  const index = list.findIndex((existing) => existing.id === item.id);
  if (index === -1) return [...list, item];
  const next = list.slice();
  next[index] = item;
  return next;
}

export interface WorkspaceHandle {
  id: Id;
  name: string;
  unread: number;
  live: boolean;
  active: boolean;
}

export interface Joined {
  id: Id;
  name: string;
  /// The workspace's own root on its relay, prefix and all.
  base_url: string;
  token: string;
}

/// Every workspace this desktop has joined, all connected at once.
///
/// The rest of the app talks to whichever one is on screen and never knows
/// the others exist — but they are live, so their agents keep working, their
/// unread counts stay true, and switching back is instant.
class Workspaces {
  private sessions = new Map<Id, Session>();
  private order: Id[] = [];
  private names = new Map<Id, string>();
  /// What a background workspace last showed in the switcher. Its own traffic
  /// must not redraw the workspace you are actually looking at.
  private badges = new Map<Id, string>();
  private listeners = new Set<Listener>();
  private activeId?: Id;
  private handles: WorkspaceHandle[] = [];

  subscribe = (listener: Listener) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): AppData => this.session?.getSnapshot() ?? EMPTY;

  /// The switcher's view. Cached so `useSyncExternalStore` sees a stable value.
  getWorkspaces = (): WorkspaceHandle[] => this.handles;

  private get session(): Session | undefined {
    return this.activeId ? this.sessions.get(this.activeId) : undefined;
  }

  get api(): Api | undefined {
    return this.session?.api;
  }

  get activeWorkspaceId(): Id | undefined {
    return this.activeId;
  }

  /// Bring the set of workspaces in line with what this desktop has joined,
  /// and show one of them. Connections that are already up are left alone.
  connect(joined: Joined[], activeId?: Id) {
    for (const [id, session] of this.sessions) {
      if (joined.some((workspace) => workspace.id === id)) continue;
      session.disconnect();
      this.sessions.delete(id);
      this.badges.delete(id);
    }
    this.order = joined.map((workspace) => workspace.id);

    for (const workspace of joined) {
      this.names.set(workspace.id, workspace.name);
      const existing = this.sessions.get(workspace.id);
      if (existing) {
        if (existing.api?.token === workspace.token) continue;
        existing.disconnect();
      }
      const session = new Session(workspace.id);
      session.subscribe(() => this.onSessionChanged(session));
      this.sessions.set(workspace.id, session);
      void session.connect(workspace.base_url, workspace.token);
    }

    this.activeId =
      (activeId && this.sessions.has(activeId) ? activeId : undefined) ??
      this.order[0];
    this.notify();
  }

  setActive(id: Id) {
    if (this.activeId === id || !this.sessions.has(id)) return;
    this.activeId = id;
    this.notify();
  }

  disconnect() {
    for (const session of this.sessions.values()) session.disconnect();
    this.sessions.clear();
    this.badges.clear();
    this.order = [];
    this.activeId = undefined;
    this.notify();
  }

  private onSessionChanged(session: Session) {
    if (session.id === this.activeId) {
      this.notify();
      return;
    }
    // A background workspace only ever changes the switcher, so it only wakes
    // the app when what the switcher shows actually moved.
    const data = session.getSnapshot();
    const badge = `${data.workspace?.name ?? ""}·${unreadOf(data)}·${data.live}`;
    if (this.badges.get(session.id) === badge) return;
    this.badges.set(session.id, badge);
    this.notify();
  }

  private notify() {
    this.handles = this.order.flatMap((id) => {
      const session = this.sessions.get(id);
      if (!session) return [];
      const data = session.getSnapshot();
      return [
        {
          id,
          name: data.workspace?.name ?? this.names.get(id) ?? "Workspace",
          unread: unreadOf(data),
          live: data.live,
          active: id === this.activeId,
        },
      ];
    });
    this.listeners.forEach((listener) => listener());
  }

  // What the app calls on the workspace it is looking at.
  loadChannel(channelId: Id, force = false) {
    return this.session?.loadChannel(channelId, force);
  }
  loadOlder(channelId: Id) {
    return this.session?.loadOlder(channelId) ?? Promise.resolve();
  }
  loadThread(messageId: Id) {
    return this.session?.loadThread(messageId);
  }
  loadRun(runId: Id) {
    return this.session?.loadRun(runId);
  }
  loadQuestion(questionId: Id) {
    return this.session?.loadQuestion(questionId);
  }
  loadPreview(previewId: Id) {
    return this.session?.loadPreview(previewId);
  }
  typing(channelId: Id) {
    this.session?.typing(channelId);
  }
}

function unreadOf(data: AppData) {
  return data.inbox.filter((item) => !item.read_at).length;
}

export const store = new Workspaces();

export function useApp(): AppData {
  return useSyncExternalStore(store.subscribe, store.getSnapshot);
}

/// Every joined workspace, for the switcher.
export function useWorkspaces(): WorkspaceHandle[] {
  return useSyncExternalStore(store.subscribe, store.getWorkspaces);
}

/// Subscribe to a part of the store rather than to all of it.
///
/// `useApp` wakes every component in the app for every event, which is fine
/// for a page you are looking at and ruinous for the hundred small things
/// mounted around it while an agent streams a reply several times a second.
/// A selector re-renders only when the slice it names actually changed —
/// compared one level deep, so returning a fresh `{ a, b }` each time is the
/// expected way to use it.
export function useAppSelector<T>(select: (data: AppData) => T): T {
  const selector = useRef(select);
  selector.current = select;
  const cached = useRef<{
    from: AppData;
    select: (data: AppData) => T;
    value: T;
  }>(undefined);

  const getSnapshot = useCallback(() => {
    const data = store.getSnapshot();
    const previous = cached.current;
    // The selector is part of the key, not just the data: one that closes over
    // a prop — the channel being looked at — asks a different question after
    // that prop changes, even though the store has not moved.
    if (previous && previous.from === data && previous.select === selector.current) {
      return previous.value;
    }
    const next = selector.current(data);
    // Same contents as last time: hand back the old object so React can see
    // that nothing changed and skip the render.
    const value = previous && shallowEqual(previous.value, next) ? previous.value : next;
    cached.current = { from: data, select: selector.current, value };
    return value;
  }, []);

  return useSyncExternalStore(store.subscribe, getSnapshot);
}

function shallowEqual(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || !a || !b) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const aKeys = Object.keys(a as object);
  const bKeys = Object.keys(b as object);
  if (aKeys.length !== bKeys.length) return false;
  return aKeys.every(
    (key) =>
      Object.prototype.hasOwnProperty.call(b, key) &&
      Object.is(
        (a as Record<string, unknown>)[key],
        (b as Record<string, unknown>)[key],
      ),
  );
}

export function useApi(): Api {
  const api = store.api;
  if (!api) throw new Error("not connected");
  return api;
}
