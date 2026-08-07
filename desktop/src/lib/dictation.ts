// Speaking instead of typing.
//
// The recogniser is the system's, running on this machine. The app only
// starts and stops it and assembles what comes back: `volatile` text is the
// tail still being revised and replaces the last one, `final` text is settled
// and is kept.

import { useCallback, useEffect, useRef, useState } from "react";
import { inTauri } from "./desktop";

type Heard =
  | { kind: "volatile"; text: string }
  | { kind: "final"; text: string }
  | { kind: "error"; message: string }
  | { kind: "stopped" };

async function invoke<T>(command: string, args?: Record<string, unknown>) {
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(command, args);
}

/// Every composer on screen that can be dictated into, newest last.
///
/// The chord goes to the one you are typing in. When focus is somewhere else
/// entirely it goes to the newest, which is the task dialog if one is open
/// and the message box otherwise — the same thing you would have clicked.
type Composer = { within: () => HTMLElement | null; toggle: () => void };
const composers: Composer[] = [];

export function toggleDictation() {
  const active = document.activeElement;
  const focused = composers.find((composer) => {
    const node = composer.within();
    return !!node && !!active && node.contains(active);
  });
  (focused ?? composers[composers.length - 1])?.toggle();
}

/// Dictate into a field. `onText` is handed the whole value the field should
/// show, so the caller never has to reason about which words are settled.
export function useDictation(onText: (text: string) => void) {
  const [supported, setSupported] = useState(false);
  /// The box this button belongs to, so the chord can tell which composer is
  /// being typed in.
  const within = useRef<HTMLElement | null>(null);
  const latestToggle = useRef(() => {});
  const [recording, setRecording] = useState(false);
  const [error, setError] = useState("");
  const base = useRef("");
  const settled = useRef("");
  const latest = useRef(onText);
  latest.current = onText;

  useEffect(() => {
    if (!inTauri) return;
    void invoke<boolean>("dictation_supported").then(setSupported).catch(() => {});
  }, []);

  useEffect(() => {
    if (!inTauri || !recording) return;
    let stop: (() => void) | undefined;
    void (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      const unlisten = await listen<Heard>("dictation", ({ payload }) => {
        // A space between what was said before and what is being said now,
        // but never a leading one: dictation into an empty box should not
        // start with a gap.
        const join = (...parts: string[]) =>
          parts.filter((part) => part.trim().length > 0).join(" ");
        switch (payload.kind) {
          case "volatile":
            latest.current(join(base.current, settled.current, payload.text));
            break;
          case "final":
            settled.current = join(settled.current, payload.text);
            latest.current(join(base.current, settled.current));
            break;
          case "error":
            setError(payload.message);
            setRecording(false);
            break;
          case "stopped":
            setRecording(false);
            break;
        }
      });
      stop = unlisten;
    })();
    return () => stop?.();
  }, [recording]);

  useEffect(() => {
    const composer: Composer = {
      within: () => within.current,
      toggle: () => latestToggle.current(),
    };
    composers.push(composer);
    return () => {
      const at = composers.indexOf(composer);
      if (at >= 0) composers.splice(at, 1);
    };
  }, []);

  const start = useCallback((current: string) => {
    base.current = current;
    settled.current = "";
    setError("");
    setRecording(true);
    void invoke("dictation_start", { locale: navigator.language }).catch(
      (err: unknown) => {
        setError(String((err as Error).message ?? err));
        setRecording(false);
      },
    );
  }, []);

  const stop = useCallback(() => {
    void invoke("dictation_stop").catch(() => {});
    setRecording(false);
  }, []);

  return { supported, recording, error, start, stop, within, latestToggle };
}
