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

The daemon is a LaunchAgent (`dev.pi.desktop.daemon`) that starts at login and restarts on
failure. It must be safe to run with no app open, and safe to have no daemon at all: the app
degrades to local-only behaviour and says so.

## Transports

1. **Unix domain socket** (always on): `~/Library/Application Support/Pi Desktop/daemon.sock`.
   Authorization is filesystem permissions: the socket's directory is `0700`, the socket `0600`.
   This is what the CLI and the app use.
2. **Loopback TCP** (opt-in, for the web remote): `127.0.0.1:<port>`, default port `7717`,
   enabled by `pidesk remote enable`. Every request must carry
   `Authorization: Bearer <token>`, where the token lives in
   `~/Library/Application Support/Pi Desktop/daemon-token` (`0600`, 32 random bytes, base64url).
   Exposing that port beyond the machine is the user's choice (an SSH or Cloudflare tunnel);
   the daemon never opens a public listener itself and never ships a tunnel client.

Protocol is HTTP/1.1 with JSON bodies, `Content-Type: application/json`, UTF-8. Errors use the
shape `{"error": {"code": "…", "message": "…"}}` with a matching HTTP status. Every response
carries `X-Pi-Desktop-Api: 1`.

## Endpoints (v1)

### Health

```
GET /v1/health
→ {"ok":true,"version":"1.0.0","api":1,"startedAt":"…","runningRuns":1,"queuedRuns":0,
   "piVersion":"0.82.1","schedulesEnabled":true}
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
→ {"runId":"…","queued":false}

POST /v1/threads/{id}/abort           → {"aborted":true}
POST /v1/threads/{id}/archive         {"archived":true} → {"thread":Thread}
POST /v1/threads/{id}/name            {"name":"…"}      → {"thread":Thread}
POST /v1/threads/{id}/read            {"unread":false}  → {"thread":Thread}
```

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
{ "id":"…", "role":"user|assistant|toolResult|system", "text":"…", "at":"…", "isError":false }
```

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

### Events (SSE)

```
GET /v1/events            // text/event-stream
event: thread    data: {Thread}
event: activity  data: {…GET /v1/activity payload…}
event: run       data: {Run}
event: schedule  data: {Schedule}
: keep-alive every 20s
```

Clients must tolerate unknown event names and unknown JSON fields — the same
forward-compatibility rule the app applies to Pi's own RPC events.

## Storage

```
~/Library/Application Support/Pi Desktop/
  daemon.sock          control socket
  daemon-token         bearer token for the loopback listener (0600)
  daemon.json          daemon settings: port, concurrency, remote enabled
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
