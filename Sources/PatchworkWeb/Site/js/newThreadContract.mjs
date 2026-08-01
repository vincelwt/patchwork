const PROMPT_BACKED_AGENT = "claude";

export const FIRST_MESSAGE_REQUIRED_ERROR =
  "Claude needs a first message before this thread can be created.";

export const PROTECTED_CREATION_REQUIRED_ERROR =
  "This Patchwork version cannot safely create threads from the browser. Update Patchwork and try again.";

export function requiresFirstMessage(agent) {
  return agent === PROMPT_BACKED_AGENT;
}

export function firstMessagePresentation(agent) {
  if (requiresFirstMessage(agent)) {
    return {
      required: true,
      label: "First message (required)",
      placeholder: "Describe what you want Claude to do",
      hint: "Claude starts the thread with this message."
    };
  }
  return {
    required: false,
    label: "First message (optional)",
    placeholder: "Leave blank to create an idle thread",
    hint: "You can start this thread now and send a message later."
  };
}

export function firstMessageValidationError(agent, message) {
  return requiresFirstMessage(agent) && !String(message ?? "").trim()
    ? FIRST_MESSAGE_REQUIRED_ERROR
    : null;
}

export function supportsProtectedThreadCreation(health) {
  return health?.threadCreationIdempotency === true;
}
