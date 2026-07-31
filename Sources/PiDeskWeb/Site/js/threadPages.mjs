const PAGE_SIZE = 200;
const MAX_THREADS = 5000;

/**
 * Reads the complete bounded thread list. The daemon caps one response at 200 rows so a large
 * history stays below the hosted relay's payload limit, while the web remote must not silently
 * stop at its first page and diverge from the Mac sidebar.
 */
export async function loadThreadPages(fetchPage, params, options = {}) {
  const pageSize = options.pageSize || PAGE_SIZE;
  const maxThreads = options.maxThreads || MAX_THREADS;
  const threads = [];
  const seenCursors = new Set();
  let cursor;

  while (threads.length < maxThreads) {
    const response = await fetchPage({
      ...params,
      limit: Math.min(pageSize, maxThreads - threads.length),
      cursor
    });
    const page = Array.isArray(response?.threads) ? response.threads : [];
    if (threads.length + page.length > maxThreads) {
      throw new Error(`Thread list exceeds the ${maxThreads}-row safety limit.`);
    }
    threads.push(...page);

    const next = response?.nextCursor;
    if (next === null || next === undefined || next === "") return threads;
    if (seenCursors.has(next)) throw new Error("Thread pagination returned a repeated cursor.");
    seenCursors.add(next);
    cursor = next;
  }

  throw new Error(`Thread list exceeds the ${maxThreads}-row safety limit.`);
}
