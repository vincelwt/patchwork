export const MAX_BODY_BYTES = 20 * 1024 * 1024;
export const MAX_CONNECTIONS = 32;
export const REQUEST_TIMEOUT_MS = 60_000;
export const SOCKET_TIMEOUT_MS = 10_000;

const idPattern = /^[a-f0-9]{32}$/;
const tokenPattern = /^[A-Za-z0-9_-]{43}$/;

export type Route =
  | { role: "host"; relayId: string }
  | { role: "client"; relayId: string; localPath: string; preview?: boolean };

export type ProxyResponse = {
  type: "response";
  id: string;
  status: number;
  headers: [string, string][];
  body: string;
};

export type SocketReady = {
  type: "socket_ready";
  id: string;
  ok: boolean;
  status?: number;
  error?: string;
};

export type HostFrame =
  | ProxyResponse
  | SocketReady
  | { type: "socket_data"; id: string; data: string; binary?: boolean }
  | { type: "socket_close"; id: string; code?: number; reason?: string };

export function route(pathname: string, hostname = ""): Route | null {
  const preview = /^p-([0-9a-z]{1,25})-([0-9a-z]{1,25})\./.exec(hostname);
  if (preview) {
    const relayId = expandId(preview[1]);
    const previewId = expandId(preview[2]);
    if (!relayId || !previewId) return null;
    return {
      role: "client",
      relayId,
      localPath: `/preview/${uuid(previewId)}${pathname}`,
      preview: true,
    };
  }
  const host = /^\/connect\/([a-f0-9]{32})\/?$/.exec(pathname);
  if (host) return { role: "host", relayId: host[1] };
  const client = /^\/r\/([a-f0-9]{32})(\/.*)?$/.exec(pathname);
  if (!client) return null;
  return {
    role: "client",
    relayId: client[1],
    localPath: client[2] || "/",
  };
}

function expandId(value: string): string | null {
  let number = 0n;
  for (const character of value) {
    const digit = parseInt(character, 36);
    if (!Number.isInteger(digit) || digit < 0 || digit >= 36) return null;
    number = number * 36n + BigInt(digit);
  }
  const hex = number.toString(16);
  return hex.length <= 32 ? hex.padStart(32, "0") : null;
}

function uuid(hex: string): string {
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function compactId(value: string): string {
  const hex = value.replaceAll("-", "");
  if (!/^[a-f0-9]{32}$/.test(hex)) throw new Error("invalid id");
  return BigInt(`0x${hex}`).toString(36);
}

export function isRelayId(value: unknown): value is string {
  return typeof value === "string" && idPattern.test(value);
}

export function isHostToken(value: unknown): value is string {
  return typeof value === "string" && tokenPattern.test(value);
}

export function isRequestId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{22}$/.test(value);
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseHostFrame(value: unknown): HostFrame | null {
  if (!isRecord(value) || !isRequestId(value.id) || typeof value.type !== "string") return null;
  if (value.type === "response") {
    if (!Number.isInteger(value.status) || (value.status as number) < 100 || (value.status as number) > 599) return null;
    if (!headerPairs(value.headers) || typeof value.body !== "string" || value.body.length > Math.ceil(MAX_BODY_BYTES * 4 / 3) + 4) return null;
    return value as ProxyResponse;
  }
  if (value.type === "socket_ready") {
    if (typeof value.ok !== "boolean") return null;
    if (value.status !== undefined && !Number.isInteger(value.status)) return null;
    if (value.error !== undefined && typeof value.error !== "string") return null;
    return value as SocketReady;
  }
  if (value.type === "socket_data") {
    const limit = value.binary ? Math.ceil(MAX_BODY_BYTES * 4 / 3) + 4 : MAX_BODY_BYTES;
    return typeof value.data === "string" && value.data.length <= limit &&
      (value.binary === undefined || typeof value.binary === "boolean")
      ? value as HostFrame
      : null;
  }
  if (value.type === "socket_close") {
    if (value.code !== undefined && !Number.isInteger(value.code)) return null;
    if (value.reason !== undefined && typeof value.reason !== "string") return null;
    return value as HostFrame;
  }
  return null;
}

export function headerPairs(value: unknown): value is [string, string][] {
  return Array.isArray(value) && value.length <= 64 && value.every((pair) =>
    Array.isArray(pair) && pair.length === 2 &&
    typeof pair[0] === "string" && pair[0].length <= 128 &&
    typeof pair[1] === "string" && pair[1].length <= 8192
  );
}

export function proxyHeaders(headers: Headers): [string, string][] {
  const blocked = new Set([
    "connection", "content-length", "host", "keep-alive", "proxy-authenticate",
    "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
    "cf-connecting-ip", "cf-ipcountry", "cf-ray", "cf-visitor", "x-forwarded-for",
    "x-forwarded-host", "x-forwarded-proto",
  ]);
  return [...headers].filter(([name]) => {
    const lower = name.toLowerCase();
    return !blocked.has(lower) &&
      (lower === "sec-websocket-protocol" || !lower.startsWith("sec-websocket-"));
  });
}

export function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

export function decodeBase64(value: string): Uint8Array | null {
  try {
    const binary = atob(value);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    return bytes.byteLength <= MAX_BODY_BYTES ? bytes : null;
  } catch {
    return null;
  }
}

export function randomId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return base64url(bytes);
}

export async function tokenHash(token: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))));
}

export function equalFixed(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let different = 0;
  for (let index = 0; index < a.length; index++) different |= a.charCodeAt(index) ^ b.charCodeAt(index);
  return different === 0;
}

function base64url(bytes: Uint8Array): string {
  return encodeBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
