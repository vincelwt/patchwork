// The Tauri side of the app: settings that survive a restart, and this
// machine's execution host. In a plain browser (vite dev without Tauri) these
// degrade to localStorage so the UI is still workable.

import type { HostCapabilities } from "./types";

export type AwakePolicy = "never" | "while_running" | "while_open";

export interface DesktopSettings {
  relay_url: string;
  token: string;
  member_id: string;
  member_name: string;
  host_id: string;
  host_name: string;
  project_paths: Record<string, string>;
  awake: AwakePolicy;
}

export interface HostStatus {
  connected: boolean;
  host_id: string;
  host_name: string;
  last_error?: string;
}

export interface DesktopInfo {
  settings: DesktopSettings;
  host: HostStatus;
  platform: string;
  capabilities: HostCapabilities;
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
    relay_url: parsed.relay_url ?? "",
    token: parsed.token ?? "",
    member_id: parsed.member_id ?? "",
    member_name: parsed.member_name ?? "",
    host_id: parsed.host_id ?? "",
    host_name: parsed.host_name ?? "",
    project_paths: parsed.project_paths ?? {},
    awake: parsed.awake ?? "never",
  };
}

/// Settings and host status only, for the paths that cannot afford to wait.
export async function desktopBoot(): Promise<DesktopBoot> {
  if (inTauri) return invoke<DesktopBoot>("desktop_boot");
  return {
    settings: browserSettings(),
    host: { connected: false, host_id: "", host_name: "" },
    platform: "browser",
  };
}

export async function desktopInfo(): Promise<DesktopInfo> {
  if (inTauri) return invoke<DesktopInfo>("desktop_info");
  return {
    settings: browserSettings(),
    host: { connected: false, host_id: "", host_name: "" },
    platform: "browser",
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

export async function joinWorkspace(input: {
  relay_url: string;
  invite_code: string;
  display_name: string;
}): Promise<DesktopSettings> {
  if (inTauri) return invoke<DesktopSettings>("join_workspace", { input });

  const base = input.relay_url.trim().replace(/\/$/, "");
  const response = await fetch(`${base}/api/auth/join`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      invite_code: input.invite_code.trim(),
      display_name: input.display_name.trim(),
    }),
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
  const auth = JSON.parse(text);
  const settings: DesktopSettings = {
    relay_url: base,
    token: auth.token,
    member_id: auth.member.id,
    member_name: auth.member.display_name,
    host_id: "",
    host_name: "",
    project_paths: {},
    awake: "never",
  };
  localStorage.setItem(BROWSER_KEY, JSON.stringify(settings));
  return settings;
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
  const settings = { ...browserSettings(), project_paths: paths };
  localStorage.setItem(BROWSER_KEY, JSON.stringify(settings));
  return settings;
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
