# Pi Desktop

A native macOS interface for [Pi](https://pi.dev), built with SwiftUI and AppKit. Pi remains the source of truth: the app reads existing Pi sessions and starts the installed Pi CLI in RPC mode only for commands that need it. Browsing, Git inspection, and renaming never send a provider prompt.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)

## Features

- Minimal three-column workspace: folder-grouped session sidebar, centered transcript/composer, and a reserved Environment inspector column
- App-owned folders that nest at any depth, inside a project group or another folder, with drag-and-drop and “Move to…” across the whole tree. Folders never touch the filesystem.
- Codex-style turns: streamed reasoning stays visible, tool calls roll up into fading live activity, and the work log smoothly collapses into one “Worked for 4m 1s” line as the answer starts. Compaction and branch summaries are shown as their own transcript events.
- Independent live runtimes per working conversation, plus same-folder idle-process reuse; the one retained idle runtime retires after a resettable 120-second lease
- Per-conversation drafts that survive switching conversations and relaunching the app, capped and evicted so state stays bounded
- Desktop notifications when the app is in the background and clickable in-app banners when it is frontmost, for finished turns, questions, errors, and approval requests. Banners omit the conversation name; clicking one opens its conversation. The conversation you are looking at never notifies, and a finished-turn notification shows the beginning of Pi's actual answer instead of a generic phrase.
- Run state and completed-answer IDs verified against a small Pi extension (`pi-desktop-activity`), so an idle RPC attachment cannot hide a terminal still working and unread/notification state advances only for a terminal assistant answer (`stop`, `length`, `error`, or `aborted`), never for mtime churn or `toolUse`
- A Pi crash or disconnect mid-turn is shown persistently in the conversation (not just a toast) with the exact last message ready to resend in one click; provider/network failures and exhausted auto-retries are shown the same durable way
- Recent conversations and sidebar neighbours prefetch only their newest bounded page; opening shows the latest 50 messages and scrolling upward pages through the active JSONL branch without an eager full-history parse
- Fast native search, app-local non-destructive archive/restore (also one hover click from any row), rename from any idle session, HTML export, reveal, and compaction
- Branch/worktree state and additions/deletions totals with expandable per-file LOC
- Messages appear in the transcript immediately on Send; Pi starts only after a composer edit, attachment edit, picker interaction, or command, while transcript history continues to come from the session file/cache
- Pi RPC streaming, final `agent_settled` handling, retry/compaction state, abort, and exact model/thinking choices from both the composer and the status bar (falling back to the cycle commands only when Pi reports no list)
- Full steering/follow-up queue text, explicit delivery choice, and `all` / `one-at-a-time` queue modes. Escape stops a running turn only when an app-held message is queued, promoting it to the follow-up that continues; double-Escape clears that queue and fully stops the run.
- A status bar that stays quiet when idle: session cost with the full token breakdown on hover, context usage, provider/model, thinking level, and extension status. Hovering the account chip renders the whole `/limits` report — every signed-in account and window — with native controls.
- One composer control: an effort slider across the `mode` extension's `xfast → ultra` range
- Selectable text plus restrained thinking, tool, result, custom, system, and bounded unknown-event disclosures
- Paste, full-conversation drop, file attach, preview, remove, open, zoom, and save for images. Tool-generated images and screenshots stay visible outside collapsed work details.
- Subagent/background-process lifecycle presentation, with compact agent type, model, tool-call count, and runtime metadata, plus Pi extension UI dialogs/status/widgets/title/editor bridge
- A native `ask_user_question` questionnaire rendered inline in the transcript outside nested tool disclosures instead of in a modal sheet, with option cards, previews, custom answers, and header-chip navigation across buffered questions. While unanswered it stays visible even when the work log is collapsed, and Return/Escape/space/arrows act only while focus is inside the card. A multi-select question can be submitted with nothing selected, which is sent to Pi as an empty answer; a single-select question still requires one option or custom text.
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
heartbeat says so, is fresher than ten seconds, and its process is still alive. The same heartbeat
carries a stable terminal assistant entry ID, which drives unread dots and exactly-once completion
notifications even when file mtimes collide. Sessions started before the extension existed fall
back to a bounded file heuristic. Opt out with
`defaults write dev.pi.desktop PiDesktopActivityHeartbeatDisabled -bool YES`.

## Run during development

Requirements: macOS 14+, Xcode 26+ (for packaging the Icon Composer app icon), and Pi installed.

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
open "/Applications/Pi Desktop.app"
```

The script builds, bundles, ad-hoc signs, and installs `/Applications/Pi Desktop.app`. It includes
`PiDesktop` plus the `pi-deskd`/`pidesk` helpers it starts and stops (`Contents/Helpers/`, each
signed individually before the whole-bundle pass so `codesign --verify --deep --strict` still
passes). Pi and Node are intentionally not bundled.

## Keyboard and queue behavior

| Shortcut | Action |
|---|---|
| `⌘N` | New chat |
| `⌘K` | Quick switch |
| `⌥⌘S` | Automations page |
| `⌘R` | Refresh sessions and cached Git state |
| `⌘.` | Abort the active turn |
| `Return` | Send when idle; steer while running |
| `Shift-Return` | Insert a newline |

While Pi is running, the delivery menu explicitly offers **Steer current run** and **Queue as follow-up**. The queue badge shows complete bounded queue strings and exposes steering/follow-up processing modes (`all` or `one-at-a-time`). Draft text and images are restored if Pi startup, `get_state`, or command acceptance fails.

## Architecture

- **`FileSessionRepository` / `SessionSummaryCache`** — discovers direct project session files, excludes nested subagent sessions, and maintains a versioned atomic cache keyed by standardized path, file size, and modification time. Archive flags are applied after lookup; missing files are pruned.
- **`SessionParser`** — bounded reverse JSONL paging over the final active parent chain. The newest and older-page APIs project 50 messages at a time, ignore an unterminated final line until its LF arrives, traverse compaction/branch entries without retaining raw history, and cap each scan at 64 MiB / 20,000 records with a 32 MiB single-record ceiling. Legacy full parsing remains only for compatibility and diagnostics, not conversation opening.
- **`TranscriptCache`** — a bounded (entry-count and byte-cost) in-memory LRU of projected page windows and their older cursors, warmed on launch and around the selected session, never persisted. Lock protection keeps a hit synchronous so selection can publish it in the same tick.
- **`PiRuntimeProtocol` / `PiRPCClient`** — strict LF JSONL framing, correlated commands, same-folder idle-process session switching, and forward-compatible event delivery. A process exit rejects any pending command as outcome-unknown unless it was a read-only state query, so a crash mid-command is never assumed safe to blindly retry.
- **`GitStatusProviding` / `GitService`** — branch, porcelain status, numstat, exact small untracked-text LOC classification, and linked-worktree detection (`git rev-parse --git-dir` vs `--git-common-dir`, detailed via `git worktree list --porcelain`).
- **`SessionActivityMonitor` / `ActivityHeartbeatStore` / `ActivityExtensionInstaller`** — run and completion detection. Heartbeats carry the active branch's latest terminal assistant entry ID; a bounded tail fallback safely ignores torn writes. One monitor polls every 2 seconds while active and 15 seconds in the background, round-robins at most 64 heartbeat-free file stats, and performs at most 16 tail reads per tick.
- **`ActivityPresenting` / `ActivityPresenter`** — stable process/run identity where Pi provides `processId`, `runId`, or `id`; history projection runs off the main actor.
- **`AppStore`** — main-actor route/RPC coordinator, path-based route identity, generation-checked page loading/prepending, completion cursors, terminal-answer durability overlays, draft rollback, process reuse/leases, queue state, and bounded prefetch.
- **SwiftUI/AppKit views** — `LazyVStack` history uses durable row IDs, native bottom anchoring, real clip-view geometry for pin detection, and height-delta preservation while prepending. Settled answer TextKit sizing is synchronous on the first layout pass. `NativeComposerTextView` supplies Return/Shift-Return and paste/drop semantics.

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
~/.pi/agent/desktop-activity/<sessionId>-<pid>.json
```

Archiving never moves or edits a Pi JSONL file.

## Performance and memory

- Warm scans do not reparse unchanged JSONL files; warm page hits publish synchronously.
- Cold opens read the newest 50 active-branch messages only. Older pages load on upward intent, prepend without moving the viewport, and stop retaining at 1,000 displayed messages.
- Rapid route changes cancel newest-page, older-page, and activity-projection work and reject stale publications.
- Abandoned branches and raw/base64 trees are not retained. A torn final JSONL line is invisible until complete.
- Session search folds one bounded key per summary and groups once per sidebar snapshot.
- Streaming is rendered separately instead of allocating `messages + [streamingMessage]` on every token; auto-scroll is coalesced and runs only while native viewport geometry says the reader is pinned.
- Git refresh pauses while the app is inactive, refreshes the selected folder at a modest interval, and avoids a full session rescan/reload after every settled turn. A folder shown only as the passive pre-selection default (not yet chosen by the user, and not backing any real session) never triggers a refresh at all, so a fresh launch never touches a TCC-protected folder like Desktop just to draw the New Chat screen.
- Image imports are limited to 8 images, 16 MB each and 64 MB total, with decoded `NSImage` reuse.
- The transcript cache bounds both entry count and estimated byte cost (text plus already-budgeted image bytes), evicting least-recently-used windows first.
- Opening uses SwiftUI's native bottom anchor instead of a post-paint jump. A loading indicator is delayed 120 ms so ordinary page reads do not flash; cached windows can restore an in-memory row anchor, while unread sessions target the first unseen completion available in the loaded page.
- Instruments points-of-interest mark newest-page read, first publish, first text paint, activity projection, prepend, viewport restore, RPC ready, and first model output.
- The current 25.8 MiB largest-session gate reads its newest page in about 32 ms (5.5 MiB scanned) versus about 1.05 s for the legacy full parse, so no sidecar index is justified yet; add one only if measured page latency stops meeting the sub-50 ms target.

## Verification

```bash
swift build
swift test
./scripts/package-app.sh
```

Tests cover JSONL framing, bounded active-branch pages, compaction traversal, torn-tail repair, large payload limits, stable transcript identities, synchronous answer sizing, final-answer presentation/durability, path-unique routes, viewport geometry policy, page-cache eviction, lazy/reused/cross-folder runtimes, idle leases, replacement pipe generations, completion-ID migration/unread/notification deduplication, background monitoring, and the existing Git, draft, queue, image, extension, daemon, and scheduler behavior. Set `PI_DESKTOP_REAL_SESSION_SMOKE=1` for the opt-in installed-session scan; it never prompts a provider.

## Current limitations

Pi Desktop keeps separate RPC subprocesses only for conversations with protected live work; one clean idle process may remain leased for 120 seconds for same-folder reuse. One displayed transcript window retains at most 1,000 messages; a page scan reports an explicit bounded-history state if a record exceeds 32 MiB or no continuation can be produced. Without the heartbeat extension, completion fallback sees only the final 256 KiB. The inspector still hides at narrow detail widths, and passive Git rows use cached snapshots rather than continuous polling.
