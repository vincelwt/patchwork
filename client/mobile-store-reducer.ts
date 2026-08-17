import type {
  AutomationRun,
  Bootstrap,
  Envelope,
  Event,
  Id,
  Message,
  Millis,
  RunDetail,
  Worktree,
} from "./types";

export const MAX_CACHED_CHANNELS = 8;
export const MAX_CACHED_MESSAGES = 60;

/// A message the phone took responsibility for before the relay had it: sent
/// while offline, or sent and not answered. `id` is also the idempotency key
/// the relay dedupes on, so retrying an ambiguous timeout cannot post twice.
export interface OutboxMessage {
  id: Id;
  channelId: Id;
  parentId?: Id;
  replyToId?: Id;
  body: string;
  attachmentIds: Id[];
  createdAt: Millis;
  status: "saving" | "queued" | "sending" | "failed";
  attempts: number;
  error?: string;
}

export interface WorkspaceData {
  bootstrap?: Bootstrap;
  seq: number;
  messages: Record<Id, Message[]>;
  hasMore: Record<Id, boolean>;
  threads: Record<Id, Message[]>;
  runDetails: Record<Id, RunDetail>;
  automationRuns: Record<Id, AutomationRun>;
  worktrees: Record<Id, Worktree>;
  typing: Record<Id, Record<Id, number>>;
  drafts: Record<Id, string>;
  recentChannels: Id[];
  outbox: OutboxMessage[];
}

export interface WorkspaceCache {
  version: 1;
  bootstrap: Bootstrap;
  seq: number;
  messages: Record<Id, Message[]>;
  hasMore: Record<Id, boolean>;
  drafts: Record<Id, string>;
  recentChannels: Id[];
  outbox?: OutboxMessage[];
  lastSyncAt?: number;
}

export function queueOutbox(
  state: WorkspaceData,
  entry: OutboxMessage,
): WorkspaceData {
  return { ...state, outbox: [...state.outbox, entry] };
}

export function patchOutbox(
  state: WorkspaceData,
  id: Id,
  patch: Partial<OutboxMessage>,
): WorkspaceData {
  return {
    ...state,
    outbox: state.outbox.map((entry) =>
      entry.id === id ? { ...entry, ...patch } : entry,
    ),
  };
}

export function dropOutbox(state: WorkspaceData, id: Id): WorkspaceData {
  return { ...state, outbox: state.outbox.filter((entry) => entry.id !== id) };
}

/// Oldest queued first, so a conversation arrives in the order it was written.
/// A message still being saved or one the relay refused is not ready to send.
export function nextOutbox(state: WorkspaceData): OutboxMessage | undefined {
  return state.outbox.find((entry) => entry.status === "queued");
}

/// Which composer a queued message belongs to: its channel, and its thread.
export function outboxFor(
  state: WorkspaceData,
  channelId: Id,
  parentId?: Id,
): OutboxMessage[] {
  return state.outbox.filter(
    (entry) => entry.channelId === channelId && entry.parentId === parentId,
  );
}

/// A send that may still succeed: no answer at all, a timeout, a rate limit, or
/// the relay having a bad moment. Anything else was refused on purpose and
/// retrying it forever would only hide the refusal.
export function retryableFailure(status?: number): boolean {
  return status === undefined || status === 408 || status === 429 || status >= 500;
}

export function emptyWorkspaceData(): WorkspaceData {
  return {
    seq: 0,
    messages: {},
    hasMore: {},
    threads: {},
    runDetails: {},
    automationRuns: {},
    worktrees: {},
    typing: {},
    drafts: {},
    recentChannels: [],
    outbox: [],
  };
}

export function applyBootstrap(
  state: WorkspaceData,
  bootstrap: Bootstrap,
): WorkspaceData {
  const seq = Math.max(state.seq, bootstrap.seq);
  return { ...state, bootstrap: { ...bootstrap, seq }, seq };
}

export function applyEnvelope(
  state: WorkspaceData,
  envelope: Envelope,
): WorkspaceData {
  if (envelope.seq > 0 && envelope.seq <= state.seq) return state;

  const event = envelope as unknown as Event;
  const seq = envelope.seq > 0 ? envelope.seq : state.seq;
  const bootstrap = state.bootstrap;

  switch (event.kind) {
    case "message_created":
      return withMessage(state, event.message, false, seq);
    case "message_updated":
      return withMessage(state, event.message, true, seq);
    case "message_deleted": {
      const removed = Object.values(state.threads)
        .flat()
        .find((message) => message.id === event.message_id);
      let messages = removeMessage(state.messages, event.message_id);
      if (removed?.parent_id && messages[removed.channel_id]) {
        messages = {
          ...messages,
          [removed.channel_id]: messages[removed.channel_id].map((message) =>
            message.id === removed.parent_id
              ? { ...message, reply_count: Math.max(0, message.reply_count - 1) }
              : message,
          ),
        };
      }
      const threads = removeMessage(state.threads, event.message_id);
      return { ...state, seq, messages, threads };
    }
    case "channel_created":
    case "channel_updated":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            channels: upsert(bootstrap.channels, event.channel),
          })
        : { ...state, seq };
    case "channel_deleted": {
      if (!bootstrap) return { ...state, seq };
      const messages = { ...state.messages };
      const hasMore = { ...state.hasMore };
      delete messages[event.channel_id];
      delete hasMore[event.channel_id];
      return {
        ...state,
        seq,
        bootstrap: {
          ...bootstrap,
          channels: bootstrap.channels.filter((item) => item.id !== event.channel_id),
        },
        messages,
        hasMore,
        recentChannels: state.recentChannels.filter((id) => id !== event.channel_id),
      };
    }
    case "sections_updated":
      return bootstrap
        ? withBootstrap(state, seq, { ...bootstrap, sections: event.sections })
        : { ...state, seq };
    case "workspace_skills_updated":
      return bootstrap
        ? withBootstrap(state, seq, { ...bootstrap, skills: event.skills })
        : { ...state, seq };
    case "member_updated":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            me: bootstrap.me.id === event.member.id ? event.member : bootstrap.me,
            members: upsert(bootstrap.members, event.member),
          })
        : { ...state, seq };
    case "member_removed":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            members: bootstrap.members.filter((item) => item.id !== event.member_id),
          })
        : { ...state, seq };
    case "presence_changed":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            me:
              bootstrap.me.id === event.member_id
                ? { ...bootstrap.me, presence: event.presence }
                : bootstrap.me,
            members: bootstrap.members.map((item) =>
              item.id === event.member_id
                ? { ...item, presence: event.presence }
                : item,
            ),
          })
        : { ...state, seq };
    case "typing":
      return {
        ...state,
        seq,
        typing: {
          ...state.typing,
          [event.channel_id]: {
            ...state.typing[event.channel_id],
            [event.member_id]: Date.now(),
          },
        },
      };
    case "task_created":
    case "task_updated":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            tasks: upsert(bootstrap.tasks, event.task),
          })
        : { ...state, seq };
    case "task_deleted":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            tasks: bootstrap.tasks.filter((item) => item.id !== event.task_id),
          })
        : { ...state, seq };
    case "run_updated": {
      const runDetails = state.runDetails[event.run.id]
        ? {
            ...state.runDetails,
            [event.run.id]: { ...state.runDetails[event.run.id], run: event.run },
          }
        : state.runDetails;
      if (!bootstrap) return { ...state, seq, runDetails };
      const active = ["queued", "dispatched", "running", "waiting"].includes(
        event.run.status,
      );
      return {
        ...state,
        seq,
        runDetails,
        bootstrap: {
          ...bootstrap,
          active_runs: active
            ? upsert(bootstrap.active_runs, event.run)
            : bootstrap.active_runs.filter((item) => item.id !== event.run.id),
        },
      };
    }
    case "run_event_appended": {
      const detail = state.runDetails[event.event.run_id];
      return detail
        ? {
            ...state,
            seq,
            runDetails: {
              ...state.runDetails,
              [event.event.run_id]: {
                ...detail,
                events: upsert(detail.events, event.event),
              },
            },
          }
        : { ...state, seq };
    }
    case "question_updated": {
      const detail = state.runDetails[event.question.run_id];
      const runDetails = detail
        ? {
            ...state.runDetails,
            [event.question.run_id]: {
              ...detail,
              questions: upsert(detail.questions, event.question),
            },
          }
        : state.runDetails;
      return bootstrap
        ? {
            ...withBootstrap(state, seq, {
              ...bootstrap,
              open_questions:
                event.question.status === "open"
                  ? upsert(bootstrap.open_questions, event.question)
                  : bootstrap.open_questions.filter(
                      (item) => item.id !== event.question.id,
                    ),
            }),
            runDetails,
          }
        : { ...state, seq, runDetails };
    }
    case "inbox_item_created":
    case "inbox_item_updated":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            inbox: upsert(bootstrap.inbox, event.item),
          })
        : { ...state, seq };
    case "host_updated":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            hosts: upsert(bootstrap.hosts, event.host),
          })
        : { ...state, seq };
    case "project_updated":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            projects: upsert(bootstrap.projects, event.project),
          })
        : { ...state, seq };
    case "project_deleted":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            projects: bootstrap.projects.filter((item) => item.id !== event.project_id),
          })
        : { ...state, seq };
    case "automation_updated":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            automations: upsert(bootstrap.automations, event.automation),
          })
        : { ...state, seq };
    case "automation_deleted":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            automations: bootstrap.automations.filter(
              (item) => item.id !== event.automation_id,
            ),
          })
        : { ...state, seq };
    case "automation_run_updated":
      return {
        ...state,
        seq,
        automationRuns: {
          ...state.automationRuns,
          [event.run.id]: event.run,
        },
      };
    case "preview_updated":
      return bootstrap
        ? withBootstrap(state, seq, {
            ...bootstrap,
            previews: upsert(bootstrap.previews, event.preview),
          })
        : { ...state, seq };
    case "worktree_updated":
      return {
        ...state,
        seq,
        worktrees: { ...state.worktrees, [event.worktree.id]: event.worktree },
      };
    case "workspace_updated":
      return bootstrap
        ? withBootstrap(state, seq, { ...bootstrap, workspace: event.workspace })
        : { ...state, seq };
  }
}

export function touchChannel(state: WorkspaceData, channelId: Id): WorkspaceData {
  return {
    ...state,
    recentChannels: [
      ...state.recentChannels.filter((id) => id !== channelId),
      channelId,
    ].slice(-MAX_CACHED_CHANNELS),
  };
}

export function toCache(
  state: WorkspaceData,
  lastSyncAt?: number,
): WorkspaceCache | undefined {
  if (!state.bootstrap) return undefined;
  const recentChannels = state.recentChannels.slice(-MAX_CACHED_CHANNELS);
  const messages = Object.fromEntries(
    recentChannels.flatMap((channelId) => {
      const list = state.messages[channelId];
      return list ? [[channelId, list.slice(-MAX_CACHED_MESSAGES)]] : [];
    }),
  );
  const hasMore = Object.fromEntries(
    recentChannels.flatMap((channelId) =>
      channelId in state.hasMore ? [[channelId, state.hasMore[channelId]]] : [],
    ),
  );
  return {
    version: 1,
    bootstrap: { ...state.bootstrap, seq: state.seq },
    seq: state.seq,
    messages,
    hasMore,
    drafts: state.drafts,
    recentChannels,
    outbox: state.outbox,
    lastSyncAt,
  };
}

export function fromCache(value: unknown): {
  data: WorkspaceData;
  lastSyncAt?: number;
} | null {
  if (!isCache(value)) return null;
  const recentChannels = value.recentChannels.slice(-MAX_CACHED_CHANNELS);
  const messages = Object.fromEntries(
    recentChannels.flatMap((channelId) => {
      const list = value.messages[channelId];
      return Array.isArray(list)
        ? [[channelId, list.slice(-MAX_CACHED_MESSAGES)]]
        : [];
    }),
  );
  return {
    data: {
      ...emptyWorkspaceData(),
      bootstrap: value.bootstrap,
      seq: Math.max(value.seq, value.bootstrap.seq),
      messages,
      hasMore: Object.fromEntries(
        recentChannels.flatMap((channelId) =>
          channelId in value.hasMore
            ? [[channelId, Boolean(value.hasMore[channelId])]]
            : [],
        ),
      ),
      drafts: value.drafts,
      recentChannels,
      // A send that was in flight when the app went away has an unknown fate;
      // it is queued again, and its client id keeps the relay from storing it
      // twice if the first attempt did land.
      outbox: (Array.isArray(value.outbox) ? value.outbox : [])
        .filter(isOutboxMessage)
        .map((entry) => ({
          id: entry.id,
          channelId: entry.channelId,
          parentId: typeof entry.parentId === "string" ? entry.parentId : undefined,
          replyToId: typeof entry.replyToId === "string" ? entry.replyToId : undefined,
          body: entry.body,
          attachmentIds: entry.attachmentIds.filter(
            (id): id is Id => typeof id === "string",
          ),
          createdAt: typeof entry.createdAt === "number" ? entry.createdAt : 0,
          attempts: typeof entry.attempts === "number" ? entry.attempts : 0,
          status: entry.status === "failed" ? ("failed" as const) : ("queued" as const),
          error: typeof entry.error === "string" ? entry.error : undefined,
        })),
    },
    lastSyncAt: value.lastSyncAt,
  };
}

function isOutboxMessage(value: unknown): value is OutboxMessage {
  const entry = value as Partial<OutboxMessage> | null;
  return (
    !!entry &&
    typeof entry.id === "string" &&
    typeof entry.channelId === "string" &&
    typeof entry.body === "string" &&
    Array.isArray(entry.attachmentIds)
  );
}

function isCache(value: unknown): value is WorkspaceCache {
  if (!value || typeof value !== "object") return false;
  const cache = value as Partial<WorkspaceCache>;
  return (
    cache.version === 1 &&
    !!cache.bootstrap?.workspace?.id &&
    typeof cache.seq === "number" &&
    !!cache.messages &&
    !!cache.hasMore &&
    !!cache.drafts &&
    Array.isArray(cache.recentChannels)
  );
}

function withBootstrap(
  state: WorkspaceData,
  seq: number,
  bootstrap: Bootstrap,
): WorkspaceData {
  return { ...state, seq, bootstrap: { ...bootstrap, seq } };
}

function withMessage(
  state: WorkspaceData,
  message: Message,
  replaceOnly: boolean,
  seq: number,
): WorkspaceData {
  if (message.parent_id) {
    const thread = state.threads[message.parent_id];
    const alreadyPresent = thread?.some((item) => item.id === message.id) ?? false;
    const list = state.messages[message.channel_id];
    return {
      ...state,
      seq,
      threads: thread
        ? { ...state.threads, [message.parent_id]: upsert(thread, message) }
        : state.threads,
      messages: list
        ? {
            ...state.messages,
            [message.channel_id]: list.map((item) =>
              item.id === message.parent_id
                ? {
                    ...item,
                    reply_count: item.reply_count + (replaceOnly || alreadyPresent ? 0 : 1),
                    last_reply_at: Math.max(item.last_reply_at, message.created_at),
                  }
                : item,
            ),
          }
        : state.messages,
    };
  }
  const list = state.messages[message.channel_id];
  const open = !!list || state.recentChannels.includes(message.channel_id);
  return {
    ...state,
    seq,
    messages: open
      ? {
          ...state.messages,
          [message.channel_id]: upsert(list ?? [], message),
        }
      : state.messages,
  };
}

function removeMessage(
  groups: Record<Id, Message[]>,
  messageId: Id,
): Record<Id, Message[]> {
  let changed = false;
  const next = Object.fromEntries(
    Object.entries(groups).map(([id, messages]) => {
      const filtered = messages.filter((message) => message.id !== messageId);
      if (filtered.length !== messages.length) changed = true;
      return [id, filtered];
    }),
  );
  return changed ? next : groups;
}

function upsert<T extends { id: Id }>(list: T[], item: T): T[] {
  const index = list.findIndex((existing) => existing.id === item.id);
  if (index === -1) return [...list, item];
  const next = list.slice();
  next[index] = item;
  return next;
}
