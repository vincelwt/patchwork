// Lightweight touch-driven pull-to-refresh. Progressive enhancement only: the explicit refresh
// button every list screen also has is the reliable, keyboard/AT-accessible path; this just
// makes the common case feel native on a phone. Silently does nothing on a non-touch device.

const THRESHOLD = 64;

/** Attaches a pull-to-refresh gesture to `scrollEl`, reporting progress into `indicatorEl`. */
export function attachPullToRefresh(scrollEl, indicatorEl, onRefresh) {
  let startY = 0;
  let pulling = false;
  let active = false;

  scrollEl.addEventListener(
    "touchstart",
    (event) => {
      if (scrollEl.scrollTop > 0 || active) return;
      startY = event.touches[0].clientY;
      pulling = true;
    },
    { passive: true }
  );

  scrollEl.addEventListener(
    "touchmove",
    (event) => {
      if (!pulling) return;
      const delta = event.touches[0].clientY - startY;
      if (delta <= 0) {
        indicatorEl.style.height = "0px";
        return;
      }
      const height = Math.min(delta * 0.5, THRESHOLD + 20);
      indicatorEl.style.height = `${height}px`;
      indicatorEl.textContent = height > THRESHOLD ? "Release to refresh" : "Pull to refresh";
    },
    { passive: true }
  );

  scrollEl.addEventListener("touchend", async () => {
    if (!pulling) return;
    pulling = false;
    const height = parseFloat(indicatorEl.style.height || "0");
    if (height > THRESHOLD && !active) {
      active = true;
      indicatorEl.style.height = "28px";
      indicatorEl.textContent = "Refreshing…";
      try {
        await onRefresh();
      } finally {
        indicatorEl.style.height = "0px";
        active = false;
      }
    } else {
      indicatorEl.style.height = "0px";
    }
  });
}
