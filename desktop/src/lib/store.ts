// A small observable store. The relay is the source of truth: every mutation
// goes over HTTP and comes back as a realtime event, so what the UI shows is
// always what the workspace actually agreed on.

import { useSyncExternalStore } from "react";
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
} from "./types";

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

class Store {
  private data: AppData = EMPTY;
  private listeners = new Set<Listener>();
  private socket?: WebSocket;
  private reconnectTimer?: number;
  private loadingChannels = new Set<Id>();
  api?: Api;

  subscribe = (listener: Listener) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = () => this.data;

  private set(patch: Partial<AppData>) {
    this.data = { ...this.data, ...patch };
    this.listeners.forEach((listener) => listener());
  }

  async connect(baseUrl: string, token: string) {
    this.api = new Api(baseUrl, token);
    this.set({ status: "loading", error: undefined });
    try {
      const bootstrap = await this.api.bootstrap();
      this.applyBootstrap(bootstrap);
      this.openSocket();
    } catch (err) {
      this.set({ status: "error", error: String((err as Error).message ?? err) });
    }
  }

  disconnect() {
    this.socket?.close();
    this.socket = undefined;
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
      if (payload.t === "event") this.applyEvent(payload.envelope as Envelope);
    };
    socket.onclose = () => {
      this.set({ live: false });
      this.scheduleReconnect();
    };
    socket.onerror = () => socket.close();
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = window.setTimeout(() => {
      if (!this.api) return;
      // Re-bootstrap: cheaper than replaying a long backlog, and guarantees
      // the shell is correct after a long sleep.
      void this.connect(this.api.baseUrl, this.api.token);
    }, 2000);
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

export const store = new Store();

export function useApp(): AppData {
  return useSyncExternalStore(store.subscribe, store.getSnapshot);
}

export function useApi(): Api {
  const api = store.api;
  if (!api) throw new Error("not connected");
  return api;
}
