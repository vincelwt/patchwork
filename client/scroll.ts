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
