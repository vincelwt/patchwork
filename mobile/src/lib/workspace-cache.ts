const CACHE_NAMESPACE = "patchwork.workspace.";
const CACHE_VERSION = "v2";

export function workspaceCacheKey(baseUrl: string, tokenDigest: string) {
  return `${CACHE_NAMESPACE}${CACHE_VERSION}:${encodeURIComponent(baseUrl.replace(/\/$/, ""))}:${tokenDigest}`;
}

export function isWorkspaceCacheKey(key: string) {
  return key.startsWith(CACHE_NAMESPACE);
}
