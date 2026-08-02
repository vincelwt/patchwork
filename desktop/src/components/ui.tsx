// The shared shell vocabulary: page scaffolding, a real dropdown, and empty
// states. Every page uses these so the app reads as one thing rather than a
// dozen hand-rolled headers.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { ChevronIcon } from "./icons";

export function Page({
  title,
  subtitle,
  back,
  actions,
  children,
  wide,
  scroll = true,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  back?: { label: string; onClick: () => void };
  actions?: ReactNode;
  children: ReactNode;
  wide?: boolean;
  scroll?: boolean;
}) {
  return (
    <div className="column">
      <div className="topbar">
        {back && (
          <button className="button quiet" onClick={back.onClick}>
            ‹ {back.label}
          </button>
        )}
        <span className="title">{title}</span>
        {subtitle && <span className="subtitle">{subtitle}</span>}
        <span className="spacer" />
        {actions}
      </div>
      {scroll ? (
        <div className="page">
          <div className={`page-inner${wide ? " wide" : ""}`}>{children}</div>
        </div>
      ) : (
        children
      )}
    </div>
  );
}

export function Section({
  title,
  action,
  children,
}: {
  title: string;
  action?: ReactNode;
  children: ReactNode;
}) {
  return (
    <>
      <div className="section-head">
        <span className="section-title">{title}</span>
        <span className="spacer" />
        {action}
      </div>
      {children}
    </>
  );
}

export function Empty({
  title,
  hint,
  action,
}: {
  title: string;
  hint?: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <div className="empty-title">{title}</div>
      {hint && <div className="empty-hint">{hint}</div>}
      {action && <div style={{ marginTop: 16 }}>{action}</div>}
    </div>
  );
}

export interface Option {
  value: string;
  label: string;
  hint?: string;
}

/// A dropdown that belongs to this app rather than to the platform: native
/// selects bring their own chrome, sizing and focus ring, and none of it
/// matches anything else here.
export function Dropdown({
  value,
  options,
  onChange,
  placeholder = "Select",
  align = "left",
  quiet,
  width,
}: {
  value: string;
  options: Option[];
  onChange: (value: string) => void;
  placeholder?: string;
  align?: "left" | "right";
  quiet?: boolean;
  width?: number;
}) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const current = options.find((option) => option.value === value);

  useEffect(() => {
    if (!open) return;
    const onDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  // Flip upward when there is no room below.
  useLayoutEffect(() => {
    const menu = list.current;
    if (!open || !menu) return;
    const rect = menu.getBoundingClientRect();
    if (rect.bottom > window.innerHeight - 8) {
      menu.style.bottom = "calc(100% + 4px)";
      menu.style.top = "auto";
    }
  }, [open]);

  return (
    <div className="dropdown" ref={root} style={width ? { width } : undefined}>
      <button
        className={`dropdown-trigger${quiet ? " quiet" : ""}${open ? " open" : ""}`}
        onClick={() => setOpen(!open)}
      >
        <span className="dropdown-value">{current?.label ?? placeholder}</span>
        <ChevronIcon size={13} />
      </button>
      {open && (
        <div className={`dropdown-menu ${align}`} ref={list}>
          {options.map((option) => (
            <button
              key={option.value}
              className={`dropdown-option${option.value === value ? " selected" : ""}`}
              onClick={() => {
                onChange(option.value);
                setOpen(false);
              }}
            >
              <span className="grow">
                <span className="name">{option.label}</span>
                {option.hint && <span className="sub">{option.hint}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export function FormSelect({
  label,
  help,
  ...props
}: Parameters<typeof Dropdown>[0] & { label: string; help?: string }) {
  return (
    <div className="form-row">
      <label>{label}</label>
      <Dropdown {...props} />
      {help && <span className="form-help">{help}</span>}
    </div>
  );
}

export function Toggle({
  checked,
  onChange,
  label,
  help,
}: {
  checked: boolean;
  onChange: (checked: boolean) => void;
  label: string;
  help?: string;
}) {
  return (
    <button className="toggle-row" onClick={() => onChange(!checked)}>
      <span className="grow">
        <span className="name">{label}</span>
        {help && <span className="sub">{help}</span>}
      </span>
      <span className={`switch${checked ? " on" : ""}`}>
        <span className="knob" />
      </span>
    </button>
  );
}
