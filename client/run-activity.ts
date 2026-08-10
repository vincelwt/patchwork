import type { RunEvent } from "./types";

type Data = Record<string, unknown>;

export interface ToolActivity {
  type: "tool";
  call: RunEvent;
  updates: RunEvent[];
  title: string;
  status: string;
  startedAt: number;
  endedAt: number;
  paths: string[];
  cwd?: string;
  input?: unknown;
  exitCode?: number;
  signal?: string;
}

export type RunActivityItem =
  | ToolActivity
  | { type: "thought"; id: string; text: string }
  | { type: "event"; event: RunEvent };

export interface RunActivity {
  items: RunActivityItem[];
  debug: RunEvent[];
  toolCount: number;
  fileCount: number;
  warningCount: number;
}

function dataOf(event: RunEvent): Data {
  return event.data && typeof event.data === "object" && !Array.isArray(event.data)
    ? (event.data as Data)
    : {};
}

function nested(data: Data, first: string, second: string): Data {
  const value = data[first];
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const child = (value as Data)[second];
  return child && typeof child === "object" && !Array.isArray(child)
    ? (child as Data)
    : {};
}

function stringAt(data: Data, key: string): string | undefined {
  return typeof data[key] === "string" ? data[key] : undefined;
}

function toolCallId(event: RunEvent): string | undefined {
  return stringAt(dataOf(event), "toolCallId");
}

function toolTitle(event: RunEvent, paths: string[]): string {
  const data = dataOf(event);
  const title = stringAt(data, "title") || event.text.replace(/ — \w+$/, "");
  if (paths.length !== 1 || !["read", "write", "edit"].includes(title.toLowerCase())) {
    return title;
  }
  const name = paths[0].split(/[\\/]/).pop();
  return `${title[0].toUpperCase()}${title.slice(1)} ${name}`;
}

function toolPaths(data: Data): string[] {
  if (!Array.isArray(data.locations)) return [];
  return data.locations.flatMap((location) => {
    if (!location || typeof location !== "object" || Array.isArray(location)) return [];
    const path = (location as Data).path;
    return typeof path === "string" ? [path] : [];
  });
}

export function toolOutput(updates: RunEvent[]): unknown {
  const terminal = updates.flatMap((event) => {
    const output = nested(dataOf(event), "_meta", "terminal_output").data;
    return typeof output === "string" ? [output] : [];
  });
  if (terminal.length) return terminal.join("");

  for (let index = updates.length - 1; index >= 0; index -= 1) {
    const data = dataOf(updates[index]);
    if (data.content !== undefined) return data.content;
    if (data.rawOutput !== undefined) return data.rawOutput;
  }
  return undefined;
}

function toolActivity(call: RunEvent, updates: RunEvent[]): ToolActivity {
  const callData = dataOf(call);
  const finalData = updates.length ? dataOf(updates[updates.length - 1]) : callData;
  const terminal = nested(finalData, "_meta", "terminal_exit");
  const paths = toolPaths(callData);
  return {
    type: "tool",
    call,
    updates,
    title: toolTitle(call, paths),
    status: stringAt(finalData, "status") || stringAt(callData, "status") || "pending",
    startedAt: call.created_at,
    endedAt: updates.at(-1)?.created_at ?? call.created_at,
    paths,
    cwd: stringAt(nested(callData, "_meta", "terminal_info"), "cwd"),
    input: callData.rawInput,
    exitCode: typeof terminal.exit_code === "number" ? terminal.exit_code : undefined,
    signal: typeof terminal.signal === "string" ? terminal.signal : undefined,
  };
}

function warningLike(event: RunEvent): boolean {
  return event.kind === "lifecycle" && /warn|error|failed|could not|denied/i.test(event.text);
}

function debugEvent(event: RunEvent): boolean {
  if (event.kind === "permission") return /^Allowed:/i.test(event.text);
  return event.kind === "lifecycle" && !warningLike(event);
}

function changedFileCount(text: string): number {
  return text.split("\n").reduce((count, line) => {
    if (!line.trim()) return count;
    const rest = /^… and (\d+) more$/.exec(line.trim());
    return count + (rest ? Number(rest[1]) : 1);
  }, 0);
}

export function projectRunActivity(events: RunEvent[]): RunActivity {
  let latestPlan: string | undefined;
  for (const event of events) {
    if (event.kind === "plan") latestPlan = event.id;
  }
  const toolCalls = new Set<string>();
  const updates = new Map<string, RunEvent[]>();
  for (const event of events) {
    const id = toolCallId(event);
    if (!id) continue;
    if (event.kind === "tool_call") toolCalls.add(id);
    if (event.kind !== "tool_result") continue;
    const existing = updates.get(id);
    if (existing) existing.push(event);
    else updates.set(id, [event]);
  }

  const items: RunActivityItem[] = [];
  const debug: RunEvent[] = [];
  const changedPaths = new Set<string>();
  let fileChanges = 0;
  let warnings = 0;
  let thought: Extract<RunActivityItem, { type: "thought" }> | undefined;

  const finishThought = () => {
    if (thought) items.push(thought);
    thought = undefined;
  };

  for (const event of events) {
    if (event.kind === "tool_result") {
      const id = toolCallId(event);
      if (id && toolCalls.has(id)) continue;
      finishThought();
      items.push({ type: "event", event });
      if (stringAt(dataOf(event), "status") === "failed" || /failed/i.test(event.text)) {
        warnings += 1;
      }
      continue;
    }
    if ((event.kind === "plan" && event.id !== latestPlan) || debugEvent(event)) {
      debug.push(event);
      continue;
    }
    if (event.kind === "thought") {
      if (thought) thought.text += `\n\n${event.text}`;
      else thought = { type: "thought", id: event.id, text: event.text };
      continue;
    }

    finishThought();
    if (event.kind === "tool_call") {
      const id = toolCallId(event);
      const tool = toolActivity(event, id ? updates.get(id) ?? [] : []);
      items.push(tool);
      const kind = stringAt(dataOf(event), "kind")?.toLowerCase();
      if (kind && ["edit", "write", "apply_patch"].includes(kind)) {
        tool.paths.forEach((path) => changedPaths.add(path));
      }
      if (tool.status === "failed") warnings += 1;
      continue;
    }
    items.push({ type: "event", event });
    if (event.kind === "file_change") fileChanges += changedFileCount(event.text);
    if (
      event.kind === "error" ||
      (event.kind === "permission" && /^Denied:/i.test(event.text)) ||
      warningLike(event)
    ) {
      warnings += 1;
    }
  }
  finishThought();

  return {
    items,
    debug,
    toolCount: items.filter((item) => item.type === "tool").length,
    fileCount: Math.max(changedPaths.size, fileChanges),
    warningCount: warnings,
  };
}
