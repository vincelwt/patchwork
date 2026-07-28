# Pi Desktop Cloudflare relay

Cloudflare Worker and SQLite-backed Durable Object for Pi Desktop's hosted, end-to-end encrypted remote relay. The Worker routes `/relay/*` plus mutable `/js/*` and `/css/*` assets before the static Pi Desk site and serves other requests from `../Sources/PiDeskWeb/Site`.

The Durable Object is keyed by the 32-character installation ID. It retains only the host token hash, protocol version, one pairing-offer hash/expiry, short-lived idempotent approval records, and up to 32 paired devices. The fragment-only ticket is replaced by a hash plus endpoint-verifiable HMAC proof before the browser sends a frame. Ciphertext is forwarded only while the host is online; there is no offline queue. WebSocket frames, credentials, keys, tickets, and payloads are never logged. Cloudflare bindings rate-limit connections, first-time installation claims, and frames by source IP; keep account-level spend limits enabled for this intentionally accountless service.

Safari 27 can accept a `304` for an ES module from memory and then refuse access to its cached body, leaving the page blank. The Worker strips conditional validators from JavaScript and CSS requests and returns them with `Cache-Control: no-store`. This costs one Worker invocation per code/style asset (roughly two dozen on a cold page), so account-level request and spend limits remain required.

## Local development

Requires Node.js and a Cloudflare account for deployment.

```sh
cd CloudflareRelay
npm install
npm test
npm run typecheck
npm run dev
```

`npm run dev` uses Wrangler's local Durable Object and static-assets support. Generate a host bearer token as 32 random bytes encoded as unpadded base64url; the first accepted host connection claims the installation.

## Deploy

Authenticate Wrangler, then deploy the Worker, Durable Object migration, assets binding, and custom domain configured in `wrangler.jsonc`:

```sh
cd CloudflareRelay
npx wrangler login
npm run deploy
```

The production custom domain is `remote.ai.gloom.sh`. No D1, KV, R2, secrets, or runtime npm dependencies are required.
