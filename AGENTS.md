# Pi Desktop — working agreement

Native macOS SwiftUI/AppKit client for the Pi CLI. Pi stays the source of truth; this app reads Pi's session files and drives `pi --mode rpc`.

## Commands

```bash
swift build                 # compile
swift test                  # 44+ deterministic tests, no provider calls
./scripts/package-app.sh    # dist/Pi Desktop.app (ad-hoc signed)
swift run PiDesktop         # run from source
```

`PI_DESKTOP_REAL_SESSION_SMOKE=1 swift test` additionally scans the installed session directory.

## Hard rules

- **Never send a provider prompt from tests or QA.** Verification uses existing sessions, `get_state`, and extension commands only.
- **No third-party dependencies.** SwiftUI, AppKit, and Foundation only.
- **Pi owns conversation data.** Archive state, recent folders, expansion state, and cached summaries are the only app-owned metadata; never rewrite a Pi JSONL file.
- **Stay forward-compatible.** Unknown entry types, tool names, extension statuses, and RPC events must degrade to a bounded, visible fallback instead of being dropped.
- **Bound everything retained.** Images, tool payloads, unknown events, and previews all have explicit limits; do not reintroduce unbounded raw JSON retention.

## Parallel work with worktrees

```bash
scripts/worktree.sh new inline-images     # ../pi-desktop-worktrees/inline-images on wt/inline-images
scripts/worktree.sh list
scripts/worktree.sh rm inline-images
```

- One writer per worktree. Never run two writers in the same checkout.
- Each worktree has its own `.build` and `dist`, so builds and packaged apps do not collide.
- Only one packaged app should run at a time; they share `~/Library/Application Support/Pi Desktop/state.json` and `~/Library/Caches/Pi Desktop/`.
- Rebase or merge back into `main` with `--no-ff`, then re-run build, tests, and packaging.

## Layout

| Area | Files |
|---|---|
| App shell, routing, menus | `PiDesktopApp.swift` |
| State coordinator | `AppStore.swift` |
| Pi process/protocol | `PiRPCClient.swift`, `RPCPolicy.swift`, `JSONLFramer.swift`, `JSONValue.swift` |
| Sessions | `SessionRepository.swift`, `SessionParser.swift`, `SessionSummaryCache.swift` |
| Services | `GitService.swift`, `ActivityPresenter.swift`, `ImageBudget.swift` |
| UI | `SidebarView.swift`, `ConversationView.swift`, `MessageView.swift`, `ComposerView.swift`, `InspectorView.swift`, `NewChatView.swift`, `OverlayViews.swift`, `Theme.swift` |

Layout, spacing, type, and color constants belong in `Theme.swift`; views should not hardcode ad-hoc padding.

## Conventions

- Keep `AppStore` on the main actor and parsing off it.
- Route/generation-check every async publication so a stale load or retired runtime cannot overwrite current state.
- Add a focused deterministic test with each behavioral change.
- Update `README.md` when features, shortcuts, or performance behavior change.
