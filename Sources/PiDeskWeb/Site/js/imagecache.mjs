// A bounded LRU of decoded image data URLs, shared by every thread view.
//
// The transcript repaints on a 700ms debounce whenever a run event lands, and each repaint builds
// fresh <img> elements. Without a cache that means refetching every visible image, several times a
// second, over a phone tunnel. With one, a repaint is free and the bytes are fetched once.
//
// Bounded by count *and* by bytes, because the entries are the images themselves: forty 1 MB
// screenshots would otherwise be 40 MB pinned in memory for as long as the tab lives.

export const MAX_ENTRIES = 24;
export const MAX_BYTES = 12 * 1024 * 1024;
/**
 * How many *distinct* images may be fetching at once. Requests for one key still share a single
 * fetch, so this bounds concurrent tunnel work, not repaints: without it a long transcript
 * scrolled quickly opens one request per thumbnail and holds every pending promise alive.
 */
export const MAX_IN_FLIGHT = 8;

/** Refused for capacity, not for content. Retrying later is the correct response. */
export class ImageCacheBusyError extends Error {
  constructor() {
    super("Too many images loading. Tap to retry.");
    this.name = "ImageCacheBusyError";
    this.retryable = true;
  }
}

/** Cheap size estimate for a `data:` URL without decoding it: base64 is 4 chars per 3 bytes. */
export function estimateBytes(dataURL) {
  const comma = String(dataURL || "").indexOf(",");
  return comma === -1 ? 0 : Math.floor(((dataURL.length - comma - 1) / 4) * 3);
}

export function createImageCache({ maxEntries = MAX_ENTRIES, maxBytes = MAX_BYTES, maxInFlight = MAX_IN_FLIGHT } = {}) {
  // Map preserves insertion order, which is all an LRU needs: re-inserting on read moves an entry
  // to the end, so the first key is always the least recently used.
  const entries = new Map();
  const inFlight = new Map();
  let bytes = 0;

  function evictIfNeeded() {
    while (entries.size > maxEntries || bytes > maxBytes) {
      const oldest = entries.keys().next();
      if (oldest.done) return;
      bytes -= entries.get(oldest.value).bytes;
      entries.delete(oldest.value);
    }
  }

  return {
    /** The cached data URL, or null. Counts as a use, so it survives the next eviction pass. */
    peek(key) {
      const entry = entries.get(key);
      if (!entry) return null;
      entries.delete(key);
      entries.set(key, entry);
      return entry.dataURL;
    },

    /**
     * Fetches once per key, no matter how many repaints ask for it concurrently. `load` is only
     * called on a genuine miss.
     */
    fetch(key, load) {
      const cached = this.peek(key);
      if (cached) return Promise.resolve(cached);
      const existing = inFlight.get(key);
      if (existing) return existing;
      // Nothing is cached and nothing is retained, so a refusal costs only this attempt: the
      // tile keeps its placeholder and a tap tries again.
      if (inFlight.size >= maxInFlight) return Promise.reject(new ImageCacheBusyError());

      const promise = load()
        .then((dataURL) => {
          const size = estimateBytes(dataURL);
          // A single image larger than the whole budget is served but never retained, so it
          // cannot evict everything else on its way in.
          if (size <= maxBytes) {
            entries.set(key, { dataURL, bytes: size });
            bytes += size;
            evictIfNeeded();
          }
          return dataURL;
        })
        .finally(() => inFlight.delete(key));
      inFlight.set(key, promise);
      return promise;
    },

    get size() {
      return entries.size;
    },
    get byteCount() {
      return bytes;
    },
    get inFlightCount() {
      return inFlight.size;
    }
  };
}

/** The process-wide cache the thread view uses. */
export const imageCache = createImageCache();
