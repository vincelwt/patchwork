import Foundation
import PiDeskKit
import XCTest
@testable import PiDesktop

/// Covers the pure logic behind conversation worktrees, archive retention, the flat archive
/// list, and the header's pull-request link. No git process, no runtime, no provider call.
final class ConversationWorktreeTests: XCTestCase {
    private func summary(
        id: String, cwd: String, archived: Bool, modifiedAt: Date = Date(), filePath: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            fileURL: URL(fileURLWithPath: filePath ?? "/tmp/\(id).jsonl"),
            cwd: URL(fileURLWithPath: cwd, isDirectory: true),
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            name: id,
            preview: "",
            messageCount: 0,
            metrics: TokenMetrics(),
            isArchived: archived
        )
    }

    private func message(_ text: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            blocks: [MessageBlock(id: UUID().uuidString, kind: .text(text))],
            timestamp: Date(),
            raw: .null
        )
    }

    // MARK: - Worktree location

    /// The single guard standing between automatic retention and a real project checkout.
    func testOnlyPathsInsideTheWorktreeRootAreEverConsideredManaged() {
        XCTAssertTrue(WorktreeService.isManaged(WorktreeService.root.appendingPathComponent("pi-desktop-20260729-120000")))
        XCTAssertFalse(WorktreeService.isManaged(URL(fileURLWithPath: "/Users/someone/code/pi-desktop")))
        XCTAssertFalse(WorktreeService.isManaged(WorktreeService.root), "The root itself is not a worktree")
        XCTAssertFalse(
            WorktreeService.isManaged(URL(fileURLWithPath: WorktreeService.root.path + "-elsewhere/repo")),
            "A sibling directory sharing the root's prefix must not be treated as managed"
        )
    }

    func testWorktreesLiveUnderThePiHomeDirectoryRatherThanTheProject() {
        XCTAssertTrue(WorktreeService.root.path.hasSuffix("/.pi/worktrees"))
    }

    func testSlugCombinesRepositoryNameAndTimestampSoRepeatedWorktreesNeverCollide() {
        let first = WorktreeService.slug(forRepositoryNamed: "pi-desktop", now: Date(timeIntervalSince1970: 0))
        let second = WorktreeService.slug(forRepositoryNamed: "pi-desktop", now: Date(timeIntervalSince1970: 3_600))
        XCTAssertTrue(first.hasPrefix("pi-desktop-"))
        XCTAssertNotEqual(first, second)
    }

    /// A worktree must branch off the project's main line, never off whatever another task left
    /// checked out; `HEAD` is only the last resort for a repo with no main branch at all.
    func testBaseRefPrefersTheMainLineAndFallsBackToHead() {
        XCTAssertEqual(WorktreeService.baseRef(candidates: ["origin/main", "main"]) { $0 == "main" }, "main")
        XCTAssertEqual(WorktreeService.baseRef(candidates: ["origin/main", "main"]) { _ in true }, "origin/main")
        XCTAssertEqual(WorktreeService.baseRef(candidates: ["origin/main", "main"]) { _ in false }, "HEAD")
    }

    func testManagedWorktreeSessionStaysOrganizedUnderItsProject() throws {
        let project = "/Users/test/code/pi-desktop"
        let worktree = WorktreeService.root.appendingPathComponent("pi-desktop-20260729-120000").path
        let session = summary(id: "work", cwd: worktree, archived: false)
        let projects = [worktree: project]
        let snapshot = SidebarSnapshot(
            sessions: [session],
            query: "",
            managedWorktreeProjects: projects
        )

        XCTAssertEqual(snapshot.activeGroups.count, 1)
        let group = try XCTUnwrap(snapshot.activeGroups.first)
        XCTAssertEqual(group.path, project)
        XCTAssertEqual(group.sessions.map(\.id), [session.id])
        XCTAssertEqual(
            WorkspaceOrganization.categorization(
                of: session,
                folders: [],
                assignments: [:],
                managedWorktreeProjects: projects
            ),
            ["pi-desktop", "work"]
        )

        let folder = VirtualFolder(id: "focus", name: "Focus")
        XCTAssertEqual(
            WorkspaceOrganization.defaultWorkingDirectory(
                forVirtualFolder: folder.id,
                sessions: [session],
                assignments: [session.fileURL.standardizedFileURL.path: folder.id],
                folders: [folder],
                fallback: URL(fileURLWithPath: "/tmp/fallback"),
                managedWorktreeProjects: projects
            ).path,
            project
        )
    }

    // MARK: - Archive retention

    @MainActor
    func testDaemonMutationUpdatesOnlyTheMatchingSidebarPath() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PiDaemonSync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AppStore(
            persistence: AppPersistence(baseURL: base),
            activityMonitor: SessionActivityMonitor(isActiveOverride: false)
        )
        let first = summary(id: "duplicate", cwd: "/tmp/a", archived: false, filePath: "/tmp/first.jsonl")
        let second = summary(id: "duplicate", cwd: "/tmp/b", archived: false, filePath: "/tmp/second.jsonl")
        store.sessions = [first, second]

        store.applyDaemonThreadUpdate(PiThread(
            id: "duplicate", path: "/tmp/second.jsonl", name: "Renamed externally",
            cwd: "/tmp/b", folder: "b", createdAt: Date(), updatedAt: Date(), archived: true
        ))

        XCTAssertEqual(store.sessions[0].name, "duplicate")
        XCTAssertFalse(store.sessions[0].isArchived)
        XCTAssertEqual(store.sessions[1].name, "Renamed externally")
        XCTAssertTrue(store.sessions[1].isArchived)
        XCTAssertTrue(store.sessions[1].searchKey.contains("renamed externally"))
        XCTAssertTrue(store.persistence.state.archivedSessionIDs.isEmpty, "daemon state must not become app-owned")
        XCTAssertNotNil(store.persistence.state.archivedAt["duplicate"], "external archives still sort by archive time")
    }

    @MainActor
    func testArchivesExpireOnlyAfterTheRetentionWindow() {
        let now = Date()
        let sessions = [
            summary(id: "fresh", cwd: "/tmp/a", archived: true),
            summary(id: "stale", cwd: "/tmp/b", archived: true),
            summary(id: "active", cwd: "/tmp/c", archived: false)
        ]
        let archivedAt: [String: Date] = [
            "fresh": now.addingTimeInterval(-AppStore.archiveRetention + 60),
            "stale": now.addingTimeInterval(-AppStore.archiveRetention - 60),
            "active": now.addingTimeInterval(-AppStore.archiveRetention * 10)
        ]

        let expired = AppStore.expiredArchiveIDs(sessions, archivedAt: archivedAt, now: now)

        XCTAssertEqual(expired, ["stale"], "Only archived conversations past the window are pruned")
    }

    /// Sessions archived by an older build carry no timestamp; their clock starts when this build
    /// first sees them rather than expiring them instantly.
    @MainActor
    func testUnstampedArchivesAreNotExpiredImmediately() {
        let expired = AppStore.expiredArchiveIDs(
            [summary(id: "legacy", cwd: "/tmp/a", archived: true)],
            archivedAt: [:],
            now: Date()
        )
        XCTAssertTrue(expired.isEmpty)
    }

    func testRetentionIsSevenDays() {
        XCTAssertEqual(AppStore.archiveRetention, 7 * 24 * 60 * 60)
    }

    // MARK: - Flat archive list

    func testArchiveIsAFlatListOrderedByArchiveRecency() {
        let now = Date()
        let sessions = [
            summary(id: "old", cwd: "/tmp/a", archived: true),
            summary(id: "newest", cwd: "/tmp/b", archived: true),
            summary(id: "middle", cwd: "/tmp/a", archived: true),
            summary(id: "active", cwd: "/tmp/a", archived: false)
        ]
        let stamps: [String: Date] = [
            "old": now.addingTimeInterval(-300),
            "newest": now,
            "middle": now.addingTimeInterval(-100)
        ]

        let snapshot = SidebarSnapshot(
            sessions: sessions,
            query: "",
            archivedAt: { stamps[$0.id] ?? $0.modifiedAt }
        )

        XCTAssertEqual(
            snapshot.archivedSessions.map(\.id),
            ["newest", "middle", "old"],
            "Archived rows are sorted by archive date, not grouped by folder"
        )
    }

    // MARK: - Persisted state

    func testArchiveDatesLastFolderAndWorktreeProjectsSurviveAStateRoundTrip() throws {
        var state = PersistedAppState()
        state.archivedAt = ["a": Date(timeIntervalSince1970: 1_700_000_000)]
        state.lastFolder = "/tmp/project"
        state.managedWorktreeProjects = ["/tmp/worktree": "/tmp/project"]

        let decoded = try JSONDecoder().decode(PersistedAppState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded.archivedAt["a"], state.archivedAt["a"])
        XCTAssertEqual(decoded.lastFolder, "/tmp/project")
        XCTAssertEqual(decoded.managedWorktreeProjects, state.managedWorktreeProjects)
    }

    /// A `state.json` written before this feature must still decode, archive flags intact.
    func testLegacyStateWithoutTheNewFieldsStillDecodes() throws {
        let legacy = Data(#"{"archivedSessionIDs":["kept"],"recentFolders":["/tmp/x"]}"#.utf8)
        let decoded = try JSONDecoder().decode(PersistedAppState.self, from: legacy)

        XCTAssertEqual(decoded.archivedSessionIDs, ["kept"])
        XCTAssertTrue(decoded.archivedAt.isEmpty)
        XCTAssertNil(decoded.lastFolder)
    }

    // MARK: - Pull request link

    func testTheMostRecentPullRequestInTheTranscriptWins() {
        let messages = [
            message("Opened https://github.com/acme/widgets/pull/11 earlier."),
            message("Now shipped as https://github.com/acme/widgets/pull/482 instead.")
        ]

        let link = PullRequestLink.latest(in: messages)

        XCTAssertEqual(link?.absoluteString, "https://github.com/acme/widgets/pull/482")
        XCTAssertEqual(link.flatMap(PullRequestLink.number(in:)), "#482")
    }

    @MainActor
    func testPullRequestLinkCacheInvalidatesWhenATranscriptWithTheSameCountReplacesIt() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PiPRLink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AppStore(
            persistence: AppPersistence(baseURL: base),
            activityMonitor: SessionActivityMonitor(isActiveOverride: false)
        )

        store.messages = [message("https://github.com/acme/widgets/pull/11")]
        XCTAssertEqual(store.pullRequestLink?.absoluteString, "https://github.com/acme/widgets/pull/11")

        store.messages = [message("https://github.com/acme/widgets/pull/482")]
        XCTAssertEqual(
            store.pullRequestLink?.absoluteString,
            "https://github.com/acme/widgets/pull/482",
            "Switching between equal-length transcripts must not retain the previous thread's link"
        )
    }

    func testPullRequestCreationDetectionIgnoresQuotedSourceText() {
        XCTAssertTrue(PullRequestLink.invokesCreation("gh pr create --fill"))
        XCTAssertTrue(PullRequestLink.invokesCreation("git push && gh pr create --fill"))
        XCTAssertTrue(PullRequestLink.invokesCreation("url=$(gh pr create --fill)"))
        XCTAssertFalse(PullRequestLink.invokesCreation("python3 -c \"print('gh pr create')\""))
        XCTAssertFalse(PullRequestLink.invokesCreation("rg 'gh pr create' Sources"))
        XCTAssertFalse(PullRequestLink.invokesCreation("rg -n 'text|gh pr create --base' session.jsonl"))
        XCTAssertFalse(PullRequestLink.invokesCreation("echo xgh pr create"))
    }

    func testGitHubPullRequestStateQueryUsesGraphQLStringLiterals() {
        let query = GitHubPullRequestStateService.graphqlQuery(for: [
            URL(string: "https://github.com/acme/widgets/pull/11")!
        ])

        XCTAssertTrue(query.contains(#"repository(owner: "acme", name: "widgets")"#))
        XCTAssertTrue(query.contains("codexReviews: reviews"))
        XCTAssertFalse(query.contains(#"\"acme\""#), "GraphQL rejects backslashes before string delimiters")
    }

    func testGitHubPullRequestStateBatchKeepsUnsupportedHostsUnknown() {
        let open = URL(string: "https://github.com/acme/widgets/pull/11")!
        let merged = URL(string: "https://github.com/acme/widgets/pull/12")!
        let reviewed = URL(string: "https://github.com/acme/widgets/pull/13")!
        let gitLab = URL(string: "https://gitlab.com/acme/widgets/-/merge_requests/7")!
        let states = GitHubPullRequestStateService.decodedStates(from: .object([
            "data": .object([
                "pr0": .object(["pullRequest": .object(["state": .string("OPEN")])]),
                "pr1": .object(["pullRequest": .object(["state": .string("MERGED")])]),
                "pr2": .object(["pullRequest": .object([
                    "state": .string("OPEN"),
                    "codexReviews": .object(["nodes": .array([
                        .object(["submittedAt": .string("2026-07-30T12:00:00Z")])
                    ])])
                ])])
            ])
        ]), for: [open, merged, reviewed, gitLab])

        XCTAssertEqual(states[open], .open)
        XCTAssertEqual(states[merged], .closed)
        XCTAssertEqual(states[reviewed], .openWithCodexReview)
        XCTAssertEqual(states[gitLab], .unknown)
    }

    @MainActor
    func testOnlyFreshIdleCodexReviewsWakeTheirConversation() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func review(_ id: String, age: TimeInterval, archived: Bool = false) -> SessionSummary {
            var value = summary(id: id, cwd: "/tmp", archived: archived, modifiedAt: now)
            value.pullRequestURL = URL(string: "https://github.com/acme/widgets/pull/\(id)")!
            value.pullRequestCreatedAt = now.addingTimeInterval(-age)
            return value
        }
        let fresh = review("1", age: 60)
        let running = review("2", age: 60)
        let stale = review("3", age: AppStore.pullRequestReviewMaxAge + 1)
        let archived = review("4", age: 60, archived: true)
        let sessions = [fresh, running, stale, archived]
        let states = Dictionary(uniqueKeysWithValues: sessions.compactMap {
            $0.pullRequestURL.map { ($0, PullRequestState.openWithCodexReview) }
        })

        let ready = AppStore.pullRequestReviewsReady(
            in: sessions, states: states, now: now, isRunning: { $0.id == running.id }
        )

        XCTAssertEqual(ready.map { $0.0.id }, [fresh.id])
    }

    func testGitLabMergeRequestsCountAndUnrelatedGitHubLinksDoNot() {
        XCTAssertEqual(
            PullRequestLink.firstLink(in: "see https://gitlab.com/acme/widgets/-/merge_requests/7")?.absoluteString,
            "https://gitlab.com/acme/widgets/-/merge_requests/7"
        )
        XCTAssertNil(PullRequestLink.firstLink(in: "https://github.com/acme/widgets/issues/12"))
        XCTAssertNil(PullRequestLink.firstLink(in: "https://github.com/acme/widgets"))
        XCTAssertNil(PullRequestLink.latest(in: [message("no links at all here")]))
    }

    /// `gh pr create` prints the URL last, after any progress chatter that may itself name an
    /// older PR; the tail of the blob is the one that just got created.
    func testTheLastLinkInsideOneMessageWins() {
        let output = """
        remote: resolving deltas
        Superseding https://github.com/acme/widgets/pull/3
        https://github.com/acme/widgets/pull/4
        """
        XCTAssertEqual(PullRequestLink.firstLink(in: output)?.absoluteString, "https://github.com/acme/widgets/pull/4")
    }
}
