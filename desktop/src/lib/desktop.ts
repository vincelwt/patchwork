// The Tauri side of the app: settings that survive a restart, and this
// machine's execution host. In a plain browser (vite dev without Tauri) these
// degrade to localStorage so the UI is still workable.

import type { HostCapabilities } from "./types";

export type AwakePolicy = "never" | "while_running" | "while_open";

/// One joined workspace. Several can be live at once, on one relay or on
/// several.
export interface WorkspaceSettings {
  id: string;
  name: string;
  /// The relay root, without the workspace prefix.
  relay_url: string;
  token: string;
  member_id: string;
  member_name: string;
}

export interface DesktopSettings {
  workspaces: WorkspaceSettings[];
  /// Which workspace the window is showing.
  active: string;
  host_id: string;
  host_name: string;
  project_paths: Record<string, string>;
  awake: AwakePolicy;
}

/// Everything a workspace is reached through hangs off here.
export function workspaceBaseUrl(workspace: WorkspaceSettings) {
  return `${workspace.relay_url.replace(/\/$/, "")}/w/${workspace.id}`;
}

export interface HostStatus {
  connected: boolean;
  host_id: string;
  host_name: string;
  last_error?: string;
  workspaces_online?: number;
  workspaces?: number;
}

export interface DesktopInfo {
  settings: DesktopSettings;
  host: HostStatus;
  platform: string;
  capabilities: HostCapabilities;
  /// This machine is the relay, and is serving right now.
  hosting_relay: boolean;
}

/// What the first frame needs. Deliberately without `capabilities`: working out
/// which agent runtimes exist costs a subprocess each plus a round trip to
/// GitHub, and the window should not be waiting on any of it.
export type DesktopBoot = Omit<DesktopInfo, "capabilities">;

const BROWSER_KEY = "patchwork.settings";

export const inTauri = "__TAURI_INTERNALS__" in window;

// Started at module load rather than at the first call: the very first thing
// the app does is invoke a command, and fetching this chunk only then puts a
// module round trip in front of it.
const core = inTauri ? import("@tauri-apps/api/core") : undefined;

async function invoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  const { invoke } = await (core ?? import("@tauri-apps/api/core"));
  return invoke<T>(command, args);
}

function browserSettings(): DesktopSettings {
  const raw = localStorage.getItem(BROWSER_KEY);
  const parsed = raw ? (JSON.parse(raw) as Partial<DesktopSettings>) : {};
  return {
    workspaces: parsed.workspaces ?? [],
    active: parsed.active ?? "",
    host_id: parsed.host_id ?? "",
    host_name: parsed.host_name ?? "",
    project_paths: parsed.project_paths ?? {},
    awake: parsed.awake ?? "never",
  };
}

function saveBrowserSettings(settings: DesktopSettings): DesktopSettings {
  localStorage.setItem(BROWSER_KEY, JSON.stringify(settings));
  return settings;
}

/// Settings and host status only, for the paths that cannot afford to wait.
export async function desktopBoot(): Promise<DesktopBoot> {
  if (inTauri) return invoke<DesktopBoot>("desktop_boot");
  return {
    settings: browserSettings(),
    host: { connected: false, host_id: "", host_name: "" },
    platform: "browser",
    hosting_relay: false,
  };
}

/// Use this machine as the relay: the app serves one itself, so a solo user
/// never has to run a server. Only the desktop app can do this.
export async function useThisDeviceAsRelay(input: {
  workspace_name: string;
  display_name: string;
}): Promise<DesktopSettings> {
  if (!inTauri) {
    throw new Error("hosting a relay needs the Patchwork Desktop app");
  }
  // Wrapped in `input`, like every other command here: Tauri renames loose
  // arguments to camelCase, and a struct's fields keep the names serde gives
  // them.
  return invoke<DesktopSettings>("use_this_device_as_relay", { input });
}

export async function desktopInfo(): Promise<DesktopInfo> {
  if (inTauri) return invoke<DesktopInfo>("desktop_info");
  return {
    settings: browserSettings(),
    host: { connected: false, host_id: "", host_name: "" },
    platform: "browser",
    hosting_relay: false,
    capabilities: {
      runtimes: [],
      has_git: false,
      has_gh: false,
      gh_authenticated: false,
      has_node: false,
      browser_automation: false,
      home_dir: "",
      machine_key: "",
      notes: ["local agent execution needs the Patchwork Desktop app"],
    },
  };
}

async function postAuth(
  url: string,
  token: string | undefined,
  body: unknown,
): Promise<{ token: string; member: { id: string; display_name: string }; workspace: { id: string; name: string } }> {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) {
    let message = text;
    try {
      message = JSON.parse(text)?.error?.message ?? text;
    } catch {
      // keep the raw body
    }
    throw new Error(message);
  }
  return JSON.parse(text);
}

function remember(
  settings: DesktopSettings,
  relayUrl: string,
  auth: { token: string; member: { id: string; display_name: string }; workspace: { id: string; name: string } },
): DesktopSettings {
  const workspace: WorkspaceSettings = {
    id: auth.workspace.id,
    name: auth.workspace.name,
    relay_url: relayUrl,
    token: auth.token,
    member_id: auth.member.id,
    member_name: auth.member.display_name,
  };
  const workspaces = settings.workspaces.filter((w) => w.id !== workspace.id);
  workspaces.push(workspace);
  return saveBrowserSettings({ ...settings, workspaces, active: workspace.id });
}

/// Redeem an invite. Workspaces already joined keep running.
export async function joinWorkspace(input: {
  relay_url: string;
  invite_code: string;
  display_name: string;
}): Promise<DesktopSettings> {
  if (inTauri) return invoke<DesktopSettings>("join_workspace", { input });

  const base = input.relay_url.trim().replace(/\/$/, "");
  const auth = await postAuth(`${base}/api/auth/join`, undefined, {
    invite_code: input.invite_code.trim(),
    display_name: input.display_name.trim(),
  });
  return remember(browserSettings(), base, auth);
}

/// A second workspace on the relay this desktop is already in.
export async function createWorkspace(name: string): Promise<DesktopSettings> {
  if (inTauri) return invoke<DesktopSettings>("create_workspace", { name });

  const settings = browserSettings();
  const active =
    settings.workspaces.find((w) => w.id === settings.active) ??
    settings.workspaces[0];
  if (!active) throw new Error("join a workspace first");
  const auth = await postAuth(
    `${active.relay_url}/api/workspaces`,
    active.token,
    { name: name.trim() },
  );
  return remember(settings, active.relay_url, auth);
}

/// Only which workspace is on screen: nothing disconnects.
export async function switchWorkspace(id: string): Promise<DesktopSettings> {
  if (inTauri) return invoke<DesktopSettings>("switch_workspace", { id });
  return saveBrowserSettings({ ...browserSettings(), active: id });
}

export async function leaveWorkspace(id: string): Promise<DesktopSettings> {
  if (inTauri) return invoke<DesktopSettings>("leave_workspace", { id });
  const settings = browserSettings();
  const workspaces = settings.workspaces.filter((w) => w.id !== id);
  return saveBrowserSettings({
    ...settings,
    workspaces,
    active: settings.active === id ? (workspaces[0]?.id ?? "") : settings.active,
  });
}

export async function signOut(): Promise<void> {
  if (inTauri) {
    await invoke("sign_out");
    return;
  }
  localStorage.removeItem(BROWSER_KEY);
}

export async function setProjectPaths(
  paths: Record<string, string>,
): Promise<DesktopSettings> {
  if (inTauri) return invoke<DesktopSettings>("set_project_paths", { paths });
  return saveBrowserSettings({ ...browserSettings(), project_paths: paths });
}

/// Stopping this machine from sleeping mid-run. A no-op outside the app,
/// because a browser tab has no business holding a power assertion.
export async function setAwakePolicy(policy: AwakePolicy): Promise<DesktopSettings> {
  if (inTauri) return invoke<DesktopSettings>("set_awake_policy", { policy });
  return { ...browserSettings(), awake: policy };
}

export async function reconnectHost(): Promise<HostStatus> {
  if (inTauri) return invoke<HostStatus>("reconnect_host");
  return { connected: false, host_id: "", host_name: "" };
}

export async function pickDirectory(): Promise<string | null> {
  if (!inTauri) return window.prompt("Absolute path to the project folder") ?? null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const chosen = await open({ directory: true, multiple: false });
  return typeof chosen === "string" ? chosen : null;
}

export async function openExternal(url: string) {
  if (!inTauri) {
    window.open(url, "_blank");
    return;
  }
  const { openUrl } = await import("@tauri-apps/plugin-opener");
  await openUrl(url);
}
