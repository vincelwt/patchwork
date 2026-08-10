// One place that knows every keyboard shortcut in the app.
//
// Two rules make this work. Nothing fires while you are typing, unless it is a
// chord with a modifier — otherwise `g` would leave the channel mid-sentence.
// And every entry carries the label the help sheet and the command palette
// show, so a shortcut cannot exist without being documented somewhere a person
// can find it.

export interface Shortcut {
  id: string;
  /// Displayed form, e.g. "⌘K" or "G then I".
  keys: string;
  label: string;
  group: "Go to" | "Create" | "Do" | "View";
  /// Does this key event trigger it?
  match: (event: KeyboardEvent, pending: string) => boolean;
  /// A leading key that arms this shortcut, e.g. `g` in "g then i".
  chord?: string;
  run: () => void;
}

const mod = (event: KeyboardEvent) => event.metaKey || event.ctrlKey;

export function combo(key: string, options: { shift?: boolean } = {}) {
  return (event: KeyboardEvent) =>
    mod(event) &&
    event.key.toLowerCase() === key &&
    (options.shift ? event.shiftKey : !event.shiftKey);
}

export function chord(lead: string, key: string) {
  return (event: KeyboardEvent, pending: string) =>
    pending === lead && !mod(event) && event.key.toLowerCase() === key;
}

/// Rows a list can walk: the buttons the inbox and the pages draw, plus the
/// cards on the task board. Scoped to the main column so the arrow keys never
/// wander into the sidebar or the side panel.
const ROWS = "button.inbox-row, button.row, .task-card";

/// Move the selection one row down (`1`) or up (`-1`), and say whether there
/// was a list to move in.
///
/// Focus *is* the selection. The rows are already buttons with a focus ring, so
/// there is no per-page selected-index state to keep in sync, Enter opens the
/// focused row on its own, and the very first press works the moment a page
/// opens — nothing has to be clicked to "activate" the list first.
export function moveRowFocus(step: 1 | -1): boolean {
  // A dialog, a menu or a dropdown owns the arrow keys while it is open.
  if (document.querySelector(".modal-backdrop, .menu, .dropdown-menu")) return false;
  const main = document.querySelector(".content > .column");
  const rows = [...(main?.querySelectorAll<HTMLElement>(ROWS) ?? [])];
  if (rows.length === 0) return false;
  const at = rows.indexOf(document.activeElement as HTMLElement);
  // Nothing focused yet: down starts at the top of the list, up at the bottom.
  const next = at === -1 ? (step === 1 ? 0 : rows.length - 1) : at + step;
  rows[Math.min(Math.max(next, 0), rows.length - 1)].focus();
  return true;
}

export function isTyping(target: EventTarget | null): boolean {
  const element = target as HTMLElement | null;
  if (!element) return false;
  const tag = element.tagName;
  return (
    tag === "INPUT" ||
    tag === "TEXTAREA" ||
    tag === "SELECT" ||
    element.isContentEditable
  );
}
