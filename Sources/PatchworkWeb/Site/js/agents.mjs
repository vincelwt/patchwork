/**
 * The agents this build knows how to label. The daemon is the source of truth for which agent a
 * thread belongs to; this is only presentation.
 */
export const AGENTS = [
  { id: "pi", label: "Pi" },
  { id: "codex", label: "Codex" },
  { id: "claude", label: "Claude" }
];

/**
 * Short badge text for a thread's agent. An agent a newer daemon knows about is shown by its raw
 * name (bounded) rather than hidden or mislabelled as Pi.
 */
export function agentLabel(agent) {
  if (!agent) return "Pi";
  const known = AGENTS.find((candidate) => candidate.id === agent);
  return known ? known.label : String(agent).slice(0, 12);
}

/** Pi is the historical default, so its badge is redundant noise on a Pi-only machine. */
export function shouldShowAgentBadge(agent) {
  return Boolean(agent) && agent !== "pi";
}

/** Mutation capabilities that differ on the remote surface today. Unknown agents fail closed. */
export function canRenameSession(agent) {
  return agent === "pi" || agent === "codex" || agent === "claude" || !agent;
}

export function canChangeThinking(agent) {
  return agent === "pi" || agent === "codex" || !agent;
}
