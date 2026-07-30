# Pi Desktop

A native macOS interface for [Pi](https://pi.dev), built with SwiftUI and AppKit. Pi remains the source of truth: the app reads existing Pi sessions and starts the installed Pi CLI in RPC mode only for commands that need it. Browsing, Git inspection, and renaming never send a provider prompt.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)

## Features

- Minimal three-column workspace: global conversations under **Recents**, folder-grouped project sessions, a centered transcript/composer, and a reserved Environment inspector column
- New conversations reopen in the folder the last chat used (Global, with Pi's neutral `~/Desktop` cwd, until you pick one); **Choose…** lists only projects already known from sidebar conversations
- A **Worktree** checkbox on the new-chat row runs the conversation in a fresh git worktree cut off the project's main line (`origin/main` → `origin/master` → `main` → `master` → `HEAD`) and stored under `~/.pi/worktrees`, never inside the project. The worktree is execution-only: the new-chat row, sidebar, breadcrumbs, search, and folder defaults keep treating the conversation as part of its original project. Unchecking it before sending removes the worktree again; the branch always survives
- App-owned folders created from the sidebar context menu, nesting at any depth inside another virtual folder or a real project. Real projects can also be grouped under a virtual folder through “Move Folder to…”. Virtual folders never touch the filesystem.
- A sidebar **Tree**/**Status** switch: Status drops the hierarchy and lists every project's conversations under **Running**, **Unread**, **Open PRs**, **Done**, and **Automated**, in that priority so each appears exactly once, with a quiet location hint. Every category header carries a count and folds its rows away on a click, Automated included; categories start expanded. Pi Desktop recognizes the latest GitHub PR created by each active conversation branch and checks current PR/review state through one authenticated `gh` query on refresh and every five minutes while open. Running order follows the stable turn start in both the sidebar and menu bar, so tool writes never reshuffle it; other sections remain newest-first. The menu bar panel lists the same **Running**, **Unread**, and **Done** buckets, filled in that order up to one shared 50-row bound with the remainder as a single line. The menu bar dot carries the Running count, and the Dock icon badge carries the Done count. Archived keep their pinned area in both modes, and the toolbar names the open conversation by its full `project > folder > name` path.
- Codex-style turns: running work stays collapsed to a live latest-reasoning/error/compaction line with elapsed time and a pulsing green dot, expands into borderless details on demand, and settles into one “Worked for 4m 1s” line as the answer starts. Retried errors, compaction, and branch summaries stay inside that same work log.
- Independent live runtimes per working conversation, plus same-folder idle-process reuse; the one retained idle runtime retires after a resettable 120-second lease
- One app-owned macOS sleep hold covers every running thread and releases when the last one settles. The coffee icon in the sidebar footer shows the live state; one silent app lease also drives the installed closed-lid companion, with no per-Pi-process sleep workers or failure notifications.
- Per-conversation drafts that survive switching conversations and relaunching the app, capped and evicted so state stays bounded
- Desktop notifications when the app is in the background and clickable in-app banners when it is frontmost, for finished turns, questions, settled errors, and approval requests. Banners omit the conversation name; clicking one opens its conversation. The conversation you are looking at never notifies, errors Pi is still retrying stay silent, and a finished-turn notification shows a plain-text beginning of Pi's actual latest answer instead of a generic phrase.
- Run state and completed-answer IDs verified against a small Pi extension (`pi-desktop-activity`), so an idle RPC attachment cannot hide a terminal still working and unread/notification state advances only for a terminal assistant answer (`stop`, `length`, `error`, or `aborted`), never for mtime churn or `toolUse`
- Transient provider failures keep retrying without replaying the original prompt. Desktop pauses Pi's retry budget while offline, resumes when connectivity returns, and after Pi exhausts its short built-in retries continues with exponential backoff from 15 seconds to one hour for as long as the app remains open. The installed helper keeps continuations hidden and context-only, with a visible plain continuation fallback if unavailable. If a continuation cannot be sent, the visible **Retry** button uses the same safe path; crashes before prompt acceptance still restore the exact draft.
- App-owned accepted turns survive an app restart as durable recovery records. A heartbeat-verified provider-only interruption queues one continuation against the same Pi session on launch; unknown ownership or prompt delivery, a live writer, an active tool, or a previously interrupted recovery is surfaced for review instead of being replayed. Plain terminal `pi` sessions are never adopted.
- Recent conversations and sidebar neighbours prefetch only their newest bounded page. Older/Newer history navigation replaces that page instead of accumulating it, keeps user prompts and final assistant answers while omitting historical work detail, and can reach the first active-branch message with bounded memory; Latest returns directly to live work
- Fast native search, app-local non-destructive archive/restore (also one hover click from any row; archiving the open conversation advances to the next active chat). When automations target a conversation, Archive confirms first and deletes them before moving the conversation. Rename works even while Pi is working, alongside HTML export, reveal, and compaction
- The archive reads as a flat list, most recently archived first, with each row's project as its hint — not the folder tree the active list uses. Archiving keeps the conversation's worktree so a restore still has it; 7 days after archiving, the conversation leaves the sidebar and its worktree is released. Removal is never forced, so a worktree with uncommitted work stays on disk, and Pi's own session file is never touched
- When a conversation opens a pull or merge request, the toolbar carries a quick link to it (`#482`), pointing at the most recent one. Pi Desktop itself watches fresh GitHub PRs for up to 24 hours, without creating an automation or polling a provider; review findings wake the same conversation to address, test, and push fixes without ever merging
- Pi automatically gives each new conversation a concise semantic name during its first turn instead of leaving the opening prompt as its title; explicit names are preserved
- Sidebar rows carry their status on the trailing edge: a pulsing green dot while Pi, a subagent, or a managed process is working, a blue dot when unread, and a clock when any automation (running or paused) targets that conversation. A managed process keeps its conversation's Pi runtime alive until the lifecycle update arrives. Real project headers use a Git branch icon, orange when dirty, while virtual folders keep the folder icon. Running rows show live elapsed time and swap it for their Pi process tree's CPU and memory use on hover; the sidebar footer reports the whole Pi Desktop process tree plus any external running conversations. Reduce Motion keeps working indicators static. The composer takes focus as soon as a conversation opens.
- Branch/worktree state and additions/deletions totals with expandable per-file LOC; when tools switch to a repository or linked worktree, the Environment inspector follows it and shows the worktree name. Its open/closed state is global and survives relaunches.
- Messages appear in the transcript immediately on Send; Pi starts only after a composer edit, attachment edit, picker interaction, or command, while transcript history and live updates continue to come from the session file/cache without replacing the open scroll surface
- Editing and resubmitting the latest user message creates a new branch inside the current Pi session, keeping the conversation and its alternate history together instead of creating another sidebar conversation
- Pi RPC streaming, final `agent_settled` handling, retry/compaction state, abort, and exact model/thinking choices from both the composer and the status bar (falling back to the cycle commands only when Pi reports no list)
- Full steering/follow-up queue text, explicit delivery choice, and `all` / `one-at-a-time` queue modes. One Escape stops the current turn and preserves queued messages as follow-ups; double-Escape, ⌘., and the stop button fully stop the thread.
- A status bar that stays quiet when idle and distinguishes provider queueing, waiting for the first response, and retry countdowns (with the provider error on hover). It also shows provider/model, thinking level, an always-available fast-priority toggle, and extension status. Hovering the account chip renders the whole `/limits` report — every signed-in account and window — with native controls.
- One composer control: an effort slider across the `mode` extension's `xfast → ultra` range
- Selectable text plus restrained thinking, tool, result, custom, system, and bounded unknown-event disclosures
- Paste, full-conversation drop, file attach, preview, remove, open, zoom, and save for images. An opened image opens fitted to the viewer (large screenshots scale down with their aspect ratio, small images stay at intrinsic size, zoom scrolls) and closes on Escape, Done, or a click outside the panel. It steps to the previous/next image of the same message with Left/Right (or the viewer's arrow buttons), stopping at the first and last. Multiple previews sit side by side in a horizontally scrolling strip instead of stacking down the transcript. The composer grows around inline image previews so its text stays visible. Composer images stay visible in the sent user message and are sent to Pi as both image input and local file paths, so tools and subagents can reuse them directly. Tool-generated images and screenshots stay visible outside collapsed work details.
- Subagent/background-process lifecycle presentation, with compact agent type, model, tool-call count, and runtime metadata, plus Pi extension UI dialogs/status/widgets/title/editor bridge
- A native `ask_user_question` questionnaire rendered inline in the transcript outside nested tool disclosures instead of in a modal sheet, with option cards, previews, custom answers, and header-chip navigation across buffered questions. While unanswered it stays visible even when the work log is collapsed, its thread uses a purple sidebar status dot, and Return/Escape/space/arrows act only while focus is inside the card. A multi-select question can be submitted with nothing selected, which is sent to Pi as an empty answer; a single-select question still requires one option or custom text.
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
| Web remote | `remote.ai.gloom.sh` | QR-paired, end-to-end encrypted phone UI for threads and schedules |

Click the phone button in the sidebar footer only to pair or manage a browser. After that, the
hosted relay starts automatically with Pi Desktop and the phone reconnects whenever the app is
open; no VPN, inbound port, or tunnel is needed. A browser stays paired until its site data is
cleared or it is revoked on the Mac. The Mac still executes every request and must be online.

The phone UI covers the daily loop, not just reading:

- **Conversations read like the app's.** One user message, one collapsed work row holding
  reasoning, narration, tool calls and their results, retried errors, and compaction, then Pi's
  answer. A live turn shows its latest thought and a running clock; opening the row reveals the
  log, with tool detail nested one disclosure deeper. Answers, images, and question cards stay
  outside it. Opening reads the newest messages directly from a bounded file tail instead of
  rescanning the whole session. While a run is in flight the open thread refreshes on its own,
  and an unchanged refresh leaves the transcript, its open disclosures, and scroll position alone.
- **New threads open on their real session id.** A first message is queued only after Pi creates
  the session, so the browser never routes to a `pending:` placeholder; the web client also
  resolves placeholders from older daemons through their run id instead of showing “thread not found.”
- **A thread can start in an existing checkout.** When the chosen folder is a repository with more
  than one checkout, a Checkout menu lists the main one and every existing worktree. Selection
  only: worktrees are still created and removed in the app.
- **Archiving has somewhere to go.** The list has explicit Active and Archived modes and a worded
  Archive/Unarchive button. A thread archived in the Mac app still shows under Archived, but
  restoring it answers `409` and has to be done in the app: the daemon never writes `state.json`.
- **Model and thinking stay editable.** Exact choices from Pi appear above the composer and can be
  changed throughout the conversation. The daemon shares an active run's runtime or reserves one
  short-lived idle attachment, and refuses rather than racing a runtime leased by the Mac app.
- **Sending is optimistic and honest.** The composer clears immediately and the message shows as
  queued / working / steering / failed until Pi's own session file confirms it. A failed send
  keeps its text with Retry, and a per-message submission id means a retry after a lost response
  replays the original answer instead of prompting Pi twice.
- **Steering and follow-ups are real.** Both are delivered into the live Pi turn with Pi's own
  `steer` / `follow_up` command — a steer joins the turn in progress, a follow-up runs as its own
  next turn, and the daemon settles each accordingly. With no daemon-owned turn running there is
  nothing to interrupt, and the UI says the message was queued instead of claiming it steered.
- **Questions can be answered from the phone.** An `ask_user_question` step or permission prompt
  raised by a daemon run appears in the thread with accessible single-select, multi-select, typed,
  and confirm forms. Nothing is ever auto-answered; an unsupported dialog says so and offers
  Cancel.
- **Assistant and tool screenshots render inline** as responsive thumbnails with a tap-to-open
  lightbox and download, fetched per image so a screenshot-heavy thread stays inside the relay's
  payload budget.
- **The thread list mirrors the sidebar's folder tree**, read-only, with collapsible groups and
  unread/running markers.

By default the control service runs directly inside `Pi Desktop.app`: the Unix-socket API,
scheduler, remote relay, and their Pi workers start and stop with the app, with no separate
`pi-deskd` child to supervise. The bundle still includes `pidesk` and the optional standalone
host so the explicit LaunchAgent mode below remains available. If a LaunchAgent or manually
started host already owns the socket, the app defers to it rather than starting a competing
service.

The packaged app ships `pidesk` inside its bundle, so it is not on `PATH` until you link it.
Settings → Daemon has an **Install “pidesk”** button that symlinks it into `~/.local/bin`
(next to the Pi CLI); it never overwrites an existing file it does not own.

For a daemon that runs without the app at all — a headless machine, or automations that must
survive the app never being opened — install it as a LaunchAgent instead:

```bash
swift build -c release --product pi-deskd
swift build -c release --product pidesk
scripts/install-daemon.sh              # LaunchAgent, starts at login, restarts on crash
pidesk threads list
pidesk schedule add --name "Morning triage" --thread <id> \
    --prompt "Check overnight CI failures" --cron "0 9 * * 1-5"
pidesk remote enable --port 7717      # optional legacy loopback/tunnel listener
```

If both are present, the app defers to the LaunchAgent rather than running a second daemon;
`pidesk daemon status` reports which one (or neither) is actually in play. See docs/daemon-api.md's
"Lifecycle" section for the full contract, including what happens to a scheduled run in progress
when the app quits.

Automations also have their own page in the window: pick **Automations** in the sidebar or press
`⌥⌘S`. It opens in the detail area, so the selected conversation and its draft stay put; pausing
and resuming is the switch on each row, and the clock button opens **Run History** — the most
recent 50 runs for that automation with their status, start time, duration, and stored error or
summary; full output remains in the target conversation. When the background service is reachable,
compatible scheduling requests from a thread use this same durable store, so they appear on the
page and survive that Pi process exiting. Existing-thread runs reopen that conversation, so Pi keeps
the scheduled message concise and relies on its durable history instead of repeating the full
runbook. The Agent extension's session-local scheduler remains the fallback for specialized
subagent jobs or when the service is off.

The default app-hosted service runs only while Pi Desktop is open. On quit it stops its own Pi
workers; direct terminal `pi` processes remain external and untouched. Missed one-shot, cron, and
interval work is kept durably and coalesced into one catch-up run on the next launch; heartbeat
checks simply resume. An offline Mac keeps work pending without consuming an attempt; temporary
failures before prompt delivery retry with bounded persisted backoff, even across launches. Once
prompt delivery begins, an interrupted run is never resent blindly, because arbitrary prompts
can have side effects.

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

On launch, Pi Desktop installs or repairs `~/.pi/agent/extensions/pi-desktop-activity.ts` (source of truth: `Resources/pi-desktop-activity.ts`) so every Pi session — terminal or RPC — reports its own run state and can name a new conversation during its first turn. It only ever writes a missing file or an older version, is never installed over a file it does not recognize, and can be turned off entirely with `defaults write dev.pi.desktop PiDesktopActivityHeartbeatDisabled -bool YES`.

## Package a local app

```bash
./scripts/package-app.sh
open "/Applications/Pi Desktop.app"
```

The script builds, bundles, ad-hoc signs, and installs `/Applications/Pi Desktop.app`. The app
contains the default control service directly; `Contents/Helpers/` carries `pidesk` plus the
optional standalone `pi-deskd` LaunchAgent host, each signed before the whole-bundle pass. Pi and
Node are intentionally not bundled.

## Keyboard and queue behavior

| Shortcut | Action |
|---|---|
| `⌘N` | New chat |
| `⌘K` | Quick switch |
| `⌥⌘S` | Automations page |
| `⌘R` | Refresh sessions, schedules, and cached Git state |
| `⇧⌘R` | Rename the selected conversation |
| `⌘.` | Fully stop the active thread |
| `Esc` | Stop the current turn and continue with queued follow-ups |
| `Esc Esc` | Fully stop the active thread |
| `Return` | Send when idle; steer while running |
| `Shift-Return` | Insert a newline |

While Pi is running, the delivery menu explicitly offers **Steer current run** and **Queue as follow-up**. The queue badge shows complete bounded queue strings and exposes steering/follow-up processing modes (`all` or `one-at-a-time`). A single Escape preserves every app-held message, aborts the current turn, then sends those follow-ups as soon as that turn settles. Double-Escape, ⌘., and the stop button clear queues and terminate that thread's runtime. Draft text and images are restored if Pi startup, `get_state`, or command acceptance fails.

## Architecture

- **`FileSessionRepository` / `SessionSummaryCache`** — discovers direct project session files, excludes nested subagent sessions, and maintains a versioned atomic cache keyed by standardized path, file size, and modification time. Archive flags are applied after lookup; missing files are pruned.
- **`SessionParser`** — bounded reverse JSONL paging over the final active parent chain. The newest page preserves full work detail; focused history pages count only user prompts, final assistant answers, and forward-compatible notes toward their 50-message target, discarding tool/thinking payloads as they scan. Pages finish at a user-turn or compaction boundary (with a 1,000-message pathological-turn ceiling), ignore an unterminated final line until its LF arrives, and cap each scan at 64 MiB / 20,000 records with a 32 MiB single-record ceiling. Legacy full parsing remains only for compatibility and diagnostics, not conversation opening.
- **`TranscriptCache`** — a bounded (entry-count and byte-cost) in-memory LRU of projected page windows and their older cursors, warmed on launch and around the selected session, never persisted. Lock protection keeps a hit synchronous so selection can publish it in the same tick.
- **`PiRuntimeProtocol` / `PiRPCClient`** — strict LF JSONL framing, correlated commands, same-folder idle-process session switching, and forward-compatible event delivery. A process exit rejects any pending command as outcome-unknown unless it was a read-only state query, so a crash mid-command is never assumed safe to blindly retry.
- **`GitStatusProviding` / `GitService`** — branch, porcelain status, numstat, exact small untracked-text LOC classification, linked-worktree detection (`git rev-parse --git-dir` vs `--git-common-dir`), and bounded projection of explicit tool cwd/edit paths so the selected environment follows a conversation into its worktree.
- **`SessionActivityMonitor` / `ActivityHeartbeatStore` / `ActivityExtensionInstaller`** — run and completion detection. Heartbeats carry the active branch's latest terminal assistant entry ID; unchanged files reuse decoded records and settled idle paths skip repeat work. A bounded tail fallback safely ignores torn writes. One monitor polls every 2 seconds while active and 15 seconds in the background, round-robins at most 64 heartbeat-free file stats, and performs at most 16 tail reads per tick.
- **`ActivityPresenting` / `ActivityPresenter`** — stable process/run identity where Pi provides `processId`, `runId`, or `id`; history projection runs off the main actor.
- **`AppStore` / `ConnectivityMonitor`** — main-actor route/RPC coordinator plus native `NWPathMonitor` path changes. Provider retries exhausted by Pi continue through hidden extension context messages with capped exponential backoff; disconnected retries pause locally until reconnection. Route identity, generation-checked paging, draft rollback, process reuse/leases, queue state, and prefetch remain bounded.
- **SwiftUI/AppKit views** — `LazyVStack` history uses durable row IDs, native bottom anchoring, real clip-view geometry for pin detection, and deterministic top/bottom placement when a disjoint history page replaces the current one. Settled answer TextKit sizing is synchronous on the first layout pass. `NativeComposerTextView` supplies Return/Shift-Return and paste/drop semantics.

App-owned archive and recent-folder metadata lives at:

```text
~/Library/Application Support/Pi Desktop/state.json
```

The summary index lives under:

```text
~/Library/Caches/Pi Desktop/session-summaries-v5.json
```

Activity heartbeats (app/extension-owned, never Pi session data) live under:

```text
~/.pi/agent/desktop-activity/<sessionId>-<pid>.json
```

Archiving never moves or edits a Pi JSONL file.

## Performance and memory

- Warm scans do not reparse unchanged JSONL files; warm page hits publish synchronously.
- Cold opens read the newest bounded turn-aligned page. Older pages are explicit, dialogue-focused replacements rather than accumulated rows; Newer uses a bounded 256-position cursor LRU and replays from the frozen latest page only on a miss. This keeps memory and rendered rows bounded without imposing a total-history cutoff. Live disk/RPC changes stay buffered while older history is visible and reconcile on return to Latest.
- Rapid route changes cancel newest-page, older-page, and activity-projection work and reject stale publications.
- Abandoned branches and raw/base64 trees are not retained. A torn final JSONL line is invisible until complete.
- Session search folds one bounded key per summary and groups once per sidebar snapshot.
- Streaming is rendered separately instead of allocating `messages + [streamingMessage]` on every token; streaming deltas are coalesced to ~12 Hz before publishing, and hidden token bursts do not republish an unchanged working state or invalidate the visible window. Every published partial answer is rendered as Markdown. Transcript projection is memoized by content revision, scroll callbacks are coalesced, and per-row frame preferences no longer run while the user scrolls. Settled parsed Markdown blocks and built answer text are kept in bounded caches so re-realizing a row while scrolling does not re-parse it.
- Running-state pulse dots animate on the render server (Core Animation layer animations), so visible running conversations cost the main thread nothing per frame; a SwiftUI repeat-forever animation here measurably degraded scroll frame rate while several conversations ran. Leaf timelines update only their compact elapsed or resource labels. The existing heartbeat poll samples per-thread and whole-app CPU and physical memory off the main actor with native libproc calls, bounded to 1,024 processes per sampled tree. Tiny sidebar timelines read the latest samples locally, so resource changes do not invalidate the whole window.
- Composer edits use their own observation scope, so native typing and key repeat do not invalidate the transcript, sidebar, inspector, or menu bar. Draft persistence is coalesced after a burst, and repeated keys do not rebuild the same Pi runtime lease.
- Git refresh keeps the selected project or detected worktree current at a modest interval even while the app is inactive, and avoids a full session rescan/reload after every settled turn. Global mode's neutral `~/Desktop` cwd is always excluded from passive Git inspection, so drawing New Chat never touches Desktop; Pi uses it only after the user sends a prompt.
- Image imports are limited to 8 images, 16 MB each and 64 MB total. Images over 2,000 pixels on either edge are downscaled before sending so image-heavy Claude conversations remain valid, with decoded `NSImage` reuse.
- Transcript rows never decode full-resolution bitmaps: images render as bounded downsampled thumbnails decoded off the main thread into the costed cache, with the row's exact frame reserved from a header-only size read so the swap never shifts layout. Only the image viewer decodes full resolution. Clipboard-only images are materialized in a temporary cache capped at 64 files / 1 GB so every prompt can carry a usable path.
- The transcript cache bounds both entry count and estimated byte cost (text plus already-budgeted image bytes), evicting least-recently-used windows first.
- Every conversation opens at the newest durable or live result. The AppKit layer owns scroll corrections synchronously inside each layout pass: pinned live growth re-pins the bottom before drawing; Older replacements open at their newest edge, Newer replacements open at their oldest edge, and Latest pins to the live bottom. TextKit supplies a nonzero first-pass measure even before SwiftUI proposes a width. A loading indicator is delayed 120 ms so ordinary page reads do not flash.
- Instruments points-of-interest mark newest-page read, focused-history page read, first publish, first text paint, activity projection, RPC ready, and first model output.
- The current 25.8 MiB largest-session gate reads a warm 50-message page in about 35–39 ms (5.5 MiB scanned); extending a cold page to a 140-message turn boundary took about 51 ms, versus 1.1–1.2 s for the legacy full parse. No sidecar index is justified by those measurements.

## Verification

```bash
swift build
swift test
node --test docs/js-checks/*.test.mjs      # pure web-remote logic, no DOM, no network
(cd CloudflareRelay && npm test && npm run typecheck)
./scripts/package-app.sh
```

Tests cover JSONL framing, bounded active-branch pages, compaction traversal, torn-tail repair, large payload limits, stable transcript identities, synchronous answer sizing, final-answer presentation/durability, path-unique routes, viewport geometry policy, page-cache eviction, lazy/reused/cross-folder runtimes, idle leases, replacement pipe generations, completion-ID migration/unread/notification deduplication, background monitoring, and the existing Git, draft, queue, image, extension, daemon, and scheduler behavior. The remote-parity work adds coverage for the wire's structured message blocks (order, tool-call identity, one shared bounded budget, and older payloads that carry none of them), the web transcript projection (narration folded into the work log while the answer stays top level, results attached by call id, live status, failed steps vs a failed answer, compaction, orphan results, and unknown roles), optimistic pending-message reconciliation and its eviction rules (only server-accepted bubbles are evictable, and a run event that beat its own response is replayed), submission replay protection (in-flight claims are never evicted; the 257th concurrent submission is refused with `503` instead), the live-session settlement boundary (steer-joins-this-turn vs follow-up-owns-the-next, in-flight deliveries crossing the boundary, late callers refused during it, concurrent credit bounds, and the bounded shutdown drain that keeps a timeout or an abort from killing Pi under a write in flight), bounded pipe writes against a child that never reads, folder-tree cycle/depth/legacy handling on both sides including the app's own depth boundary from top level and inside a project, inline-image projection with encoding validation and bounded retrieval, the bounded image cache and its in-flight bound, interaction loads that preserve the last good set and retry with backoff, the interaction registry's bounds, method-appropriate response validation and expiry-cancels-never-answers rule, `tool_execution_start` questionnaire parsing, live steer/follow-up delivery outcomes, concurrent stdin writes against a fake `pi`, bounded read-only worktree discovery (porcelain parsing, entry and output caps, a non-repository folder, a missing or non-directory `cwd`), and the archive restore boundary between the daemon's own flag and the app's. Set `PI_DESKTOP_REAL_SESSION_SMOKE=1` for the opt-in installed-session scan; it never prompts a provider.

## Current limitations

Pi Desktop keeps separate RPC subprocesses only for conversations with protected live work; one clean idle process may remain leased for 120 seconds for same-folder reuse. One displayed detailed transcript page retains at most 1,000 messages, but dialogue-focused page replacement can navigate through the entire active branch; a page scan reports an explicit unreadable-history state if a record exceeds 32 MiB or no continuation can be produced. Without the heartbeat extension, completion fallback sees only the final 256 KiB. The inspector still hides at narrow detail widths, and passive Git rows use cached snapshots rather than continuous polling.

On the web remote: the transcript is polled while a thread runs (SSE carries no message bodies), so a long turn advances in ~2.5s steps rather than token by token, and unlike the Mac app there is no streaming answer. Work-row disclosures are open per screen and are not restored after a reload. Steering only reaches a turn the *daemon* is running, since a conversation open in the app belongs to the app's own runtime (the API returns `409 thread_leased`). A questionnaire can be answered forward but not revisited because Pi's dialog bridge is sequential, so there is no Back. Unconfirmed messages live with the open screen and are not restored after a reload. Replay protection for a send is in-memory and bounded to 256 submissions for 30 minutes, so a retry that spans a daemon restart can still duplicate; while all 256 are still running, a new send is refused with `503 submissions_busy` rather than losing one submission's protection. Message attachments are rejected rather than forwarded. Images over 1 MB decoded are shown as placeholders rather than downscaled; the daemon does no image processing. Folders are read-only from a phone. Worktrees can be selected but not created or removed. Archiving from the web is the daemon's own flag: a thread archived in the Mac app still shows under Archived, but restoring it answers `409 archived_in_app` and has to be done in the app, because the daemon never writes the app's `state.json`.
