# Pi Desktop control plane

Pi Desktop grows a headless half so threads can run, be scheduled, and be driven when the
window is closed — from a CLI, from another agent, or from a phone. This document is the
contract between the four pieces. It is normative: the daemon, the CLI, the web remote, and the
app all implement exactly what is written here.

```
        pidesk (CLI)        web remote (browser)        Pi Desktop.app
              \                    |                        /
               \                   |                       /
                +-------- HTTP/JSON control API ----------+
                                   |
                            pi-deskd (daemon)
                                   |
                     spawns `pi --mode rpc` per run
                                   |
                        ~/.pi/agent/sessions/*.jsonl
```

Pi stays the source of truth. The daemon never writes a session file itself; it drives the Pi
CLI exactly like the app does. Schedules, tokens, and run history are app-owned metadata.

## Processes

| Piece | Target | Binary | Role |
|---|---|---|---|
| Daemon | `PiDeskDaemon` | `pi-deskd` | Scheduler, thread runner, control API |
| CLI | `PiDeskCLI` | `pidesk` | Thin client over the control API |
| Shared | `PiDeskKit` | — | Wire models, client, paths, shared by all three and by the app |
| App | `PiDesktop` | `Pi Desktop.app` | Window UI; a client of the same API for schedules |

The daemon must be safe to run with no app open, and safe to have no daemon at all: the app
degrades to local-only behaviour and says so.

## Lifecycle

There are two supported ways to run `pi-deskd`, and exactly one runs at a time:

- **App-managed (default).** Pi Desktop.app bundles `pi-deskd` and `pidesk` inside
  `Contents/Helpers/` and owns their process lifecycle itself (`Sources/PiDesktop/
  DaemonSupervisor.swift`): it starts the daemon on launch if nothing is already serving the
  control socket, restarts it if it dies while the app is running, and stops it on quit. No
  install step; this is what a person who never heard of `pidesk` gets by default.
- **LaunchAgent (opt-in, always-on).** `scripts/install-daemon.sh` (or `pidesk daemon install`)
  registers `pi-deskd` as a per-user LaunchAgent (`dev.pi.desktop.daemon`) that starts at login
  and restarts on crash, independent of whether the app is even installed. For a headless
  machine, or automations that must keep running with the window app never opened.

Both write and read the exact same `~/Library/Application Support/Pi Desktop/*` files, so
schedules and run history are identical either way; only who launches the process differs.

**Only one daemon at a time.** Before starting anything, the app probes `GET /v1/health` on the
control socket. A *file* at the socket path is not evidence of a running daemon — a crash can
leave one behind — so the app never treats the file's existence as "already running"; only a
successful health response does. A stale socket file left by a crash needs no special handling
from the app either way: `pi-deskd`'s own listener setup (`POSIXListener.unixSocket`) probes it
first and unlinks-and-rebinds automatically when nothing answers. If a LaunchAgent is installed,
the app defers to it unconditionally — never starts its own, never stops the LaunchAgent's — even
while it is momentarily unreachable (e.g. between a crash and launchd's restart). Installing the
LaunchAgent while the app is already running its own is also safe: the app notices within one
poll interval (a few seconds) and relinquishes, and launchd's own throttled retries pick it up.

**Ownership.** When the app spawns `pi-deskd` itself, it records the pid and start time in
`daemon-owner.json` (see Storage below). That file is the *only* thing that makes a running
daemon "the app's to stop" — a daemon started by the LaunchAgent or by hand
(`pidesk daemon start`) never has one, so the app can never mistake either for its own, on this
launch or a later one (the record survives an app crash, so a relaunched app still recognises and
continues supervising the same still-alive daemon rather than spawning a duplicate).

**Restart.** If the app-managed daemon dies while the app is running, the app restarts it with
exponential backoff (2s, 4s, 8s, 16s, 32s, capped at 60s) up to 5 attempts; a 6th failure in that
window gives up and surfaces a clear "not responding" state in Settings instead of looping
silently. A daemon that stays up clears the failure count, so an old crash from hours ago never
counts against a currently-stable one.

**Shutdown.** On quit (or a plain `SIGTERM`/`SIGINT`, however it was sent), the daemon stops
scheduling new runs immediately, then gives whatever is already running up to 10 seconds to
finish naturally, then cancels anything still going — the same cooperative cancellation
`POST /v1/threads/{id}/abort` uses, so an in-flight `pi` process still gets a graceful
SIGTERM-then-SIGKILL instead of being abandoned, and the run is recorded as `timeout` rather than
left `running` forever. Only once that has actually finished does the daemon process itself exit.
The app, in turn, waits up to 15 seconds (comfortably above the daemon's own worst case) for the
process to exit before force-killing its whole process group as a last resort — which only
abandons a run if the daemon failed to shut down on its own in that window. In short: a scheduled
run in progress when the app quits gets a real but bounded chance to finish, never a silent
half-written result, and never an orphaned process either way.

**Turning it off.** "Automatically run the background service with this app" in Pi Desktop.app's
Settings persists (`UserDefaults`) and can be turned off entirely; a stopped-by-setting daemon
stops just like a quit does. With it off, automations say so explicitly instead of a bare
"unreachable" error (`ScheduleServiceError.daemonUnavailable`).

## Transports

1. **Unix domain socket** (always on): `~/Library/Application Support/Pi Desktop/daemon.sock`.
   Authorization is filesystem permissions: the socket's directory is `0700`, the socket `0600`.
   This is what the CLI and the app use.
2. **Loopback TCP** (opt-in, for local/tunnel use): `127.0.0.1:<port>`, default port `7717`,
   enabled by `pidesk remote enable`. Every request must carry
   `Authorization: Bearer <token>`, where the token lives in
   `~/Library/Application Support/Pi Desktop/daemon-token` (`0600`, 32 random bytes, base64url).
3. **Hosted relay** (outbound, automatic): `pi-deskd` connects by WSS to
   `remote.ai.gloom.sh`. QR-approved browsers prove possession of the fragment-only ticket, then
   authenticate with a per-device P-256 key and send direction-bound AES-256-GCM envelopes
   through a Cloudflare Durable Object. The Mac retains the approved public key and highest
   mutation counter locally. Hosted protocol version 2 resets incompatible legacy pairing state
   instead of attempting mixed-version traffic. No listener, tunnel, or daemon bearer token is
   exposed. Pairing management remains Unix-socket-only.

Protocol is HTTP/1.1 with JSON bodies, `Content-Type: application/json`, UTF-8. Errors use the
shape `{"error": {"code": "…", "message": "…"}}` with a matching HTTP status. Every response
carries `X-Pi-Desktop-Api: 1`.

## Endpoints (v1)

### Health

```
GET /v1/health
→ {"ok":true,"version":"1.0.0","api":1,"startedAt":"…","runningRuns":1,"queuedRuns":0,
   "piVersion":"0.82.1","schedulesEnabled":true,"scheduleIdempotency":true}
```

### Threads

A *thread* is a Pi session. `id` is the session's stable id; `path` is its JSONL path. Both are
accepted wherever `{id}` appears, so a caller can use whichever it has.

```
GET  /v1/threads?query=&limit=50&cursor=&archived=false&running=
→ {"threads":[Thread],"nextCursor":null}

GET  /v1/threads/{id}?messages=20
→ {"thread":Thread,"messages":[Message]}

POST /v1/threads
     {"cwd":"/Users/x/code","name":"Nightly triage","message":"…","mode":"ultra"}
→ {"thread":Thread,"runId":"…"}          // message is optional; without it the session is created idle

POST /v1/threads/{id}/messages
     {"text":"…","delivery":"auto|steer|followUp","clientId":"web-…"}
→ {"runId":"…","queued":false,"delivery":"auto|steer|followUp"}

POST /v1/threads/{id}/abort           → {"aborted":true}
POST /v1/threads/{id}/archive         {"archived":true} → {"thread":Thread}
POST /v1/threads/{id}/name            {"name":"…"}      → {"thread":Thread}
POST /v1/threads/{id}/read            {"unread":false}  → {"thread":Thread}

GET  /v1/threads/{id}/images/{imageId}
→ {"id":"…","mimeType":"image/png","byteCount":8321,"fileName":"shot.png","data":"<base64>"}
```

**Delivery is reported, not assumed.** `delivery` in the *response* says what actually happened,
which is not always what was asked:

- `steer` / `followUp` are delivered into the live Pi turn by sending Pi's own `steer` /
  `follow_up` command to the session the daemon already has open for that thread. They are never
  turned into a queued prompt behind the current run.
- If there is no daemon-owned turn in flight, there is nothing to interrupt: the text runs as an
  ordinary prompt and the response says `"delivery":"auto"`.
- If Pi rejects the command, the request fails with `409 delivery_rejected` — it is not quietly
  re-queued.
- If the write reached Pi but no acknowledgement arrived in time, the message is reported as
  delivered and **never resent**. Re-queueing is the one failure mode that could prompt Pi twice,
  which is worse than an unconfirmed delivery.
- A thread the *app* has leased still returns `409 thread_leased`; the app owns that runtime.

**`clientId` makes sending replayable.** A phone loses the *response* to a send far more often than
the request, and the natural reaction is to retry — which without this prompts Pi twice. Send a
stable id per message (1–128 letters, numbers, dashes, underscores), reused verbatim on retry:

- The same `(thread, clientId)` returns the original `SendMessageResponse` byte for byte and
  neither enqueues nor delivers anything again.
- A retry that overlaps the original gets `409 submission_in_flight`. That is not a failure; the
  first attempt is still running and the client should keep showing the message as sending.
- A submission that *failed* releases its claim, so an honest retry is never locked out.
- Omitting `clientId` is allowed and behaves exactly as before: no replay protection.
- Bounded and in-memory: 256 submissions, 30 minutes. A daemon restart forgets them, so a retry
  across a restart can still duplicate. `runs.jsonl` records no client id, so closing that window
  would mean a new persisted store for a gap measured in seconds; it is documented, not built.
- Independent of the hosted relay's mutation counter, which rejects a replayed *ciphertext frame*
  outright. This replays a response to a legitimately re-sent request; neither weakens the other.

**`attachments` are rejected, not dropped.** A non-empty `attachments` array returns
`400 attachments_unsupported`. This daemon has no path from an attachment to Pi's prompt, and
accepting the message while silently discarding its images would report a success the caller never
got. Attach images in the Mac app.

**Inline images** are metadata in the transcript and bytes on demand. `Message.images` carries
`{id, mimeType, byteCount, fileName, status, note}` and never base64, because one screenshot-heavy
thread detail would otherwise exceed the hosted relay's per-payload ceiling.

`status` is a promise about what fetching will do:

- `ok` — the payload is present, within the size limit, and validly encoded, so
  `GET /v1/threads/{id}/images/{imageId}` **will** return bytes. Encoding is checked when the
  transcript is projected, so `ok` never advertises an image that can only fail to load.
- `omitted` — past this view's automatic budget. Still fetchable by id; the cap bounds what a
  client loads *without being asked*, so a client may offer an explicit "load".
- `tooLarge` / `invalid` — will never return bytes.

Anything other than `ok` carries a `note` to show in place of the picture rather than dropping it
silently. Bounds: at most 8 images per message, 40 marked `ok` per `GET /v1/threads/{id}` (newest
first), 1 MB decoded per image. `imageId` is `"<jsonlRecordOrdinal>-c<blockIndex>"` for a `content`
block or `…-a<n>` for an `attachments` entry; Pi only appends, so an id stays valid for the life of
the file.

```jsonc
// Thread
{
  "id": "019f9dea-…", "path": "/Users/x/.pi/agent/sessions/--Users-x-code--/….jsonl",
  "name": "Desktop app", "cwd": "/Users/x/code", "folder": "code",
  "createdAt": "…", "updatedAt": "…",
  "running": true, "unread": false, "archived": false,
  "preview": "first line of the last assistant message",
  "cost": 12.34, "contextPercent": 61.0
}
// Message
{ "id":"…", "role":"user|assistant|toolResult|system", "text":"…", "at":"…", "isError":false,
  "images":[{"id":"12-c1","mimeType":"image/png","byteCount":8321,"fileName":"shot.png",
             "status":"ok|omitted|tooLarge|invalid","note":null}] }
```

### Folders

```
GET /v1/folders
→ {"folders":[{"id":"…","name":"Review","parentId":null,"depth":0}],
   "assignments":{"/Users/x/.pi/agent/sessions/…/….jsonl":"<folderId>"}}
```

Read-only projection of the app's own virtual folders from `state.json`. The daemon never writes
that file. `parentId` uses the app's group-id scheme — `null` for top level, a filesystem project
path, or `"virtual:<uuid>"` — and is always the *effective* parent: a cycle or a dangling parent is
already resolved to top level, and folders past a depth of 24 are dropped, so a client renders the
list without any cycle logic of its own. Assignments naming a folder that did not survive are
dropped for the same reason. Missing, legacy (pre-nesting), or malformed state yields an empty
tree, never an error.

### Activity

```
GET /v1/activity
→ {"running":[{"threadId":"…","since":"…","source":"daemon|app|terminal"}],
   "unreadCount":3,"observedAt":"…"}
```

Run state comes from the same heartbeat files the app uses
(`~/.pi/agent/desktop-activity/*.json`), so the CLI, the web remote, and the app always agree.

### Schedules

```
GET    /v1/schedules                       → {"schedules":[Schedule]}
POST   /v1/schedules      {Schedule}       → {"schedule":Schedule}
GET    /v1/schedules/{id}                  → {"schedule":Schedule,"runs":[Run]}
PATCH  /v1/schedules/{id} {partial}        → {"schedule":Schedule}
DELETE /v1/schedules/{id}                  → {"deleted":true}
POST   /v1/schedules/{id}/run              → {"runId":"…"}      // run now, out of band
POST   /v1/schedules/{id}/pause            {"paused":true} → {"schedule":Schedule}
```

`POST /v1/schedules` accepts an optional `idempotencyKey` (16–64 letters, numbers, dashes, or
underscores). Repeating the same request with the same key returns the existing schedule; reusing
the key for different content is rejected.

```jsonc
// Schedule
{
  "id": "sch_…",
  "name": "Morning triage",
  "enabled": true,
  "target": { "kind": "existingThread", "threadId": "…" },
     // or  { "kind": "newThread", "cwd": "/Users/x/code", "namePattern": "Triage {date}" }
  "prompt": "Check overnight CI failures and summarise",
  "mode": "ultra",                     // optional, applies the /mode extension before the prompt
  "trigger": { … see below … },
  "policy": {
    "skipIfRunning": true,             // never stack runs on a busy thread
    "catchUpMissed": false,            // fire once on wake for a trigger missed while asleep
    "timeoutSeconds": 3600,
    "quietHours": {"from":"23:00","to":"07:00","timeZone":"Europe/Paris"}
  },
  "createdAt": "…", "updatedAt": "…",
  "lastRunAt": "…", "lastStatus": "ok|failed|skipped", "nextRunAt": "…"
}

// Triggers
{"kind":"once",      "at":"2026-07-27T09:00:00Z"}
{"kind":"interval",  "everySeconds":3600,"startAt":"…"}
{"kind":"cron",      "expression":"0 9 * * 1-5","timeZone":"Europe/Paris"}
{"kind":"heartbeat", "everySeconds":900}   // fires only while the thread is idle; never stacks
```

Cron support is the standard 5-field form (minute hour day-of-month month day-of-week) with
`*`, `,`, `-`, `*/n` and named months/days. Anything unparseable is rejected at creation time
with a clear error rather than silently never firing.

### Runs

```
GET /v1/runs?scheduleId=&threadId=&limit=50 → {"runs":[Run]}
GET /v1/runs/{id}                            → {"run":Run}
```

```jsonc
// Run
{ "id":"run_…","scheduleId":"sch_…","threadId":"…","trigger":"schedule|manual|api",
  "startedAt":"…","finishedAt":"…","status":"running|ok|failed|skipped|timeout",
  "error":null,"summary":"first line of the answer" }
```

### Limits

```
GET /v1/limits → {"report":{…parsed /limits…},"generatedAt":"…","stale":false}
```

### Interactions

A daemon run can block on a dialog Pi raises over `extension_ui_request` — an
`ask_user_question` step, a permission prompt, an editor request. These endpoints are how a remote
client sees and answers them.

```
GET  /v1/interactions?threadId=          → {"interactions":[PendingInteraction]}
POST /v1/interactions/{id}/respond
     {"value":"…"} | {"confirmed":true} | {"cancelled":true}
→ {"accepted":true}
```

Exactly one answer field, and one that suits the dialog's `method`:

| Response | Accepted for | Rejected |
|---|---|---|
| `{"value":"…"}` | `select`, `input`, `editor` | `confirm`, and any `select` value Pi did not offer |
| `{"confirmed":true\|false}` | `confirm` | everything else |
| `{"cancelled":true}` | every method, including unknown ones | combining it with `value`/`confirmed` |

Combining fields, omitting all of them, or answering an unrecognised method with anything but a
cancellation is `400`. `503 response_not_delivered` means the write to Pi failed: the answer did
*not* land, the dialog is still pending, and it can be retried — the one thing this endpoint will
not do is report success for an answer Pi never received.

```jsonc
// PendingInteraction
{ "id":"…", "runId":"run_…", "threadId":"…",
  "method":"select|confirm|input|editor", "title":"…", "message":"…",
  "options":["Alpha","Beta"],            // the exact strings Pi offered
  "placeholder":null, "prefill":null,
  "createdAt":"…", "expiresAt":"…", "resolvedAt":null,
  // Present only when the dialog was matched to an ask_user_question tool call in the same run:
  "header":"Auth", "multiSelect":false, "questionIndex":0, "questionCount":2,
  "choices":[{"id":0,"value":"Alpha","label":"OAuth","description":"…","preview":"…"}] }
```

Rules this endpoint holds to:

- **`GET` is authoritative.** The `interaction` SSE event is only a hint that something changed; a
  client that reconnected, was backgrounded, or missed a frame re-reads this list rather than
  trusting accumulated state.
- **Nothing is ever auto-answered.** A `select` response must be one of `options` verbatim, or the
  request is rejected with `400 invalid_option`. A body with no `value` and no `confirmed` is
  rejected too; only an explicit `{"cancelled":true}` declines.
- **`choices[].value` is what to submit.** Single-select values are Pi's raw option strings;
  multi-select (which the questionnaire plugin models as a typed `input`) uses the 1-based index
  encoding, so a client never reconstructs an option format.
- **Bounded.** At most 16 pending dialogs; past that the daemon cancels the new request outright
  rather than leaving Pi blocked on something nobody will see. Options are capped at 100 entries,
  500 characters each, 20 000 in total, and an answer at 20 000 characters. Each dialog expires
  (Pi's own `timeout`, else 10 minutes, capped at 30) and expiry sends Pi an explicit
  *cancellation* — never an invented answer — so the run unwinds instead of burning its timeout.
- **Cleared on every exit.** Answering, expiry, and the run ending all retire the dialog; a
  finished run never leaves an unanswerable prompt on a phone.
- **Unknown methods are surfaced, not swallowed.** Only the methods the app itself handles without
  replying — `notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text` — are filtered out.
  Anything else, including a `method` this build has never seen, may be holding the run hostage, so
  it appears in the list; a client shows it with a Cancel button, and cancellation is the only
  answer the daemon will forward for it.

### Hosted remote management (local Unix socket only)

```
GET    /v1/remote                         → connection, paired devices, pending approvals
POST   /v1/remote/pairings                → one-time QR URL + five-minute expiry
POST   /v1/remote/pairings/{id}           {"approved":true|false}
DELETE /v1/remote/devices/{id}            → {"deleted":true}
```

These endpoints reject TCP and hosted-relay origins. A paired browser can call the ordinary API
but cannot approve another browser.

### Events (SSE)

```
GET /v1/events            // text/event-stream
event: thread      data: {Thread}
event: activity    data: {…GET /v1/activity payload…}
event: run         data: {Run}
event: schedule    data: {Schedule}
event: interaction data: {PendingInteraction}   // resolvedAt set = it is no longer answerable
: keep-alive every 20s
```

Clients must tolerate unknown event names and unknown JSON fields — the same
forward-compatibility rule the app applies to Pi's own RPC events.

## Storage

```
~/Library/Application Support/Pi Desktop/
  daemon.sock          control socket
  daemon-token         bearer token for the loopback listener (0600)
  daemon.json          daemon settings: port, concurrency, loopback remote enabled
  relay-identity.json  hosted installation/host keys, approved device keys, replay counters (0600)
  daemon-owner.json    pid + start time of the pi-deskd Pi Desktop.app itself started, if any —
                       local coordination between the app and pidesk, not part of this API
  schedules.json       every Schedule, written atomically
  runs.jsonl           append-only run history, rotated at a bounded size
  state.json           existing app state (archive, folders, drafts, unread) — unchanged
~/Library/Logs/Pi Desktop/daemon.log
```

The daemon owns `schedules.json` and `runs.jsonl`. The app reads them through the API, never by
touching the files, so there is exactly one writer.

## Execution model

- At most `concurrency` (default 2) runs at once; the rest queue in FIFO order.
- A run spawns `pi --mode rpc` for the target session, applies `mode` if requested, sends the
  prompt, streams events until `agent_settled`, then stops the runtime. A run that exceeds
  `timeoutSeconds` is aborted and recorded as `timeout`.
- `skipIfRunning` consults the heartbeat state, so a thread a human is using in a terminal is
  never disturbed.
- The daemon must not run a scheduled prompt while the same thread is attached to the app's own
  runtime — the app announces its attachment through the API (`POST /v1/threads/{id}/lease`).
- Every run is recorded in `runs.jsonl` with its status and a bounded summary.
- While a run's turn is in flight, its session is published in a live registry keyed by thread and
  generation-checked by run id, which is what makes `delivery: steer|followUp` possible. It is
  registered only after Pi accepts the prompt and removed on every exit path, so a settling run
  can never retire its successor's registration.
- **The settlement boundary is guarded on both sides.** Admission closes under the same lock a
  delivery claims its reservation with, so a caller either gets in before the run finishes or finds
  nothing and falls back to a fresh queued run — there is no window in between, and the executor
  never stops a session while a write or acknowledgement is outstanding.
- **`steer` and `follow_up` settle differently, because Pi runs them differently.** A `steer` is
  folded into the turn already running, so the next `agent_settled` *is* its settle and the run may
  end there. A `follow_up` runs as its own later turn, so an accepted (or unacknowledged) one banks
  a *turn credit* the run must spend before admission can close — otherwise the settle of the turn
  already in progress would stop the session and discard it. Crediting a steer would be the mirror
  mistake: the run would wait for a turn that never starts and record a finished conversation as a
  timeout.
- **A delivery still in flight when the boundary arrives is the ambiguous case.** It may have
  landed too late to join the settling turn, so if it could have been delivered at all the run
  continues exactly once; if Pi rejected it or the write failed, it owes nothing and the run
  closes. Each credit extends the deadline by up to five minutes, and a run may be extended at most
  8 times before further live messages are refused and queue as new runs instead. Steering is not
  rate-limited by that bound, since it owes no turns.
- **Writing to Pi is bounded.** A full stdin buffer — what a wedged `pi` looks like — would
  otherwise park the writing task indefinitely, holding an HTTP handler and the session's write
  lock. Writes use a non-blocking descriptor with a 15-second `poll()` deadline; a timeout fails
  the command (nothing incomplete can have been executed, so the caller may safely queue it
  instead) and poisons the session's writer, since a partial record cannot be repaired by writing
  more.
- Pi's stdin has exactly one writer lock (request ids and whole JSONL lines are written under it)
  and its stdout exactly one drainer (the run's own event loop). A steer delivered from an HTTP
  handler collects its acknowledgement from the bounded response cache that loop fills; it never
  reads the pipe itself.

## CLI surface

```
pidesk threads list [--json] [--query q] [--running] [--archived]
pidesk threads show <id> [--messages N] [--json]
pidesk threads new --cwd DIR [--name N] [--message M] [--mode ultra]
pidesk threads send <id> "text" [--steer|--follow-up] [--wait]
pidesk threads abort|archive|unarchive|rename <id> [args]
pidesk threads watch [<id>]                     # streams /v1/events

pidesk schedule list [--json]
pidesk schedule add --name N (--thread ID | --cwd DIR) --prompt P
                    (--at ISO | --every 15m | --cron "0 9 * * 1-5" | --heartbeat 15m)
                    [--mode ultra] [--skip-if-running] [--timeout 30m]
pidesk schedule show|pause|resume|remove|run <id>

pidesk daemon status|start|stop|restart|install|uninstall|logs [-f]
pidesk remote enable [--port 7717] | disable | url | token
pidesk limits [--json]
```

Every command supports `--json` so another agent can drive the app without screen-scraping.
Exit codes: `0` ok, `1` request failed, `2` bad usage, `3` daemon unreachable.

## Compatibility rules

- `X-Pi-Desktop-Api` is bumped only for breaking changes; additive fields never bump it.
- Unknown fields in requests are rejected with `400 unknown_field` only when they change
  behaviour; otherwise they are ignored, so an older daemon and a newer CLI still interoperate.
- Every client shows a clear, non-fatal message when the daemon is missing, outdated, or
  unreachable, and keeps working in read-only/local mode where that is possible.
