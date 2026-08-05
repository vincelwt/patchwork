// Which workspaces this desktop belongs to, and which one is on screen.
//
// Joining, creating and switching all end in the same place: the settings on
// disk and the live connections agreeing with each other. Switching is only a
// change of what is drawn — every workspace stays connected, so agents keep
// working in the one you just left.

import { useSyncExternalStore } from "react";
import {
  createWorkspace,
  desktopBoot,
  inTauri,
  joinWorkspace,
  leaveWorkspace,
  signOut,
  switchWorkspace,
  useThisDeviceAsRelay,
  workspaceBaseUrl,
} from "./desktop";
import type { DesktopSettings } from "./desktop";
import { store } from "./store";

let settings: DesktopSettings | undefined;
const listeners = new Set<() => void>();

function publish(next: DesktopSettings) {
  settings = next;
  store.connect(
    next.workspaces.map((workspace) => ({
      id: workspace.id,
      name: workspace.name,
      base_url: workspaceBaseUrl(workspace),
      token: workspace.token,
    })),
    next.active,
  );
  listeners.forEach((listener) => listener());
}

export function useSettings(): DesktopSettings | undefined {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => settings,
  );
}

export async function boot() {
  const info = await desktopBoot();
  publish(info.settings);
  return info;
}

export async function join(input: {
  relay_url: string;
  invite_code: string;
  display_name: string;
}) {
  publish(await joinWorkspace(input));
}

export async function create(name: string) {
  publish(await createWorkspace(name));
}

/// Start a relay inside this app and join the workspace it holds.
export async function hostRelayHere(input: {
  workspace_name: string;
  display_name: string;
}) {
  publish(await useThisDeviceAsRelay(input));
}

/// Only the desktop app can serve a relay; a browser tab cannot.
export const canHostRelay = inTauri;

export async function leave(id: string) {
  publish(await leaveWorkspace(id));
}

/// Instant on screen, persisted after: the connection it switches to is
/// already up, so there is nothing to wait for.
export async function switchTo(id: string) {
  store.setActive(id);
  publish(await switchWorkspace(id));
}

export async function signOutOfEverything() {
  await signOut();
  store.disconnect();
  publish({
    workspaces: [],
    active: "",
    host_id: "",
    host_name: "",
    project_paths: {},
    awake: "never",
  });
}
