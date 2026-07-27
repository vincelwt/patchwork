// pi-desktop-activity-version: 4
//
// Maintained by Pi Desktop. Safe to delete at any time — it reports whether a session is
// active and routes thread-created schedules into Pi Desktop's durable Automations service.
// Activity reporting lets the app avoid matching `ps`/`lsof` output
// (Pi's process title is indistinguishable from a bare interpreter) or a working directory
// (several sessions can share one). Hand edits survive future Pi Desktop launches unless the
// version comment above is bumped by a newer release, and even then only a file that still
// starts with a recognized, older `pi-desktop-activity-version:` marker is ever replaced.
//
// Writes one small JSON file per process to ~/.pi/agent/desktop-activity/<sessionId>-<pid>.json:
//   { sessionId, sessionFile, sessionDir, cwd, pid, state: "running" | "idle",
//     startedAt, updatedAt, preview, stopReason }
// Every heartbeat write is atomic (temp file + rename), and every activity handler is wrapped
// in try/catch: heartbeat failures must never interrupt the user's actual Pi session.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as http from "node:http";
import * as os from "node:os";
import * as path from "node:path";

/// While a run is in flight this refreshes `updatedAt`, so a process that crashes mid-turn
/// leaves a heartbeat that goes stale within a couple of missed beats instead of forever
/// claiming to be running.
const HEARTBEAT_INTERVAL_MS = 2_000;
const PREVIEW_LIMIT = 160;
const DAEMON_TIMEOUT_MS = 3_000;
const DAEMON_RESPONSE_LIMIT = 1_048_576;
const DAEMON_SOCKET_PATH = process.env.PI_DESKTOP_DAEMON_SOCKET_PATH ?? path.join(
  os.homedir(), "Library", "Application Support", "Pi Desktop", "daemon.sock"
);

type AutomationTrigger =
  | { kind: "once"; at: string }
  | { kind: "interval"; everySeconds: number }
  | { kind: "cron"; expression: string; timeZone?: string };

type DaemonResponse = { status: number; body: unknown; headers: http.IncomingHttpHeaders };
type CreatedSchedule = { id: string; name: string; nextRunAt?: string };
type ScheduleRequest = {
  idempotencyKey: string;
  name: string;
  enabled: boolean;
  target: { kind: "existingThread"; threadId: string };
  prompt: string;
  trigger: AutomationTrigger;
  policy: { skipIfRunning: boolean; catchUpMissed: boolean; timeoutSeconds: number };
};

function isDaemonCron(expression: string): boolean {
  const ranges = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 7]];
  const fields = expression.split(/\s+/);
  if (fields.length !== ranges.length) return false;
  return fields.every((field, index) => field.split(",").every((item) => {
    const stepParts = item.split("/");
    if (stepParts.length > 2 || (stepParts[1] !== undefined
        && (!/^[1-9]\d*$/.test(stepParts[1]) || !Number.isSafeInteger(Number(stepParts[1]))))) return false;
    const base = stepParts[0];
    if (base === "*") return true;
    const bounds = base.split("-");
    if (bounds.length > 2 || !bounds.every((part) => /^\d+$/.test(part))) return false;
    const values = bounds.map(Number);
    const [minimum, maximum] = ranges[index];
    return values.every((number) => minimum <= number && number <= maximum)
      && (values.length === 1 || values[0] <= values[1]);
  }));
}

function parseAutomationSchedule(value: string, now = Date.now()): AutomationTrigger {
  const schedule = value.trim();
  const units: Record<string, number> = { s: 1, m: 60, h: 3_600, d: 86_400 };
  const relative = schedule.match(/^\+(\d+)(s|m|h|d)$/);
  if (relative) {
    const seconds = Number(relative[1]) * units[relative[2]];
    const target = now + seconds * 1_000;
    if (seconds > 0 && Number.isSafeInteger(target)) {
      return { kind: "once", at: new Date(target).toISOString() };
    }
  }

  const interval = schedule.match(/^(\d+)(s|m|h|d)$/);
  if (interval) {
    const everySeconds = Number(interval[1]) * units[interval[2]];
    if (everySeconds >= 60 && Number.isSafeInteger(everySeconds)) {
      return { kind: "interval", everySeconds };
    }
  }

  if (/^\d{4}-\d{2}-\d{2}T/.test(schedule)) {
    const target = new Date(schedule);
    if (!Number.isNaN(target.getTime()) && target.getTime() > now) {
      return { kind: "once", at: target.toISOString() };
    }
  }

  const fields = schedule.split(/\s+/);
  const expression = fields.length === 5
    ? fields.join(" ")
    : fields.length === 6 && fields[0] === "0"
      ? fields.slice(1).join(" ")
      : undefined;
  if (expression && isDaemonCron(expression)) {
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    return { kind: "cron", expression, ...(timeZone ? { timeZone } : {}) };
  }

  throw new Error(
    "Use a 5-field cron, a 6-field cron with zero seconds, an interval of at least 1m, or a one-shot like +10m."
  );
}

function daemonRequest(
  method: string,
  requestPath: string,
  body?: unknown,
  signal?: AbortSignal
): Promise<DaemonResponse> {
  const payload = body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body));
  return new Promise((resolve, reject) => {
    const request = http.request({
      socketPath: DAEMON_SOCKET_PATH,
      path: requestPath,
      method,
      timeout: DAEMON_TIMEOUT_MS,
      signal,
      headers: {
        "X-Pi-Desktop-Api": "1",
        ...(body === undefined ? {} : {
          "Content-Type": "application/json",
          "Content-Length": String(payload.length),
        }),
      },
    }, (response) => {
      const chunks: Buffer[] = [];
      let byteCount = 0;
      response.on("data", (chunk: Buffer) => {
        byteCount += chunk.length;
        if (byteCount > DAEMON_RESPONSE_LIMIT) {
          response.destroy(new Error("Pi Desktop background service returned too much data."));
          return;
        }
        chunks.push(chunk);
      });
      response.once("error", reject);
      response.once("end", () => {
        try {
          const data = Buffer.concat(chunks);
          resolve({
            status: response.statusCode ?? 0,
            body: data.length ? JSON.parse(data.toString("utf8")) : {},
            headers: response.headers,
          });
        } catch (error) {
          reject(error);
        }
      });
    });
    request.once("timeout", () => request.destroy(new Error("Pi Desktop background service timed out.")));
    request.once("error", reject);
    request.end(payload);
  });
}

function responseMessage(body: unknown): string | undefined {
  if (!body || typeof body !== "object") return undefined;
  const value = body as { message?: unknown; error?: unknown };
  if (typeof value.message === "string") return value.message;
  if (typeof value.error === "string") return value.error;
  if (value.error && typeof value.error === "object") {
    const message = (value.error as { message?: unknown }).message;
    if (typeof message === "string") return message;
  }
  return undefined;
}

function apiCompatible(response: DaemonResponse): boolean {
  return response.headers["x-pi-desktop-api"] === "1";
}

function decodedSchedule(body: unknown): CreatedSchedule | undefined {
  if (!body || typeof body !== "object") return undefined;
  const schedule = (body as { schedule?: Partial<CreatedSchedule> }).schedule;
  return schedule && typeof schedule.id === "string" && typeof schedule.name === "string"
    ? schedule as CreatedSchedule
    : undefined;
}

async function desktopDaemonAvailable(signal?: AbortSignal): Promise<boolean> {
  try {
    const response = await daemonRequest("GET", "/v1/health", undefined, signal);
    if (response.status !== 200 || !apiCompatible(response) || !response.body || typeof response.body !== "object") {
      return false;
    }
    const health = response.body as Record<string, unknown>;
    return health.ok === true && health.api === 1 && health.schedulesEnabled === true
      && health.scheduleIdempotency === true;
  } catch {
    return false;
  }
}

async function createDesktopAutomation(
  input: { name: string; prompt: string; schedule: string },
  sessionId: string,
  signal?: AbortSignal
): Promise<CreatedSchedule> {
  const name = input.name.trim();
  const prompt = input.prompt.trim();
  if (!name) throw new Error("Give the automation a name.");
  if (!prompt) throw new Error("Write the prompt Pi should run.");
  if (!sessionId) throw new Error("This conversation has no session ID yet.");

  const requestWithoutKey = {
    name,
    enabled: true,
    target: { kind: "existingThread" as const, threadId: sessionId },
    prompt: input.prompt,
    trigger: parseAutomationSchedule(input.schedule),
    policy: { skipIfRunning: true, catchUpMissed: false, timeoutSeconds: 3_600 },
  };
  const request: ScheduleRequest = {
    idempotencyKey: randomUUID(),
    ...requestWithoutKey,
  };
  if (!await desktopDaemonAvailable(signal)) {
    if (signal?.aborted) throw new Error("Cancelled.");
    throw new Error("Pi Desktop's compatible background service is not running.");
  }

  let response: DaemonResponse;
  try {
    response = await daemonRequest("POST", "/v1/schedules", request, signal);
  } catch {
    try {
      response = await daemonRequest("POST", "/v1/schedules", request);
    } catch {
      throw new Error("Pi Desktop could not confirm whether it created the automation. Check the Automations page before retrying.");
    }
  }
  if (response.status !== 200 && response.status !== 201) {
    throw new Error(responseMessage(response.body) ?? `Pi Desktop rejected the automation (HTTP ${response.status}).`);
  }
  const schedule = apiCompatible(response) ? decodedSchedule(response.body) : undefined;
  if (schedule) return schedule;
  throw new Error("Pi Desktop returned an incompatible response. Check the Automations page before retrying.");
}

function normalizedSchedule(trigger: AutomationTrigger): string {
  switch (trigger.kind) {
    case "once": return trigger.at;
    case "interval": return `${trigger.everySeconds}s`;
    case "cron": return trigger.expression;
  }
}

function canRedirectAgentSchedule(input: Record<string, unknown>): boolean {
  return (input.subagent_type === undefined || input.subagent_type === "general-purpose")
    && input.model === undefined && input.max_turns === undefined && input.isolated !== true
    && input.isolation === undefined && input.inherit_context !== true && input.resume === undefined
    && input.run_in_background !== false;
}

function runAutomationSelfTest(): void {
  const cron = parseAutomationSchedule("0 0 9 * * 1") as { expression?: string };
  const interval = parseAutomationSchedule("15m") as { everySeconds?: number };
  const once = parseAutomationSchedule("+10m", 0) as { at?: string };
  let rejectedUnsupportedCron = false;
  try { parseAutomationSchedule("0 0 9 ? * 1"); } catch { rejectedUnsupportedCron = true; }
  if (cron.expression !== "0 9 * * 1" || interval.everySeconds !== 900
      || once.at !== "1970-01-01T00:10:00.000Z" || !rejectedUnsupportedCron) {
    throw new Error("Pi Desktop automation schedule parser self-test failed.");
  }
}

if (process.env.PI_DESKTOP_AUTOMATION_SELF_TEST === "1") runAutomationSelfTest();

export default function piDesktopActivity(pi: ExtensionAPI) {
  let heartbeatPath: string | null = null;
  let sessionId: string | null = null;
  let sessionDir: string | null = null;
  let sessionFile: string | undefined;
  let cwd: string | null = null;
  let startedAt: string | null = null;
  let preview: string | undefined;
  let stopReason: string | undefined;
  let timer: ReturnType<typeof setInterval> | null = null;
  let agentRunning = false;
  const backgroundAgents = new Set<string>();

  function clearTimer(): void {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  }

  function write(state: "running" | "idle"): void {
    if (!heartbeatPath || !sessionId) return;
    try {
      fs.mkdirSync(path.dirname(heartbeatPath), { recursive: true });
      const payload = {
        sessionId,
        sessionFile,
        sessionDir,
        cwd,
        pid: process.pid,
        state,
        startedAt,
        updatedAt: new Date().toISOString(),
        preview,
        stopReason,
      };
      // Readers must never observe a half-written file: same-directory temp file, then rename.
      const tmpPath = `${heartbeatPath}.${process.pid}.tmp`;
      fs.writeFileSync(tmpPath, JSON.stringify(payload));
      fs.renameSync(tmpPath, heartbeatPath);
    } catch {
      // Disk full, permissions, race with a concurrent writer — never surface this to the user.
    }
  }

  function remove(): void {
    if (!heartbeatPath) return;
    try {
      fs.unlinkSync(heartbeatPath);
    } catch {
      // Already gone, or not removable right now; the desktop app's freshness/pid checks cover
      // whatever is left behind.
    }
  }

  function syncHeartbeat(): void {
    const running = agentRunning || backgroundAgents.size > 0;
    write(running ? "running" : "idle");
    if (running && !timer) {
      timer = setInterval(() => write(agentRunning || backgroundAgents.size > 0 ? "running" : "idle"), HEARTBEAT_INTERVAL_MS);
      timer.unref?.();
    } else if (!running) {
      clearTimer();
    }
  }

  function updateBackgroundAgent(data: unknown, running: boolean): void {
    const id = data && typeof data === "object" ? (data as { id?: unknown }).id : undefined;
    if (typeof id !== "string") return;
    if (running) backgroundAgents.add(id);
    else backgroundAgents.delete(id);
    syncHeartbeat();
  }

  function extractPreview(content: unknown): string | undefined {
    let text = "";
    if (typeof content === "string") {
      text = content;
    } else if (Array.isArray(content)) {
      const block = content.find(
        (item) => item && typeof item === "object" && (item as { type?: unknown }).type === "text"
      ) as { text?: unknown } | undefined;
      if (block && typeof block.text === "string") text = block.text;
    }
    const singleLine = text.replace(/\s+/g, " ").trim();
    if (!singleLine) return undefined;
    return singleLine.length > PREVIEW_LIMIT ? `${singleLine.slice(0, PREVIEW_LIMIT)}…` : singleLine;
  }

  if (process.env.PI_DESKTOP_AUTOMATION_SELF_TEST === "1"
      && process.env.PI_DESKTOP_DAEMON_SOCKET_PATH) {
    pi.registerCommand("pi-desktop-automation-self-test", {
      description: "Exercise the Pi Desktop automation bridge",
      handler: async (_args, ctx) => {
        const created = await createDesktopAutomation(
          { name: "Bridge self-test", prompt: "No provider call.", schedule: "15m" },
          ctx.sessionManager.getSessionId()
        );
        if (created.id !== "sch_self_test") throw new Error("Automation bridge self-test failed.");
      },
    });
  }

  pi.registerTool({
    name: "schedule_automation",
    label: "Schedule Automation",
    description: "Create a durable scheduled prompt for the current conversation. It appears in Pi Desktop's Automations page and runs through the background service even after this Pi process exits.",
    promptSnippet: "Create durable scheduled prompts managed by Pi Desktop",
    promptGuidelines: [
      "Use schedule_automation instead of Agent's schedule parameter whenever the user explicitly asks for scheduled, recurring, or delayed work in the current conversation.",
    ],
    parameters: Type.Object({
      name: Type.String({ description: "Short name shown on the Automations page." }),
      prompt: Type.String({ description: "The complete prompt Pi should execute when the automation fires." }),
      schedule: Type.String({
        description: "5-field cron, 6-field cron with zero seconds, interval (15m/1h), or one-shot (+10m/ISO timestamp).",
      }),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      if (signal?.aborted) throw new Error("Cancelled.");
      const schedule = await createDesktopAutomation(
        params,
        ctx.sessionManager.getSessionId(),
        signal
      );
      const nextRun = schedule.nextRunAt ? ` Next run: ${schedule.nextRunAt}.` : "";
      return {
        content: [{
          type: "text",
          text: `Scheduled “${schedule.name}” in Pi Desktop Automations (id: ${schedule.id}).${nextRun}`,
        }],
        details: { scheduleId: schedule.id, name: schedule.name, nextRunAt: schedule.nextRunAt },
      };
    },
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName.toLowerCase() !== "agent" || !pi.getActiveTools().includes("schedule_automation")) return;
    const input = event.input as Record<string, unknown>;
    if (typeof input.schedule !== "string" || !canRedirectAgentSchedule(input)) return;
    let trigger: AutomationTrigger;
    try {
      trigger = parseAutomationSchedule(input.schedule);
    } catch {
      return; // Keep Agent's session-local scheduler for formats the daemon cannot represent.
    }
    if (!await desktopDaemonAvailable(ctx.signal)) return;
    const name = typeof input.description === "string" ? input.description : "Scheduled automation";
    return {
      block: true,
      reason: `Use schedule_automation for durable scheduled work: name=${JSON.stringify(name)}, `
        + `schedule=${JSON.stringify(normalizedSchedule(trigger))}, and the same prompt. `
        + "No Agent schedule was created.",
    };
  });

  pi.on("session_start", async (_event, ctx) => {
    try {
      sessionId = ctx.sessionManager.getSessionId();
      sessionDir = ctx.sessionManager.getSessionDir();
      sessionFile = ctx.sessionManager.getSessionFile();
      cwd = ctx.sessionManager.getCwd();
      startedAt = new Date().toISOString();
      preview = undefined;
      stopReason = undefined;
      // Several processes can attach to one session. A reader must see every writer so an idle
      // RPC attachment cannot overwrite a terminal that is still working.
      heartbeatPath = sessionId
        ? path.join(os.homedir(), ".pi", "agent", "desktop-activity", `${sessionId}-${process.pid}.json`)
        : null;
      agentRunning = !ctx.isIdle();
      syncHeartbeat();
    } catch {
      // No heartbeat for this session; the desktop app falls back to its file heuristic.
    }
  });

  pi.on("agent_start", async () => {
    agentRunning = true;
    syncHeartbeat();
  });

  pi.on("turn_start", async () => {
    agentRunning = true;
    syncHeartbeat();
  });

  pi.on("turn_end", async (event) => {
    try {
      const message = (event as { message?: { role?: string; content?: unknown; stopReason?: unknown } })
        .message;
      if (message && message.role === "assistant") {
        preview = extractPreview(message.content) ?? preview;
        stopReason = typeof message.stopReason === "string" ? message.stopReason : stopReason;
      }
      syncHeartbeat();
    } catch {
      // Best effort only.
    }
  });

  pi.on("agent_end", async (_event, ctx) => {
    agentRunning = !ctx.isIdle();
    syncHeartbeat();
  });

  pi.on("agent_settled", async () => {
    agentRunning = false;
    syncHeartbeat();
  });

  // Background subagents outlive the parent agent run. Keep the session working until the
  // subagent manager reports every started or queued agent complete.
  pi.events.on("subagents:created", (data) => updateBackgroundAgent(data, true));
  pi.events.on("subagents:started", (data) => updateBackgroundAgent(data, true));
  pi.events.on("subagents:completed", (data) => updateBackgroundAgent(data, false));
  pi.events.on("subagents:failed", (data) => updateBackgroundAgent(data, false));

  pi.on("session_shutdown", async () => {
    clearTimer();
    backgroundAgents.clear();
    remove();
  });

  // Covers a clean process exit; a crash is instead caught by the desktop app's freshness/pid
  // checks against the last heartbeat this process managed to write.
  process.on("exit", () => {
    try {
      remove();
    } catch {
      // The process is already on its way out.
    }
  });
}
