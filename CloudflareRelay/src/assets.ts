type AssetFetcher = { fetch(request: Request): Promise<Response> };

export async function freshMutableAsset(request: Request, assets: AssetFetcher): Promise<Response> {
  if (!/^\/(?:js|css)\//.test(new URL(request.url).pathname)) return assets.fetch(request);
  const headers = new Headers(request.headers);
  headers.delete("if-none-match");
  headers.delete("if-modified-since");
  const asset = await assets.fetch(new Request(request, { headers }));
  const fresh = new Response(asset.body, asset);
  // ponytail: one Worker hop avoids Safari's broken 304 cache; use hashed assets if volume matters.
  fresh.headers.set("cache-control", "no-store");
  return fresh;
}
