# Pi Desktop

A native macOS interface for [Pi](https://pi.dev), built with SwiftUI and AppKit. Pi remains the source of truth: the app reads existing Pi sessions and starts the installed Pi CLI in RPC mode only for commands that need it. Browsing, Git inspection, and renaming never send a provider prompt.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)

## Features

- Minimal three-column workspace: folder-grouped session sidebar, centered transcript/composer, and a reserved Environment inspector column
- App-owned folders that nest at any depth, inside a project group or another folder, with drag-and-drop and “Move to…” across the whole tree. Folders never touch the filesystem.
- Codex-style turns: reasoning and tool activity stay open while Pi works, then collapse into one “Worked for 4m 1s” line above the answer. Compaction and branch summaries are shown as their own transcript events.
- Per-conversation drafts that survive switching conversations and relaunching the app, capped and evicted so state stays bounded
- Desktop notifications when the app is in the background and in-app banners when it is frontmost, for finished turns, questions, errors, and approval requests. The conversation you are looking at never notifies, and a finished-turn notification shows the beginning of Pi's actual answer instead of a generic phrase.
- Run state verified against a small Pi extension (`pi-desktop-activity`) that reports each session's own running/idle state directly, so a finished or killed terminal turn stops showing as running without flicker; sessions without the extension fall back to a file heuristic
- A Pi crash or disconnect mid-turn is shown persistently in the conversation (not just a toast) with the exact last message ready to resend in one click; provider/network failures and exhausted auto-retries are shown the same durable way
- Recent conversations and the sidebar neighbours of the one you have open are prefetched into a bounded in-memory cache, so reopening them is instant instead of re-parsing
- Fast native search, app-local non-destructive archive/restore (also one hover click from any row), rename from any idle session, HTML export, reveal, and compaction
- Branch/worktree state and additions/deletions totals with expandable per-file LOC
- Pi RPC streaming, final `agent_settled` handling, retry/compaction state, abort, and exact model/thinking choices from both the composer and the status bar (falling back to the cycle commands only when Pi reports no list)
- Full steering/follow-up queue text, explicit delivery choice, and `all` / `one-at-a-time` queue modes
- A status bar that stays quiet when idle: session cost with the full token breakdown on hover, context usage, provider/model, thinking level, and extension status. Hovering the account chip renders the whole `/limits` report — every signed-in account and window — with native controls.
- One composer control: an effort slider across the `mode` extension's `xfast → ultra` range
- Selectable text plus restrained thinking, tool, result, custom, system, and bounded unknown-event disclosures
- Paste, drop, file attach, preview, remove, open, zoom, and save for images
- Subagent/background-process lifecycle presentation and Pi extension UI dialogs/status/widgets/title/editor bridge
- A native `ask_user_question` sheet with option cards, previews, custom answers, and header-chip navigation across buffered questions. A multi-select question can be submitted with nothing selected, which is sent to Pi as an empty answer; a single-select question still requires one option or custom text.
- Native keyboard commands and VoiceOver labels

No provider request is made when the app launches, browses sessions, inspects Git, or renames a session.

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

The script builds, bundles, and ad-hoc signs the executable. Pi and Node are intentionally not bundled.

## Keyboard and queue behavior

| Shortcut | Action |
|---|---|
| `⌘N` | New chat |
| `⌘K` | Quick switch |
| `⌘R` | Refresh sessions and cached Git state |
| `⌘.` | Stop the active Pi run |
| `Return` | Send when idle; steer while running |
| `Shift-Return` | Insert a newline |

While Pi is running, the delivery menu explicitly offers **Steer current run** and **Queue as follow-up**. The queue badge shows complete bounded queue strings and exposes steering/follow-up processing modes (`all` or `one-at-a-time`). Draft text and images are restored if Pi startup, `get_state`, or command acceptance fails.

## Architecture

- **`FileSessionRepository` / `SessionSummaryCache`** — discovers direct project session files, excludes nested subagent sessions, and maintains a versioned atomic cache keyed by standardized path, file size, and modification time. Archive flags are applied after lookup; missing files are pruned.
- **`SessionParser`** — summary projection plus a two-pass conversation parser. The first pass retains only entry identity/parent/type; the second decodes only the final active chain. Known messages discard duplicate raw JSON/base64 trees after projection; unknown fallbacks are bounded strings.
- **`TranscriptCache`** — a bounded (entry-count and byte-cost) in-memory LRU of parsed transcripts, warmed on launch and around the selected session, never persisted.
- **`PiRuntimeProtocol` / `PiRPCClient`** — one subprocess, strict LF JSONL framing, correlated commands, and forward-compatible event delivery. A process exit rejects any pending command as outcome-unknown unless it was a read-only state query, so a crash mid-command is never assumed safe to blindly retry.
- **`GitStatusProviding` / `GitService`** — branch, porcelain status, numstat, and exact small untracked-text LOC classification.
- **`SessionActivityMonitor` / `ActivityHeartbeatStore` / `ActivityExtensionInstaller`** — run-state detection. The bundled `pi-desktop-activity` extension (installed into `~/.pi/agent/extensions/`) reports each session's own running/idle state via a small heartbeat file; the monitor trusts it when fresh and the pid is alive, and falls back to a file-mtime-and-tail heuristic otherwise. An ambiguous read never overrides an already-known verdict.
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

## Verification

```bash
swift build
swift test
./scripts/package-app.sh
```

Tests cover JSONL framing, active-branch reconstruction, large abandoned image/payload exclusion, no duplicate known-message raw tree, versioned summary-cache warm hits/invalidation/pruning, direct-session discovery, exact Git LOC/empty-text classification, turn/work-log projection, folder-tree nesting and cycle rejection, draft persistence and eviction, activity-heartbeat freshness/staleness/dead-pid classification and its file-heuristic fallback, sticky-unknown run state, transcript-cache eviction, crash/outcome-unknown RPC classification and single-shot draft retry, notification triggers/coalescing/preview text, extension-notice toast filtering, safe folder defaults, `/limits` parsing, and an installed-Pi `get_state` smoke test that never prompts a provider. Set `PI_DESKTOP_REAL_SESSION_SMOKE=1` for the opt-in installed-session scan.

## Current limitations

Pi Desktop intentionally owns one RPC subprocess at a time. An idle runtime can switch sessions for rename/send, but a different actively running conversation must settle or be stopped first. The inspector hides at narrow detail widths, and Git row indicators use the most recently cached per-folder snapshot rather than continuously polling every project.
