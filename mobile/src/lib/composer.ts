import type { Id } from "@client/types";

export function composerKey(channelId: Id, parentId?: Id) {
  return parentId ? `thread:${parentId}` : channelId;
}
