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
     {"text":"…","delivery":"auto|steer|followUp","attachments":[]}
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

**Inline images** are metadata in the transcript and bytes on demand. `Message.images` carries
`{id, mimeType, byteCount, fileName, status, note}` and never base64, because one screenshot-heavy
thread detail would otherwise exceed the hosted relay's per-payload ceiling. `status` is `ok`,
`omitted` (past this view's image budget), `tooLarge`, or `invalid`; anything other than `ok`
carries a `note` a client shows in place of the picture rather than dropping it silently. Bounds:
at most 8 images per message, 40 fetchable per `GET /v1/threads/{id}` (newest first), 1 MB decoded
per image. `imageId` is `"<jsonlRecordOrdinal>-c<blockIndex>"` for a `content` block or `…-a<n>`
for an `attachments` entry; Pi only appends, so an id stays valid for the life of the file.

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
  rather than leaving Pi blocked on something nobody will see. Each dialog expires (Pi's own
  `timeout`, else 10 minutes, capped at 30) and expiry sends Pi an explicit *cancellation* — never
  an invented answer — so the run unwinds instead of burning its whole timeout.
- **Cleared on every exit.** Answering, expiry, and the run ending all retire the dialog; a
  finished run never leaves an unanswerable prompt on a phone.
- Only the four blocking methods above are surfaced. `notify`, `setStatus`, `setWidget`,
  `setTitle` and anything unrecognised expect no reply, exactly as the app treats them, and are
  not turned into dialogs. A client that cannot render a surfaced method must still show it and
  offer Cancel.

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
