import AsyncStorage from "@react-native-async-storage/async-storage";
import NetInfo, { type NetInfoState } from "@react-native-community/netinfo";
import * as Crypto from "expo-crypto";
import { Image } from "expo-image";
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import { Alert, AppState } from "react-native";

import { Api, ApiError } from "@client/api";
import {
  applyBootstrap,
  applyEnvelope,
  emptyWorkspaceData,
  fromCache,
  toCache,
  touchChannel,
  type WorkspaceData,
} from "@client/mobile-store-reducer";
import { REALTIME_HEARTBEAT, REALTIME_HEARTBEAT_MS } from "@client/types";
import type { Envelope, Id, Message, RunDetail } from "@client/types";
import {
  apiFor,
  clearPairedSession,
  type PairedSession,
} from "@/lib/session";
import { isWorkspaceCacheKey, workspaceCacheKey } from "@/lib/workspace-cache";

export type ConnectionState = "connecting" | "live" | "offline" | "error";

export interface WorkspaceSnapshot extends WorkspaceData {
  connection: ConnectionState;
  error?: string;
  lastSyncAt?: number;
}

export class OfflineError extends Error {
  constructor() {
    super("Patchwork is offline. This change was not sent.");
    this.name = "OfflineError";
  }
}

type Listener = () => void;
const MAX_CACHE_CHARS = 2_000_000;
const EMPTY: WorkspaceSnapshot = {
  ...emptyWorkspaceData(),
  connection: "offline",
};

export class MobileWorkspaceStore {
  private snapshot: WorkspaceSnapshot = EMPTY;
  private listeners = new Set<Listener>();
  private api?: Api;
  private cacheKey?: string;
  private socket?: WebSocket;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private heartbeatTimer?: ReturnType<typeof setInterval>;
  private cacheTimer?: ReturnType<typeof setTimeout>;
  private cacheWrite: Promise<void> = Promise.resolve();
  private localCleanup: Promise<void> = Promise.resolve();
  private retryDelay = 1_000;
  private generation = 0;
  private attempt = 0;
  private hydrated = false;
  private active = AppState.currentState === "active";
  private reachable = false;
  private connecting?: Promise<void>;
  private notifying = false;

  subscribe = (listener: Listener) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;
  getServerSnapshot = () => EMPTY;

  async setSession(session: PairedSession | null | undefined): Promise<void> {
    const generation = ++this.generation;
    this.stopConnection();
    this.clearCacheTimer();
    this.api = session ? apiFor(session) : undefined;
    this.cacheKey = undefined;
    this.hydrated = false;
    this.replace({
      ...emptyWorkspaceData(),
      connection: session && this.active && this.reachable ? "connecting" : "offline",
    });
    if (session === undefined) return;
    if (!session) {
      await Promise.all([
        this.pruneWorkspaceCaches(undefined, generation),
        this.clearImageCaches(),
      ]).catch(() => undefined);
      return;
    }

    const tokenDigest = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      session.token,
    );
    if (generation !== this.generation) return;
    const cacheKey = workspaceCacheKey(session.baseUrl, tokenDigest);
    this.cacheKey = cacheKey;
    await Promise.all([
      this.pruneWorkspaceCaches(cacheKey, generation),
      this.clearImageCaches(),
    ]).catch(() => undefined);
    if (generation !== this.generation) return;

    try {
      const raw = await AsyncStorage.getItem(cacheKey);
      if (generation !== this.generation) return;
      if (raw && raw.length <= MAX_CACHE_CHARS) {
        const restored = fromCache(JSON.parse(raw));
        if (restored) {
          this.replace({
            ...restored.data,
            connection: this.active && this.reachable ? "connecting" : "offline",
            lastSyncAt: restored.lastSyncAt,
          });
        }
      } else if (raw) {
        await AsyncStorage.removeItem(cacheKey);
      }
    } catch {
      // A corrupt or unavailable cache is expendable; the relay is authoritative.
    }
    if (generation !== this.generation) return;
    this.hydrated = true;
    void this.connectNow();
  }

  setActive(active: boolean) {
    if (this.active === active) return;
    this.active = active;
    if (!active) {
      this.stopConnection();
      this.patch({ connection: "offline" });
      void this.persistNow();
    } else if (this.reachable) {
      this.retryDelay = 1_000;
      void this.connectNow();
    }
  }

  setNetwork(state: NetInfoState) {
    const reachable =
      state.isConnected === true && state.isInternetReachable !== false;
    if (this.reachable === reachable) return;
    this.reachable = reachable;
    if (!reachable) {
      this.stopConnection();
      this.patch({ connection: "offline" });
    } else if (this.active) {
      this.retryDelay = 1_000;
      void this.connectNow();
    }
  }

  dispose() {
    ++this.generation;
    this.stopConnection();
    this.clearCacheTimer();
    this.listeners.clear();
  }

  async clearLocalData(expected?: PairedSession): Promise<void> {
    if (
      expected &&
      (this.api?.baseUrl !== expected.baseUrl || this.api.token !== expected.token)
    ) return;
    ++this.generation;
    const cacheKey = this.cacheKey;
    this.stopConnection();
    this.clearCacheTimer();
    this.api = undefined;
    this.cacheKey = undefined;
    this.hydrated = false;
    this.replace({ ...emptyWorkspaceData(), connection: "offline" });
    const cleanup = this.localCleanup
      .catch(() => undefined)
      .then(async () => {
        await this.cacheWrite;
        await Promise.all([
          cacheKey ? AsyncStorage.removeItem(cacheKey) : Promise.resolve(),
          this.clearImageCaches(),
        ]);
      });
    this.localCleanup = cleanup;
    await cleanup;
  }

  async refresh(): Promise<void> {
    if (!this.canConnect()) {
      this.patch({ connection: "offline" });
      return;
    }
    await this.connectNow(true);
  }

  async loadMessages(channelId: Id, before?: Id): Promise<void> {
    const current = touchChannel(this.snapshot, channelId);
    this.replaceData(current);
    this.scheduleCache();
    if (!this.canConnect() || !this.api) return;

    await this.request(
      () => this.api!.messages(channelId, before),
      (page) => {
        const existing = this.snapshot.messages[channelId] ?? [];
        this.replaceData({
          ...this.snapshot,
          messages: {
            ...this.snapshot.messages,
            [channelId]: before
              ? mergeMessages(page.messages, existing)
              : page.messages,
          },
          hasMore: { ...this.snapshot.hasMore, [channelId]: page.has_more },
        });
        this.scheduleCache();
      },
    );
  }

  async loadThread(messageId: Id): Promise<void> {
    if (!this.canConnect() || !this.api) return;
    await this.request(
      () => this.api!.thread(messageId),
      (replies) => this.replaceData({
        ...this.snapshot,
        threads: { ...this.snapshot.threads, [messageId]: replies },
      }),
    );
  }

  async loadRun(runId: Id): Promise<void> {
    if (!this.canConnect() || !this.api) return;
    await this.request(
      () => this.api!.run(runId),
      (detail) => this.setRunDetail(detail),
    );
  }

  setDraft(channelId: Id, draft: string) {
    const drafts = { ...this.snapshot.drafts };
    if (draft) drafts[channelId] = draft;
    else delete drafts[channelId];
    this.replaceData({ ...this.snapshot, drafts });
    this.scheduleCache();
  }

  sendTyping(channelId: Id) {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    this.socket.send(JSON.stringify({ t: "typing", channel_id: channelId }));
  }

  async mutate<T>(
    operation: (api: Api) => Promise<T>,
    refresh = true,
    apply?: (result: T) => void,
  ): Promise<void> {
    if (!this.canConnect() || !this.api) throw new OfflineError();
    const generation = this.generation;
    const api = this.api;
    const result = await this.request(() => operation(api));
    if (refresh) await this.refresh();
    if (generation !== this.generation || api !== this.api) {
      throw new Error("The workspace session changed.");
    }
    apply?.(result);
  }

  private async connectNow(force = false): Promise<void> {
    if (!this.hydrated || !this.canConnect() || !this.api) return;
    if (this.connecting) return this.connecting;
    if (force) this.stopConnection();
    if (this.socket?.readyState === WebSocket.OPEN && !force) return;

    const generation = this.generation;
    const attempt = ++this.attempt;
    const api = this.api;
    this.clearReconnect();
    this.patch({ connection: "connecting", error: undefined });

    const task = (async () => {
      try {
        await this.request(
          () => api.bootstrap(),
          (bootstrap) => {
            if (this.isCurrent(generation, attempt)) {
              this.replaceData(applyBootstrap(this.snapshot, bootstrap));
            }
          },
        );
        if (!this.isCurrent(generation, attempt)) return;

        // Bootstrap does not contain messages. Refresh the bounded recent set so
        // events covered by bootstrap.seq cannot leave restored channel caches stale.
        await Promise.allSettled(
          this.snapshot.recentChannels.map(async (channelId) => {
            await this.request(
              () => api.messages(channelId),
              (page) => {
                if (!this.isCurrent(generation, attempt)) return;
                this.replaceData({
                  ...this.snapshot,
                  messages: {
                    ...this.snapshot.messages,
                    [channelId]: page.messages,
                  },
                  hasMore: {
                    ...this.snapshot.hasMore,
                    [channelId]: page.has_more,
                  },
                });
              },
            );
          }),
        );
        if (!this.isCurrent(generation, attempt)) return;

        // Start realtime from the boundary returned by bootstrap. The relay
        // replays mutations that happened while the snapshot and recent
        // message pages were loading, without an ambiguous startup window.
        this.openSocket(generation, attempt, api);
        this.replace({
          ...this.snapshot,
          lastSyncAt: Date.now(),
          error: undefined,
          connection:
            this.socket?.readyState === WebSocket.OPEN ? "live" : "connecting",
        });
        this.retryDelay = 1_000;
        this.scheduleCache();
      } catch (error) {
        if (!this.isCurrent(generation, attempt) || !this.api) return;
        this.closeSocket();
        this.patch({
          connection: this.reachable ? "error" : "offline",
          error: messageOf(error),
        });
        this.scheduleReconnect();
      }
    })().finally(() => {
      if (!this.isCurrent(generation, attempt)) return;
      this.connecting = undefined;
      if (!this.socket && this.canConnect()) this.scheduleReconnect();
    });
    this.connecting = task;
    return task;
  }

  private openSocket(generation: number, attempt: number, api: Api) {
    this.closeSocket();
    const url = new URL(
      `${api.baseUrl.replace(/^http/, "ws").replace(/\/$/, "")}/ws`,
    );
    url.searchParams.set("token", api.token);
    url.searchParams.set("since", String(this.snapshot.seq));
    url.searchParams.set("heartbeat", "1");
    url.searchParams.set("connection", "mobile");
    const socket = new WebSocket(url.toString());
    this.socket = socket;

    socket.onopen = () => {
      if (!this.isCurrent(generation, attempt) || socket !== this.socket) return;
      this.stopHeartbeat();
      this.heartbeatTimer = setInterval(() => {
        if (socket.readyState === WebSocket.OPEN) socket.send(REALTIME_HEARTBEAT);
      }, REALTIME_HEARTBEAT_MS);
      this.retryDelay = 1_000;
      this.patch({ connection: "live", error: undefined });
    };
    socket.onmessage = ({ data }) => {
      if (!this.isCurrent(generation, attempt) || socket !== this.socket) return;
      try {
        const payload = JSON.parse(String(data)) as {
          t?: string;
          envelope?: Envelope;
        };
        if (payload.t !== "event" || !payload.envelope) return;
        const next = applyEnvelope(this.snapshot, payload.envelope);
        if (next !== this.snapshot) {
          this.replaceData(next);
          this.patch({ lastSyncAt: Date.now() });
          this.scheduleCache();
        }
      } catch {
        socket.close();
      }
    };
    socket.onerror = () => socket.close();
    socket.onclose = () => {
      if (!this.isCurrent(generation, attempt) || socket !== this.socket) return;
      this.stopHeartbeat();
      this.socket = undefined;
      if (!this.canConnect()) {
        this.patch({ connection: "offline" });
        return;
      }
      this.patch({ connection: "connecting" });
      this.scheduleReconnect();
    };
  }

  private scheduleReconnect() {
    if (!this.canConnect() || this.reconnectTimer || !this.api) return;
    const ceiling = Math.min(this.retryDelay, 15_000);
    const delay = Math.min(15_000, ceiling * (0.5 + Math.random()));
    this.retryDelay = Math.min(this.retryDelay * 2, 15_000);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.connectNow();
    }, delay);
  }

  private async request<T>(
    operation: () => Promise<T>,
    apply?: (result: T) => void,
  ): Promise<T> {
    const generation = this.generation;
    const api = this.api;
    try {
      const result = await operation();
      if (generation !== this.generation || api !== this.api) {
        throw new Error("The workspace session changed.");
      }
      apply?.(result);
      return result;
    } catch (error) {
      if (generation !== this.generation || api !== this.api) throw error;
      if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
        await this.invalidateSession(error);
      }
      throw error;
    }
  }

  private async invalidateSession(error: ApiError) {
    const expected = this.api
      ? { baseUrl: this.api.baseUrl, token: this.api.token }
      : undefined;
    let cleanupError = "";
    try {
      await this.clearLocalData(expected);
    } catch (caught) {
      cleanupError = ` Local data could not be fully removed: ${messageOf(caught)}`;
    }
    let removed = false;
    try {
      removed = await clearPairedSession(expected);
    } catch (caught) {
      cleanupError += ` The device credential could not be removed: ${messageOf(caught)}`;
    }
    if (!removed) {
      if (cleanupError) Alert.alert("Previous session cleanup incomplete", cleanupError.trim());
      return;
    }
    if (expected && this.api) return;
    if (cleanupError) {
      Alert.alert("Local data removal incomplete", cleanupError.trim());
    }
    this.replace({
      ...emptyWorkspaceData(),
      connection: "error",
      error: `${
        error.status === 401
          ? "This phone is no longer paired with that workspace."
          : "This phone no longer has access to that workspace."
      }${cleanupError}`,
    });
  }

  private setRunDetail(detail: RunDetail) {
    this.replaceData({
      ...this.snapshot,
      runDetails: { ...this.snapshot.runDetails, [detail.run.id]: detail },
    });
  }

  private canConnect() {
    return !!this.api && this.active && this.reachable;
  }

  private isCurrent(generation: number, attempt: number) {
    return generation === this.generation && attempt === this.attempt;
  }

  private stopConnection() {
    ++this.attempt;
    this.connecting = undefined;
    this.clearReconnect();
    this.closeSocket();
  }

  private closeSocket() {
    this.stopHeartbeat();
    const socket = this.socket;
    if (!socket) return;
    this.socket = undefined;
    socket.onopen = null;
    socket.onmessage = null;
    socket.onerror = null;
    socket.onclose = null;
    socket.close();
  }

  private stopHeartbeat() {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = undefined;
  }

  private clearReconnect() {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
  }

  private scheduleCache() {
    this.clearCacheTimer();
    this.cacheTimer = setTimeout(() => {
      this.cacheTimer = undefined;
      void this.persistNow();
    }, 500);
  }

  private clearCacheTimer() {
    if (this.cacheTimer) clearTimeout(this.cacheTimer);
    this.cacheTimer = undefined;
  }

  private async persistNow() {
    const cacheKey = this.cacheKey;
    if (!cacheKey) return;
    const cache = toCache(this.snapshot, this.snapshot.lastSyncAt);
    if (!cache) return;
    const raw = JSON.stringify(cache);
    if (raw.length > MAX_CACHE_CHARS) return;
    this.cacheWrite = this.cacheWrite
      .then(() => AsyncStorage.setItem(cacheKey, raw))
      .catch(() => undefined);
    await this.cacheWrite;
  }

  private async pruneWorkspaceCaches(keep: string | undefined, generation: number) {
    await this.cacheWrite;
    const stale = (await AsyncStorage.getAllKeys()).filter(
      (key) => isWorkspaceCacheKey(key) && key !== keep,
    );
    if (generation === this.generation && stale.length) {
      await AsyncStorage.multiRemove(stale);
    }
  }

  private async clearImageCaches() {
    const [memory, disk] = await Promise.all([
      Image.clearMemoryCache(),
      Image.clearDiskCache(),
    ]);
    if (!memory || !disk) throw new Error("Cached images could not be removed.");
  }

  private replaceData(data: WorkspaceData) {
    this.replace({
      ...this.snapshot,
      ...data,
      connection: this.snapshot.connection,
      error: this.snapshot.error,
      lastSyncAt: this.snapshot.lastSyncAt,
    });
  }

  private patch(patch: Partial<WorkspaceSnapshot>) {
    this.replace({ ...this.snapshot, ...patch });
  }

  private replace(snapshot: WorkspaceSnapshot) {
    this.snapshot = snapshot;
    if (this.notifying) return;
    this.notifying = true;
    queueMicrotask(() => {
      this.notifying = false;
      this.listeners.forEach((listener) => listener());
    });
  }
}

const WorkspaceContext = createContext<MobileWorkspaceStore | null>(null);

export function WorkspaceProvider({
  session,
  children,
}: {
  session: PairedSession | null | undefined;
  children: ReactNode;
}) {
  const store = useMemo(() => new MobileWorkspaceStore(), []);

  useEffect(() => {
    void store.setSession(session);
  }, [session, store]);

  useEffect(() => {
    store.setActive(AppState.currentState === "active");
    const appState = AppState.addEventListener("change", (next) => {
      store.setActive(next === "active");
    });
    const network = NetInfo.addEventListener((state) => store.setNetwork(state));
    void NetInfo.fetch().then((state) => store.setNetwork(state));
    return () => {
      appState.remove();
      network();
      store.dispose();
    };
  }, [store]);

  return (
    <WorkspaceContext.Provider value={store}>
      {children}
    </WorkspaceContext.Provider>
  );
}

export function useWorkspace(): WorkspaceSnapshot {
  const store = useWorkspaceStore();
  return useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
    store.getServerSnapshot,
  );
}

export function useWorkspaceStore(): MobileWorkspaceStore {
  const store = useContext(WorkspaceContext);
  if (!store) throw new Error("useWorkspaceStore requires WorkspaceProvider");
  return store;
}

function mergeMessages(older: Message[], newer: Message[]): Message[] {
  const byId = new Map(newer.map((message) => [message.id, message]));
  for (const message of older) byId.set(message.id, message);
  return [...byId.values()].sort((a, b) => a.created_at - b.created_at);
}

function messageOf(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
