export const MAX_FRAME_BYTES = 2 * 1024 * 1024;
export const MAX_SOCKETS = 32;
export const MAX_DEVICES = 32;

const base64urlPattern = /^[A-Za-z0-9_-]+$/;
const idPattern = /^[A-Za-z0-9_-]{32}$/;
const encoder = new TextEncoder();

export type PublicJwk = {
  kty: "EC";
  crv: "P-256";
  x: string;
  y: string;
  ext: true;
};

export type CipherPayload = { nonce: string; data: string };

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isInstallationID(value: unknown): value is string {
  return typeof value === "string" && idPattern.test(value);
}

export function isDeviceID(value: unknown): value is string {
  return isInstallationID(value);
}

export function isConnectionID(value: unknown): value is string {
  return typeof value === "string" && decodeBase64url(value, 16) !== null;
}

export function isRequestID(value: unknown): value is string {
  return typeof value === "string" && value.length >= 1 && value.length <= 128 && !/[\u0000-\u001f\u007f]/.test(value);
}

export function isName(value: unknown): value is string {
  return typeof value === "string" && value === value.trim() && Array.from(value).length >= 1 && Array.from(value).length <= 64 && encoder.encode(value).byteLength <= 256 && !/[\u0000-\u001f\u007f]/.test(value);
}

export function decodeBase64url(value: string, expectedBytes?: number): Uint8Array | null {
  if (!value || !base64urlPattern.test(value) || value.length % 4 === 1) return null;
  try {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    if (expectedBytes !== undefined && bytes.byteLength !== expectedBytes) return null;
    return encodeBase64url(bytes) === value ? bytes : null;
  } catch {
    return null;
  }
}

export function encodeBase64url(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function isToken(value: unknown): value is string {
  return typeof value === "string" && decodeBase64url(value, 32) !== null;
}

export function isSignature(value: unknown): value is string {
  return typeof value === "string" && decodeBase64url(value, 64) !== null;
}

export function publicJwk(value: unknown): PublicJwk | null {
  if (!isRecord(value)) return null;
  const allowed = new Set(["kty", "crv", "x", "y", "ext", "key_ops"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) return null;
  if (value.kty !== "EC" || value.crv !== "P-256" || typeof value.x !== "string" || typeof value.y !== "string") return null;
  if (value.ext !== undefined && value.ext !== true) return null;
  if (value.key_ops !== undefined && (!Array.isArray(value.key_ops) || (value.key_ops.length !== 0 && (value.key_ops.length !== 1 || value.key_ops[0] !== "verify")))) return null;
  if (!decodeBase64url(value.x, 32) || !decodeBase64url(value.y, 32)) return null;
  return { kty: "EC", crv: "P-256", x: value.x, y: value.y, ext: true };
}

export function cipherPayload(value: unknown): CipherPayload | null {
  if (!isRecord(value) || Object.keys(value).length !== 2 || typeof value.nonce !== "string" || typeof value.data !== "string") return null;
  if (!decodeBase64url(value.nonce, 12) || !decodeBase64url(value.data)) return null;
  return { nonce: value.nonce, data: value.data };
}

export function challengeData(installationID: string, deviceID: string, nonce: string): Uint8Array {
  return encoder.encode(`pi-remote-v1:${installationID}:${deviceID}:${nonce}`);
}

export function hostPresenceMessage(online: boolean): { type: "hostOnline" | "hostOffline" } {
  return { type: online ? "hostOnline" : "hostOffline" };
}

export function broadcastHostPresence<T>(sockets: Iterable<T>, online: boolean, send: (socket: T, message: { type: "hostOnline" | "hostOffline" }) => void): void {
  const message = hostPresenceMessage(online);
  for (const socket of sockets) send(socket, message);
}

export function frameByteLength(message: unknown): number {
  return encoder.encode(JSON.stringify(message)).byteLength;
}

export async function sha256Base64url(value: string): Promise<string> {
  return encodeBase64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

export function equalFixed(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  return difference === 0;
}

export function randomBase64url(bytes: number): string {
  return encodeBase64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

export function verificationCode(): string {
  const limit = 0x1_0000_0000 - (0x1_0000_0000 % 1_000_000);
  const value = new Uint32Array(1);
  do crypto.getRandomValues(value); while (value[0] >= limit);
  return value[0].toString().padStart(6, "0");
}

export function relayRoute(pathname: string): { role: "host" | "device"; installationID: string } | null {
  const match = /^\/relay\/(host|device)\/([A-Za-z0-9_-]{32})$/.exec(pathname);
  return match ? { role: match[1] as "host" | "device", installationID: match[2] } : null;
}
