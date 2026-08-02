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
