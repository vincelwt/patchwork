/** A bounded wire-safe id shared by browser mutation paths. */
export function newClientId(prefix = "web") {
  const random = globalThis.crypto?.randomUUID?.()
    ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return `${prefix}-${random}`.replace(/[^a-zA-Z0-9_-]/g, "-").slice(0, 64);
}
