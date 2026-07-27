// One API wrapper for both transports: same-origin fetch + bearer token on the daemon's legacy
// loopback site, or encrypted RPC over the hosted relay. Views keep the exact same `/v1` contract.

import { isRelayMode, relayRequest } from "./relay.js";

const TOKEN_KEY = "pi-desktop-web-token";

export function getToken() {
  try {
    return localStorage.getItem(TOKEN_KEY) || "";
  } catch {
    return ""; // private browsing / storage disabled: behave as signed out
  }
}

export function setToken(token) {
  try {
    localStorage.setItem(TOKEN_KEY, token);
  } catch {
    // Storage unavailable: the token still works for this page load, it just will not persist.
  }
}

export function clearToken() {
  try {
    localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* nothing to clear */
  }
}

export function hasToken() {
  return getToken().length > 0;
}

/** A well-formed `{"error":{"code","message"}}` response, or a bare non-2xx status. */
export class ApiError extends Error {
  constructor(status, code, message) {
    super(message || `Request failed (${status})`);
    this.status = status;
    this.code = code;
  }
}

/** `fetch` itself failed: offline, DNS, daemon/tunnel down. Distinct from a well-formed error. */
export class NetworkError extends Error {}

/** A short, user-facing message for anything this module can throw. Never includes the token. */
export function describeError(err) {
  if (err instanceof NetworkError) return "Can\u2019t reach your Mac. Check that Pi Desktop is running and online.";
  if (err instanceof ApiError) return err.message;
  return "Something went wrong.";
}

/**
 * Fires `pi:unauthorized` on the window for a 401 so app.js can return to the token screen from
 * one place, regardless of which call triggered it.
 */
async function request(path, options = {}) {
  let status;
  let text;
  if (isRelayMode()) {
    try {
      const response = await relayRequest(options.method || "GET", path, options.body);
      status = response.status;
      text = response.body;
    } catch (err) {
      throw new NetworkError(err instanceof Error ? err.message : "Relay request failed");
    }
  } else {
    const headers = { Authorization: `Bearer ${getToken()}`, ...(options.headers || {}) };
    if (options.body && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
    let response;
    try {
      response = await fetch(path, { ...options, headers });
    } catch (err) {
      throw new NetworkError(err instanceof Error ? err.message : "Network request failed");
    }
    status = response.status;
    text = status === 204 ? "" : await response.text();
  }

  if (status === 401) {
    if (!isRelayMode()) window.dispatchEvent(new CustomEvent("pi:unauthorized"));
    throw new ApiError(401, "unauthorized", "Sign in again.");
  }
  if (status < 200 || status >= 300) {
    let code = "error";
    let message = `Request failed (${status})`;
    try {
      const body = JSON.parse(text);
      if (body && body.error) {
        code = body.error.code || code;
        message = body.error.message || message;
      }
    } catch {
      /* body was not JSON; keep the generic message */
    }
    throw new ApiError(status, code, message);
  }
  return text ? JSON.parse(text) : null;
}

function toQuery(params) {
  const usp = new URLSearchParams();
  for (const [key, value] of Object.entries(params || {})) {
    if (value !== undefined && value !== null && value !== "") usp.set(key, value);
  }
  const qs = usp.toString();
  return qs ? `?${qs}` : "";
}

function post(path, body) {
  return request(path, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) });
}

// One method per documented endpoint (docs/daemon-api.md "Endpoints (v1)"). Thread and schedule
// URLs always use `id` (never the JSONL `path`, which can contain slashes) — the API accepts
// either, and `id` keeps client-side routing a single path segment.
export const api = {
  health: () => request("/v1/health"),

  threads: (params) => request(`/v1/threads${toQuery(params)}`),
  thread: (id, messages) => request(`/v1/threads/${encodeURIComponent(id)}${toQuery({ messages })}`),
  createThread: (body) => post("/v1/threads", body),
  sendMessage: (id, body) => post(`/v1/threads/${encodeURIComponent(id)}/messages`, body),
  abortThread: (id) => post(`/v1/threads/${encodeURIComponent(id)}/abort`),
  archiveThread: (id, archived) => post(`/v1/threads/${encodeURIComponent(id)}/archive`, { archived }),
  renameThread: (id, name) => post(`/v1/threads/${encodeURIComponent(id)}/name`, { name }),
  markThreadRead: (id, unread) => post(`/v1/threads/${encodeURIComponent(id)}/read`, { unread }),
  // Metadata only travels in the thread detail; each image is fetched separately so one
  // screenshot-heavy transcript cannot exceed the relay's per-payload ceiling.
  threadImage: (id, imageId) =>
    request(`/v1/threads/${encodeURIComponent(id)}/images/${encodeURIComponent(imageId)}`),

  // Read-only projection of the Mac app's own folder tree; never written from here.
  folders: () => request("/v1/folders"),

  // The authoritative list of dialogs a daemon run is blocked on. The `interaction` SSE event is
  // only a hint that something changed — this is what a reconnecting client rehydrates from.
  interactions: (threadId) => request(`/v1/interactions${toQuery({ threadId })}`),
  respondInteraction: (id, body) => post(`/v1/interactions/${encodeURIComponent(id)}/respond`, body),

  activity: () => request("/v1/activity"),

  schedules: () => request("/v1/schedules"),
  schedule: (id) => request(`/v1/schedules/${encodeURIComponent(id)}`),
  createSchedule: (body) => post("/v1/schedules", body),
  updateSchedule: (id, patch) => request(`/v1/schedules/${encodeURIComponent(id)}`, { method: "PATCH", body: JSON.stringify(patch) }),
  deleteSchedule: (id) => request(`/v1/schedules/${encodeURIComponent(id)}`, { method: "DELETE" }),
  runScheduleNow: (id) => post(`/v1/schedules/${encodeURIComponent(id)}/run`),
  pauseSchedule: (id, paused) => post(`/v1/schedules/${encodeURIComponent(id)}/pause`, { paused }),

  limits: () => request("/v1/limits")
};
