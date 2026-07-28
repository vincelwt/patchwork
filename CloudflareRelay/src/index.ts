import { freshMutableAsset } from "./assets";
import {
  MAX_DEVICES,
  MAX_FRAME_BYTES,
  MAX_SOCKETS,
  broadcastHostPresence,
  challengeData,
  cipherPayload,
  decodeBase64url,
  equalFixed,
  frameByteLength,
  isConnectionID,
  isDeviceID,
  isName,
  isRecord,
  isRequestID,
  isSignature,
  isToken,
  p256PublicKey,
  publicJwk,
  randomBase64url,
  relayRoute,
  sha256Base64url,
  type PublicJwk,
} from "./protocol";

interface Env {
  RELAY: DurableObjectNamespace;
  ASSETS: Fetcher;
  CONNECTION_RATE_LIMITER: RateLimit;
  ENROLLMENT_RATE_LIMITER: RateLimit;
  FRAME_RATE_LIMITER: RateLimit;
}

type Device = {
  id: string;
  name: string;
  authPublicKey: PublicJwk;
  ecdhPublicKey: string;
  pairedAt: number;
  lastSeenAt: number;
};

type PendingPairing = {
  pairingId: string;
  deviceId: string;
  name: string;
  requestedAt: number;
  expiresAt: number;
  authPublicKey: PublicJwk;
  ecdhPublicKey: string;
  proof: string;
  hostPublicKey: string;
};

type SocketAttachment =
  | { role: "host"; connectionId: string; clientIP: string }
  | {
      role: "device";
      connectionId: string;
      clientIP: string;
      nonce: string;
      issuedAt: number;
      authenticated: boolean;
      deviceId?: string;
      pairing?: PendingPairing;
    };

type DeviceRow = {
  id: string;
  name: string;
  auth_public_key: string;
  ecdh_public_key: string;
  paired_at: number;
  last_seen_at: number;
};

type OfferRow = { ticket_hash: string; expires_at: number; host_public_key: string };
type PairingDecisionRow = { approved: number };
type ExpiryRow = { expires_at: number | null };

const PROTOCOL_VERSION = "2";
const response = (status: number, body: string) => new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
const onlyKeys = (value: Record<string, unknown>, keys: string[]) => Object.keys(value).every((key) => keys.includes(key)) && keys.every((key) => key in value);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = relayRoute(url.pathname);

    if (!route) {
      if (url.pathname.startsWith("/relay/")) return response(404, "Not found");
      return env.ASSETS ? freshMutableAsset(request, env.ASSETS) : response(404, "Not found");
    }
    if (request.method !== "GET") return response(400, "WebSocket relay requires GET");
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return response(426, "WebSocket upgrade required");
    if (url.searchParams.get("v") !== PROTOCOL_VERSION) return response(426, "Relay protocol upgrade required");
    const clientIP = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.CONNECTION_RATE_LIMITER.limit({ key: clientIP })).success) return response(429, "Relay connection rate exceeded");
    if (route.role === "host") {
      const match = /^Bearer ([A-Za-z0-9_-]+)$/i.exec(request.headers.get("Authorization") ?? "");
      if (!match || !isToken(match[1])) return response(401, "Invalid bearer token");
    }

    const id = env.RELAY.idFromName(route.installationID);
    return env.RELAY.get(id).fetch(request);
  },
};

export class Relay {
  private readonly sql: SqlStorage;

  constructor(private readonly state: DurableObjectState, private readonly env: Env) {
    this.sql = state.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS pair_offer (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        ticket_hash TEXT NOT NULL,
        expires_at INTEGER NOT NULL,
        host_public_key TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        auth_public_key TEXT NOT NULL,
        ecdh_public_key TEXT NOT NULL,
        paired_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS pairing_decisions (
        id TEXT PRIMARY KEY,
        approved INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      );
    `);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const route = relayRoute(url.pathname);
    if (!route) return response(404, "Not found");
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return response(426, "WebSocket upgrade required");
    if (url.searchParams.get("v") !== PROTOCOL_VERSION) return response(426, "Relay protocol upgrade required");
    if (!this.ensureInstallationID(route.installationID)) return response(400, "Installation mismatch");
    if (route.role === "device" && this.config("protocol_version") !== PROTOCOL_VERSION) return response(409, "Host protocol upgrade required");

    const clientIP = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const sockets = this.state.getWebSockets();
    const oldHosts = route.role === "host" ? this.hostSockets() : [];
    const unauthenticated = this.deviceSockets()
      .filter((socket) => {
        const attachment = this.attachment(socket);
        return attachment?.role === "device" && !attachment.authenticated;
      })
      .sort((left, right) => {
        const a = this.attachment(left);
        const b = this.attachment(right);
        return (a?.role === "device" ? a.issuedAt : 0) - (b?.role === "device" ? b.issuedAt : 0);
      });
    if (route.role === "device" && (sockets.length >= MAX_SOCKETS || unauthenticated.length >= 4)) {
      const oldest = unauthenticated[0];
      if (oldest) this.close(oldest, 1013, "Replaced by a newer pairing connection");
      else return response(429, "Too many relay connections");
    }
    if (route.role === "host" && sockets.length - oldHosts.length >= MAX_SOCKETS) {
      const candidate = unauthenticated[0] ?? this.deviceSockets()[0];
      if (candidate) this.close(candidate, 1013, "Host connection has priority");
      else return response(429, "Too many relay connections");
    }

    if (route.role === "host") {
      const match = /^Bearer ([A-Za-z0-9_-]+)$/i.exec(request.headers.get("Authorization") ?? "");
      if (!match || !isToken(match[1])) return response(401, "Invalid bearer token");
      const tokenHash = await sha256Base64url(match[1]);
      const storedHash = this.config("host_token_hash");
      if (storedHash !== null && !equalFixed(storedHash, tokenHash)) return response(401, "Invalid bearer token");
      if (storedHash === null) {
        if (!(await this.env.ENROLLMENT_RATE_LIMITER.limit({ key: clientIP })).success) return response(429, "Installation enrollment rate exceeded");
        this.setConfig("host_token_hash", tokenHash);
      }
      if (this.config("protocol_version") !== PROTOCOL_VERSION) {
        this.sql.exec("DELETE FROM pair_offer; DELETE FROM devices; DELETE FROM pairing_decisions;");
        this.setConfig("protocol_version", PROTOCOL_VERSION);
        for (const deviceSocket of this.deviceSockets()) {
          this.send(deviceSocket, { type: "revoked" });
          this.close(deviceSocket, 1008, "Relay protocol upgraded");
        }
      }
      for (const socket of oldHosts) socket.close(1000, "Replaced by a newer host connection");
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const connectionId = randomBase64url(16);

    if (route.role === "host") {
      const attachment: SocketAttachment = { role: "host", connectionId, clientIP };
      server.serializeAttachment(attachment);
      this.state.acceptWebSocket(server, ["host", `connection:${connectionId}`]);
      this.send(server, { type: "hostReady", devices: this.devices() });
      const connectedDevices = this.authenticatedDeviceSockets();
      broadcastHostPresence(connectedDevices, true, (socket, message) => this.send(socket, message));
      for (const socket of connectedDevices) {
        const deviceAttachment = this.attachment(socket);
        if (deviceAttachment?.role !== "device" || !deviceAttachment.deviceId) continue;
        const device = this.device(deviceAttachment.deviceId);
        if (device) this.send(server, { type: "deviceConnected", device, connectionId: deviceAttachment.connectionId });
      }
    } else {
      const nonce = randomBase64url(32);
      const attachment: SocketAttachment = { role: "device", connectionId, clientIP, nonce, issuedAt: Date.now(), authenticated: false };
      server.serializeAttachment(attachment);
      this.state.acceptWebSocket(server, ["device", `connection:${connectionId}`]);
      this.send(server, { type: "challenge", nonce, hostOnline: this.hostOnline() });
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, frame: string | ArrayBuffer): Promise<void> {
    const attachment = this.attachment(socket);
    if (!attachment) {
      this.close(socket, 1011, "Missing socket state");
      return;
    }
    if (!(await this.env.FRAME_RATE_LIMITER.limit({ key: attachment.clientIP })).success) {
      this.close(socket, 1013, "Relay frame rate exceeded");
      return;
    }
    if (typeof frame !== "string") {
      this.close(socket, frame.byteLength > MAX_FRAME_BYTES ? 1009 : 1003, "Text frames only");
      return;
    }
    if (new TextEncoder().encode(frame).byteLength > MAX_FRAME_BYTES) {
      this.close(socket, 1009, "Frame too large");
      return;
    }

    let message: unknown;
    try {
      message = JSON.parse(frame);
    } catch {
      this.close(socket, 1007, "Invalid JSON");
      return;
    }
    if (!isRecord(message) || typeof message.type !== "string") {
      this.close(socket, 1008, "Invalid message");
      return;
    }

    if (attachment.role === "host") {
      if (this.currentHost() !== socket) return this.invalid(socket);
      await this.handleHost(socket, message);
    } else {
      await this.handleDevice(socket, attachment, message);
    }
  }

  webSocketClose(socket: WebSocket): void {
    this.socketEnded(socket);
  }

  webSocketError(socket: WebSocket): void {
    this.socketEnded(socket);
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    this.sql.exec("DELETE FROM pairing_decisions WHERE expires_at <= ?", now);
    let nextExpiry = this.sql.exec<ExpiryRow>("SELECT MIN(expires_at) AS expires_at FROM pairing_decisions").toArray()[0]?.expires_at ?? null;
    const host = this.currentHost();
    for (const socket of this.deviceSockets()) {
      const attachment = this.attachment(socket);
      if (attachment?.role !== "device" || !attachment.pairing) continue;
      if (attachment.pairing.expiresAt <= now) {
        this.send(socket, { type: "pairRejected", reason: "expiredTicket" });
        this.close(socket, 1008, "Pairing expired");
        if (host) this.send(host, { type: "pairExpired", pairingId: attachment.pairing.pairingId });
      } else {
        nextExpiry = nextExpiry === null ? attachment.pairing.expiresAt : Math.min(nextExpiry, attachment.pairing.expiresAt);
      }
    }
    if (nextExpiry !== null) await this.state.storage.setAlarm(nextExpiry);
  }

  private async handleHost(socket: WebSocket, message: Record<string, unknown>): Promise<void> {
    switch (message.type) {
      case "pairOffer": {
        if (!onlyKeys(message, ["type", "id", "ticketHash", "expiresAt", "hostPublicKey"]) || !isRequestID(message.id) || !isToken(message.ticketHash) || !Number.isSafeInteger(message.expiresAt) || (message.expiresAt as number) <= Date.now()) return this.invalid(socket);
        const hostPublicKey = p256PublicKey(message.hostPublicKey);
        if (!hostPublicKey) return this.invalid(socket);
        this.sql.exec(
          "INSERT OR REPLACE INTO pair_offer (singleton, ticket_hash, expires_at, host_public_key) VALUES (1, ?, ?, ?)",
          message.ticketHash,
          message.expiresAt as number,
          hostPublicKey,
        );
        this.send(socket, { type: "ack", id: message.id, ok: true });
        return;
      }
      case "pairDecision": {
        if (!onlyKeys(message, ["type", "id", "pairingId", "approved"]) || !isRequestID(message.id) || !isConnectionID(message.pairingId) || typeof message.approved !== "boolean") return this.invalid(socket);
        this.sql.exec("DELETE FROM pairing_decisions WHERE expires_at <= ?", Date.now());
        const pendingSocket = this.deviceSockets().find((candidate) => {
          const candidateAttachment = this.attachment(candidate);
          return candidateAttachment?.role === "device" && candidateAttachment.pairing?.pairingId === message.pairingId;
        });
        const pendingAttachment = pendingSocket && this.attachment(pendingSocket);
        const pairing = pendingAttachment?.role === "device" ? pendingAttachment.pairing : undefined;
        if (!pendingSocket || !pendingAttachment || pendingAttachment.role !== "device" || !pairing) {
          const prior = this.sql.exec<PairingDecisionRow>("SELECT approved FROM pairing_decisions WHERE id = ?", message.pairingId).toArray()[0];
          if (prior && Boolean(prior.approved) === message.approved) this.send(socket, { type: "ack", id: message.id, ok: true });
          else this.send(socket, { type: "ack", id: message.id, ok: false, error: "pairingNotFound" });
          return;
        }
        if (pairing.expiresAt <= Date.now()) {
          this.send(pendingSocket, { type: "pairRejected", reason: "expiredTicket" });
          this.close(pendingSocket, 1008, "Pairing expired");
          this.send(socket, { type: "ack", id: message.id, ok: false, error: "pairingExpired" });
          return;
        }
        if (!message.approved) {
          const decisionExpiry = Date.now() + 600_000;
          this.sql.exec("INSERT OR REPLACE INTO pairing_decisions (id, approved, expires_at) VALUES (?, 0, ?)", message.pairingId, decisionExpiry);
          await this.schedulePairingAlarm(decisionExpiry);
          this.send(pendingSocket, { type: "pairRejected", reason: "denied" });
          this.close(pendingSocket, 1008, "Pairing denied");
          this.send(socket, { type: "ack", id: message.id, ok: true });
          return;
        }
        if (this.device(pairing.deviceId) || this.deviceCount() >= MAX_DEVICES) {
          this.send(pendingSocket, { type: "pairRejected", reason: "deviceLimit" });
          this.close(pendingSocket, 1008, "Device cannot be paired");
          this.send(socket, { type: "ack", id: message.id, ok: false, error: "deviceLimit" });
          return;
        }
        const now = Date.now();
        this.sql.exec(
          "INSERT INTO devices (id, name, auth_public_key, ecdh_public_key, paired_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)",
          pairing.deviceId,
          pairing.name,
          JSON.stringify(pairing.authPublicKey),
          pairing.ecdhPublicKey,
          now,
          now,
        );
        for (const existing of this.socketsForDevice(pairing.deviceId)) this.close(existing, 1000, "Replaced by a newer device connection");
        pendingSocket.serializeAttachment({
          role: "device",
          connectionId: pendingAttachment.connectionId,
          clientIP: pendingAttachment.clientIP,
          nonce: pendingAttachment.nonce,
          issuedAt: pendingAttachment.issuedAt,
          authenticated: true,
          deviceId: pairing.deviceId,
        } satisfies SocketAttachment);
        const decisionExpiry = now + 600_000;
        this.sql.exec("INSERT OR REPLACE INTO pairing_decisions (id, approved, expires_at) VALUES (?, 1, ?)", message.pairingId, decisionExpiry);
        await this.schedulePairingAlarm(decisionExpiry);
        const pairedDevice = this.device(pairing.deviceId);
        this.send(socket, { type: "ack", id: message.id, ok: true });
        if (pairedDevice) this.send(socket, { type: "deviceConnected", device: pairedDevice, connectionId: pendingAttachment.connectionId });
        this.send(pendingSocket, { type: "paired", deviceId: pairing.deviceId, hostPublicKey: pairing.hostPublicKey });
        this.send(pendingSocket, { type: "ready", hostOnline: true });
        this.send(socket, { type: "devicesSnapshot", devices: this.devices() });
        return;
      }
      case "devicesList": {
        if (!onlyKeys(message, ["type", "id"]) || !isRequestID(message.id)) return this.invalid(socket);
        this.send(socket, { type: "ack", id: message.id, ok: true, devices: this.devices() });
        return;
      }
      case "revokeDevice": {
        if (!onlyKeys(message, ["type", "id", "deviceId"]) || !isRequestID(message.id) || !isDeviceID(message.deviceId)) return this.invalid(socket);
        this.sql.exec("DELETE FROM devices WHERE id = ?", message.deviceId);
        for (const deviceSocket of this.socketsForDevice(message.deviceId)) this.send(deviceSocket, { type: "revoked" });
        for (const deviceSocket of this.socketsForDevice(message.deviceId)) this.close(deviceSocket, 1008, "Device revoked");
        this.send(socket, { type: "ack", id: message.id, ok: true });
        this.send(socket, { type: "devicesSnapshot", devices: this.devices() });
        return;
      }
      case "toDevice": {
        const allowed = message.connectionId === undefined ? ["type", "deviceId", "payload"] : ["type", "deviceId", "connectionId", "payload"];
        if (!onlyKeys(message, allowed) || !isDeviceID(message.deviceId) || (message.connectionId !== undefined && !isConnectionID(message.connectionId))) return this.invalid(socket);
        const payload = cipherPayload(message.payload);
        if (!payload) return this.invalid(socket);
        const targets = this.socketsForDevice(message.deviceId).filter((candidate) => !message.connectionId || this.attachment(candidate)?.connectionId === message.connectionId);
        for (const target of targets) this.send(target, { type: "cipher", payload });
        return;
      }
      default:
        return this.invalid(socket);
    }
  }

  private async handleDevice(socket: WebSocket, attachment: Extract<SocketAttachment, { role: "device" }>, message: Record<string, unknown>): Promise<void> {
    if (!attachment.authenticated && !attachment.pairing && Date.now() - attachment.issuedAt > 60_000) {
      return this.close(socket, 1008, "Authentication challenge expired");
    }
    if (attachment.authenticated) {
      if (!onlyKeys(message, ["type", "payload"]) || message.type !== "cipher") return this.invalid(socket);
      const payload = cipherPayload(message.payload);
      if (!payload || !attachment.deviceId) return this.invalid(socket);
      const host = this.currentHost();
      if (!host) {
        this.send(socket, { type: "hostOffline" });
        return;
      }
      const device = this.device(attachment.deviceId);
      if (!device) return this.invalid(socket);
      const forwarded = {
        type: "fromDevice",
        deviceId: attachment.deviceId,
        connectionId: attachment.connectionId,
        ecdhPublicKey: device.ecdhPublicKey,
        payload,
      };
      if (frameByteLength(forwarded) > MAX_FRAME_BYTES) return this.invalid(socket);
      this.send(host, forwarded);
      return;
    }

    if (attachment.pairing) return this.invalid(socket);
    if (message.type === "pair") {
      if (!onlyKeys(message, ["type", "ticketHash", "proof", "deviceId", "name", "authPublicKey", "ecdhPublicKey"]) || !isToken(message.ticketHash) || !isToken(message.proof) || !isDeviceID(message.deviceId) || !isName(message.name)) return this.invalid(socket);
      const authPublicKey = publicJwk(message.authPublicKey);
      const ecdhPublicKey = p256PublicKey(message.ecdhPublicKey);
      if (!authPublicKey || !ecdhPublicKey) return this.invalid(socket);
      const host = this.currentHost();
      if (!host) return this.rejectAndClose(socket, "hostOffline", "Host is offline");
      if (this.device(message.deviceId) || this.deviceCount() >= MAX_DEVICES) return this.rejectAndClose(socket, "deviceLimit", "Device cannot be paired");
      const offer = this.sql.exec<OfferRow>("SELECT ticket_hash, expires_at, host_public_key FROM pair_offer WHERE singleton = 1").toArray()[0];
      if (!offer) return this.rejectAndClose(socket, "invalidTicket", "No active pairing offer");
      if (offer.expires_at <= Date.now()) {
        this.sql.exec("DELETE FROM pair_offer WHERE singleton = 1");
        return this.rejectAndClose(socket, "expiredTicket", "Pairing offer expired");
      }
      if (!equalFixed(message.ticketHash, offer.ticket_hash)) return this.rejectAndClose(socket, "invalidTicket", "Invalid pairing ticket");
      this.sql.exec("DELETE FROM pair_offer WHERE singleton = 1");

      const pairing: PendingPairing = {
        pairingId: randomBase64url(16),
        deviceId: message.deviceId,
        name: message.name,
        requestedAt: Date.now(),
        expiresAt: offer.expires_at,
        authPublicKey,
        ecdhPublicKey,
        proof: message.proof,
        hostPublicKey: offer.host_public_key,
      };
      socket.serializeAttachment({ ...attachment, pairing });
      this.send(host, { type: "pairRequest", pairing: {
        id: pairing.pairingId,
        deviceId: pairing.deviceId,
        name: pairing.name,
        requestedAt: pairing.requestedAt,
        expiresAt: pairing.expiresAt,
        authPublicKey: pairing.authPublicKey,
        ecdhPublicKey: pairing.ecdhPublicKey,
        proof: pairing.proof,
      } });
      this.send(socket, { type: "pairPending", pairingId: pairing.pairingId, expiresAt: pairing.expiresAt });
      await this.schedulePairingAlarm(pairing.expiresAt);
      return;
    }

    if (message.type === "authenticate") {
      if (!onlyKeys(message, ["type", "deviceId", "signature"]) || !isDeviceID(message.deviceId) || !isSignature(message.signature)) return this.invalid(socket);
      const device = this.device(message.deviceId);
      if (!device) {
        this.send(socket, { type: "revoked" });
        return this.close(socket, 1008, "Device revoked");
      }
      let verified = false;
      try {
        const key = await crypto.subtle.importKey("jwk", device.authPublicKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
        verified = await crypto.subtle.verify(
          { name: "ECDSA", hash: "SHA-256" },
          key,
          decodeBase64url(message.signature, 64)!,
          challengeData(this.installationID(), message.deviceId, attachment.nonce),
        );
      } catch {
        verified = false;
      }
      const currentDevice = this.device(message.deviceId);
      if (!verified || !currentDevice || JSON.stringify(currentDevice.authPublicKey) !== JSON.stringify(device.authPublicKey)) {
        this.send(socket, { type: "authRejected" });
        return this.close(socket, 1008, "Authentication failed");
      }
      const now = Date.now();
      this.sql.exec("UPDATE devices SET last_seen_at = ? WHERE id = ?", now, message.deviceId);
      for (const existing of this.socketsForDevice(message.deviceId)) this.close(existing, 1000, "Replaced by a newer device connection");
      socket.serializeAttachment({ ...attachment, authenticated: true, deviceId: message.deviceId } satisfies SocketAttachment);
      const host = this.currentHost();
      this.send(socket, { type: "ready", hostOnline: host !== null });
      if (host) this.send(host, { type: "deviceConnected", device: { ...currentDevice, lastSeenAt: now }, connectionId: attachment.connectionId });
      return;
    }

    this.invalid(socket);
  }

  private socketEnded(socket: WebSocket): void {
    const attachment = this.attachment(socket);
    if (attachment?.role === "host" && !this.hostOnline()) {
      broadcastHostPresence(this.authenticatedDeviceSockets(), false, (deviceSocket, message) => this.send(deviceSocket, message));
    } else if (attachment?.role === "device" && attachment.authenticated && attachment.deviceId) {
      const stillConnected = this.socketsForDevice(attachment.deviceId).some((candidate) => candidate !== socket);
      const host = this.currentHost();
      if (!stillConnected && host) this.send(host, { type: "deviceDisconnected", deviceId: attachment.deviceId, connectionId: attachment.connectionId });
    } else if (attachment?.role === "device" && attachment.pairing) {
      const host = this.currentHost();
      if (host) this.send(host, { type: "pairExpired", pairingId: attachment.pairing.pairingId });
    }
  }

  private async schedulePairingAlarm(expiresAt: number): Promise<void> {
    const current = await this.state.storage.getAlarm();
    if (current === null || expiresAt < current) await this.state.storage.setAlarm(expiresAt);
  }

  private ensureInstallationID(installationID: string): boolean {
    const stored = this.config("installation_id");
    if (stored !== null) return stored === installationID;
    this.setConfig("installation_id", installationID);
    return true;
  }

  private installationID(): string {
    const value = this.config("installation_id");
    if (!value) throw new Error("Installation ID is unavailable");
    return value;
  }

  private config(key: string): string | null {
    return this.sql.exec<{ value: string }>("SELECT value FROM config WHERE key = ?", key).toArray()[0]?.value ?? null;
  }

  private setConfig(key: string, value: string): void {
    this.sql.exec("INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)", key, value);
  }

  private deviceCount(): number {
    return this.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM devices").toArray()[0]?.count ?? 0;
  }

  private device(id: string): Device | null {
    const row = this.sql.exec<DeviceRow>("SELECT * FROM devices WHERE id = ?", id).toArray()[0];
    return row ? this.rowToDevice(row) : null;
  }

  private devices(): Device[] {
    return this.sql.exec<DeviceRow>("SELECT * FROM devices ORDER BY paired_at, id").toArray().map((row) => this.rowToDevice(row));
  }

  private rowToDevice(row: DeviceRow): Device {
    return {
      id: row.id,
      name: row.name,
      authPublicKey: JSON.parse(row.auth_public_key) as PublicJwk,
      ecdhPublicKey: row.ecdh_public_key,
      pairedAt: row.paired_at,
      lastSeenAt: row.last_seen_at,
    };
  }

  private attachment(socket: WebSocket): SocketAttachment | null {
    const value = socket.deserializeAttachment();
    return isRecord(value) && (value.role === "host" || value.role === "device") ? value as SocketAttachment : null;
  }

  private hostSockets(): WebSocket[] {
    return this.state.getWebSockets("host").filter((socket) => socket.readyState === WebSocket.OPEN);
  }

  private deviceSockets(): WebSocket[] {
    return this.state.getWebSockets("device").filter((socket) => socket.readyState === WebSocket.OPEN);
  }

  private authenticatedDeviceSockets(): WebSocket[] {
    return this.deviceSockets().filter((socket) => {
      const attachment = this.attachment(socket);
      return attachment?.role === "device" && attachment.authenticated;
    });
  }

  private socketsForDevice(deviceId: string): WebSocket[] {
    return this.authenticatedDeviceSockets().filter((socket) => {
      const attachment = this.attachment(socket);
      return attachment?.role === "device" && attachment.deviceId === deviceId;
    });
  }

  private currentHost(): WebSocket | null {
    return this.hostSockets()[0] ?? null;
  }

  private hostOnline(): boolean {
    return this.currentHost() !== null;
  }

  private send(socket: WebSocket, message: unknown): void {
    if (socket.readyState !== WebSocket.OPEN) return;
    try {
      if (frameByteLength(message) > MAX_FRAME_BYTES) return this.close(socket, 1009, "Frame too large");
      socket.send(JSON.stringify(message));
    } catch {
      this.close(socket, 1011, "Send failed");
    }
  }

  private rejectAndClose(socket: WebSocket, reason: string, closeReason: string): void {
    this.send(socket, { type: "pairRejected", reason });
    this.close(socket, 1008, closeReason);
  }

  private invalid(socket: WebSocket): void {
    this.close(socket, 1008, "Invalid or unauthorized message");
  }

  private close(socket: WebSocket, code: number, reason: string): void {
    try { socket.close(code, reason); } catch { /* already closed */ }
  }
}
