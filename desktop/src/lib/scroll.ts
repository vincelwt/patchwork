import { useCallback, useEffect, useLayoutEffect, useRef } from "react";
import { isNearScrollEnd } from "@client/scroll";

/// Open a scrollable history at its newest content, then keep following only
/// while the reader remains near the end. The content callback ref lets the
/// observer attach even when an async detail view renders after this hook.
export function useBottomAnchor(scopeKey: string, threshold = 80) {
  const scrollerRef = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);
  const observer = useRef<ResizeObserver>(undefined);

  const scrollToEnd = useCallback((force = false) => {
    const element = scrollerRef.current;
    if (element && (force || pinned.current)) {
      element.scrollTop = element.scrollHeight;
    }
  }, []);

  const updatePinned = useCallback(() => {
    const element = scrollerRef.current;
    if (!element) return;
    pinned.current = isNearScrollEnd(
      element.scrollHeight,
      element.scrollTop,
      element.clientHeight,
      threshold,
    );
  }, [threshold]);

  const contentRef = useCallback(
    (element: HTMLDivElement | null) => {
      observer.current?.disconnect();
      observer.current = undefined;
      if (!element) return;

      observer.current = new ResizeObserver(() => scrollToEnd());
      observer.current.observe(element);
      requestAnimationFrame(() => scrollToEnd());
    },
    [scrollToEnd],
  );

  useLayoutEffect(() => {
    pinned.current = true;
    scrollToEnd(true);
    const frame = requestAnimationFrame(() => scrollToEnd(true));
    return () => cancelAnimationFrame(frame);
  }, [scopeKey, scrollToEnd]);

  useEffect(() => () => observer.current?.disconnect(), []);

  return { scrollerRef, contentRef, scrollToEnd, updatePinned };
}
