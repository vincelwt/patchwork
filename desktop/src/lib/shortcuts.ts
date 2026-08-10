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

/// The three columns of the app, left to right, and what counts as a row in
/// each. ↑ ↓ walk the rows of the pane you are in, ← → step between the panes,
/// so the sidebar, the conversation and the side panel are all reachable
/// without a mouse. Everything else inside a pane stays reachable with Tab, the
/// way it always was.
const PANES = [
  {
    pane: "aside.sidebar",
    rows: "button.nav-item, button.group-label, button.footer-button",
  },
  {
    pane: ".content > .column",
    rows: "button.inbox-row, button.row, .task-card, .message",
  },
  { pane: "aside.inspector", rows: "button.row, .message" },
];
const MAIN = 1;

/// A dialog, a menu or a dropdown owns the arrow keys while it is open.
const overlaid = () =>
  document.querySelector(".modal-backdrop, .menu, .dropdown-menu") !== null;

/// Focus a row and bring it into view. The scroll is ours rather than the one
/// `focus()` does by itself, because that one ignores `scroll-margin` — which is
/// what keeps a message clear of the composer floating over the transcript.
function land(row: HTMLElement) {
  row.focus({ preventScroll: true });
  const show = () => row.scrollIntoView({ block: "nearest" });
  requestAnimationFrame(show);
  // A virtualised transcript is still re-anchoring itself a few frames later, so
  // the newest message would come to rest under the box you just left. Asking
  // again once it has settled costs nothing when nothing needs to move.
  setTimeout(show, 200);
}

const rowsIn = (index: number) => [
  ...(document
    .querySelector(PANES[index].pane)
    ?.querySelectorAll<HTMLElement>(PANES[index].rows) ?? []),
];

/// Which pane the focus is in. Nothing focused means the main column, so the
/// first ↓ after a page opens walks that page's list rather than the sidebar.
function focusedPane(): number {
  const at = document.activeElement;
  const found = PANES.findIndex((entry) => at?.closest(entry.pane));
  return found === -1 ? MAIN : found;
}

/// Move the selection one row down (`1`) or up (`-1`), and say whether there
/// was a list to move in.
///
/// Focus *is* the selection. The rows are already buttons with a focus ring, so
/// there is no per-page selected-index state to keep in sync, Enter opens the
/// focused row on its own, and the very first press works the moment a page
/// opens — nothing has to be clicked to "activate" the list first.
export function moveRowFocus(step: 1 | -1): boolean {
  if (overlaid()) return false;
  const rows = rowsIn(focusedPane());
  if (rows.length === 0) return false;
  const at = rows.indexOf(document.activeElement as HTMLElement);
  // Nothing focused yet: down starts at the top of the list, up at the bottom.
  const next = at === -1 ? (step === 1 ? 0 : rows.length - 1) : at + step;
  land(rows[Math.min(Math.max(next, 0), rows.length - 1)]);
  return true;
}

/// Esc in a message box hands the keyboard back to navigation. It lands on the
/// newest message of the same pane — the thread panel keeps its own — so ↑
/// carries on reading upwards from where you stopped writing.
export function leaveComposer(box: HTMLElement) {
  box.blur();
  const pane = PANES.findIndex((entry) => box.closest(entry.pane));
  const last = rowsIn(pane === -1 ? MAIN : pane).at(-1);
  if (last) land(last);
}

/// Step to the pane on the left (`-1`) or the right (`1`), landing on what that
/// pane is already showing as current: the open channel in the sidebar, the
/// message box in a conversation, otherwise its first row. Panes that are not
/// on screen are skipped, and running out of panes leaves the key alone.
export function movePane(step: 1 | -1): boolean {
  if (overlaid()) return false;
  for (let index = focusedPane() + step; index >= 0 && index < PANES.length; index += step) {
    const root = document.querySelector(PANES[index].pane);
    const target =
      root?.querySelector<HTMLElement>(".nav-item.active, .composer textarea") ??
      rowsIn(index)[0];
    if (!target) continue;
    land(target);
    return true;
  }
  return false;
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
