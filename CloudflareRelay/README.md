# Pi Desktop Cloudflare relay

Cloudflare Worker and SQLite-backed Durable Object for Pi Desktop's hosted, end-to-end encrypted remote relay. The Worker routes `/relay/*` before the static Pi Desk site and serves other requests from `../Sources/PiDeskWeb/Site`.

The Durable Object is keyed by the 32-character installation ID. It retains only the host token hash, one pairing offer, and up to 32 paired-device records. Ciphertext is forwarded only while the host is online; there is no offline queue. WebSocket frames, credentials, keys, tickets, and payloads are never logged.

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
