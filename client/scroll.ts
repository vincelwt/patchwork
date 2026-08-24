/// Whether a scroll viewport is close enough to its trailing edge that new
/// content should keep following it. Negative distance means the content is
/// shorter than the viewport, which also counts as being at the end.
export function isNearScrollEnd(
  contentLength: number,
  offset: number,
  viewportLength: number,
  threshold = 80,
): boolean {
  return contentLength - offset - viewportLength <= threshold;
}

/// Keep a viewport at its trailing edge without rewriting a scroll position
/// that only differs because DOM dimensions are rounded to whole CSS pixels.
export function alignScrollEnd(viewport: {
  scrollHeight: number;
  scrollTop: number;
  clientHeight: number;
}): void {
  const end = Math.max(0, viewport.scrollHeight - viewport.clientHeight);
  if (Math.abs(end - viewport.scrollTop) > 1) {
    viewport.scrollTop = viewport.scrollHeight;
  }
}

/// Where a viewport belongs once a page of older content has been prepended:
/// under the same words the reader was already looking at. The height that was
/// added is `height - previousHeight`, and the reader keeps whatever they had
/// already scrolled past, so dropping `previousTop` throws them back to the top
/// of the conversation every time a page lands.
export function scrollTopAfterPrepend(
  previousHeight: number,
  previousTop: number,
  height: number,
): number {
  return Math.max(0, height - previousHeight + previousTop);
}

/// Running top edge of every row, plus a final entry for the total height.
///
/// Rows are addressed by a stable key rather than by position: history is
/// prepended, so a row's index changes under it while its measured height does
/// not, and an index-keyed table hands each row the height of whichever row
/// used to sit there. Rows nobody has measured yet contribute `estimate`.
export function rowOffsets(
  keys: readonly string[],
  heights: ReadonlyMap<string, number>,
  estimate: number,
): number[] {
  const out = new Array<number>(keys.length + 1);
  out[0] = 0;
  for (let index = 0; index < keys.length; index += 1) {
    out[index + 1] = out[index] + (heights.get(keys[index]) ?? estimate);
  }
  return out;
}

/// The rows a viewport covers, widened by the overscan kept mounted around
/// them. `first` is the topmost row actually on screen: a row above it that
/// changes height moves everything the reader can see, so `first` is the line
/// such a change has to be compensated against.
export function visibleRange(
  offsets: readonly number[],
  scrollTop: number,
  viewportHeight: number,
  overscan: number,
): { first: number; start: number; end: number } {
  const count = Math.max(0, offsets.length - 1);
  const top = Math.max(0, scrollTop);
  const bottom = top + viewportHeight;

  // Binary search the first row whose bottom edge is past the viewport top.
  let low = 0;
  let high = count;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (offsets[middle + 1] <= top) low = middle + 1;
    else high = middle;
  }
  let end = low;
  while (end < count && offsets[end] < bottom) end += 1;

  return {
    first: low,
    start: Math.max(0, low - overscan),
    end: Math.min(count, end + overscan),
  };
}
