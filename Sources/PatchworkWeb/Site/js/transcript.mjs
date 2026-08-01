// Turn projection, ported from the Mac app's `TranscriptPresenter` (see
// Sources/Patchwork/TranscriptPresentation.swift) so both clients fold a conversation the same
// way: one user message, one collapsible work log (reasoning, mid-turn narration, tool activity,
// retried errors, compaction), then the answer.
//
// Pure data in, pure data out — no DOM, no fetch, no clock — so `docs/js-checks` can exercise the
// rules directly. Everything a message carries beyond `text` (`blocks`, `toolCallId`, `toolName`,
// `stopReason`) is optional: a daemon that predates them yields one text block per message, which
// still projects into readable turns.

/** Pi's own terminal reasons: prose carrying one of these is an answer, not narration. */
const TERMINAL_STOP_REASONS = new Set(["stop", "length", "error", "aborted"]);
/** The daemon writes compaction/branch summaries as a title block plus a summary block. */
const COMPACTION_TITLES = new Set(["Context compacted", "Branch summary"]);

/** The readable categories the Mac app shows; same names, same matching rules. */
export function classifyTool(name) {
  const tool = String(name || "").toLowerCase();
  if (tool === "bash") return "Ran commands";
  if (["read", "grep", "find", "ls"].includes(tool)) return "Read files";
  if (["edit", "write"].includes(tool)) return "Edited files";
  if (["web_search", "fetch_content", "get_search_content", "source_check"].includes(tool)) return "Searched web";
  if (tool === "chrome_js" || tool.startsWith("chrome_")) return "Used browser";
  if (["computer_js", "observe_ui", "act_ui", "find_roots"].includes(tool)) return "Used computer";
  if (["agent", "get_subagent_result", "steer_subagent"].includes(tool) || tool.startsWith("subagent")) return "Ran agents";
  if (tool === "process") return "Managed processes";
  if (tool === "imagegen") return "Generated image";
  if (tool === "ask_user_question") return "Asked question";
  return "Used tool";
}

/** "12s", "3m 4s", "1h 20m" — the app's own `NumberFormatting.duration`. */
export function formatDuration(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  if (total < 60) return `${total}s`;
  if (total < 3600) return `${Math.floor(total / 60)}m ${total % 60}s`;
  return `${Math.floor(total / 3600)}h ${Math.floor((total % 3600) / 60)}m`;
}

/** "Ran commands", "Ran commands and Read files", "A, B, and C" — the app's own phrasing. */
export function activitySummary(entry) {
  const labels = [...new Set(entry.steps.map((step) => step.category))];
  if (!labels.length) return "Used tool";
  if (labels.length === 1) return labels[0];
  if (labels.length === 2) return labels.join(" and ");
  return `${labels.slice(0, -1).join(", ")}, and ${labels[labels.length - 1]}`;
}

/** "Step 2 of 4" while the group is live, "4 steps" once it has settled. */
export function activityProgress(entry) {
  const total = entry.steps.length;
  if (!entry.active) return `${total} step${total === 1 ? "" : "s"}`;
  const next = entry.steps.findIndex((step) => !step.complete);
  return `Step ${Math.max(1, next < 0 ? total : next + 1)} of ${total}`;
}

/** Sentence case for a tool name: "Web search", not "web_search". */
export function toolDisplayName(name) {
  const spaced = String(name || "tool").replace(/_/g, " ");
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

/**
 * Projects wire messages into transcript items.
 *
 * - `{ kind: "message", key, message }` — a user message, a turn's answer, or a standalone entry
 *   that belongs to no turn.
 * - `{ kind: "work", key, entries, active, … }` — one turn's work log.
 */
export function projectTranscript(messages, { running = false } = {}) {
  const builder = new TurnBuilder(running === true);
  for (const message of Array.isArray(messages) ? messages : []) builder.consume(message);
  return builder.finish();
}

/**
 * Keeps a work row's identity when loading older history changes which entry happens to lead it.
 * The native app applies the same overlap rule so an open disclosure does not snap shut at a
 * pagination seam or when a waiting row receives its first durable progress entry.
 */
export function preserveWorkKeys(previous, projected) {
  const priorItems = Array.isArray(previous) ? previous : [];
  const nextItems = Array.isArray(projected) ? projected : [];
  const ownerByEntryKey = new Map();
  let waitingKey = null;

  for (const item of priorItems) {
    if (item?.kind !== "work") continue;
    if (item.active === true && (!Array.isArray(item.entries) || item.entries.length === 0)) {
      waitingKey = item.key;
    }
    for (const entry of Array.isArray(item.entries) ? item.entries : []) {
      if (entry?.key) ownerByEntryKey.set(entry.key, item.key);
    }
  }

  const used = new Set();
  return nextItems.map((item) => {
    if (item?.kind !== "work") return item;
    const overlappingKey = (Array.isArray(item.entries) ? item.entries : [])
      .map((entry) => ownerByEntryKey.get(entry?.key))
      .find((key) => key && !used.has(key));
    const preservedKey = overlappingKey || (item.active === true && waitingKey && !used.has(waitingKey) ? waitingKey : null);
    if (!preservedKey) return item;
    used.add(preservedKey);
    return item.key === preservedKey ? item : { ...item, key: preservedKey };
  });
}

/** Work and nested activity disclosures that were live and have now settled. */
export function settledDisclosureKeys(previous, projected) {
  const liveWorkKeys = new Set();
  const liveKeys = new Set();
  for (const item of Array.isArray(previous) ? previous : []) {
    if (item?.kind !== "work") continue;
    if (item.active === true) liveWorkKeys.add(item.key);
    for (const entry of Array.isArray(item.entries) ? item.entries : []) {
      if (entry?.kind === "activity" && entry.active === true) liveKeys.add(entry.key);
    }
  }
  const settled = [];
  for (const item of Array.isArray(projected) ? projected : []) {
    if (item?.kind !== "work") continue;
    if (item.active !== true && liveWorkKeys.has(item.key)) settled.push(item.key);
    for (const entry of Array.isArray(item.entries) ? item.entries : []) {
      if (entry?.kind === "activity" && entry.active !== true && liveKeys.has(entry.key)) settled.push(entry.key);
    }
  }
  return settled;
}

class TurnBuilder {
  constructor(isLive) {
    this.isLive = isLive;
    this.result = [];
    this.entries = [];
    this.pending = null; // open activity group
    this.trailing = []; // prose that is the answer unless more work follows it
    this.trailingIsAnswer = false;
    this.turnStart = null;
    this.turnAnchorID = null;
    this.lastTimestamp = null;
    this.answerFailed = false;
  }

  consume(message) {
    if (!message || typeof message !== "object") return;
    const role = message.role;

    if (role === "user") {
      // Closed with Pi's last timestamp, not the next user's later reply time.
      this.closeTurn(false);
      this.lastTimestamp = message.at || null;
      this.turnStart = message.at || null;
      this.turnAnchorID = message.id || null;
      this.result.push(messageItem(message, 0));
      return;
    }

    if (role === "assistant") this.consumeAssistant(message);
    else if (role === "toolResult") this.attachResult(message);
    else if (role === "system" && compactionOf(message)) {
      this.demoteTrailing();
      this.closeActivity();
      this.entries.push(noteEntry(message, 0));
    } else this.log(message);

    if (message.at) this.lastTimestamp = message.at;
  }

  finish() {
    this.closeTurn(this.isLive && this.trailing.length === 0);
    return this.result;
  }

  consumeAssistant(message) {
    // Blocks are handled in order, so narration that precedes a tool call stays above it in the
    // work log instead of being reordered after it.
    const blocks = Array.isArray(message.blocks) && message.blocks.length
      ? message.blocks
      : [{ type: "text", text: message.text || "" }];
    let prose = [];
    let proseIndex = 0;
    const parts = [];

    const proseMessage = () => {
      const text = prose.map((entry) => entry.text).join("\n\n").trim();
      const index = proseIndex;
      prose = [];
      if (!text) return null;
      const part = { message: { ...message, text, images: [], blocks: undefined }, index };
      parts.push(part);
      return part;
    };

    for (const [index, block] of blocks.entries()) {
      const type = block?.type;
      if (type === "thinking") {
        const narration = proseMessage();
        if (narration) {
          this.demoteTrailing();
          this.entries.push(noteEntry(narration.message, narration.index));
        }
        this.demoteTrailing();
        this.closeActivity();
        const text = (block.text || "").trim();
        if (text) this.entries.push({ kind: "thinking", key: `thinking:${message.id}:${index}`, text });
        proseIndex = index + 1;
      } else if (type === "toolCall") {
        const narration = proseMessage();
        if (narration) {
          this.demoteTrailing();
          this.entries.push(noteEntry(narration.message, narration.index));
        }
        this.demoteTrailing();
        this.appendCall(block, `${message.id}:${index}`);
        proseIndex = index + 1;
      } else if (type === "text" && block.text) {
        if (!prose.length) proseIndex = index;
        prose.push({ text: block.text });
      } else if (type !== "image") {
        // Match the app's visible fallback instead of silently dropping a newer block kind.
        if (!prose.length) proseIndex = index;
        prose.push({ text: `Unsupported content \u00b7 ${type || "unknown"}` });
      }
      // Images travel in `message.images` and ride with the prose part below.
    }

    const final = proseMessage();
    // Inline images belong to the last piece of prose this message produced — normally the
    // answer, which is exactly where they must stay visible.
    const owner = parts[parts.length - 1];
    if (owner) owner.message.images = Array.isArray(message.images) ? message.images : [];

    if (message.isError) {
      // Transport/model errors are retry events inside the same work log, not answers that split
      // one uninterrupted run into several turns.
      this.demoteTrailing();
      this.answerFailed = true;
      if (final) {
        this.closeActivity();
        this.entries.push(noteEntry(final.message, final.index));
      }
      return;
    }

    if (final && message.stopReason === "toolUse") {
      this.demoteTrailing();
      this.closeActivity();
      this.entries.push(noteEntry(final.message, final.index));
      return;
    }

    // Recorded after the blocks, not before: a `demoteTrailing()` above can close the previous
    // turn, whose header must report *that* turn's answer, not this one.
    this.answerFailed = false;
    if (final) {
      if (this.entries.length || this.pending || TERMINAL_STOP_REASONS.has(message.stopReason || "")) {
        this.trailingIsAnswer = true;
      }
      this.trailing.push(messageItem(final.message, final.index));
    }
  }

  /** System and future-role entries join the work log mid-turn and stand alone otherwise. */
  log(message) {
    this.demoteTrailing();
    if (!this.entries.length && !this.pending && !this.trailing.length) this.result.push(messageItem(message, 0));
    else this.entries.push(noteEntry(message, 0));
  }

  appendCall(block, fallbackId) {
    const callId = block.callId || fallbackId;
    if (!this.pending) this.pending = { kind: "activity", key: `activity:${callId}`, steps: [], active: true };
    this.pending.steps.push({
      key: `step:${callId}`,
      callId,
      name: block.name || "tool",
      label: toolDisplayName(block.name),
      category: classifyTool(block.name),
      arguments: block.arguments || "",
      result: null,
      complete: false,
      failed: false
    });
  }

  attachResult(message) {
    const callId = message.toolCallId || message.id;
    const settle = (step) => {
      step.result = message;
      step.complete = true;
      step.failed = message.isError === true;
    };

    const open = this.pending ? lastIndexWhere(this.pending.steps, (step) => step.callId === callId) : -1;
    if (open >= 0) {
      settle(this.pending.steps[open]);
      return;
    }
    // A result can land after reasoning already closed its group.
    for (let index = this.entries.length - 1; index >= 0; index -= 1) {
      const entry = this.entries[index];
      if (entry.kind !== "activity") continue;
      const stepIndex = lastIndexWhere(entry.steps, (step) => step.callId === callId && !step.complete);
      if (stepIndex >= 0) {
        settle(entry.steps[stepIndex]);
        return;
      }
    }

    // An orphan result (resumed session, tool call outside the loaded window) still shows.
    const name = message.toolName || "tool";
    this.demoteTrailing();
    if (!this.pending) this.pending = { kind: "activity", key: `activity:${callId}`, steps: [], active: true };
    const step = {
      key: `step:${callId}`,
      callId,
      name,
      label: toolDisplayName(name),
      category: classifyTool(name),
      arguments: "",
      result: null,
      complete: false,
      failed: false
    };
    settle(step);
    this.pending.steps.push(step);
  }

  /**
   * Prose followed by more work was narration — but only when it also came *before* that work.
   * Prose Pi wrote after its tool calls is the turn's answer: a late tool result or a follow-on
   * call opens a new turn under it rather than collapsing the answer the reader is looking at.
   */
  demoteTrailing() {
    if (!this.trailing.length) return;
    if (this.trailingIsAnswer) {
      this.closeTurn(false);
      return;
    }
    this.closeActivity();
    for (const item of this.trailing) this.entries.push(noteEntry(item.message, item.blockIndex));
    this.trailing = [];
  }

  closeActivity(active = false) {
    if (!this.pending || !this.pending.steps.length) {
      this.pending = null;
      return;
    }
    this.pending.active = active;
    this.entries.push(this.pending);
    this.pending = null;
  }

  closeTurn(active) {
    this.closeActivity(active);
    if (this.entries.length) {
      this.result.push(workItem({
        entries: this.entries,
        active,
        startedAt: this.turnStart,
        endedAt: this.lastTimestamp,
        answerFailed: this.answerFailed,
        key: null
      }));
    } else if (active && this.trailing.length === 0) {
      this.result.push(workItem({
        entries: [],
        active: true,
        startedAt: this.turnStart,
        endedAt: this.lastTimestamp,
        answerFailed: false,
        key: `work:waiting:${this.turnAnchorID || "active-thread"}`
      }));
    }
    this.result.push(...this.trailing);
    this.entries = [];
    this.trailing = [];
    this.trailingIsAnswer = false;
    this.answerFailed = false;
    // Work after a settled answer starts its own clock rather than inheriting the finished
    // turn's start and reporting a duration spanning both.
    this.turnStart = this.lastTimestamp;
  }
}

function lastIndexWhere(list, predicate) {
  for (let index = list.length - 1; index >= 0; index -= 1) if (predicate(list[index])) return index;
  return -1;
}

function messageItem(message, blockIndex) {
  return { kind: "message", key: `message:${message.id}:${blockIndex}`, message, blockIndex };
}

function noteEntry(message, blockIndex) {
  return { kind: "note", key: `note:${message.id}:${blockIndex}`, message, compaction: compactionOf(message) };
}

/** `{ title, summary }` for a compaction/branch-summary system entry, else `null`. */
export function compactionOf(message) {
  if (!message || message.role !== "system") return null;
  const blocks = Array.isArray(message.blocks) ? message.blocks.filter((b) => b?.type === "text") : [];
  if (blocks.length && COMPACTION_TITLES.has(blocks[0].text)) {
    return { title: blocks[0].text, summary: blocks.slice(1).map((b) => b.text || "").join("\n") };
  }
  // A daemon that predates `blocks` sends only the flattened "Title: summary" line.
  for (const title of COMPACTION_TITLES) {
    if (typeof message.text === "string" && message.text.startsWith(`${title}:`)) {
      return { title, summary: message.text.slice(title.length + 1).trim() };
    }
  }
  return null;
}

function workItem({ entries, active, startedAt, endedAt, answerFailed, key }) {
  const steps = entries.filter((entry) => entry.kind === "activity").flatMap((entry) => entry.steps);
  const duration = durationSeconds(startedAt, endedAt);
  const item = {
    kind: "work",
    key: key || `work:${entries[0].key}`,
    entries,
    active,
    startedAt: startedAt || null,
    endedAt: endedAt || null,
    answerFailed: answerFailed === true,
    stepCount: steps.length,
    hasFailure: steps.some((step) => step.failed),
    // Turn-level output stays visible outside the collapsed log.
    images: steps.flatMap((step) => (Array.isArray(step.result?.images) ? step.result.images : [])),
    status: latestStatus(entries),
    title: workTitle(steps.length, duration)
  };
  // A live turn, a failed answer, or a compaction shows what just happened instead of a count.
  item.showsStatus = item.active || item.answerFailed || endsWithCompaction(entries);
  item.headline = (item.showsStatus && item.status) || (item.active ? "Thinking" : item.title);
  item.duration = duration;
  return item;
}

function workTitle(stepCount, duration) {
  if (duration !== null) return `Worked for ${formatDuration(duration)}`;
  if (stepCount > 0) return `Worked \u00b7 ${stepCount} step${stepCount === 1 ? "" : "s"}`;
  return "Worked";
}

/** Whole seconds between two wire timestamps, or `null` when either is missing or nonsensical. */
export function durationSeconds(from, to) {
  if (!from || !to) return null;
  const start = new Date(from).getTime();
  const end = new Date(to).getTime();
  // Missing Pi timestamps arrive over this legacy wire shape as `Date.distantPast`.
  if (Number.isNaN(start) || Number.isNaN(end) || start <= 0 || end <= 0 || end < start) return null;
  return (end - start) / 1000;
}

/** One collapsed status line: newest thought line, but first error line. */
function statusLine(text, latest) {
  const lines = String(text || "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const line = latest ? lines.at(-1) : lines[0];
  return (line || "").replace(/\s+/g, " ").replace(/\*\*/g, "");
}

/** The newest thought or exceptional event worth surfacing while the details stay collapsed. */
function latestStatus(entries) {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry.kind === "thinking") return statusLine(entry.text, true);
    if (entry.kind !== "note") continue;
    if (entry.compaction) return entry.compaction.title;
    const detail = statusLine(entry.message.text, entry.message.isError !== true);
    if (entry.message.isError === true) return detail ? `Agent error: ${detail}` : "Agent error";
    if (detail) return detail;
  }
  return null;
}

function endsWithCompaction(entries) {
  const last = entries[entries.length - 1];
  return !!(last && last.kind === "note" && last.compaction);
}
