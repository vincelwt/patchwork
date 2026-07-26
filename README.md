# Pi Desktop

A native macOS interface for [Pi](https://pi.dev), built with SwiftUI and AppKit. Pi remains the source of truth: the app reads existing Pi sessions and starts the installed Pi CLI in RPC mode only for commands that need it. Browsing, Git inspection, and renaming never send a provider prompt.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)

## Features

- Minimal three-column workspace: folder-grouped session sidebar, centered transcript/composer, and a reserved Environment inspector column
- Fast native search, app-local non-destructive archive/restore, rename from any idle session, HTML export, reveal, and compaction
- Branch/worktree state and additions/deletions totals with expandable per-file LOC
- Pi RPC streaming, final `agent_settled` handling, retry/compaction state, abort, and exact model/thinking choices from both the composer and the status bar (falling back to the cycle commands only when Pi reports no list)
- Full steering/follow-up queue text, explicit delivery choice, and `all` / `one-at-a-time` queue modes
- Input/output/cache-read/cache-write tokens, latest assistant cache-hit percentage, context usage, cost, provider/model, and extension status
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
| `⌘R` | Refresh sessions and cached Git state |
| `⌘.` | Stop the active Pi run |
| `Return` | Send when idle; steer while running |
| `Shift-Return` | Insert a newline |

While Pi is running, the delivery menu explicitly offers **Steer current run** and **Queue as follow-up**. The queue badge shows complete bounded queue strings and exposes steering/follow-up processing modes (`all` or `one-at-a-time`). Draft text and images are restored if Pi startup, `get_state`, or command acceptance fails.

## Architecture

- **`FileSessionRepository` / `SessionSummaryCache`** — discovers direct project session files, excludes nested subagent sessions, and maintains a versioned atomic cache keyed by standardized path, file size, and modification time. Archive flags are applied after lookup; missing files are pruned.
- **`SessionParser`** — summary projection plus a two-pass conversation parser. The first pass retains only entry identity/parent/type; the second decodes only the final active chain. Known messages discard duplicate raw JSON/base64 trees after projection; unknown fallbacks are bounded strings.
- **`PiRuntimeProtocol` / `PiRPCClient`** — one subprocess, strict LF JSONL framing, correlated commands, and forward-compatible event delivery.
- **`GitStatusProviding` / `GitService`** — branch, porcelain status, numstat, and exact small untracked-text LOC classification.
- **`ActivityPresenting` / `ActivityPresenter`** — stable process/run identity where Pi provides `processId`, `runId`, or `id`.
- **`AppStore`** — main-actor route/RPC coordinator, cancellable generation-checked conversation loading, draft rollback, queue state, bounded extension state, and modest active-app Git refresh.
- **SwiftUI views** — `LazyVStack` history plus a separate streaming row and bottom sentinel; disclosure details format only when expanded. `NativeComposerTextView` supplies Return/Shift-Return and paste/drop semantics.

App-owned archive and recent-folder metadata lives at:

```text
~/Library/Application Support/Pi Desktop/state.json
```

The summary index lives under:

```text
~/Library/Caches/Pi Desktop/session-summaries-v2.json
```

Archiving never moves or edits a Pi JSONL file.

## Performance and memory

- Warm scans do not reparse unchanged JSONL files.
- Rapid route changes cancel the previous file read, release old message/activity/image state, and reject stale publications.
- Abandoned branches are not retained as full JSON. Known projected messages do not retain a duplicate raw payload.
- Session search folds one bounded key per summary and groups once per sidebar snapshot.
- Streaming is rendered separately instead of allocating `messages + [streamingMessage]` on every token; auto-scroll is coalesced.
- Git refresh pauses while the app is inactive, refreshes the selected folder at a modest interval, and avoids a full session rescan/reload after every settled turn.
- Image imports are limited to 8 images, 16 MB each and 64 MB total, with decoded `NSImage` reuse.

## Verification

```bash
swift build
swift test
./scripts/package-app.sh
```

Tests cover JSONL framing, active-branch reconstruction, large abandoned image/payload exclusion, no duplicate known-message raw tree, versioned summary-cache warm hits/invalidation/pruning, direct-session discovery, exact Git LOC/empty-text classification, draft restoration, and an installed-Pi `get_state` smoke test that never prompts a provider. Set `PI_DESKTOP_REAL_SESSION_SMOKE=1` for the opt-in installed-session scan.

## Current limitations

Pi Desktop intentionally owns one RPC subprocess at a time. An idle runtime can switch sessions for rename/send, but a different actively running conversation must settle or be stopped first. The inspector hides at narrow detail widths, and Git row indicators use the most recently cached per-folder snapshot rather than continuously polling every project.
