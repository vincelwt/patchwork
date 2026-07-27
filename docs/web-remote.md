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

Pure logic lives in `.mjs` modules with no DOM (`markdown`, `time`, `trigger`, `relayCrypto`,
`pending`, `folders`) and is tested directly with `node --test docs/js-checks/*.test.mjs`. The
`.js` view files are the only ones that touch the DOM.

## Sending a message

A send is optimistic. `POST /v1/threads/{id}/messages` only *accepts* the text; Pi appends the
user entry to its session file seconds later. The composer therefore clears immediately and the
text moves into a pending bubble carrying an honest status — sending, queued, working, steering,
or failed — which is removed only when the real parsed message appears in a refetch, or when the
message's run finishes successfully. A failed send keeps its text with **Retry** and **Dismiss**;
nothing is silently lost, and a duplicate bubble is impossible because each pending entry is
reconciled against a count of identical user messages recorded when it was submitted. Status
changes are announced through one persistent live region rather than from the bubbles themselves,
which are replaced on every repaint and would announce unreliably.

**Retry never prompts Pi twice.** Each bubble generates a `clientId` once and reuses it verbatim on
retry, so a send whose response was lost replays the original answer instead of starting a second
turn. Retry also re-sends the delivery that was originally *requested*, so retrying a steer that
the daemon had to downgrade still asks to steer.

At most eight unconfirmed messages are held, and they are scoped to the open screen rather than
persisted. When that bound is reached the oldest *accepted* message is dropped — its text is
already on its way into the transcript. If every slot holds a message that was never sent, a new
send is refused and its text goes back into the composer: evicting an unsent message would destroy
the only copy of it.

Attachments are not supported here. The daemon rejects them outright rather than accepting a
message and dropping its images.

The composer's overflow menu offers **Send as follow-up** and **Send as steer**. Both are real:
the daemon delivers them into the live Pi turn. When no daemon-owned turn is running there is
nothing to interrupt, the daemon reports `delivery: auto`, and the bubble says the message is
queued rather than pretending it steered anything.

## Questions and approvals

When a daemon run blocks on a dialog — an `ask_user_question` step, a permission prompt — it
appears at the bottom of the thread and can be answered from the phone:

- **Single select** renders as a radio group: one tap selects, **Submit** sends. A mis-tap is
  recoverable, unlike a list of buttons that answer on contact.
- **Multi select** renders as checkboxes plus a free-text field for "none of these" or an answer
  that is not on the list.
- **Typed answer / editor** renders a text field or textarea, prefilled when Pi supplied one.
- **Confirm** renders Yes / No / Cancel.
- A dialog kind this build cannot render still appears, says it needs the Mac app, and offers
  Cancel — Pi is blocked until it gets an answer, so it is never silently skipped.

Option lists use a native `fieldset`/`legend` group so screen readers announce them correctly, and
an option's code preview sits outside its label: inside it, scrolling the sample would toggle the
option. Cards are reused across refreshes, so answering one dialog never wipes an answer typed into
another, and a dialog Pi has stopped waiting for says so plainly rather than reading as a failed
submission.

Nothing is answered automatically. `Question 2 of 3` is shown when the dialog is matched to a
questionnaire, and answering advances to the next one. **Going back to a previous question is not
possible from the web remote**: Pi's bridge is sequential and has already consumed the earlier
answer. Use the Mac app when a questionnaire needs revisiting.

## Images

Assistant and tool-result inline images render as responsive thumbnails; tapping one opens a
focus-trapped lightbox with a download link, which locks background scrolling and marks the screen
behind it inert while open, and is torn down if the screen is navigated away from.

Bytes are fetched per image from `GET /v1/threads/{id}/images/{imageId}` rather than embedded in
the thread detail, which is what keeps a screenshot-heavy conversation inside the relay's 1.5 MB
per-payload ceiling. Loading is deliberately not eager: a thumbnail fetches when it scrolls near
the viewport, and decoded results go into a shared cache bounded to 24 images and 12 MB, so the
transcript's debounced repaint re-renders from memory instead of re-downloading everything several
times a second.

An image that is too large (over 1 MB decoded) or unreadable shows a labelled placeholder. One past
the per-view budget of 40 shows a **Load** tile instead — the budget bounds automatic loading, not
availability.

## Folders

The thread list mirrors the Mac app's sidebar: threads filed into a virtual folder appear there,
everything else groups under its project directory, and folders nest inside projects or other
folders. Group headers are disclosure buttons with subtree counts and unread/running markers;
indentation is capped so a deep tree still leaves room for a title on a phone. Folders are
read-only here — they are created, renamed, and rearranged in the Mac app. A machine with a single
project and no folders keeps the flat list, and a daemon that predates `GET /v1/folders` falls
back to project grouping rather than showing an error.
