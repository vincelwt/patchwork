# `patchwork` — the Patchwork CLI

`patchwork` is a thin client over the control API described in
[`daemon-api.md`](daemon-api.md). It exists so another agent, a voice assistant, or a script can
fully operate Patchwork without a window: create threads, send follow-ups, manage schedules, and
watch what's happening — all with `--json` for machine consumption.

```
patchwork threads list|show|new|send|abort|archive|unarchive|rename|watch
patchwork schedule list|add|show|pause|resume|remove|run
patchwork daemon status|start|stop|restart|install|uninstall|logs
patchwork remote enable|disable|url|token
patchwork limits
```

Every level answers `--help`/`-h` with real examples: `patchwork --help`, `patchwork threads --help`,
`patchwork threads send --help`. Running bare `patchwork` lists the 20 newest active threads, then
prints top-level help, so an agent gets both discovery and usage in one call.

## Global flags

These work on every command, in any position (before or after the subcommand):

| Flag | Default | Notes |
|---|---|---|
| `--socket PATH` | `~/Library/Application Support/Patchwork/daemon.sock` | Unix domain socket |
| `--url URL` | — | talk to the loopback remote instead, e.g. `http://127.0.0.1:7717` |
| `--token TOKEN` | `$PATCHWORK_TOKEN` | bearer token, only sent with `--url` |
| `--timeout SECONDS` | `10`, or `$PATCHWORK_TIMEOUT` | per-request timeout |
| `--json` | off | machine-readable output (see below) |
| `--quiet` / `-q` | off | suppress incidental/progress text; requested data and errors still print |

`--` stops flag parsing, so an argument that legitimately starts with `-` (message text, a
schedule name, whatever) can be passed through untouched: `patchwork threads send abc -- "-1 degree
today"`. Without `--`, a token starting with `-` that isn't a known flag is a usage error rather
than a guess — ambiguity is rejected, not silently misparsed.

One deliberate exception: **inside `schedule add`, `--timeout DURATION` sets the run's own
timeout** (e.g. `30m`), not the request timeout above — see [`schedule add`](#schedule-add). Set
the client request timeout for that one command via `$PATCHWORK_TIMEOUT` if you ever need to.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | ok |
| `1` | request failed (the daemon was reached but said no, or a stream broke) |
| `2` | bad usage (argument parsing/validation failed locally) |
| `3` | daemon unreachable |

A missing daemon always prints a short, actionable message on stderr and exits `3` — never a
stack trace:

```
$ patchwork threads list
patchwork: cannot reach the Patchwork daemon (socket not found)
start it with `patchwork daemon start` (or `patchwork daemon install` to run at login); check `patchwork daemon status`
```

## JSON output contract

- Every read command supports `--json`. One-shot commands (`list`, `show`, `new`, `add`, …) print
  **one pretty-printed JSON document** with sorted keys — stable field order, safe to diff.
  Streaming commands (`threads watch`, `daemon logs -f`) print **one compact JSON object per
  line** (NDJSON) so a consumer can read incrementally.
- Where the control API already defines a response shape (docs/daemon-api.md), the JSON output
  *is* that shape, verbatim — e.g. `threads list --json` is exactly `{"threads":[Thread],
  "nextCursor":...}`. No extra wrapping, no internal-type dump.
- A few shapes are this CLI's own, because the API doesn't define a CLI-level concept:
  - `threads send --json` always has the keys `runId`, `queued`, `delivery`, `run`; `run` is `null` unless
    `--wait` was given, so the key set never changes based on flags.
  - `threads watch --json` / `daemon logs -f --json`: one line per event, each
    `{"event":"...", "data":{...}, "receivedAt":"..."}` for watch, or `{"line":"..."}` for logs.
  - `daemon status --json`: `{"mode":"appManaged|launchAgent|external|notRunning",
    "modeDetail":"...","health":Health}` when reachable, or `{"ok":false,"mode":"...",
    "error":{"code":"unreachable","message":"..."}}` when not — `mode` is this CLI's own
    knowledge (which of the two lifecycle modes in daemon-api.md is in play, or neither), so it
    wraps the raw `GET /v1/health` shape rather than being merged into it.
  - `daemon start|stop|restart|install|uninstall --json`: `{"ok":true,"action":"...",
    "detail":...}` — these are local process actions, not API calls.
  - `remote enable|disable|url --json`: `{"enabled":bool,"port":N,"url":"...","token":...}`.
  - `remote token --json`: `{"token":"..."}`.
- Progress/incidental text ("Waiting for run to finish…", "Watching for events…") always goes to
  **stderr**, never stdout, so it can never corrupt JSON/NDJSON output on stdout. `--quiet`
  suppresses it entirely.
- Colour is never used in `--json` mode. In human mode it's used only when stdout is a TTY and
  `NO_COLOR` is unset.

## `threads`

```
patchwork threads list [--query TEXT] [--running] [--automated] [--archived | --all]
                    [--limit N] [--cursor C] [--json]
patchwork threads show <id> [--messages N] [--offset N] [--all] [--json]
patchwork threads new --cwd DIR [--agent AGENT] [--worktree] [--name NAME] [--message TEXT] [--mode MODE]
                   [--client-id ID] [--json]
patchwork threads send <id> <text|-> [--steer | --follow-up] [--wait] [--client-id ID] [--json]
patchwork threads abort <id> [--json]
patchwork threads archive <id> [--json]
patchwork threads unarchive <id> [--json]
patchwork threads rename <id> <name> [--json]
patchwork threads watch [<id>] [--json]
```

Notes:

- Lists default to 20 non-archived threads. `--archived` shows only archived threads; list
  `--all` includes both. `--running` and `--automated` are strict filters. `--cursor` continues a
  bounded, coherent catalog snapshot. An opaque cursor that has expired returns `409`; restart
  once without a cursor. A malformed cursor returns `400` rather than silently returning page one.
- Human lists print a UUID's random final segment instead of all 36 characters. Every thread
  endpoint, `watch`, and `schedule add --thread` accepts an unambiguous prefix or suffix. An
  ambiguous abbreviation fails instead of selecting a thread.
- `show` defaults to the latest 8 user/assistant messages and omits tool/system results. Use
  `--all` for the raw message stream and `--offset N` to page older messages. When another page
  exists, human output prints the next command on stderr and JSON includes `nextOffset`.
- `new --worktree` uses the Desktop app's managed worktree flow: main-line base selection,
  `~/.pi/worktrees`, `pi/` branch naming, non-force cleanup on failed creation, and source-project
  organization in the app. The session `cwd` remains the real worktree path.
- Pi and Codex accept `new` without `--message` and create an idle thread. The Codex service always
  materializes that thread with a non-empty requested or fallback name. Claude Code creates its
  conversation with the first message, so `--agent claude` requires `--message`; the CLI rejects a
  missing message before contacting the daemon.
- `<text>` (in `send`) and `--message` (in `new`) accept `-` to read the message from stdin:
  `echo "continue" | patchwork threads send <id> -`.
- `new` and `send` generate one retry id for every invocation. `--client-id` supplies it explicitly
  for a retry across invocations; valid ids are 1-128 ASCII letters, digits, `_`, or `-`. Reuse the
  exact id only for the exact same request. Reusing it for different content is rejected. If a
  create returns a thread plus `firstMessageError`, creation succeeded: send the preserved message
  to that thread and do not recreate it. For a daemon advertising creation idempotency, the CLI
  retries `create_retryable` and `creation_pending` with the same id; `creation_outcome_unknown`
  always requires a thread-list review.
- Delivery: no flag is `"auto"`; `--steer` interrupts the current turn; `--follow-up` queues
  behind it. They're mutually exclusive.
- `--wait` prepares `/v1/events` before sending, filters for the run just started, and streams until
  it reaches a terminal status (`ok`/`failed`/`skipped`/`timeout`). If the stream drops, it polls
  `GET /v1/runs/{id}` until the terminal result is visible. A continuously unreachable daemon stops
  that fallback after the configured global `--timeout`; a healthy long-running run has no overall
  deadline. Exit code is `1` unless the run ended `ok`. A pre-prompt failure may be retried with a
  new id; after delivery may have started, the CLI says to review the thread instead of recommending
  a resend.
- `watch` prints every `thread`/`run`/`schedule`/`activity` event; give it a thread id to filter
  client-side to that thread (the SSE stream itself isn't scoped per-thread). `activity` events
  are global snapshots and always pass through regardless of the filter.

## `schedule`

```
patchwork schedule list [--json]
patchwork schedule add --name NAME (--thread ID | --cwd DIR) --prompt TEXT
                     (--at ISO|LOCAL | --every DUR | --cron EXPR | --heartbeat DUR)
                     [--name-pattern PATTERN] [--timezone TZ] [--start-at ISO|LOCAL]
                     [--agent AGENT] [--mode MODE] [--client-id ID]
                     [--skip-if-running] [--timeout DUR] [--json]
patchwork schedule show <id> [--json]
patchwork schedule pause <id> [--json]
patchwork schedule resume <id> [--json]
patchwork schedule remove <id> [--json]
patchwork schedule run <id> [--client-id ID] [--json]
```

### Target

Exactly one of:
- `--thread ID` — run against an existing thread.
- `--cwd DIR` — create a new thread each run. `--name-pattern` sets the created thread's name
  (e.g. `"Triage {date}"`); it defaults to `--name` if you don't set it separately.

`--name-pattern` is limited to 256 UTF-8 bytes. `{date}` uses the owed occurrence's UTC calendar
date, including when a delayed run catches up later.

`--agent AGENT` applies only to `--cwd`; an existing thread keeps its own agent. `--mode` is only
valid for Pi-backed runs. Schedule creation and manual runs generate a retry id automatically.
Use `--client-id` to repeat the exact same request after a safe-to-retry failure. If the running
daemon does not advertise replay protection and the outcome is ambiguous, inspect the schedule
list or run history before trying again.

### Trigger (exactly one required — ambiguity is a usage error, not a guess)

| Flag | Produces | Example |
|---|---|---|
| `--at ISO\|LOCAL` | `{"kind":"once","at":...}` | `--at 2026-07-27T09:00:00Z` or `--at "2026-07-27T09:00"` |
| `--every DUR [--start-at ...]` | `{"kind":"interval","everySeconds":...}` | `--every 15m` |
| `--cron EXPR [--timezone TZ]` | `{"kind":"cron","expression":...,"timeZone":...}` | `--cron "0 9 * * 1-5"` |
| `--heartbeat DUR` | `{"kind":"heartbeat","everySeconds":...}` | `--heartbeat 15m` |

**Durations** (`--every`, `--heartbeat`, `schedule add --timeout`): an integer/decimal plus a unit
(`s`, `m`, `h`, `d`), optionally compounded — `45s`, `15m`, `2h`, `1d`, `1h30m`. A bare number
without a unit is rejected rather than assumed to be seconds.

**Dates** (`--at`, `--start-at`): either strict ISO-8601 with a zone (`2026-07-27T09:00:00Z`,
`2026-07-27T09:00:00+02:00`), or a friendly local datetime with no zone
(`2026-07-27T09:00`, `2026-07-27 09:00`, `2026-07-27`) interpreted in your machine's local time
zone (override with `TZ=...`) and converted to an absolute instant before being sent.

**Cron** (`--cron`): standard 5-field `minute hour day-of-month month day-of-week`, with `*`,
`,`, `-`, `*/n`, and named months/weekdays (`JAN`-`DEC`, `MON`-`SUN`, case-insensitive). Validated
locally at parse time — an unparseable expression is a usage error (exit `2`), not something that
reaches the daemon and silently never fires. `--timezone` defaults to your machine's local zone.

### Policy

- `--skip-if-running` — never stack a run on a thread that's already busy.
- `--timeout DUR` — abort the run if it exceeds this. **Note:** this is a different flag from the
  global `--timeout SECONDS`; see [Global flags](#global-flags).

## `daemon`

```
patchwork daemon status [--json]
patchwork daemon start
patchwork daemon stop
patchwork daemon restart
patchwork daemon install
patchwork daemon uninstall
patchwork daemon logs [-f] [--lines N] [--json]
```

`patchwork daemon status` reports reachability itself — when the daemon is down this is expected
output, not a crash, but it still exits `3` (consistent with every other command) so scripts can
branch on it. It also reports **mode**: `app-managed` (hosted inside Patchwork.app by default —
see daemon-api.md's "Lifecycle"), `LaunchAgent` (installed with `install` below or
`scripts/install-daemon.sh`), reachable-but-neither ("external" — started by hand, or by
`daemon start`'s own fallback), or not running at all. `install` registers `patchworkd` as a
LaunchAgent (`app.patchwork.desktop.daemon`, starts at login, restarts on crash but not on a clean
exit); `start`/`stop`/`restart` drive that LaunchAgent via `launchctl`. If it was never installed,
`start` falls back to a direct, non-persistent spawn (logged to the same log file) so a one-off
local session still works; `stop`/`restart` in that case tell you so rather than pretending to
manage a process they never tracked — including Patchwork.app itself, which
`patchwork daemon stop` never terminates (quit the app to stop its in-process service).

`logs` shows the last 100 lines by default (bounded read from the tail of the file, never the
whole file); `-f` follows new output.

## `remote`

```
patchwork remote enable [--port 7717] [--json]
patchwork remote disable [--json]
patchwork remote url [--json]
patchwork remote token [--json]
```

**Design note:** the control-plane contract defines `daemon.json`'s fields (port, concurrency,
remote-enabled) but no HTTP endpoint to change them — everything else in the contract is an
API call, but toggling the loopback listener is daemon-process configuration. `enable`/`disable`
therefore write `daemon.json` directly (same `0600`/`0700` permissions the service uses) and
print a restart reminder, since settings are read at host startup. Restart the LaunchAgent with
`patchwork daemon restart`; for app-hosted mode, quit and reopen Patchwork. If a future contract
revision adds a settings endpoint, this is the one command group that should move over to it.

`token` reads (or, on first use, generates: 32 random bytes, base64url, `0600`) the bearer token
at `~/Library/Application Support/Patchwork/daemon-token` — the same file `remote enable` seeds.

## `limits`

```
patchwork limits [--json]
```

`--json` prints `{"report":..., "generatedAt":..., "stale":...}` verbatim from `GET /v1/limits`.
The `report` shape isn't pinned down by the contract, so human output renders it generically
(indented `key: value`, bounded depth and line count) instead of assuming fields that might not
be there.

## Recipes

### A nightly CI-triage schedule

```
patchwork schedule add \
  --name "Nightly triage" \
  --cwd ~/code/myapp \
  --prompt "Check overnight CI failures on main and summarise what needs attention" \
  --cron "0 7 * * *" \
  --mode ultra \
  --skip-if-running \
  --timeout 20m

patchwork schedule list
patchwork schedule show sch_xxxxx --json | jq '.runs[0]'
```

Every morning at 07:00 local time, if the target thread isn't already busy, this sends the prompt
and aborts if it runs longer than 20 minutes. Check in on it later with `schedule show`, or force
an out-of-band run with `patchwork schedule run sch_xxxxx`.

### A voice agent creating a thread and following up

```
# 1. Create a thread. `new` can send the first message too, but splitting it out lets us
#    --wait on a single, uniform code path for both the first turn and every follow-up.
result=$(patchwork threads new --cwd ~/code/myapp --name "Voice session" \
  --client-id voice_create_001 --json)
thread_id=$(echo "$result" | jq -r '.thread.id')

# 2. Speak the user's request, wait for the full turn, then speak the answer.
reply=$(patchwork threads send "$thread_id" "Summarise what changed in the last 3 commits" \
  --client-id voice_turn_001 --wait --json)
if [ $? -ne 0 ]; then
  say "Sorry, that run failed."
else
  say "$(echo "$reply" | jq -r '.run.summary')"
fi

# 3. Later, follow up in the same thread the same way.
reply=$(patchwork threads send "$thread_id" "Now do the same for the last PR" \
  --client-id voice_turn_002 --wait --json)
say "$(echo "$reply" | jq -r '.run.summary')"
```

`--wait` does the event-filtering loop internally, so a voice agent never needs its own polling
loop. For a dashboard that reacts to *every* thread's activity rather than one run it started
itself, use `patchwork threads watch --json` instead and filter the NDJSON stream.

## Talking to the daemon directly (no `patchwork`)

Everything above is a thin wrapper around the control API in `daemon-api.md`. If you'd rather
speak HTTP yourself: same Unix socket, same JSON bodies, same error envelope — `patchwork`'s
`--socket`/`--url`/`--token` flags exist so you never have to.
