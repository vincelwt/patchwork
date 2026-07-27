import test from "node:test";
import assert from "node:assert/strict";
import { createImageCache, estimateBytes } from "../../Sources/PiDeskWeb/Site/js/imagecache.mjs";

const dataURL = (bytes) => `data:image/png;base64,${"A".repeat(Math.ceil(bytes / 3) * 4)}`;

test("byte estimate reads the base64 payload, not the whole URL", () => {
  assert.equal(estimateBytes("data:image/png;base64,AAAA"), 3);
  assert.equal(estimateBytes(""), 0);
  assert.equal(estimateBytes(null), 0);
});

test("a repaint reads from cache instead of refetching", async () => {
  const cache = createImageCache();
  let calls = 0;
  const load = () => {
    calls += 1;
    return Promise.resolve(dataURL(30));
  };

  await cache.fetch("a", load);
  await cache.fetch("a", load);
  assert.equal(calls, 1, "this is the whole point: the 700ms repaint must be free");
  assert.equal(cache.peek("a"), dataURL(30));
  assert.equal(cache.peek("missing"), null);
});

test("concurrent requests for one image share a single fetch", async () => {
  const cache = createImageCache();
  let calls = 0;
  const load = () => {
    calls += 1;
    return new Promise((resolve) => setTimeout(() => resolve(dataURL(30)), 10));
  };

  await Promise.all([cache.fetch("a", load), cache.fetch("a", load), cache.fetch("a", load)]);
  assert.equal(calls, 1);
});

test("the cache is bounded by entry count", async () => {
  const cache = createImageCache({ maxEntries: 2, maxBytes: 1_000_000 });
  await cache.fetch("a", () => Promise.resolve(dataURL(30)));
  await cache.fetch("b", () => Promise.resolve(dataURL(30)));
  await cache.fetch("c", () => Promise.resolve(dataURL(30)));

  assert.equal(cache.size, 2);
  assert.equal(cache.peek("a"), null, "least recently used went first");
  assert.ok(cache.peek("c"));
});

test("reading an entry keeps it alive across the next eviction", async () => {
  const cache = createImageCache({ maxEntries: 2, maxBytes: 1_000_000 });
  await cache.fetch("a", () => Promise.resolve(dataURL(30)));
  await cache.fetch("b", () => Promise.resolve(dataURL(30)));
  cache.peek("a");
  await cache.fetch("c", () => Promise.resolve(dataURL(30)));

  assert.ok(cache.peek("a"), "recently used survives");
  assert.equal(cache.peek("b"), null);
});

test("the cache is bounded by bytes, so screenshots cannot pin tens of megabytes", async () => {
  const cache = createImageCache({ maxEntries: 100, maxBytes: 300 });
  await cache.fetch("a", () => Promise.resolve(dataURL(200)));
  await cache.fetch("b", () => Promise.resolve(dataURL(200)));

  assert.ok(cache.byteCount <= 300);
  assert.equal(cache.size, 1);
});

test("an image larger than the whole budget is served but never retained", async () => {
  const cache = createImageCache({ maxEntries: 10, maxBytes: 100 });
  await cache.fetch("small", () => Promise.resolve(dataURL(30)));
  const huge = await cache.fetch("huge", () => Promise.resolve(dataURL(5_000)));

  assert.ok(huge.startsWith("data:image/png;base64,"), "the caller still gets its image");
  assert.equal(cache.peek("huge"), null, "but it does not evict everything else on the way in");
  assert.ok(cache.peek("small"));
});

test("a failed fetch is not cached and does not block a retry", async () => {
  const cache = createImageCache();
  await assert.rejects(() => cache.fetch("a", () => Promise.reject(new Error("offline"))));
  assert.equal(cache.peek("a"), null);
  assert.equal(await cache.fetch("a", () => Promise.resolve(dataURL(30))), dataURL(30));
});
