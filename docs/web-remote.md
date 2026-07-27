# Web remote

Pi Desktop can be used from a phone or another browser without a VPN, inbound port, or tunnel.
The daemon opens an outbound WebSocket to the Cloudflare relay at
[`remote.ai.gloom.sh`](https://remote.ai.gloom.sh); the same phone-first static app remains
available over the older loopback listener for local/tunnel use.

Pi and the Mac remain the source of truth. Cloudflare routes encrypted request, response, and
event envelopes but never receives Pi provider credentials or session files.

## Hosted remote

The hosted connection starts automatically with `pi-deskd`. Since the app supervises the daemon
by default, opening Pi Desktop also starts the remote connection. If `pi-deskd` is installed as a
LaunchAgent, it stays reachable after the window app quits.

Pair a browser once:

1. Click the phone button in the sidebar footer.
2. Scan the QR code with the phone.
3. Confirm the same six-digit code on the phone and Mac, then click **Allow**.
4. Optionally add the site to the phone's Home Screen.

The QR link expires after five minutes and is single-use. It contains a random installation ID,
one-time ticket, and the Mac's public encryption key. It contains no provider credential,
session data, or reusable daemon bearer token.

After approval, the browser keeps non-exportable P-256 authentication and key-agreement keys in
IndexedDB. The URL-fragment ticket never goes to the relay: the browser sends its SHA-256 hash
and an HMAC proof binding the ticket, installation, label, and both device public keys. The Mac
verifies that proof and derives the same six-digit code before it records the approved key
locally. Each reconnection signs a fresh challenge.

API traffic uses a device-specific key derived with P-256 ECDH + HKDF-SHA256 and AES-256-GCM.
Authenticated additional data binds ciphertext direction, and a persistent per-device mutation
counter makes captured mutations fail closed if replayed. Clearing site data, using private
browsing, or revoking the device requires pairing again. Each browser has its own identity and
can be revoked independently from the same sheet.

The Mac must be online and `pi-deskd` must be running to execute or read conversations. The
relay deliberately does not queue mutations while the host is offline, avoiding an ambiguous
"did this prompt run twice?" failure after reconnect.

### Hosted topology

```text
browser/PWA -- encrypted WSS --> Cloudflare Worker + Durable Object <-- WSS -- pi-deskd
```

One hibernatable Durable Object coordinates each random installation ID. It retains only the
host-token hash, public device keys, device labels/timestamps, and one bounded pairing offer
(ticket hash, expiry, and host public key). Pending approvals expire at the same five-minute
deadline. There is no D1, KV, R2, plaintext conversation cache, or offline prompt queue. Static
files are the same `Sources/PiDeskWeb/Site/` assets bundled into the daemon.

Deployment lives in `CloudflareRelay/`:

```bash
cd CloudflareRelay
npm test
npx wrangler deploy
```

`wrangler.jsonc` binds the Durable Object, static assets, and `remote.ai.gloom.sh` custom domain.

## Local loopback remote

The Unix socket used by the Mac app and `pidesk` is always on. The optional local web listener
remains available for development, SSH forwarding, or a user-managed tunnel:

```bash
pidesk remote enable            # 127.0.0.1:7717
pidesk remote enable --port 8080
pidesk remote url
pidesk remote token
pidesk remote disable
```

Restart the daemon after changing this setting. The token lives at:

```text
~/Library/Application Support/Pi Desktop/daemon-token
```

It is 32 random bytes, base64url-encoded, and stored with mode `0600`. Local TCP API requests
carry `Authorization: Bearer <token>`. The web app stores that token in `localStorage`; it never
places it in a URL or log. The listener binds only to `127.0.0.1`.

For a manual Cloudflare quick tunnel:

```bash
cloudflared tunnel --url http://127.0.0.1:7717
```

The hosted relay does not use this listener or token and does not expose a port on the Mac.

## Security boundaries

- Hosted traffic enters the daemon only after Durable Object device authentication,
  device-to-daemon decryption, and a match against the Mac's locally approved device key.
- Pairing/device-management endpoints are Unix-socket-only. A paired browser cannot mint or
  approve another device.
- Hosted RPC accepts only the documented `/v1/*` methods and rejects `/v1/remote/*`, oversized
  frames, malformed ciphertext, and unknown mutation methods.
- Relay and browser frames are bounded to 2 MiB (encrypted plaintext is capped lower to account
  for AES-GCM and base64 expansion); retained devices are capped at 32 and pending sockets at 4.
  Cloudflare rate-limit bindings also cap connection attempts, new installations, and frames per
  source IP. Keep account spend alerts/limits enabled because enrollment is intentionally
  accountless.
- The hosted wire protocol is versioned. A protocol upgrade clears incompatible relay records,
  locally approved legacy keys, and stale browser metadata rather than leaving a half-paired
  device retrying forever. Unknown API fields and event names remain forward-compatible.
- Pairing and revocation wait for a relay acknowledgement. Revocation then deletes both the
  relay-side record and the Mac's local authorization before closing live browser sockets.
- Cloudflare can observe connection metadata and encrypted payload sizes/timing. It cannot read
  the encrypted API body. As with any hosted web app, a compromised future JavaScript deployment
  could target a browser after page load; a native mobile client would be the upgrade if that
  threat model becomes necessary.

## Web app

`Sources/PiDeskWeb/Site/` is plain HTML/CSS/JavaScript with no framework, CDN, or build step.
`PiDeskWeb.asset(for:)` bundles it for loopback use, while Wrangler serves the same directory on
the hosted origin. Local mode uses HTTP + authenticated SSE; hosted mode swaps only the transport
for the encrypted relay WebSocket. The views and `/v1` response contract are shared.
