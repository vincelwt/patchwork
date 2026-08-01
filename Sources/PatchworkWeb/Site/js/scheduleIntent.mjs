import { newClientId } from "./clientId.mjs";
import { createDurableMutationIntentStore } from "./durableIntent.mjs";

const CREATE_SCOPE = "create";

function canonicalScheduleRequest(body) {
  if (!body || typeof body !== "object") return null;
  const { idempotencyKey: _ignored, ...request } = body;
  return request;
}

function validScheduleRequest(body) {
  return !!body && typeof body === "object"
    && typeof body.name === "string" && body.name.trim().length > 0
    && typeof body.prompt === "string" && body.prompt.trim().length > 0
    && body.target && typeof body.target === "object"
    && body.trigger && typeof body.trigger === "object";
}

function canonicalRunBody(body) {
  return { scheduleId: String(body?.scheduleId || "") };
}

function validScheduleID(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 256
    && !/[\u0000-\u001f\u007f]/.test(value);
}

export function createScheduleCreationIntentStore(options = {}) {
  return createDurableMutationIntentStore({
    storageKey: "patchwork-schedule-create-intent-v1",
    maxEntries: 1,
    maxBytes: 2 * 1024 * 1024,
    maxBodyBytes: 1_500_000,
    canonicalize: canonicalScheduleRequest,
    validateScope: (scope) => scope === CREATE_SCOPE,
    validateBody: validScheduleRequest,
    idFactory: () => newClientId("web-schedule"),
    requestLabel: "schedule creation request",
    reviewInstruction: "Review the schedule list before resetting this saved request.",
    ...options
  });
}

export function createScheduleRunIntentStore(options = {}) {
  return createDurableMutationIntentStore({
    storageKey: "patchwork-schedule-run-intents-v1",
    maxEntries: 32,
    maxBytes: 256 * 1024,
    maxBodyBytes: 4 * 1024,
    canonicalize: canonicalRunBody,
    validateScope: validScheduleID,
    validateBody: (body) => validScheduleID(body?.scheduleId),
    validateReservation: (scope, body) => scope === body.scheduleId,
    idFactory: () => newClientId("web-run"),
    requestLabel: "manual run request",
    reviewInstruction: "Review this schedule's run history before resetting the saved request.",
    ...options
  });
}

export const scheduleCreationIntents = createScheduleCreationIntentStore();
export const scheduleRunIntents = createScheduleRunIntentStore();
export const scheduleCreationScope = CREATE_SCOPE;
