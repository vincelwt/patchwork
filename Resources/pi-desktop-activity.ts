// pi-desktop-activity-version: 1
//
// Maintained by Pi Desktop. Safe to delete at any time — it only reports whether a session is
// active so the desktop app can show accurate run state without matching `ps`/`lsof` output
// (Pi's process title is indistinguishable from a bare interpreter) or a working directory
// (several sessions can share one). Hand edits survive future Pi Desktop launches unless the
// version comment above is bumped by a newer release, and even then only a file that still
// starts with a recognized, older `pi-desktop-activity-version:` marker is ever replaced.
//
// Writes one small JSON file per session to ~/.pi/agent/desktop-activity/<sessionId>.json:
//   { sessionId, sessionFile, sessionDir, cwd, pid, state: "running" | "idle",
//     startedAt, updatedAt, preview, stopReason }
// Every write is atomic (temp file + rename) and every handler below is wrapped in try/catch:
// a failure in here must never interrupt the user's actual Pi session.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

/// While a run is in flight this refreshes `updatedAt`, so a process that crashes mid-turn
/// leaves a heartbeat that goes stale within a couple of missed beats instead of forever
/// claiming to be running.
const HEARTBEAT_INTERVAL_MS = 2_000;
const PREVIEW_LIMIT = 160;

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

  pi.on("session_start", async (_event, ctx) => {
    try {
      sessionId = ctx.sessionManager.getSessionId();
      sessionDir = ctx.sessionManager.getSessionDir();
      sessionFile = ctx.sessionManager.getSessionFile();
      cwd = ctx.sessionManager.getCwd();
      startedAt = new Date().toISOString();
      preview = undefined;
      stopReason = undefined;
      heartbeatPath = sessionId
        ? path.join(os.homedir(), ".pi", "agent", "desktop-activity", `${sessionId}.json`)
        : null;
      write(ctx.isIdle() ? "idle" : "running");
    } catch {
      // No heartbeat for this session; the desktop app falls back to its file heuristic.
    }
  });

  pi.on("agent_start", async () => {
    try {
      clearTimer();
      write("running");
      timer = setInterval(() => write("running"), HEARTBEAT_INTERVAL_MS);
      timer.unref?.();
    } catch {
      // Best effort only.
    }
  });

  pi.on("turn_start", async () => {
    try {
      write("running");
    } catch {
      // Best effort only.
    }
  });

  pi.on("turn_end", async (event) => {
    try {
      const message = (event as { message?: { role?: string; content?: unknown; stopReason?: unknown } })
        .message;
      if (message && message.role === "assistant") {
        preview = extractPreview(message.content) ?? preview;
        stopReason = typeof message.stopReason === "string" ? message.stopReason : stopReason;
      }
      write("running");
    } catch {
      // Best effort only.
    }
  });

  pi.on("agent_end", async (_event, ctx) => {
    try {
      write(ctx.isIdle() ? "idle" : "running");
    } catch {
      // Best effort only.
    }
  });

  pi.on("agent_settled", async () => {
    try {
      clearTimer();
      write("idle");
    } catch {
      // Best effort only.
    }
  });

  pi.on("session_shutdown", async () => {
    try {
      clearTimer();
      remove();
    } catch {
      // Best effort only.
    }
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
