import { createContext, useContext, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { avatarStyle, initials } from "../lib/format";
import type { Id, Member, Presence } from "../lib/types";

export type View =
  | { kind: "inbox" }
  | { kind: "tasks" }
  | { kind: "channel"; id: Id }
  | { kind: "task"; id: Id }
  | { kind: "agents" }
  | { kind: "projects" }
  | { kind: "members" }
  | { kind: "automations" }
  | { kind: "automation"; id: Id }
  | { kind: "settings" }
  | { kind: "search"; query: string };

export type Inspector =
  | { kind: "thread"; messageId: Id }
  | { kind: "run"; runId: Id }
  | { kind: "task"; taskId: Id }
  | null;

interface Navigation {
  view: View;
  go: (view: View) => void;
  inspector: Inspector;
  inspect: (inspector: Inspector) => void;
  toast: (message: string) => void;
}

export const NavigationContext = createContext<Navigation>({
  view: { kind: "inbox" },
  go: () => {},
  inspector: null,
  inspect: () => {},
  toast: () => {},
});

export const useNavigation = () => useContext(NavigationContext);

/// Agents are circles, people are squircles — the shape says which kind of
/// teammate this is before you have read the name. `presence` adds the live
/// dot, and is off by default because most avatars are historical (who said
/// this, three days ago) rather than a statement about right now.
export function Avatar({
  member,
  size = 26,
  presence,
}: {
  member?: Member;
  size?: number;
  presence?: boolean;
}) {
  const isAgent = member?.kind === "agent";
  const avatar = (
    <div
      className={`avatar${isAgent ? " agent" : ""}${member ? "" : " unknown"}`}
      style={{
        ...avatarStyle(member),
        width: size,
        height: size,
        fontSize: Math.round(size * 0.4),
        borderRadius: isAgent ? 999 : Math.max(5, Math.round(size * 0.28)),
      }}
      title={member?.display_name}
    >
      {initials(member)}
    </div>
  );

  if (!presence || !member) return avatar;
  return (
    <span className="avatar-wrap" style={{ width: size, height: size }}>
      {avatar}
      <span
        className={`presence-badge ${member.presence}`}
        style={{ width: Math.max(7, size * 0.3), height: Math.max(7, size * 0.3) }}
      />
    </span>
  );
}

export function PresenceDot({ presence }: { presence: Presence }) {
  return <span className={`dot ${presence}`} />;
}


export function Chip({
  tone = "",
  children,
  title,
}: {
  tone?: string;
  children: ReactNode;
  title?: string;
}) {
  return (
    <span className={`chip ${tone}`.trim()} title={title}>
      {children}
    </span>
  );
}

export function Modal({
  title,
  subtitle,
  children,
  onClose,
  actions,
}: {
  title: string;
  subtitle?: string;
  children: ReactNode;
  onClose: () => void;
  actions?: ReactNode;
}) {
  const root = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
        return;
      }
      // ⌘↵ does what the dialog is for, from anywhere inside it — including
      // the textarea, where ↵ is a new line. Every dialog here ends in one
      // primary button, so pressing it is the whole implementation: no dialog
      // has to remember to opt in, and none can disagree about what ⌘↵ means.
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
        const primary = root.current?.querySelector<HTMLButtonElement>(
          ".modal-actions .button.primary",
        );
        if (primary && !primary.disabled) {
          event.preventDefault();
          primary.click();
        }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="modal-backdrop" onMouseDown={onClose}>
      <div
        className="modal"
        ref={root}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="modal-head">
          <h2>{title}</h2>
          {subtitle && <p className="sub">{subtitle}</p>}
        </div>
        <div className="modal-body">{children}</div>
        {actions && <div className="modal-actions">{actions}</div>}
      </div>
    </div>
  );
}

/// Most fields in this app hold identifiers — channel names, handles, paths,
/// commands, search terms. macOS "correcting" `support` to `Support` there is a
/// bug, not a favour, so single-line fields opt out of the lot and prose fields
/// keep only the spell checker.
export const plainText = {
  autoCorrect: "off",
  autoCapitalize: "off",
  spellCheck: false,
} as const;

/// Prose that still contains names and paths: check the spelling, change nothing.
export const proseText = { autoCorrect: "off", autoCapitalize: "sentences" } as const;

export function Field({
  label,
  value,
  onChange,
  placeholder,
  textarea,
  autoFocus,
  inputRef,
  type = "text",
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  textarea?: boolean;
  autoFocus?: boolean;
  inputRef?: React.RefObject<HTMLTextAreaElement | null>;
  type?: string;
}) {
  return (
    <div className="form-row">
      <label>{label}</label>
      {textarea ? (
        <textarea
          className="field"
          {...proseText}
          ref={inputRef}
          value={value}
          placeholder={placeholder}
          autoFocus={autoFocus}
          onChange={(event) => onChange(event.target.value)}
        />
      ) : (
        <input
          className="field"
          {...plainText}
          type={type}
          value={value}
          placeholder={placeholder}
          autoFocus={autoFocus}
          onChange={(event) => onChange(event.target.value)}
        />
      )}
    </div>
  );
}


/// Small helper for the many "load this on mount" panels.
export function useAsync<T>(load: () => Promise<T>, deps: unknown[]) {
  const [value, setValue] = useState<T | undefined>();
  const [error, setError] = useState<string | undefined>();
  useEffect(() => {
    let cancelled = false;
    load()
      .then((result) => !cancelled && setValue(result))
      .catch((err) => !cancelled && setError(String(err.message ?? err)));
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return { value, error, setValue };
}
