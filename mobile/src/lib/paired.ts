/// Which workspaces this device is paired with, and which one is on screen.
///
/// A device holds one separately revocable key per workspace, so switching is
/// only a change of which key the app is using. Kept free of native imports so
/// the rules can be tested on their own.

export interface PairedSession {
  /// One workspace's own base, `{relay}/w/{workspace_id}`.
  baseUrl: string;
  /// A separately revocable token issued to this device for that workspace.
  token: string;
  /// Last known workspace name, so the switcher reads well before it connects.
  name?: string;
}

export interface Paired {
  all: PairedSession[];
  active: PairedSession | null;
}

export const NO_WORKSPACES: Paired = { all: [], active: null };

export function validSession(value: unknown, allowInsecure = false): PairedSession | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<PairedSession>;
  if (typeof candidate.baseUrl !== "string" || typeof candidate.token !== "string") {
    return null;
  }
  const token = candidate.token.trim();
  try {
    const url = new URL(candidate.baseUrl);
    if (url.protocol !== "https:" && !allowInsecure) return null;
    if (!token) return null;
    const session: PairedSession = { baseUrl: url.toString().replace(/\/$/, ""), token };
    if (typeof candidate.name === "string" && candidate.name.trim()) {
      session.name = candidate.name.trim().slice(0, 120);
    }
    return session;
  } catch {
    return null;
  }
}

export function decodePaired(raw: string | null, allowInsecure = false): Paired {
  if (!raw) return NO_WORKSPACES;
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return NO_WORKSPACES;
  }
  const record = (value ?? {}) as { sessions?: unknown; active?: unknown };
  // Devices paired before multi-workspace support stored a single session alone.
  const list = Array.isArray(record.sessions) ? record.sessions : [value];
  const all: PairedSession[] = [];
  for (const entry of list) {
    const session = validSession(entry, allowInsecure);
    if (session && !all.some((existing) => existing.baseUrl === session.baseUrl)) all.push(session);
  }
  const active = all.find((session) => session.baseUrl === record.active) ?? all[0] ?? null;
  return { all, active };
}

export function encodePaired(paired: Paired): string {
  return JSON.stringify({ sessions: paired.all, active: paired.active?.baseUrl ?? "" });
}

/// Pairing the same workspace again replaces its key rather than duplicating it.
export function withSession(paired: Paired, session: PairedSession): Paired {
  const all = [...paired.all.filter((item) => item.baseUrl !== session.baseUrl), session];
  return { all, active: session };
}

export function withoutSession(paired: Paired, target: PairedSession): Paired {
  const all = paired.all.filter((item) => item.baseUrl !== target.baseUrl);
  const active = all.find((item) => item.baseUrl === paired.active?.baseUrl) ?? all[0] ?? null;
  return { all, active };
}

export function activate(paired: Paired, baseUrl: string): Paired {
  const next = paired.all.find((item) => item.baseUrl === baseUrl);
  return next ? { ...paired, active: next } : paired;
}

export function withName(paired: Paired, baseUrl: string, name: string): Paired {
  const trimmed = name.trim().slice(0, 120);
  const current = paired.all.find((item) => item.baseUrl === baseUrl);
  if (!trimmed || !current || current.name === trimmed) return paired;
  const all = paired.all.map((item) => (item.baseUrl === baseUrl ? { ...item, name: trimmed } : item));
  return { all, active: all.find((item) => item.baseUrl === paired.active?.baseUrl) ?? paired.active };
}

/// The relay host, which is what tells two same-named workspaces apart.
export function relayLabel(session: PairedSession): string {
  try {
    return new URL(session.baseUrl).host;
  } catch {
    return session.baseUrl;
  }
}

export function workspaceLabel(session: PairedSession): string {
  return session.name || relayLabel(session);
}

export function workspaceInitials(session: PairedSession): string {
  const label = workspaceLabel(session);
  const parts = label.split(/[\s._-]+/).filter(Boolean).slice(0, 2);
  return (parts.map((part) => part[0]).join("") || "?").toUpperCase();
}
