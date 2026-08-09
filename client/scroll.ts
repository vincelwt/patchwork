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
