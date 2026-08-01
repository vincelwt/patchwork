import { createContext, useContext, useEffect, useState } from "react";
import type { ReactNode } from "react";
import { initials } from "../lib/format";
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

export function Avatar({ member, size = 26 }: { member?: Member; size?: number }) {
  const isAgent = member?.kind === "agent";
  return (
    <div
      className={`avatar${isAgent ? " agent" : ""}`}
      style={{ width: size, height: size, fontSize: size * 0.44 }}
      title={member?.display_name}
    >
      {initials(member)}
    </div>
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
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="modal-backdrop" onMouseDown={onClose}>
      <div className="modal" onMouseDown={(event) => event.stopPropagation()}>
        <h2>{title}</h2>
        {subtitle && <p className="sub">{subtitle}</p>}
        {children}
        {actions && <div className="modal-actions">{actions}</div>}
      </div>
    </div>
  );
}

export function Field({
  label,
  value,
  onChange,
  placeholder,
  textarea,
  autoFocus,
  type = "text",
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  textarea?: boolean;
  autoFocus?: boolean;
  type?: string;
}) {
  return (
    <div className="form-row">
      <label>{label}</label>
      {textarea ? (
        <textarea
          className="field"
          value={value}
          placeholder={placeholder}
          autoFocus={autoFocus}
          onChange={(event) => onChange(event.target.value)}
        />
      ) : (
        <input
          className="field"
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

export function Select({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  options: { value: string; label: string }[];
}) {
  return (
    <div className="form-row">
      <label>{label}</label>
      <select
        className="field"
        value={value}
        onChange={(event) => onChange(event.target.value)}
      >
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
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
