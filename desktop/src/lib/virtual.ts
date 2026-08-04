// Rendering only the part of a long conversation that is on screen.
//
// Chat messages have no fixed height — one is a word, the next is a table and a
// code block — so this measures rows as they render and remembers them. Until
// a row has been seen it contributes an estimate, which is only ever used for
// rows nobody has scrolled to yet.
//
// Deliberately inert below a threshold: most conversations are short, and a
// virtualiser that engages at twenty messages is all risk and no benefit.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { RefObject } from "react";

/// Below this, render everything. Chosen so that the common case — a channel
/// you have just opened, one page of history — never goes near this code.
export const VIRTUALIZE_ABOVE = 80;

/// Rows kept mounted beyond the viewport, so a flick of the wheel lands on
/// something already rendered rather than on blank space.
const OVERSCAN = 12;

export interface Window {
  start: number;
  end: number;
  padTop: number;
  padBottom: number;
  /// Attach to each rendered row. Passing null on unmount is fine and ignored.
  measure: (index: number, element: HTMLElement | null) => void;
  /// True when the window is actually narrower than the list.
  active: boolean;
}

export function useVirtualWindow(
  scroller: RefObject<HTMLElement | null>,
  count: number,
  estimate = 84,
): Window {
  const heights = useRef<number[]>([]);
  const observers = useRef(new Map<number, ResizeObserver>());
  const [, bump] = useState(0);
  const [range, setRange] = useState({ start: 0, end: count });
  const active = count > VIRTUALIZE_ABOVE;

  // Prefix sums, rebuilt whenever a measurement lands. Cheap at these sizes and
  // far easier to reason about than an incremental structure.
  const offsets = useMemo(() => {
    const out = new Array<number>(count + 1);
    out[0] = 0;
    for (let index = 0; index < count; index += 1) {
      out[index + 1] = out[index] + (heights.current[index] ?? estimate);
    }
    return out;
    // `range` is in the deps because a scroll is the moment the sums are read,
    // and new measurements arrive with it.
  }, [count, estimate, range]);

  const recompute = useCallback(() => {
    const element = scroller.current;
    if (!element || !active) {
      setRange({ start: 0, end: count });
      return;
    }
    const top = element.scrollTop;
    const bottom = top + element.clientHeight;

    // Binary search the first row whose bottom edge is past the viewport top.
    let low = 0;
    let high = count;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (offsets[middle + 1] <= top) low = middle + 1;
      else high = middle;
    }
    let start = low;
    let end = start;
    while (end < count && offsets[end] < bottom) end += 1;

    start = Math.max(0, start - OVERSCAN);
    end = Math.min(count, end + OVERSCAN);
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

  // A row that changes height — an image loading, a reply streaming in — has to
  // update the sums, or everything below it drifts.
  const measure = useCallback(
    (index: number, element: HTMLElement | null) => {
      const existing = observers.current.get(index);
      if (existing) {
        existing.disconnect();
        observers.current.delete(index);
      }
      if (!element) return;

      const record = (height: number) => {
        if (height > 0 && Math.abs((heights.current[index] ?? 0) - height) > 0.5) {
          heights.current[index] = height;
          bump((n) => n + 1);
        }
      };
      record(element.offsetHeight);
      const observer = new ResizeObserver(() => record(element.offsetHeight));
      observer.observe(element);
      observers.current.set(index, observer);
    },
    [],
  );

  useEffect(() => {
    const current = observers.current;
    return () => {
      current.forEach((observer) => observer.disconnect());
      current.clear();
    };
  }, []);

  // A shorter list must not keep stale heights from the old one.
  useEffect(() => {
    if (heights.current.length > count) heights.current.length = count;
  }, [count]);

  if (!active) {
    return { start: 0, end: count, padTop: 0, padBottom: 0, measure, active: false };
  }

  const start = Math.min(range.start, count);
  const end = Math.min(Math.max(range.end, start), count);
  return {
    start,
    end,
    padTop: offsets[start] ?? 0,
    padBottom: (offsets[count] ?? 0) - (offsets[end] ?? 0),
    measure,
    active: true,
  };
}
