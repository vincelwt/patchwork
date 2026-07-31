# Pi Desktop control plane

Pi Desktop grows a headless half so threads can run, be scheduled, and be driven when the
window is closed — from a CLI, from another agent, or from a phone. This document is the
contract between the four pieces. It is normative: the service host, CLI, web remote, and app
all implement exactly what is written here.

```
        pidesk (CLI)        web remote (browser)        Pi Desktop.app
              \                    |                        /
               \                   |                       /
                +-------- HTTP/JSON control API ----------+
                                   |
                 in-app service (default) or pi-deskd
                                   |
                     spawns `pi --mode rpc` per run
                                   |
                        ~/.pi/agent/sessions/*.jsonl
```

Pi stays the source of truth. The control service never writes a session file itself; it drives
the Pi CLI exactly like the conversation UI does. Schedules, tokens, and run history are
app-owned metadata.

## Processes

| Piece | Target | Binary | Role |
|---|---|---|---|
| Service | `PiDeskDaemon` | linked into the app | Scheduler, thread runner, control API |
| Standalone host | `PiDeskDaemonMain` | `pi-deskd` | Optional LaunchAgent host for the same service |
| CLI | `PiDeskCLI` | `pidesk` | Thin client over the control API |
| Shared | `PiDeskKit` | — | Wire models, client, and shared paths |
| App | `PiDesktop` | `Pi Desktop.app` | Window UI and default service host |

The service must be safe to host either inside the app or in the optional standalone process.

## Lifecycle

There are two hosts for one `PiDeskControlService`, and exactly one owns the control socket:

- **Inside Pi Desktop (default).** The scheduler, API, relay, run queue, and Pi workers are linked
  into `Pi Desktop.app` and created from `AppDelegate`. There is no child daemon process. The app
  stops accepting work, cancels its service-owned runs cooperatively, and waits for teardown
  before it exits.
- **LaunchAgent (explicit, always-on).** `scripts/install-daemon.sh` (or
  `pidesk daemon install`) runs the small `pi-deskd` host at login. It uses the same service code
  and storage but remains independent of the window app.

Both modes use the same `~/Library/Application Support/Pi Desktop/*` files. Before starting its
in-process host, the app defers to an installed LaunchAgent or any healthy owner of the Unix
socket. A leftover socket file is not evidence of a live host; `POSIXListener` probes it and
rebinds when nothing answers.

**Ownership and migration.** In default mode `daemon-owner.json` contains the Pi Desktop process
PID plus an app-host marker, preserving `pidesk daemon status` compatibility without mistaking a
second live app instance for the legacy child process. A previous release may have left an
app-spawned `pi-deskd` child alive after a crash; the first new launch retires only that recorded
legacy PID before binding in-process. Ownerless and LaunchAgent hosts are never stopped by the
app.

**Shutdown and recovery.** Quitting Pi Desktop stops scheduling immediately and cancels every
run owned by its in-process service. Each Pi child still receives cooperative SIGTERM with a
bounded SIGKILL fallback; direct terminal `pi` processes are unrelated and untouched. Queued
scheduled occurrences remain durable for the next launch. Pre-prompt scheduled work may retry,
while work whose prompt delivery began is marked `interrupted` and never resent blindly.
Process-local API/manual queue records are also reconciled to `interrupted` on restart instead of
remaining falsely `running`. Native UI turns keep a separate bounded app-owned recovery marker:
a heartbeat-verified accepted turn with no live writer or tool in flight gets one continuation
against the same session after relaunch; unknown ownership or prompt delivery, an active tool, or
a second interrupted recovery requires review. Sessions launched by plain terminal `pi` never
get that marker and are not adopted. The
standalone host keeps its existing ten-second finish-naturally grace on SIGTERM/SIGINT before
cancellation.

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
   "piVersion":"0.82.1","schedulesEnabled":true,"scheduleIdempotency":true,
   "threadWorktrees":true}
```

### Threads

A *thread* is a Pi session. `id` is the session's stable id; `path` is its JSONL path. Both are
accepted wherever `{id}` appears. A unique id prefix or suffix is also accepted; ambiguous
abbreviations return `400 ambiguous_thread_id` rather than choosing one.

```
GET  /v1/threads?query=&limit=50&cursor=&archived=false&running=&automated=&agent=
→ {"threads":[Thread],"nextCursor":null}

GET  /v1/threads/{id}?messages=20&offset=0&all=true
→ {"thread":Thread,"messages":[Message],"nextOffset":20}

POST /v1/threads
     {"cwd":"/Users/x/code","name":"Nightly triage","message":"…","mode":"ultra","worktree":true,
      "agent":"pi"}
→ {"thread":Thread,"runId":"…"}          // message is optional; `thread.id` is always a real session id

GET  /v1/threads/{id}/runtime
→ {"runtime":{"provider":"openai-codex","modelId":"gpt-5","modelName":"GPT-5",
               "thinkingLevel":"high","availableModels":[…],
               "availableThinkingLevels":["off","high"],"running":false}}
POST /v1/threads/{id}/runtime/model    {"provider":"openai-codex","modelId":"gpt-5"}
POST /v1/threads/{id}/runtime/thinking {"level":"high"}
→ {"runtime":…}

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

A message-bearing create resolves an idle Pi session first, then queues the first prompt against
that session. The response therefore never invents a `pending:<run>` thread id that cannot be
opened. Older clients may still use `runId` to follow the prompt itself. With `worktree:true`,
the daemon uses the same managed worktree algorithm as the Mac app and records the exact source
`cwd` in its own overlay so the app groups the thread under the source project. If idle-session
creation fails, the unused worktree is removed non-force. The thread and run keep the real
worktree as their execution `cwd`.

Thread detail defaults to the existing raw projection (`all=true`) for API compatibility. Set
`all=false` to retain only user and assistant roles. `offset` is applied after that filter and
`nextOffset` is present only when an older page exists. List `automated=true` keeps threads
associated with any automation, including paused ones.

### Agents

Every thread carries `agent` (`pi|codex|claude`), decided by which agent's session root the
transcript was discovered under. The daemon lists and reads all three; an agent name it does not
know decodes as `pi` rather than failing the whole list, so a newer daemon never breaks an older
client.

`GET /v1/threads?agent=` filters by exact agent and returns `400 invalid_agent` for a value
outside the set — a filter that silently matched everything would look like it worked.

Only Pi threads can be *driven* by the daemon today. Every route that would attach a runtime —
`POST /v1/threads`, `POST /v1/threads/{id}/name`, `GET /v1/threads/{id}/runtime`, and both
`runtime/model` and `runtime/thinking` — returns a clear `agent_unsupported` error for a non-Pi
thread instead of launching `pi --mode rpc --session` against another agent's transcript, which
would append Pi's own records to that file. Sending a message to a non-Pi thread is accepted by
the queue and fails the run with the same explanation. Reading (list, detail, messages,
images) works for all three. Codex subagent rollouts (`"subsession": true`) are read but never
listed as threads.

`Schedule.agent` and `Run.agent` are optional and absent means Pi, so every pre-multi-agent
`schedules.json` and `runs.jsonl` record keeps its meaning.

**Archive is the daemon's own flag, not the app's.** It is written to the daemon overlay file, and
`Thread.archived` is the union of that flag with the app's `state.json`, which the daemon reads
and never writes. So `{"archived":true}` always takes, but `{"archived":false}` on a thread the
*app* archived cannot clear it: that answers `409 archived_in_app` rather than a success the caller
did not get. Restore it in the Mac app. Accepting a message automatically clears the daemon's
archive flag first; it returns the same `409` when the app's flag would still keep the thread
archived.

**Runtime controls use Pi, never the JSONL file.** The runtime endpoints issue Pi's own query and
`set_model` / `set_thinking_level` RPCs. During a daemon-owned turn they share that live process;
while idle they reserve the thread and attach a short-lived process. A native-app lease returns
`409 thread_leased`, and another queued/running attachment returns `409 thread_busy`, rather than
starting two writers for one session. Models are bounded to 500 and thinking levels to 32; unknown
future values remain visible. Lease acquisition is non-stealing: a different live owner gets
`409 thread_leased`, while the same owner may renew its TTL.

### Worktrees

```
GET /v1/worktrees?cwd=/Users/x/code
→ {"worktrees":[{"path":"/Users/x/code","name":"code","branch":"main","isMain":true},
                {"path":"/Users/x/code-worktrees/feature","name":"feature",
                 "branch":"feat/thing","isMain":false}]}
```

Every existing checkout of the repository containing `cwd`, main first, so a client can start a
thread in a worktree that already exists. This GET endpoint is discovery only: `git worktree list`
is run through a fixed `/usr/bin/git` path with no shell, and the request never mutates a checkout.
A directory that is not a repository (or a machine without git) answers with an empty list rather
than an error. Bounds: 64 entries, 256 KB of git output, 5-second timeout. A missing or
non-directory `cwd` is `400 invalid_cwd`.

Starting a thread in a chosen checkout needs no extra field: pass its `path` as `POST /v1/threads`'s
`cwd`. To create a fresh managed worktree instead, pass the source project as `cwd` with
`worktree:true`.

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
- A run that ends on its timeout or on `abort` closes admission first and then waits, up to three
  seconds, for deliveries already mid-write — still reading Pi's output, so an acknowledgement that
  arrived is seen — before the process is stopped. A steer that lands in that window reports what
  actually happened instead of an unknown outcome; one that does not still reports as delivered.
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
- Only *completed* submissions are evicted to make room. If all 256 slots hold sends that have not
  finished, a new `clientId` gets `503 submissions_busy` rather than costing one of them its
  protection — refusing a message is recoverable, prompting Pi twice is not. Retry shortly.
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
first), 1 MB decoded per image. New `imageId`s use `"b<byteOffset>-c<blockIndex>"` for a `content`
block or `…-a<n>` for an attachment, so the daemon can seek straight to bytes without scanning a
large session. Legacy ordinal IDs remain accepted during upgrades; Pi only appends, so both forms
stay valid for the life of the file.

**Structure is additive; `text` never changes.** `Message.text` stays the flattened projection of
the whole message (`[thinking] …`, `[tool: name]` markers included), so a client that knows nothing
about the fields below renders exactly what it always did. Everything else is optional and absent
when it has nothing to say:

- `blocks` — ordered content blocks, sent only for assistant messages (where block order is what
  separates mid-turn narration from the turn's answer) and for compaction/branch summaries (title
  block, then summary block). A `toolCall` block carries `callId`, `name`, and `arguments`, the
  last as bounded pretty-printed *text* rather than nested JSON, since a client only displays it.
  An unrecognised block `type` keeps its position instead of being dropped.
- `toolCallId` / `toolName` — on a `toolResult`, the call it answers, so a client can attach a
  result to the exact call rather than guessing by position.
- `stopReason` — Pi's own terminal reason (`stop`, `length`, `error`, `aborted`).

Bounds: at most 40 blocks per message; one shared 4,000-character budget per message across all
block text and tool arguments; and 256 characters for each structural value (block type, call ID,
tool name, role, and stop reason). A transcript carrying blocks therefore stays the same order of
magnitude as one carrying only `text`. Tool calls are admitted even once the text budget is spent,
because their bounded identity is what makes results attachable.

```jsonc
// Thread
{
  "id": "019f9dea-…-a1b2c3d4e5f6", "shortId": "a1b2c3d4e5f6",
  "path": "/Users/x/.pi/agent/sessions/--Users-x-code--/….jsonl",
  "name": "Desktop app", "cwd": "/Users/x/code", "folder": "code",
  "createdAt": "…", "updatedAt": "…",
  "running": true, "unread": false, "archived": false, "automated": true,
  "project": "/Users/x/code", "worktree": "/Users/x/.pi/worktrees/code-20260730-120000",
  "preview": "first line of the last assistant message",
  "agent": "pi",                       // pi|codex|claude; absent means pi
  "cost": 12.34, "contextPercent": 61.0
}
// Message
{ "id":"…", "role":"user|assistant|toolResult|system", "text":"…", "at":"…", "isError":false,
  "images":[{"id":"12-c1","mimeType":"image/png","byteCount":8321,"fileName":"shot.png",
             "status":"ok|omitted|tooLarge|invalid","note":null}],
  // optional, additive
  "blocks":[{"type":"thinking","text":"…"},
            {"type":"text","text":"Running the suite."},
            {"type":"toolCall","callId":"call_1","name":"bash","arguments":"{\n  \"command\": \"swift test\"\n}"}],
  "toolCallId":"call_1", "toolName":"bash", "stopReason":"stop" }
```

### Folders

```
GET /v1/folders
→ {"folders":[{"id":"…","name":"Review","parentId":null,"depth":0}],
   "assignments":{"/Users/x/.pi/agent/sessions/…/….jsonl":"<folderId>"},
   "projectAssignments":{"/Users/x/code/repo":"<folderId>"}}
```

Read-only projection of the app's own virtual folders from `state.json`. The daemon never writes
that file. `parentId` uses the app's group-id scheme — `null` for top level, a filesystem project
path, or `"virtual:<uuid>"` — and is always the *effective* parent: a cycle or a dangling parent is
already resolved to top level, and folders *past* depth 24 are dropped — the same boundary the Mac
sidebar draws, which renders the folder at depth 24 and stops at its children — so a client renders
the list without any cycle logic of its own. A project path in `parentId` hosts folders without
being a level of nesting: its folders start at depth 0, exactly like top-level ones.
`projectAssignments` performs the inverse grouping, mapping a real project path into a virtual
folder. Invalid and cyclic project assignments are dropped. Conversation assignments naming a
folder that did not survive are dropped for the same reason. Missing, legacy (pre-nesting), or
malformed state yields an empty tree, never an error.

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
    "catchUpMissed": false,            // deprecated compatibility field; global catch-up wins
    "timeoutSeconds": 3600,
    "quietHours": {"from":"23:00","to":"07:00","timeZone":"Europe/Paris"}
  },
  "createdAt": "…", "updatedAt": "…",
  "lastRunAt": "…", "lastStatus": "queued|ok|failed|skipped|timeout|interrupted",
  "nextRunAt": "…",
  "pendingOccurrence": {               // daemon-owned durable work; at most one per schedule
    "id":"occ_…", "scheduledAt":"…", "phase":"pending|dispatching|accepted",
    "attemptCount":1, "notBefore":"…", "runId":"run_…"
  }
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
  "startedAt":"…","finishedAt":"…",
  "status":"queued|running|ok|failed|skipped|timeout|interrupted",
  "error":null,"summary":"first line of the answer",
  "occurrenceId":"occ_…","scheduledAt":"…","attempt":1,
  "nextAttemptAt":null,"promptStartedAt":null,"promptAcceptedAt":null,"retryable":false }
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
  daemon-owner.json    pid + start time + host kind of the active app-hosted service, if any — local
                       coordination between Pi Desktop and pidesk, not part of this API
  schedules.json       every Schedule, written atomically
  runs.jsonl           append-only run history, rotated at a bounded size
  state.json           app state (archive, folders, drafts, unread, bounded native-turn recovery)
~/Library/Logs/Pi Desktop/daemon.log
```

The active control-service host owns `schedules.json` and `runs.jsonl`. UI code reads them through
the API, never by touching the files, so there is exactly one writer.

## Execution model

- At most `concurrency` (default 2) runs at once; the rest queue in FIFO order.
- When the app-hosted service returns, overdue once/cron/interval triggers globally coalesce into
  one durable occurrence per schedule, ordered by their original due time. Heartbeats resume from
  now and never replay an old check. The legacy `catchUpMissed` field is ignored.
- A macOS network path reported offline leaves occurrences pending without spending an attempt.
  Definite temporary failures before prompt delivery retry after 1m, 5m, 30m, 2h, and 8h; the
  attempt and deadline live in `schedules.json`, so closing the app only pauses the backoff. A
  prompt whose delivery began is outcome-ambiguous after interruption and is never auto-sent again.
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
pidesk                                      # active thread list, then help
pidesk threads list [--query q] [--agent pi|codex|claude] [--running] [--automated]
                    [--archived|--all] [--json]
pidesk threads show <id> [--messages N] [--offset N] [--all] [--json]
pidesk threads new --cwd DIR [--agent pi|codex|claude] [--worktree] [--name N]
                   [--message M] [--mode ultra]
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
