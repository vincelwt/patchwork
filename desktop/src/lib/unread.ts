// Which conversations have moved since you last looked at them.
//
// The relay has no read cursor — it knows what needs you (that is the Inbox),
// not what you have merely seen. So "seen" is a property of this machine, kept
// here, and deliberately coarse: a timestamp per channel. That is enough for
// the two signals the sidebar actually needs — *something happened here* and
// *this one is asking for you* — without pretending to a precision the data
// cannot support.

import { useSyncExternalStore } from "react";
import type { Channel, Id } from "@client/types";

const KEY = "patchwork.seen";

type Seen = Record<Id, number>;

function load(): Seen {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? "{}") as Seen;
  } catch {
    return {};
  }
}

let seen: Seen = load();
const listeners = new Set<() => void>();

function publish() {
  localStorage.setItem(KEY, JSON.stringify(seen));
  listeners.forEach((listener) => listener());
}

export function markSeen(channelId: Id, at: number = Date.now()) {
  if ((seen[channelId] ?? 0) >= at) return;
  seen = { ...seen, [channelId]: at };
  publish();
}

/// A workspace you have just joined should not open with everything shouting.
export function markEverythingSeen(channels: Channel[]) {
  const now = Date.now();
  seen = { ...seen };
  for (const channel of channels) seen[channel.id] = now;
  publish();
}

export function useSeen(): Seen {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => seen,
  );
}

export function hasUnseen(channel: Channel, seenMap: Seen, myId?: Id): boolean {
  if (!channel.last_message_at) return false;
  const at = seenMap[channel.id];
  // Never opened: only shout if there is actually something in it.
  if (at === undefined) return channel.kind !== "task";
  void myId;
  return channel.last_message_at > at;
}
