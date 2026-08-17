import type { Id } from "./types";

export interface SendAttempt {
  fingerprint: string;
  clientId: Id;
}

/// React state updates after the event that changed it. A ref closes the gap so
/// two taps or Enter presses cannot start the same send while it is in flight.
export function beginSend(lock: { current: boolean }): boolean {
  if (lock.current) return false;
  lock.current = true;
  return true;
}

/// An unanswered retry is the same send only while its contents are unchanged.
export function sendAttempt(
  fingerprint: string,
  previous: SendAttempt | undefined,
  makeId: () => Id,
): SendAttempt {
  return previous?.fingerprint === fingerprint
    ? previous
    : { fingerprint, clientId: makeId() };
}

export function parseSendAttempt(value: string | null): SendAttempt | undefined {
  if (!value) return;
  try {
    const attempt = JSON.parse(value) as Partial<SendAttempt>;
    if (typeof attempt.fingerprint === "string" && typeof attempt.clientId === "string") {
      return { fingerprint: attempt.fingerprint, clientId: attempt.clientId };
    }
  } catch {
    // A corrupt retry marker is expendable; the draft itself remains.
  }
}
