# Pi Desktop

A native macOS interface for [Pi](https://pi.dev), built with SwiftUI and AppKit. Pi remains the source of truth: the app reads existing Pi sessions and starts the installed Pi CLI in RPC mode only for commands that need it. Browsing, Git inspection, and renaming never send a provider prompt.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)

## Features

- Minimal three-column workspace: folder-grouped session sidebar, centered transcript/composer, and a reserved Environment inspector column
- App-owned folders that nest at any depth, inside a project group or another folder, with drag-and-drop and “Move to…” across the whole tree. Folders never touch the filesystem.
- Codex-style turns: streamed reasoning stays visible, tool calls roll up into fading live activity, and the work log smoothly collapses into one “Worked for 4m 1s” line as the answer starts. Compaction and branch summaries are shown as their own transcript events.
- Independent live runtimes per working conversation, so starting or revisiting another task never stops the runs already in progress
- Per-conversation drafts that survive switching conversations and relaunching the app, capped and evicted so state stays bounded
- Desktop notifications when the app is in the background and clickable in-app banners when it is frontmost, for finished turns, questions, errors, and approval requests. Clicking a banner opens its conversation. The conversation you are looking at never notifies, and a finished-turn notification shows the beginning of Pi's actual answer instead of a generic phrase.
- Run state verified against a small Pi extension (`pi-desktop-activity`) that reports each process's running/idle state directly, so an idle RPC attachment cannot hide a terminal still working; finished or killed terminal turns stop showing as running without flicker and their unread dots appear only after idle; sessions without the extension fall back to a file heuristic
- A Pi crash or disconnect mid-turn is shown persistently in the conversation (not just a toast) with the exact last message ready to resend in one click; provider/network failures and exhausted auto-retries are shown the same durable way
- Recent conversations and the sidebar neighbours of the one you have open are prefetched into a bounded in-memory cache, so reopening them is instant instead of re-parsing
- Fast native search, app-local non-destructive archive/restore (also one hover click from any row), rename from any idle session, HTML export, reveal, and compaction
- Branch/worktree state and additions/deletions totals with expandable per-file LOC
- Messages appear in the transcript immediately on Send, while Pi RPC startup and history hydration continue in the background
- Pi RPC streaming, final `agent_settled` handling, retry/compaction state, abort, and exact model/thinking choices from both the composer and the status bar (falling back to the cycle commands only when Pi reports no list)
- Full steering/follow-up queue text, explicit delivery choice, and `all` / `one-at-a-time` queue modes
- A status bar that stays quiet when idle: session cost with the full token breakdown on hover, context usage, provider/model, thinking level, and extension status. Hovering the account chip renders the whole `/limits` report — every signed-in account and window — with native controls.
- One composer control: an effort slider across the `mode` extension's `xfast → ultra` range
- Selectable text plus restrained thinking, tool, result, custom, system, and bounded unknown-event disclosures
- Paste, drop, file attach, preview, remove, open, zoom, and save for images
- Subagent/background-process lifecycle presentation and Pi extension UI dialogs/status/widgets/title/editor bridge
- A native `ask_user_question` questionnaire rendered inline in the transcript at its own tool call row instead of in a modal sheet, with option cards, previews, custom answers, and header-chip navigation across buffered questions. The work log and its rows are held open while a question is unanswered so it cannot hide under a collapsed turn, and Return/Escape/space/arrows act only while focus is inside the card. A multi-select question can be submitted with nothing selected, which is sent to Pi as an empty answer; a single-select question still requires one option or custom text.
- Native keyboard commands and VoiceOver labels

No provider request is made when the app launches, browses sessions, inspects Git, or renames a session.

## The headless half

Pi Desktop has a control plane so threads keep running, get scheduled, and can be driven when
the window is closed. The wire contract is `docs/daemon-api.md`; the CLI reference is
`docs/cli.md`; remote access is `docs/web-remote.md`.

| Piece | Binary | Role |
|---|---|---|
| Daemon | `pi-deskd` | Scheduler, thread runner, control API over a Unix socket (and loopback TCP when enabled) |
| CLI | `pidesk` | Full control from a terminal or another agent, `--json` everywhere |
| Web remote | served by the daemon | Phone-first UI for threads and schedules, bearer-token authenticated |

The daemon starts and stops with the app by default: `Pi Desktop.app` bundles `pi-deskd`/`pidesk`
in `Contents/Helpers/` and supervises them (start on launch if nothing is already running,
restart on an unexpected crash with a bounded backoff, stop on quit — never a daemon it did not
start itself). Turn it off in **Pi Desktop → Settings…** if you'd rather run it yourself; the
automations page says plainly when it's off instead of a bare connection error.

For a daemon that runs without the app at all — a headless machine, or automations that must
survive the app never being opened — install it as a LaunchAgent instead:

```bash
swift build -c release --product pi-deskd
swift build -c release --product pidesk
scripts/install-daemon.sh              # LaunchAgent, starts at login, restarts on crash
pidesk threads list
pidesk schedule add --name "Morning triage" --thread <id> \
    --prompt "Check overnight CI failures" --cron "0 9 * * 1-5"
pidesk remote enable --port 7717      # then reach it through your own SSH/Cloudflare tunnel
```

If both are present, the app defers to the LaunchAgent rather than running a second daemon;
`pidesk daemon status` reports which one (or neither) is actually in play. See docs/daemon-api.md's
"Lifecycle" section for the full contract, including what happens to a scheduled run in progress
when the app quits.

Automations also have their own page in the window: pick **Automations** in the sidebar or press
`⌥⌘S`. It opens in the detail area, so the selected conversation and its draft stay put; pausing
and resuming is the switch on each row. When the background service is reachable, compatible
scheduling requests from a thread use this same durable store, so they appear on the page and
survive that Pi process exiting. The Agent extension's session-local scheduler remains the fallback
for specialized subagent jobs or when the service is off.

## Run state

Run state and thread-to-automation routing come from a small Pi extension the app installs into
`~/.pi/agent/extensions/pi-desktop-activity.ts`. It writes one heartbeat per process to
`~/.pi/agent/desktop-activity/<sessionId>-<pid>.json`; a session counts as running when any
heartbeat says so, is fresher than ten seconds, and its process is still alive. Sessions started
before the extension existed fall back to a bounded file heuristic. Opt out with
`defaults write dev.pi.desktop PiDesktopActivityHeartbeatDisabled -bool YES`.

## Run during development

Requirements: macOS 14+, Xcode command-line tools, and Pi installed.

```bash
cd /Users/vince/code/pi-desktop
swift run PiDesktop
```

Pi Desktop searches for Pi in this order:

1. `PI_DESKTOP_PI_PATH`
2. `~/.local/bin/pi`
3. `/opt/homebrew/bin/pi`
4. `/usr/local/bin/pi`
5. `/usr/bin/pi`

The child process receives an augmented `PATH`, so Pi's `#!/usr/bin/env node` launcher also works from Finder. Set `PI_CODING_AGENT_SESSION_DIR` to use a non-default session directory.

On launch, Pi Desktop installs or repairs `~/.pi/agent/extensions/pi-desktop-activity.ts` (source of truth: `Resources/pi-desktop-activity.ts`) so every Pi session — terminal or RPC — reports its own run state. It only ever writes a missing file or an older version, is never installed over a file it does not recognize, and can be turned off entirely with `defaults write dev.pi.desktop PiDesktopActivityHeartbeatDisabled -bool YES`.

## Package a local app

```bash
./scripts/package-app.sh
open "dist/Pi Desktop.app"
```

The script builds, bundles, and ad-hoc signs `PiDesktop` plus the `pi-deskd`/`pidesk` helpers it
starts and stops (`Contents/Helpers/`, each signed individually before the whole-bundle pass so
`codesign --verify --deep --strict` still passes). Pi and Node are intentionally not bundled.

## Keyboard and queue behavior

| Shortcut | Action |
|---|---|
| `⌘N` | New chat |
| `⌘K` | Quick switch |
| `⌥⌘S` | Automations page |
| `⌘R` | Refresh sessions and cached Git state |
| `⌘.` | Stop the active Pi run |
| `Return` | Send when idle; steer while running |
| `Shift-Return` | Insert a newline |

While Pi is running, the delivery menu explicitly offers **Steer current run** and **Queue as follow-up**. The queue badge shows complete bounded queue strings and exposes steering/follow-up processing modes (`all` or `one-at-a-time`). Draft text and images are restored if Pi startup, `get_state`, or command acceptance fails.

## Architecture

- **`FileSessionRepository` / `SessionSummaryCache`** — discovers direct project session files, excludes nested subagent sessions, and maintains a versioned atomic cache keyed by standardized path, file size, and modification time. Archive flags are applied after lookup; missing files are pruned.
- **`SessionParser`** — summary projection plus a two-pass conversation parser. The first pass retains only entry identity/parent/type; the second decodes only the final active chain. Known messages discard duplicate raw JSON/base64 trees after projection; unknown fallbacks are bounded strings. `conversationTail` reconstructs just the trailing messages by reading one bounded window backward from EOF and walking the same parent-pointer chain in reverse, so opening a large session can paint its tail before the full file has even been read.
- **`TranscriptCache`** — a bounded (entry-count and byte-cost) in-memory LRU of parsed transcripts, warmed on launch and around the selected session, never persisted. Lock-protected rather than actor-isolated so a hit resolves with no `await`, letting `AppStore.selectSession` publish a cached transcript in the same tick as the selection instead of flashing a loading state first.
- **`PiRuntimeProtocol` / `PiRPCClient`** — one subprocess, strict LF JSONL framing, correlated commands, and forward-compatible event delivery. A process exit rejects any pending command as outcome-unknown unless it was a read-only state query, so a crash mid-command is never assumed safe to blindly retry.
- **`GitStatusProviding` / `GitService`** — branch, porcelain status, numstat, exact small untracked-text LOC classification, and linked-worktree detection (`git rev-parse --git-dir` vs `--git-common-dir`, detailed via `git worktree list --porcelain`).
- **`SessionActivityMonitor` / `ActivityHeartbeatStore` / `ActivityExtensionInstaller`** — run-state detection. The bundled `pi-desktop-activity` extension (installed into `~/.pi/agent/extensions/`) reports each process's running/idle state via a small heartbeat file; the monitor reports running when any fresh heartbeat's pid is alive, and falls back to a file-mtime-and-tail heuristic otherwise. An ambiguous read never overrides an already-known verdict.
- **`ActivityPresenting` / `ActivityPresenter`** — stable process/run identity where Pi provides `processId`, `runId`, or `id`.
- **`AppStore`** — main-actor route/RPC coordinator, cancellable generation-checked conversation loading, draft rollback and crash-mid-turn retry, queue state, bounded extension state, background prefetch, and modest active-app Git refresh.
- **SwiftUI views** — `LazyVStack` history plus a separate streaming row and bottom sentinel; disclosure details format only when expanded. `NativeComposerTextView` supplies Return/Shift-Return and paste/drop semantics.

App-owned archive and recent-folder metadata lives at:

```text
~/Library/Application Support/Pi Desktop/state.json
```

The summary index lives under:

```text
~/Library/Caches/Pi Desktop/session-summaries-v3.json
```

Activity heartbeats (app/extension-owned, never Pi session data) live under:

```text
~/.pi/agent/desktop-activity/<sessionId>.json
```

Archiving never moves or edits a Pi JSONL file.

## Performance and memory

- Warm scans do not reparse unchanged JSONL files.
- Rapid route changes cancel the previous file read, release old message/activity/image state, and reject stale publications.
- Abandoned branches are not retained as full JSON. Known projected messages do not retain a duplicate raw payload.
- Session search folds one bounded key per summary and groups once per sidebar snapshot.
- Streaming is rendered separately instead of allocating `messages + [streamingMessage]` on every token; auto-scroll is coalesced.
- Git refresh pauses while the app is inactive, refreshes the selected folder at a modest interval, and avoids a full session rescan/reload after every settled turn. A folder shown only as the passive pre-selection default (not yet chosen by the user, and not backing any real session) never triggers a refresh at all, so a fresh launch never touches a TCC-protected folder like Desktop just to draw the New Chat screen.
- Image imports are limited to 8 images, 16 MB each and 64 MB total, with decoded `NSImage` reuse.
- The transcript cache bounds both entry count and estimated byte cost (text length plus already-budgeted image bytes), evicting least-recently-used entries first.
- Opening a conversation never shows a spinner before something the cache already knows: a synchronous cache hit publishes the transcript, already scrolled to the bottom, with no intermediate state at all. A cold miss paints the tail (read backward from EOF, independent of total file size) immediately, still pinned to the bottom, while the full parse fills in earlier history in the background without moving the scroll position or animating.

## Verification

```bash
swift build
swift test
./scripts/package-app.sh
```

Tests cover JSONL framing, active-branch reconstruction, large abandoned image/payload exclusion, no duplicate known-message raw tree, versioned summary-cache warm hits/invalidation/pruning, direct-session discovery, exact Git LOC/empty-text classification, turn/work-log projection, folder-tree nesting and cycle rejection, draft persistence and eviction, activity-heartbeat freshness/staleness/dead-pid classification and its file-heuristic fallback, sticky-unknown run state, transcript-cache eviction and synchronous-hit behavior, tail-first scan correctness (abandoned-branch skipping, window truncation), linked-worktree detection against both literal porcelain fixtures and a real repository, crash/outcome-unknown RPC classification and single-shot draft retry, notification triggers/coalescing/preview text, extension-notice toast filtering, safe folder defaults, `/limits` parsing, and an installed-Pi `get_state` smoke test that never prompts a provider. Set `PI_DESKTOP_REAL_SESSION_SMOKE=1` for the opt-in installed-session scan, which also prints cache-hit/tail-scan/full-parse timings for the largest installed session.

## Current limitations

Pi Desktop intentionally owns one RPC subprocess at a time. An idle runtime can switch sessions for rename/send, but a different actively running conversation must settle or be stopped first. The inspector hides at narrow detail widths, shows a worktree row only when the session's cwd resolves to a linked worktree, and Git row indicators use the most recently cached per-folder snapshot rather than continuously polling every project.
