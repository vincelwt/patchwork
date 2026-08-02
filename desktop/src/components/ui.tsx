// The shared shell vocabulary: page scaffolding, a real dropdown, and empty
// states. Every page uses these so the app reads as one thing rather than a
// dozen hand-rolled headers.

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
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

export interface MenuItem {
  key: string;
  label: string;
  hint?: string;
  icon?: ReactNode;
  shortcut?: string;
  danger?: boolean;
  disabled?: boolean;
  onSelect: () => void;
}

/// A popover menu anchored to whatever opened it. This is where "how do I add
/// one of these" gets answered: a create menu, a row's overflow, a workspace
/// menu. Modals were doing this job and a modal is far too much ceremony for
/// picking one of five things.
export function Menu({
  items,
  onClose,
  align = "left",
  header,
  footer,
}: {
  items: (MenuItem | "separator")[];
  onClose: () => void;
  align?: "left" | "right";
  header?: string;
  footer?: ReactNode;
}) {
  const root = useRef<HTMLDivElement>(null);
  const [active, setActive] = useState(0);

  // Keyboard position is by selectable item, but rendering walks every entry
  // including separators and disabled rows. Resolving the mapping up front is
  // what keeps "the third one down" meaning the same thing to both.
  const rows = useMemo(() => {
    let cursor = -1;
    return items.map((item) => {
      const selectable = item !== "separator" && !item.disabled;
      if (selectable) cursor += 1;
      return { item, index: selectable ? cursor : -1 };
    });
  }, [items]);
  const selectable = rows
    .filter((row) => row.index >= 0)
    .map((row) => row.item as MenuItem);

  useEffect(() => {
    const onDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) onClose();
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onClose();
      } else if (event.key === "ArrowDown") {
        event.preventDefault();
        setActive((index) => Math.min(index + 1, selectable.length - 1));
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        setActive((index) => Math.max(index - 1, 0));
      } else if (event.key === "Enter") {
        event.preventDefault();
        const item = selectable[active];
        if (item) {
          onClose();
          item.onSelect();
        }
      }
    };
    // Capture, so a menu inside a modal closes the menu and not the modal.
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey, true);
    };
  }, [onClose, active, selectable.length]);

  return (
    <div className={`menu ${align}`} ref={root}>
      {header && <div className="menu-header">{header}</div>}
      {rows.map(({ item, index }, at) => {
        if (item === "separator") return <div className="menu-separator" key={at} />;
        const isActive = index === active && index >= 0;
        return (
          <button
            key={item.key}
            className={`menu-item${item.danger ? " danger" : ""}${isActive ? " active" : ""}`}
            disabled={item.disabled}
            onMouseEnter={() => index >= 0 && setActive(index)}
            onClick={() => {
              onClose();
              item.onSelect();
            }}
          >
            {item.icon && <span className="menu-icon">{item.icon}</span>}
            <span className="grow">
              <span className="name">{item.label}</span>
              {item.hint && <span className="sub">{item.hint}</span>}
            </span>
            {item.shortcut && <KeyHint keys={item.shortcut} />}
          </button>
        );
      })}
      {footer}
    </div>
  );
}

/// Trigger plus menu, for the common case where the button is the anchor.
export function MenuButton({
  children,
  items,
  align = "left",
  className = "icon-button",
  title,
  header,
}: {
  children: ReactNode;
  items: (MenuItem | "separator")[];
  align?: "left" | "right";
  className?: string;
  title?: string;
  header?: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <div className="menu-anchor">
      <button
        className={`${className}${open ? " open" : ""}`}
        title={title}
        onClick={(event) => {
          event.stopPropagation();
          setOpen(!open);
        }}
      >
        {children}
      </button>
      {open && (
        <Menu
          items={items}
          align={align}
          header={header}
          onClose={() => setOpen(false)}
        />
      )}
    </div>
  );
}

/// `⌘⇧K` as keycaps rather than as a string of punctuation in a sentence.
export function KeyHint({ keys }: { keys: string }) {
  return (
    <span className="keyhint">
      {keys.split(" ").map((chord, index) => (
        <kbd key={index}>{chord}</kbd>
      ))}
    </span>
  );
}

/// Text you rename by clicking it. Used for task titles, channel topics and
/// anything else where "open a dialog to change one word" is the wrong weight.
export function EditableText({
  value,
  onCommit,
  placeholder = "Untitled",
  className = "",
  multiline,
  title = "Click to edit",
}: {
  value: string;
  onCommit: (value: string) => void;
  placeholder?: string;
  className?: string;
  multiline?: boolean;
  title?: string;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value);
  const input = useRef<HTMLTextAreaElement | HTMLInputElement>(null);

  useEffect(() => {
    if (!editing) setDraft(value);
  }, [value, editing]);

  useEffect(() => {
    if (editing) {
      input.current?.focus();
      if (input.current instanceof HTMLInputElement) input.current.select();
    }
  }, [editing]);

  const commit = () => {
    setEditing(false);
    const next = draft.trim();
    if (next && next !== value) onCommit(next);
    else setDraft(value);
  };

  if (!editing) {
    return (
      <button
        className={`editable ${className}`.trim()}
        title={title}
        onClick={() => setEditing(true)}
      >
        {value || <span className="placeholder">{placeholder}</span>}
      </button>
    );
  }

  const shared = {
    className: `editable-input ${className}`.trim(),
    value: draft,
    placeholder,
    onBlur: commit,
    onChange: (event: { target: { value: string } }) => setDraft(event.target.value),
    onKeyDown: (event: React.KeyboardEvent) => {
      if (event.key === "Escape") {
        setDraft(value);
        setEditing(false);
      } else if (event.key === "Enter" && (!multiline || event.metaKey)) {
        event.preventDefault();
        commit();
      }
    },
  };

  return multiline ? (
    <textarea
      {...shared}
      ref={input as React.RefObject<HTMLTextAreaElement>}
      rows={2}
    />
  ) : (
    <input {...shared} ref={input as React.RefObject<HTMLInputElement>} />
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
