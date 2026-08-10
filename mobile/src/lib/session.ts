import { useEffect, useSyncExternalStore } from "react";
import * as SecureStore from "expo-secure-store";
import { Api } from "@client/api";

import {
  activate,
  decodePaired,
  encodePaired,
  NO_WORKSPACES,
  validSession,
  withName,
  withoutSession,
  withSession,
  type Paired,
  type PairedSession,
} from "@/lib/paired";

export type { PairedSession } from "@/lib/paired";

const KEY = "patchwork.session";

type Snapshot = Paired | undefined;
let snapshot: Snapshot;
let loading: Promise<void> | undefined;
let secureOperations: Promise<void> = Promise.resolve();
const listeners = new Set<() => void>();

function publish(next: Paired) {
  snapshot = next;
  listeners.forEach((listener) => listener());
}

function serialize<T>(operation: () => Promise<T>): Promise<T> {
  const task = secureOperations.then(operation);
  secureOperations = task.then(() => undefined, () => undefined);
  return task;
}

async function write(paired: Paired) {
  if (paired.all.length) {
    await SecureStore.setItemAsync(KEY, encodePaired(paired), {
      keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
    });
  } else {
    await SecureStore.deleteItemAsync(KEY);
  }
  publish(paired);
}

async function hydrate() {
  if (loading) return loading;
  loading = serialize(async () => {
    try {
      publish(decodePaired(await SecureStore.getItemAsync(KEY), __DEV__));
    } catch {
      publish(NO_WORKSPACES);
    }
  });
  return loading;
}

export async function savePairedSession(input: PairedSession): Promise<void> {
  const session = validSession(input, __DEV__);
  if (!session) throw new Error("That pairing response is not valid.");
  await serialize(async () => {
    await write(withSession(snapshot ?? NO_WORKSPACES, session));
  });
}

export async function switchWorkspace(baseUrl: string): Promise<void> {
  await serialize(async () => {
    const current = snapshot ?? NO_WORKSPACES;
    if (current.active?.baseUrl === baseUrl) return;
    const next = activate(current, baseUrl);
    if (next !== current) await write(next);
  });
}

/// Keep the switcher readable by remembering the name the workspace reports.
export function noteWorkspaceName(baseUrl: string, name: string): void {
  const current = snapshot;
  if (!current || withName(current, baseUrl, name) === current) return;
  void serialize(async () => {
    const next = withName(snapshot ?? NO_WORKSPACES, baseUrl, name);
    if (next !== (snapshot ?? NO_WORKSPACES)) await write(next);
  }).catch(() => undefined);
}

export async function loadPairedSession(): Promise<PairedSession | null> {
  await hydrate();
  return snapshot?.active ?? null;
}

/// Removes one workspace's key. Signing out of one leaves the others paired.
export function clearPairedSession(expected?: PairedSession): Promise<boolean> {
  return serialize(async () => {
    const current = snapshot ?? NO_WORKSPACES;
    const target = expected
      ? current.all.find((item) => item.baseUrl === expected.baseUrl && item.token === expected.token)
      : current.active;
    if (!target) return false;
    await write(withoutSession(current, target));
    return true;
  });
}

export function apiFor(session: PairedSession): Api {
  return new Api(session.baseUrl, session.token);
}

export function usePairedSession() {
  useEffect(() => {
    void hydrate();
  }, []);
  const paired = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => snapshot,
    () => undefined,
  );
  return {
    /// `undefined` until the keychain has been read, then the workspace on screen.
    session: paired === undefined ? undefined : paired.active,
    workspaces: paired?.all ?? [],
    pair: savePairedSession,
    signOut: clearPairedSession,
    switchTo: switchWorkspace,
  };
}
