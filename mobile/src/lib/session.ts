import { useEffect, useSyncExternalStore } from "react";
import * as SecureStore from "expo-secure-store";
import { Api } from "@client/api";

const KEY = "patchwork.session";

export interface PairedSession {
  /// One workspace's own base, `{relay}/w/{workspace_id}`.
  baseUrl: string;
  /// A separately revocable token issued to this device.
  token: string;
}

type Snapshot = PairedSession | null | undefined;
let snapshot: Snapshot;
let loading: Promise<void> | undefined;
let secureOperations: Promise<void> = Promise.resolve();
const listeners = new Set<() => void>();

function publish(next: Snapshot) {
  snapshot = next;
  listeners.forEach((listener) => listener());
}

function validSession(value: unknown): PairedSession | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<PairedSession>;
  if (typeof candidate.baseUrl !== "string" || typeof candidate.token !== "string") {
    return null;
  }
  const token = candidate.token.trim();
  try {
    const url = new URL(candidate.baseUrl);
    if (url.protocol !== "https:" && !__DEV__) return null;
    if (!token) return null;
    return { baseUrl: url.toString().replace(/\/$/, ""), token };
  } catch {
    return null;
  }
}

function serialize<T>(operation: () => Promise<T>): Promise<T> {
  const task = secureOperations.then(operation);
  secureOperations = task.then(() => undefined, () => undefined);
  return task;
}

async function hydrate() {
  if (loading) return loading;
  loading = serialize(async () => {
    try {
      const raw = await SecureStore.getItemAsync(KEY);
      publish(raw ? validSession(JSON.parse(raw)) : null);
    } catch {
      publish(null);
    }
  });
  return loading;
}

export async function savePairedSession(input: PairedSession): Promise<void> {
  const session = validSession(input);
  if (!session) throw new Error("That pairing response is not valid.");
  await serialize(async () => {
    await SecureStore.setItemAsync(KEY, JSON.stringify(session), {
      keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
    });
    publish(session);
  });
}

export async function loadPairedSession(): Promise<PairedSession | null> {
  await hydrate();
  return snapshot ?? null;
}

export function clearPairedSession(expected?: PairedSession): Promise<boolean> {
  return serialize(async () => {
    if (expected && !sameSession(snapshot, expected)) return false;
    await SecureStore.deleteItemAsync(KEY);
    publish(null);
    return true;
  });
}

export function apiFor(session: PairedSession): Api {
  return new Api(session.baseUrl, session.token);
}

function sameSession(a: Snapshot, b: PairedSession) {
  return a?.baseUrl === b.baseUrl && a?.token === b.token;
}

export function usePairedSession() {
  useEffect(() => {
    void hydrate();
  }, []);
  const session = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => snapshot,
    () => undefined,
  );
  return {
    session,
    pair: savePairedSession,
    signOut: clearPairedSession,
  };
}
