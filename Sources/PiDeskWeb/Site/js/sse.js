// Minimal Server-Sent Events client built on fetch + ReadableStream rather than the built-in
// EventSource API. Two reasons: EventSource cannot send custom request headers, and every
// request (docs/daemon-api.md) must carry `Authorization: Bearer <token>`; and EventSource's
// built-in reconnect has no backoff control, while the task calls for exponential backoff.

import { getToken } from "./api.js";

const INITIAL_DELAY_MS = 1000;
const MAX_DELAY_MS = 30000;

/**
 * Opens `GET /v1/events` and calls `onEvent(name, data)` per SSE frame. `data` is JSON-parsed
 * when possible; unknown event names and unknown JSON fields are passed through untouched, per
 * the API's forward-compatibility rule. `onStatus("connecting" | "online" | "offline")` reports
 * connection health for the UI banner. Reconnects forever with exponential backoff + jitter
 * (capped) until `close()` is called or the server answers 401.
 */
export function connectEvents({ onEvent, onStatus }) {
  let closed = false;
  let delay = INITIAL_DELAY_MS;
  let controller = null;

  async function loop() {
    while (!closed) {
      controller = new AbortController();
      onStatus("connecting");
      try {
        const response = await fetch("/v1/events", {
          headers: { Authorization: `Bearer ${getToken()}`, Accept: "text/event-stream" },
          signal: controller.signal
        });

        if (response.status === 401) {
          window.dispatchEvent(new CustomEvent("pi:unauthorized"));
          onStatus("offline");
          return; // stop retrying until the user signs in again
        }
        if (!response.ok || !response.body) throw new Error(`stream failed (${response.status})`);

        onStatus("online");
        delay = INITIAL_DELAY_MS; // a successful connect resets backoff
        await readFrames(response.body, onEvent);
        if (closed) return;
        delay = INITIAL_DELAY_MS; // the stream also ended cleanly: reconnect promptly, not slowly
      } catch {
        if (closed) return;
        onStatus("offline");
      }
      await sleep(withJitter(delay));
      delay = Math.min(delay * 2, MAX_DELAY_MS);
    }
  }

  loop();
  return {
    close() {
      closed = true;
      controller?.abort();
    }
  };
}

/** Parses the `text/event-stream` wire format: fields separated by `\n`, events by a blank line. */
async function readFrames(body, onEvent) {
  const reader = body.getReader();
  const decoder = new TextDecoder("utf-8");
  let buffer = "";
  let eventName = "message";
  let dataLines = [];

  const dispatch = () => {
    if (!dataLines.length) return;
    const raw = dataLines.join("\n");
    dataLines = [];
    let payload = raw;
    try {
      payload = JSON.parse(raw);
    } catch {
      /* non-JSON payload (e.g. a keep-alive with data): pass the raw string through */
    }
    onEvent(eventName, payload);
    eventName = "message";
  };

  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      dispatch();
      return;
    }
    buffer += decoder.decode(value, { stream: true });

    let newline;
    while ((newline = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newline).replace(/\r$/, "");
      buffer = buffer.slice(newline + 1);
      if (line === "") {
        dispatch();
        continue;
      }
      if (line.startsWith(":")) continue; // comment / keep-alive
      const colon = line.indexOf(":");
      const field = colon === -1 ? line : line.slice(0, colon);
      const fieldValue = colon === -1 ? "" : line.slice(colon + 1).replace(/^ /, "");
      if (field === "event") eventName = fieldValue;
      else if (field === "data") dataLines.push(fieldValue);
      // "id" and "retry" are valid SSE fields; this client has no use for either yet.
    }
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function withJitter(ms) {
  return Math.round(ms * (0.75 + Math.random() * 0.5));
}
