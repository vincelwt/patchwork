# Patchwork managed relay

The open-source Cloudflare Worker and Durable Object behind Patchwork's optional zero-configuration public connection. A Patchwork relay keeps its SQLite database, files, repositories, credentials, and agents on its own machine. This service only forwards HTTPS and WebSocket traffic to the relay's outbound connection, so users do not need a domain, certificate, port forwarding, or an open inbound firewall port.

`relay.patchwork.sh` is the hosted default. Set `PATCHWORK_MANAGED_RELAY` to another deployed Worker root to use your own, or start `patchwork-relay --direct` for ordinary self-hosting.

## Develop

```bash
npm install
npm test
npm run typecheck
npm run dev
```

## Deploy your own

Change the Worker name and custom domain in `wrangler.jsonc`. Live previews use isolated first-level subdomains so arbitrary development code never shares the authenticated relay origin. Add one proxied wildcard DNS record for your zone and the matching `*.example.com/*` Worker route; Cloudflare Universal SSL covers those first-level names. If the zone already serves first-level names such as `www.example.com`, add more-specific no-script Worker routes for them before enabling the wildcard.

Then authenticate Wrangler and deploy:

```bash
npm run deploy
```

The Durable Object keeps only a hash of each installation's host token. Request bodies, bearer tokens, files, and WebSocket messages are forwarded in memory and are never logged or persisted by this service. Traffic is protected with HTTPS/WSS to Cloudflare and from Cloudflare to the host connector. Cloudflare is a trusted transit endpoint in this first protocol version; application-level end-to-end encryption can be layered on without moving workspace storage out of the user's relay.

Managed requests are currently limited to 20 MB because one request maps to one Durable Object WebSocket frame. Direct self-hosting retains the relay's 64 MB limit.
