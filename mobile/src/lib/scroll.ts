import { useCallback, useLayoutEffect, useRef } from "react";
import type {
  FlatList,
  NativeScrollEvent,
  NativeSyntheticEvent,
} from "react-native";

import { isNearScrollEnd } from "@client/scroll";

/// Open a native virtualized list at its newest content, then follow appended
/// content only while the reader remains near the end.
export function useBottomAnchoredList<Item>(
  scopeKey: string,
  itemCount: number,
  threshold = 80,
) {
  const listRef = useRef<FlatList<Item>>(null);
  const pinned = useRef(true);
  const openedAtEnd = useRef(false);
  const userScrolling = useRef(false);

  const scrollToEnd = useCallback(() => {
    listRef.current?.scrollToEnd({ animated: false });
  }, []);

  useLayoutEffect(() => {
    pinned.current = true;
    openedAtEnd.current = false;
    userScrolling.current = false;
    const frame = requestAnimationFrame(scrollToEnd);
    return () => cancelAnimationFrame(frame);
  }, [scopeKey, scrollToEnd]);

  const onContentSizeChange = useCallback(() => {
    if (itemCount === 0) return;
    if (!openedAtEnd.current) {
      openedAtEnd.current = true;
      pinned.current = true;
      scrollToEnd();
      return;
    }
    if (pinned.current) scrollToEnd();
  }, [itemCount, scrollToEnd]);

  const updatePinned = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      const { contentOffset, contentSize, layoutMeasurement } = event.nativeEvent;
      pinned.current = isNearScrollEnd(
        contentSize.height,
        contentOffset.y,
        layoutMeasurement.height,
        threshold,
      );
    },
    [threshold],
  );

  // Layout and programmatic scroll events must not make a followed list look
  // unpinned just before onContentSizeChange runs. Only direct reader input
  // changes whether future content should follow the end.
  const onScroll = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      if (openedAtEnd.current && userScrolling.current) updatePinned(event);
    },
    [updatePinned],
  );
  const onScrollBeginDrag = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      userScrolling.current = true;
      updatePinned(event);
    },
    [updatePinned],
  );
  const onScrollEndDrag = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      updatePinned(event);
      userScrolling.current = false;
    },
    [updatePinned],
  );
  const onMomentumScrollBegin = useCallback(() => {
    userScrolling.current = true;
  }, []);
  const onMomentumScrollEnd = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      updatePinned(event);
      userScrolling.current = false;
    },
    [updatePinned],
  );

  return {
    listRef,
    onContentSizeChange,
    onScroll,
    onScrollBeginDrag,
    onScrollEndDrag,
    onMomentumScrollBegin,
    onMomentumScrollEnd,
  };
}
