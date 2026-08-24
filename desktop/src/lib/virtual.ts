// Rendering only the part of a long conversation that is on screen.
//
// Chat messages have no fixed height: one is a word, the next is a table and a
// code block, so this measures rows as they render and remembers them. Until
// a row has been seen it contributes an estimate, which is only ever used for
// rows nobody has scrolled to yet.
//
// Measurements are filed under the message id, never under the row's position.
// History is prepended, so positions shift under rows that have not changed,
// and a position-keyed table quietly hands every row the height of whichever
// message used to sit there.
//
// Deliberately inert below a threshold: most conversations are short, and a
// virtualiser that engages at twenty messages is all risk and no benefit.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { RefObject } from "react";
import { rowOffsets, visibleRange } from "@client/scroll";

/// Below this, render everything. Chosen so that the common case, a channel
/// you have just opened with one page of history, never goes near this code.
export const VIRTUALIZE_ABOVE = 80;

/// Rows kept mounted beyond the viewport, so a flick of the wheel lands on
/// something already rendered rather than on blank space.
const OVERSCAN = 12;

export interface Window {
  start: number;
  end: number;
  padTop: number;
  padBottom: number;
  /// A `ref` for the row with this key, stable for as long as that key exists.
  /// Stability is the point: an inline `el => measure(key, el)` is a new
  /// function on every render, so React detaches and reattaches every visible
  /// row, and each reattachment used to throw away a ResizeObserver and build
  /// another.
  rowRef: (key: string) => (element: HTMLElement | null) => void;
  /// True when the window is actually narrower than the list.
  active: boolean;
}

export function useVirtualWindow(
  scroller: RefObject<HTMLElement | null>,
  /// One stable id per row, in display order. Memoise it: a fresh array on
  /// every render rebuilds the prefix sums on every render.
  keys: string[],
  estimate = 84,
): Window {
  const heights = useRef(new Map<string, number>());
  const observers = useRef(new Map<string, ResizeObserver>());
  const refs = useRef(new Map<string, (element: HTMLElement | null) => void>());
  const [measured, bump] = useState(0);
  const count = keys.length;
  const [range, setRange] = useState({ start: 0, end: count });
  const active = count > VIRTUALIZE_ABOVE;

  // Where each row starts, rebuilt whenever a measurement lands. Cheap at these
  // sizes and far easier to reason about than an incremental structure.
  const offsets = useMemo(() => {
    return rowOffsets(keys, heights.current, estimate);
    // Rebuilt when a row is measured, not when the visible range moves: the
    // sums do not depend on where you are scrolled, and rebuilding them on
    // every scroll event is a full pass over the conversation per frame.
  }, [keys, estimate, measured]);

  // Read inside `measure`, which must not be rebuilt on every scroll: a new
  // callback identity there detaches and reattaches every mounted row.
  const positions = useRef(new Map<string, number>());
  const firstVisible = useRef(0);
  positions.current = useMemo(
    () => new Map(keys.map((key, index) => [key, index])),
    [keys],
  );

  const recompute = useCallback(() => {
    const element = scroller.current;
    if (!element) return;
    const next = visibleRange(
      offsets,
      element.scrollTop,
      element.clientHeight,
      OVERSCAN,
    );
    // Wanted even when the window is inert, because it is what tells a row
    // settling above the viewport how much height it has to pay back.
    firstVisible.current = next.first;
    const start = active ? next.start : 0;
    const end = active ? next.end : count;
    // Compared rather than replaced: a fresh object every scroll event used to
    // redraw a short conversation on every wheel tick to say nothing changed.
    setRange((current) =>
      current.start === start && current.end === end ? current : { start, end },
    );
  }, [scroller, count, offsets, active]);

  useEffect(() => {
    const element = scroller.current;
    if (!element) return;
    recompute();
    element.addEventListener("scroll", recompute, { passive: true });
    return () => element.removeEventListener("scroll", recompute);
  }, [scroller, recompute]);

  // A row that changes height, an image loading or a reply streaming in, has to
  // update the sums, or everything below it drifts.
  const measure = useCallback(
    (key: string, element: HTMLElement | null) => {
      const existing = observers.current.get(key);
      if (existing) {
        existing.disconnect();
        observers.current.delete(key);
      }
      if (!element) return;

      const record = (height: number) => {
        const previous = heights.current.get(key) ?? estimate;
        if (height <= 0 || Math.abs(previous - height) <= 0.5) return;
        heights.current.set(key, height);
        // A row that settles above the viewport pushes everything below it
        // down by the difference, which drags the words being read off the
        // screen. Move the viewport by the same amount and it stays still.
        // WebKit has no scroll anchoring of its own, so nothing else will.
        const viewport = scroller.current;
        const index = positions.current.get(key);
        if (viewport && index !== undefined && index < firstVisible.current) {
          viewport.scrollTop += height - previous;
        }
        bump((n) => n + 1);
      };
      record(element.offsetHeight);
      const observer = new ResizeObserver(() => record(element.offsetHeight));
      observer.observe(element);
      observers.current.set(key, observer);
    },
    [scroller, estimate],
  );

  const rowRef = useCallback(
    (key: string) => {
      const known = refs.current.get(key);
      if (known) return known;
      const callback = (element: HTMLElement | null) => measure(key, element);
      refs.current.set(key, callback);
      return callback;
    },
    [measure],
  );

  useEffect(() => {
    const current = observers.current;
    return () => {
      current.forEach((observer) => observer.disconnect());
      current.clear();
    };
  }, []);

  // Ids that are no longer on the list, because the window moved to another
  // conversation, must not sit in these maps for the life of the app. Stale
  // entries are never read, so this is only about memory: swept in bulk rather
  // than tracked per row.
  useEffect(() => {
    if (heights.current.size + refs.current.size <= 4 * count + 64) return;
    const live = new Set(keys);
    for (const key of heights.current.keys()) {
      if (!live.has(key)) heights.current.delete(key);
    }
    for (const key of refs.current.keys()) {
      if (!live.has(key)) refs.current.delete(key);
    }
  }, [keys, count]);

  if (!active) {
    return { start: 0, end: count, padTop: 0, padBottom: 0, rowRef, active: false };
  }

  const start = Math.min(range.start, count);
  const end = Math.min(Math.max(range.end, start), count);
  return {
    start,
    end,
    padTop: offsets[start] ?? 0,
    padBottom: (offsets[count] ?? 0) - (offsets[end] ?? 0),
    rowRef,
    active: true,
  };
}
