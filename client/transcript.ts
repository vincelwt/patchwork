import type { Id, Message } from "./types";

export interface TranscriptFolding {
  /// Status lines a later reading from the same run has already replaced.
  superseded: Set<Id>;
  /// Message id → the run whose activity that row anchors. At most one row
  /// per run, so a run that posted a card and a reply logs itself once.
  traces: Map<Id, Id>;
}

/// What a transcript shows of an agent's working-out.
///
/// "Cloning the repo", "Reading the diff", "Writing the fix" is one agent
/// getting on with it, and by the time you read the reply only the last of
/// them was ever true. Default reading keeps that last one and leaves the rest
/// to the run log; Show work puts every line back and hangs the log itself off
/// each run card. Nothing anyone said is ever folded away either way.
export function foldTranscript(
  messages: Message[],
  showWork: boolean,
): TranscriptFolding {
  const superseded = new Set<Id>();
  const traces = new Map<Id, Id>();

  if (showWork) {
    const traced = new Set<Id>();
    for (const message of messages) {
      const card = message.kind === "card" ? message.card : undefined;
      if (card?.type !== "run" || traced.has(card.run_id)) continue;
      traced.add(card.run_id);
      traces.set(message.id, card.run_id);
    }
    return { superseded, traces };
  }

  // Backwards, so the one kept is the newest — and so a run whose statuses are
  // interleaved with another's still keeps its own latest line.
  const seen = new Set<Id>();
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.kind !== "status" || !message.run_id) continue;
    if (seen.has(message.run_id)) superseded.add(message.id);
    else seen.add(message.run_id);
  }
  return { superseded, traces };
}
