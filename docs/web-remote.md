# Web remote

Pi Desktop can be used from a phone or another browser without a VPN, inbound port, or tunnel.
The active control service opens an outbound WebSocket to the Cloudflare relay at
[`remote.ai.gloom.sh`](https://remote.ai.gloom.sh); the same phone-first static app remains
available over the older loopback listener for local/tunnel use.

Pi and the Mac remain the source of truth. Cloudflare routes encrypted request, response, and
event envelopes but never receives Pi provider credentials or session files.

## Hosted remote

The hosted connection starts with Pi Desktop’s in-process control service. If the optional
`pi-deskd` LaunchAgent is installed, it hosts the same connection and stays reachable after the
window app quits.

Pair a browser once:

1. Click the phone button in the sidebar footer.
2. Scan the QR code with the phone.
3. Confirm the same six-digit code on the phone and Mac, then click **Allow**.
4. Optionally add the site to the phone's Home Screen.

The QR link expires after five minutes and is single-use. It contains a random installation ID,
a non-secret per-offer reload nonce, one-time ticket, and the Mac's public encryption key. The
nonce makes iPhone Safari load each newly scanned QR instead of reusing an expired pairing tab;
the ticket and key remain in the URL fragment. The link contains no provider credential, session
data, or reusable daemon bearer token.

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

The Mac must be online and either Pi Desktop or the optional `pi-deskd` host must be running to
execute or read conversations. The
relay deliberately does not queue mutations while the host is offline, avoiding an ambiguous
"did this prompt run twice?" failure after reconnect.

### Hosted topology

```text
browser/PWA -- encrypted WSS --> Cloudflare Worker + Durable Object <-- WSS -- active Mac host
```

One hibernatable Durable Object coordinates each random installation ID. It retains only the
host-token hash, public device keys, device labels/timestamps, and one bounded pairing offer
(ticket hash, expiry, and host public key). Pending approvals expire at the same five-minute
deadline. There is no D1, KV, R2, plaintext conversation cache, or offline prompt queue. Static
files are the same `Sources/PiDeskWeb/Site/` assets bundled into Pi Desktop and the standalone host.

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

After changing this setting, reopen Pi Desktop or restart the LaunchAgent host. The token lives at:

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
the hosted origin. Hosted JavaScript and CSS bypass conditional caching because Safari 27 can
receive a `304` from memory and then refuse access to the cached module body; the Worker forces a
full response with `Cache-Control: no-store`. Local mode uses HTTP + authenticated SSE; hosted mode
swaps only the transport for the encrypted relay WebSocket. The views and `/v1` response contract
are shared.

Pure logic lives in `.mjs` modules with no DOM (`markdown`, `time`, `trigger`, `relayCrypto`,
`pending`, `folders`, `transcript`) and is tested directly with `node --test docs/js-checks/*.test.mjs`.
The `.js` view files are the only ones that touch the DOM.

## Reading a conversation

A thread reads the way it does in the Mac app, not as a dump of wire messages: one user message,
one quiet **work** row, then Pi's answer. `js/transcript.mjs` is a port of the app's own
`TranscriptPresenter`, so both clients fold a turn by the same rules.

The work row is collapsed by default and carries everything that is not the answer: reasoning,
narration Pi wrote before a tool call, every tool call with its arguments and result, errors Pi
retried past, and compaction summaries. While the turn is live the row shows Pi's latest thought
with a green dot and a running clock; once it settles it becomes `Worked for 12s`. Opening it
reveals the log, and tool activity nests two more levels — one disclosure per activity group, one
per individual call — so routine tool traffic is never dumped into the transcript. Each are native
`details`/`summary` controls, so keyboard and screen-reader behaviour is the browser's own.

What stays outside the collapsed row: the answer itself, images (an answer's own and any a tool
produced), and question cards Pi is blocked on. A failed *step* stays red where it is; only a turn
whose own answer failed marks the collapsed row `failed`. A tool result whose call is outside the
loaded window still shows as its own step rather than disappearing, and a message role this build
does not know is displayed rather than dropped.

A daemon that predates the structured fields sends only `text`; the same projection then yields one
block per message, which still reads as turns.

Opening a thread reuses the metadata snapshot already shown in the list and reads recent JSONL
records backward from EOF. Latency therefore follows the visible tail rather than total session
size; if a pathological tail exceeds the bounded reverse window, the daemon falls back to its full
scanner rather than hiding history.

## Live updates

While a thread is running — a message sent from here, or a run the Mac app or a terminal started —
the open thread re-reads its transcript at least every 2.5 seconds, on top of the debounced refresh
an SSE `thread`/`run` event triggers. Events carry no message bodies (see `docs/daemon-api.md`), so
polling is what makes a long turn visibly progress.

The poll is deliberately dull: one timer, never two fetches in flight, and it stops entirely once
nothing is running. A refresh that returns an identical transcript does not touch the DOM at all,
so nothing re-animates, disclosures stay open, and a reader who has scrolled up is not dragged back
to the bottom. The elapsed clock updates as text, without repainting the turn.

## Creating a thread

A first message never becomes a fake thread route. Current daemons resolve the real Pi session
before returning and then queue the prompt against it. When paired with an older daemon that still
returns `pending:<run>`, the browser follows `GET /v1/runs/{runId}` and opens the conversation only
once that run reports the real session id; a dropped connection keeps resolving the accepted run
instead of inviting a duplicate first prompt.

The working directory is picked from the `cwd` of threads already known, or typed. When that folder
is a git repository with more than one checkout, a **Checkout** menu appears listing the main
checkout and every existing worktree (`GET /v1/worktrees`), and the selected one becomes the
thread's working directory. Selection only: worktrees are created and removed in the Mac app, and a
folder that is not a repository, or a daemon without the endpoint, simply hides the menu instead
of blocking thread creation.

## Archiving

The Threads tab has two explicit lists, **Active** and **Archived**, because archiving is only
useful if the thread visibly leaves the list it was in and stays findable in another. Switching
re-reads `GET /v1/threads?archived=…`, and an SSE `thread` event whose `archived` flag no longer
matches the visible list removes the row instead of merging it back in.

Inside a thread, the top bar carries a worded **Archive** / **Unarchive** button rather than a
glyph. Archiving keeps the thread open and readable; only the list it appears in changes. An
archived thread can be opened from the Archived list, read, and replied to. Pi's session file is
never touched; archive state is metadata.

Restoring works for threads archived **from the web**, which is what this button writes. A thread
archived in the **Mac app** cannot be restored from here: that flag lives in the app's own
`state.json`, which the daemon reads and never writes, so unarchiving answers `409` and the message
says to restore it in the app. Nothing is silently reported as restored.

## Model and thinking controls

The row above the composer shows native select menus for the current model and thinking level,
populated from Pi's exact available choices. Changes use Pi's own `set_model` and
`set_thinking_level` RPCs and apply to later provider work in the same conversation. A daemon-owned
live turn shares its existing Pi process; an idle thread gets one short-lived reserved attachment.
If the Mac app owns the runtime, the row reports that conflict and offers Retry rather than racing
two processes against one session. Older daemons without these endpoints simply hide the row.

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
persisted. When that bound is reached the oldest message the daemon has *explicitly accepted* is
dropped — its text is already on its way into the transcript. A bubble still waiting for its
response (including one told `submission_in_flight`, whose original attempt can still fail) is
never evicted: it holds the only copy of that text. If all eight are unresolved or failed, the
ninth send is refused and its text goes back into the composer.

A run event can also outrun the response that names its run. The screen keeps the latest state of
the last sixteen runs and applies the matching one the moment a bubble learns its `runId`, so a
fast failure is never left spinning on "Sending…".

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

A *failed* read of `GET /v1/interactions` is not an empty list. The last successful set stays on
screen — clearing it would discard a half-typed answer to a dialog Pi is still blocked on — and a
bounded retry chain (2s, then 4s) plus a refresh on every offline→online transition is what brings
it back up to date.

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
times a second. At most eight *distinct* images fetch at once (repeat requests for one image still
share a single fetch); past that a tile keeps its placeholder and says so, and a tap retries.

An image that is too large (over 1 MB decoded) or unreadable shows a labelled placeholder. One past
the per-view budget of 40 shows a **Load** tile instead — the budget bounds automatic loading, not
availability.

## Folders

The thread list mirrors the Mac app's sidebar: threads filed into a virtual folder appear there,
everything else groups under its project directory, and virtual folders and real projects can
contain each other. Group headers are disclosure buttons with subtree counts and unread/running
markers;
indentation is capped so a deep tree still leaves room for a title on a phone. Folders are
read-only here — they are created, renamed, and rearranged in the Mac app. A machine with a single
project and no folders keeps the flat list, and a daemon that predates `GET /v1/folders` falls
back to project grouping rather than showing an error.
