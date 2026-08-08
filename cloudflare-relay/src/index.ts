import { DurableObject } from "cloudflare:workers";
import {
  MAX_BODY_BYTES,
  MAX_CONNECTIONS,
  REQUEST_TIMEOUT_MS,
  SOCKET_TIMEOUT_MS,
  decodeBase64,
  encodeBase64,
  equalFixed,
  isHostToken,
  isRecord,
  parseHostFrame,
  proxyHeaders,
  randomId,
  route,
  tokenHash,
  type ProxyResponse,
  type SocketReady,
} from "./protocol";

interface Env {
  RELAYS: DurableObjectNamespace<ManagedRelay>;
}

type Attachment =
  | { role: "host" }
  | { role: "client"; id: string };

type Pending<T> = {
  resolve: (value: T) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

const json = (status: number, message: string) => cors(new Response(JSON.stringify({ error: { message } }), {
  status,
  headers: { "content-type": "application/json" },
}));

const cors = (response: Response) => {
  const next = new Response(response.body, response);
  next.headers.set("access-control-allow-origin", "*");
  next.headers.set("access-control-allow-headers", "authorization, content-type");
  next.headers.set("access-control-allow-methods", "GET, HEAD, POST, PATCH, PUT, DELETE, OPTIONS");
  return next;
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/api/health") {
      return cors(Response.json({ ok: true, service: "patchwork-managed-relay" }));
    }
    const destination = route(url.pathname);
    if (!destination) return json(404, "No such Patchwork relay.");
    if (destination.role === "client" && request.method === "OPTIONS") {
      return cors(new Response(null, { status: 204 }));
    }
    return env.RELAYS.getByName(destination.relayId).fetch(request);
  },
};

export class ManagedRelay extends DurableObject<Env> {
  private readonly sql: SqlStorage;
  private readonly pendingRequests = new Map<string, Pending<ProxyResponse>>();
  private readonly pendingSockets = new Map<string, Pending<SocketReady>>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec("CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
  }

  async fetch(request: Request): Promise<Response> {
    const destination = route(new URL(request.url).pathname);
    if (!destination) return json(404, "No such Patchwork relay.");
    return destination.role === "host"
      ? this.connectHost(request)
      : this.proxyClient(request, destination.localPath);
  }

  private async connectHost(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json(426, "The relay host must connect over WebSocket.");
    }
    const match = /^Bearer ([A-Za-z0-9_-]+)$/i.exec(request.headers.get("authorization") ?? "");
    if (!match || !isHostToken(match[1])) return json(401, "Invalid relay host token.");

    const hash = await tokenHash(match[1]);
    const stored = this.config("host_token_hash");
    if (stored && !equalFixed(stored, hash)) return json(401, "Invalid relay host token.");
    if (!stored) this.setConfig("host_token_hash", hash);

    for (const socket of this.ctx.getWebSockets("host")) socket.close(1012, "Relay host reconnected");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.serializeAttachment({ role: "host" } satisfies Attachment);
    this.ctx.acceptWebSocket(server, ["host"]);
    return new Response(null, { status: 101, webSocket: client });
  }

  private async proxyClient(request: Request, localPath: string): Promise<Response> {
    const host = this.host();
    if (!host) return json(503, "This Patchwork relay is offline.");
    if (this.ctx.getWebSockets().length >= MAX_CONNECTIONS || this.pendingRequests.size >= MAX_CONNECTIONS) {
      return json(429, "This Patchwork relay has too many connections.");
    }

    const url = new URL(request.url);
    const path = `${localPath}${url.search}`;
    if (request.headers.get("upgrade")?.toLowerCase() === "websocket") {
      return this.openSocket(host, path, request.headers);
    }

    const declared = Number(request.headers.get("content-length") ?? "0");
    if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return json(413, "Managed relay requests are limited to 20 MB.");
    const body = new Uint8Array(await request.arrayBuffer());
    if (body.byteLength > MAX_BODY_BYTES) return json(413, "Managed relay requests are limited to 20 MB.");

    const id = randomId();
    const response = new Promise<ProxyResponse>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error("The Patchwork relay did not answer in time."));
      }, REQUEST_TIMEOUT_MS);
      this.pendingRequests.set(id, { resolve, reject, timeout });
    });

    try {
      host.send(JSON.stringify({
        type: "request",
        id,
        method: request.method,
        path,
        headers: proxyHeaders(request.headers),
        body: encodeBase64(body),
      }));
      const result = await response;
      const bytes = decodeBase64(result.body);
      if (!bytes) return json(502, "The Patchwork relay returned an invalid response.");
      const headers = new Headers(result.headers);
      headers.delete("content-length");
      return cors(new Response(bytes, { status: result.status, headers }));
    } catch (error) {
      return json(504, error instanceof Error ? error.message : "The Patchwork relay did not answer.");
    } finally {
      const pending = this.pendingRequests.get(id);
      if (pending) clearTimeout(pending.timeout);
      this.pendingRequests.delete(id);
    }
  }

  private async openSocket(host: WebSocket, path: string, headers: Headers): Promise<Response> {
    const id = randomId();
    const ready = new Promise<SocketReady>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingSockets.delete(id);
        reject(new Error("The Patchwork relay did not open the live connection."));
      }, SOCKET_TIMEOUT_MS);
      this.pendingSockets.set(id, { resolve, reject, timeout });
    });

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.serializeAttachment({ role: "client", id } satisfies Attachment);
    this.ctx.acceptWebSocket(server, ["client", `client:${id}`]);

    try {
      host.send(JSON.stringify({ type: "socket_open", id, path, headers: proxyHeaders(headers) }));
      const opened = await ready;
      if (!opened.ok) {
        server.close(1008, opened.error ?? "Local relay refused the connection");
        return json(opened.status ?? 502, opened.error ?? "Local relay refused the connection.");
      }
      return new Response(null, { status: 101, webSocket: client });
    } catch (error) {
      server.close(1013, "Relay unavailable");
      return json(504, error instanceof Error ? error.message : "The Patchwork relay did not answer.");
    } finally {
      const pending = this.pendingSockets.get(id);
      if (pending) clearTimeout(pending.timeout);
      this.pendingSockets.delete(id);
    }
  }

  async webSocketMessage(socket: WebSocket, frame: string | ArrayBuffer): Promise<void> {
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (!attachment || typeof frame !== "string") return socket.close(1003, "Text frames only");

    if (attachment.role === "client") {
      this.sendHost({ type: "socket_data", id: attachment.id, data: frame });
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(frame);
    } catch {
      return socket.close(1007, "Invalid JSON");
    }
    const message = parseHostFrame(parsed);
    if (!message) return socket.close(1008, "Invalid host frame");

    switch (message.type) {
      case "response": {
        const pending = this.pendingRequests.get(message.id);
        if (pending) {
          clearTimeout(pending.timeout);
          this.pendingRequests.delete(message.id);
          pending.resolve(message);
        }
        return;
      }
      case "socket_ready": {
        const pending = this.pendingSockets.get(message.id);
        if (pending) {
          clearTimeout(pending.timeout);
          this.pendingSockets.delete(message.id);
          pending.resolve(message);
        }
        return;
      }
      case "socket_data": {
        this.client(message.id)?.send(message.data);
        return;
      }
      case "socket_close": {
        this.client(message.id)?.close(message.code ?? 1000, (message.reason ?? "").slice(0, 120));
        return;
      }
    }
  }

  webSocketClose(socket: WebSocket, code: number, reason: string): void {
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (attachment?.role === "client") {
      this.sendHost({ type: "socket_close", id: attachment.id, code, reason: reason.slice(0, 120) });
      return;
    }
    if (attachment?.role === "host") this.hostDisconnected();
  }

  webSocketError(socket: WebSocket): void {
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (attachment?.role === "client") {
      this.sendHost({ type: "socket_close", id: attachment.id, code: 1011, reason: "Client connection failed" });
      return;
    }
    if (attachment?.role === "host") this.hostDisconnected();
  }

  private hostDisconnected() {
    for (const pending of this.pendingRequests.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("This Patchwork relay went offline."));
    }
    this.pendingRequests.clear();
    for (const pending of this.pendingSockets.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("This Patchwork relay went offline."));
    }
    this.pendingSockets.clear();
    for (const client of this.ctx.getWebSockets("client")) client.close(1012, "Relay host disconnected");
  }

  private sendHost(message: unknown) {
    const host = this.host();
    if (host) host.send(JSON.stringify(message));
  }

  private host(): WebSocket | undefined {
    return this.ctx.getWebSockets("host")[0];
  }

  private client(id: string): WebSocket | undefined {
    return this.ctx.getWebSockets(`client:${id}`)[0];
  }

  private config(key: string): string | null {
    return this.sql.exec<{ value: string }>("SELECT value FROM config WHERE key = ?", key).toArray()[0]?.value ?? null;
  }

  private setConfig(key: string, value: string) {
    this.sql.exec("INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)", key, value);
  }
}
