const DEFAULT_RETENTION = 550;
const DEFAULT_RETENTION_BYTES = 8 * 1024 * 1024;

function keyOf(message) {
  if (typeof message?.id === "string" && message.id) return `id:${message.id}`;
  return `fallback:${message?.role || ""}:${message?.at || ""}:${message?.text || ""}`;
}

function retainedBytes(message) {
  try { return JSON.stringify(message).length * 2 + 128; }
  catch { return DEFAULT_RETENTION_BYTES + 1; }
}

function bounded(messages, maximum, keepNewest, maximumBytes = DEFAULT_RETENTION_BYTES) {
  const limit = Math.max(1, Number.isInteger(maximum) ? maximum : DEFAULT_RETENTION);
  const candidates = keepNewest ? [...messages].reverse() : messages;
  const retained = [];
  let bytes = 0;
  for (const message of candidates) {
    const cost = retainedBytes(message);
    if (retained.length >= limit || (retained.length && bytes + cost > maximumBytes)) break;
    retained.push(message);
    bytes += cost;
  }
  return keepNewest ? retained.reverse() : retained;
}

/** Exact signature for the daemon's bounded newest page, never the retained multi-page history. */
export function latestPageSignature(messages, running) {
  return JSON.stringify([Array.isArray(messages) ? messages : [], running === true]);
}

/** Merge a refreshed tail without discarding pages the reader already loaded. */
export function mergeLatestPage(current, page, maximum = DEFAULT_RETENTION) {
  const existing = Array.isArray(current) ? current : [];
  const incoming = Array.isArray(page) ? page : [];
  const incomingByKey = new Map(incoming.map((message) => [keyOf(message), message]));
  const seen = new Set(existing.map(keyOf));
  const merged = existing.map((message) => incomingByKey.get(keyOf(message)) || message);
  for (const message of incoming) {
    const key = keyOf(message);
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(message);
  }
  return bounded(merged, maximum, true);
}

/** Prepend an older page, replacing overlaps by stable message id. */
export function mergeOlderPage(current, page, maximum = DEFAULT_RETENTION) {
  const existing = Array.isArray(current) ? current : [];
  const incoming = Array.isArray(page) ? page : [];
  const existingKeys = new Set(existing.map(keyOf));
  const incomingByKey = new Map(incoming.map((message) => [keyOf(message), message]));
  const prefix = incoming.filter((message) => !existingKeys.has(keyOf(message)));
  const merged = prefix.concat(existing.map((message) => incomingByKey.get(keyOf(message)) || message));
  return bounded(merged, maximum, false);
}

/** The daemon accepts offsets through 5000. A larger cursor would repeat the last page. */
export function boundedNextOffset(value, maximum = 5000) {
  return Number.isInteger(value) && value >= 0 && value <= maximum ? value : null;
}

export function scrollTopAfterPrepend(oldTop, oldHeight, newHeight) {
  return Math.max(0, oldTop + Math.max(0, newHeight - oldHeight));
}
