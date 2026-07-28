import Foundation
import XCTest
@testable import PiDesktop

final class QuickSwitchScoringTests: XCTestCase {
    private func summary(
        _ name: String,
        id: String? = nil,
        folder: String = "code",
        preview: String = "",
        modifiedAt: Date = Date(),
        fileURL: URL? = nil
    ) -> SessionSummary {
        var value = SessionSummary(
            id: id ?? "\(name)-\(folder)",
            fileURL: fileURL ?? URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jsonl"),
            cwd: URL(fileURLWithPath: "/Users/vince/\(folder)", isDirectory: true),
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            name: name,
            preview: preview,
            messageCount: 0,
            metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }

    func testEmptyQueryMatchesEverythingAndKeepsRecentFirstOrder() {
        let now = Date()
        let sessions = [
            summary("newest", modifiedAt: now),
            summary("middle", modifiedAt: now.addingTimeInterval(-100)),
            summary("oldest", modifiedAt: now.addingTimeInterval(-200))
        ]
        let ranked = QuickSwitchScoring.rank(sessions, query: "", limit: 10)
        XCTAssertEqual(ranked.map(\.name), ["newest", "middle", "oldest"])
        XCTAssertEqual(QuickSwitchScoring.score(query: "   ", title: "anything", folder: "f", searchKey: "k"), 0)
    }

    func testPrefixBeatsWordPrefixBeatsSubstringBeatsSubsequence() {
        let prefix = try! XCTUnwrap(QuickSwitchScoring.score(query: "chart", title: "chart series fix", folder: "x", searchKey: ""))
        let word = try! XCTUnwrap(QuickSwitchScoring.score(query: "chart", title: "fix chart series", folder: "x", searchKey: ""))
        let substring = try! XCTUnwrap(QuickSwitchScoring.score(query: "chart", title: "fixchartseries", folder: "x", searchKey: ""))
        let subsequence = try! XCTUnwrap(QuickSwitchScoring.score(query: "chrt", title: "c h a r t", folder: "x", searchKey: ""))

        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, substring)
        XCTAssertGreaterThan(substring, subsequence)
    }

    func testTitleMatchOutranksSearchKeyMatch() {
        let sessions = [
            summary("unrelated title", preview: "we discussed keychain at length"),
            summary("keychain cleanup")
        ]
        let ranked = QuickSwitchScoring.rank(sessions, query: "keychain", limit: 10)
        XCTAssertEqual(ranked.map(\.name), ["keychain cleanup", "unrelated title"])
    }

    func testFolderPrefixMatches() {
        let score = QuickSwitchScoring.score(query: "gloom", title: "unrelated", folder: "gloomberb", searchKey: "")
        XCTAssertNotNil(score)
        XCTAssertEqual(score, QuickSwitchScoring.folderPrefix + 60 - min(60, "unrelated".count / 2))
    }

    func testShorterTitleWinsOnEqualMatchQuality() {
        let sessions = [
            summary("fix charting subsystem across every dashboard surface"),
            summary("fix chart")
        ]
        let ranked = QuickSwitchScoring.rank(sessions, query: "fix ch", limit: 10)
        XCTAssertEqual(ranked.first?.name, "fix chart")
    }

    func testNonMatchIsExcluded() {
        XCTAssertNil(QuickSwitchScoring.score(query: "zzz", title: "abc", folder: "def", searchKey: "abc def"))
        let ranked = QuickSwitchScoring.rank([summary("abc")], query: "zzz", limit: 10)
        XCTAssertTrue(ranked.isEmpty)
    }

    func testCaseAndWhitespaceInsensitive() {
        XCTAssertNotNil(QuickSwitchScoring.score(query: "  CHART ", title: "chart series", folder: "x", searchKey: ""))
    }

    func testSubsequenceGapsAreCountedForRanking() {
        XCTAssertEqual(QuickSwitchScoring.subsequenceGaps("abc", needle: "abc"), 0)
        XCTAssertEqual(QuickSwitchScoring.subsequenceGaps("axbxc", needle: "abc"), 2)
        XCTAssertNil(QuickSwitchScoring.subsequenceGaps("abc", needle: "acb"))
        XCTAssertEqual(QuickSwitchScoring.subsequenceGaps("anything", needle: ""), 0)
    }

    func testTighterSubsequenceOutranksLooserOne() {
        let tight = try! XCTUnwrap(QuickSwitchScoring.score(query: "abc", title: "axbc", folder: "-", searchKey: ""))
        let loose = try! XCTUnwrap(QuickSwitchScoring.score(query: "abc", title: "axxxxxbxxxxxc", folder: "-", searchKey: ""))
        XCTAssertGreaterThan(tight, loose)
    }

    func testResultLimitIsHonored() {
        let sessions = (0..<200).map { summary("session \($0)") }
        XCTAssertEqual(QuickSwitchScoring.rank(sessions, query: "session", limit: 25).count, 25)
    }

    func testHundredsOfSessionsRankQuickly() {
        let now = Date()
        let sessions = (0..<800).map { index in
            summary(
                "conversation number \(index) about charts and dashboards",
                folder: "project-\(index % 12)",
                preview: String(repeating: "context ", count: 40),
                modifiedAt: now.addingTimeInterval(-Double(index))
            )
        }
        let started = Date()
        let ranked = QuickSwitchScoring.rank(sessions, query: "dashboards", limit: PiTheme.quickSwitchResultLimit)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(ranked.count, PiTheme.quickSwitchResultLimit)
        XCTAssertLessThan(elapsed, 0.35, "⌘K must feel instant with hundreds of sessions")
    }

    // MARK: - De-duplication

    func testRankDeduplicatesBySessionFilePathKeepingTheBetterMatch() {
        let path = URL(fileURLWithPath: "/tmp/shared-session.jsonl")
        // A weak search-key-only match versus an exact title-prefix match at the same path, so
        // the winner is unambiguous rather than resting on the length tiebreak within one bucket.
        let weak = summary("unrelated title", id: "old-id", preview: "we discussed chart stuff", modifiedAt: Date().addingTimeInterval(-500), fileURL: path)
        let strong = summary("chart series fix", id: "new-id", modifiedAt: Date(), fileURL: path)
        let ranked = QuickSwitchScoring.rank([weak, strong], query: "chart", limit: 10)
        XCTAssertEqual(ranked.count, 1, "The same session file path must never appear twice in the results")
        XCTAssertEqual(ranked.first?.name, "chart series fix", "The higher-scoring instance of a duplicate wins")
    }

    func testRankKeepsTheMoreRecentDuplicateWhenScoresTie() {
        let path = URL(fileURLWithPath: "/tmp/tie-session.jsonl")
        let older = summary("dashboard work", modifiedAt: Date().addingTimeInterval(-500), fileURL: path)
        let newer = summary("dashboard work", modifiedAt: Date(), fileURL: path)
        // Recency-sorted input, exactly like `AppStore.sessions`: most recent first.
        let ranked = QuickSwitchScoring.rank([newer, older], query: "", limit: 10)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.modifiedAt, newer.modifiedAt)
    }

    func testRankDoesNotCollapseDifferentFilesThatShareAnID() {
        // SessionSummary.id is read from the JSONL's own `session` event, so two distinct files
        // can share one id (e.g. a copied session); the file path is the only guaranteed-unique
        // key, so results must be deduplicated on it and not on id.
        let first = summary("keychain draft", id: "same-id", fileURL: URL(fileURLWithPath: "/tmp/a.jsonl"))
        let second = summary("keychain final", id: "same-id", fileURL: URL(fileURLWithPath: "/tmp/b.jsonl"))
        let ranked = QuickSwitchScoring.rank([first, second], query: "keychain", limit: 10)
        XCTAssertEqual(ranked.count, 2, "Distinct files are distinct results even when their ids collide")
    }

    func testRankStaysBoundedWhenDuplicatesInflateTheCandidateCount() {
        let path = URL(fileURLWithPath: "/tmp/only-session.jsonl")
        let sessions = (0..<50).map { index in
            summary("session", modifiedAt: Date().addingTimeInterval(-Double(index)), fileURL: path)
        }
        let ranked = QuickSwitchScoring.rank(sessions, query: "", limit: 10)
        XCTAssertEqual(ranked.count, 1, "Fifty stale copies of one file still resolve to a single result")
    }
}

final class QuickSwitchNavigationTests: XCTestCase {
    func testMoveClampsToUpperAndLowerBounds() {
        XCTAssertEqual(QuickSwitchNavigation.move(0, by: -1, count: 5), 0, "Up at the top stays at the top")
        XCTAssertEqual(QuickSwitchNavigation.move(4, by: 1, count: 5), 4, "Down at the bottom stays at the bottom")
        XCTAssertEqual(QuickSwitchNavigation.move(2, by: 1, count: 5), 3)
        XCTAssertEqual(QuickSwitchNavigation.move(2, by: -1, count: 5), 1)
    }

    func testMoveWithNoResultsAlwaysResolvesToZero() {
        XCTAssertEqual(QuickSwitchNavigation.move(0, by: 1, count: 0), 0)
        XCTAssertEqual(QuickSwitchNavigation.move(3, by: -1, count: 0), 0)
    }

    func testMoveHandlesJumpsThatOvershootEitherEnd() {
        XCTAssertEqual(QuickSwitchNavigation.move(0, by: 999, count: 5), 4)
        XCTAssertEqual(QuickSwitchNavigation.move(4, by: -999, count: 5), 0)
    }
}

final class SidebarCategorizationTests: XCTestCase {
    private func session(name: String, cwd: String, path: String = "/tmp/s.jsonl") -> SessionSummary {
        SessionSummary(
            id: name,
            fileURL: URL(fileURLWithPath: path),
            cwd: URL(fileURLWithPath: cwd, isDirectory: true),
            createdAt: Date(),
            modifiedAt: Date(),
            name: name,
            preview: "",
            messageCount: 0,
            metrics: TokenMetrics()
        )
    }

    func testUnassignedSessionsSitUnderTheirProjectOrRecents() {
        let project = session(name: "convo", cwd: "/Users/vince/code/lexirise")
        XCTAssertEqual(
            WorkspaceOrganization.categorization(of: project, folders: [], assignments: [:]),
            ["lexirise", "convo"]
        )
        let global = session(name: "convo", cwd: WorkspaceOrganization.globalWorkingDirectory.path)
        XCTAssertEqual(
            WorkspaceOrganization.categorization(of: global, folders: [], assignments: [:]),
            ["Recents", "convo"]
        )
    }

    func testNestedFolderWalksFromItsProjectDownToTheAssignedFolder() {
        var folders: [VirtualFolder] = []
        let product = WorkspaceOrganization.create(named: "product", parentID: "/Users/vince/code/lexirise", in: &folders)!
        let growth = WorkspaceOrganization.create(
            named: "growth", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: product.id), in: &folders
        )!
        // The session's own cwd is a different project: the assignment, not the cwd, decides.
        let convo = session(name: "convo name", cwd: "/Users/vince/code/elsewhere")
        let path = convo.fileURL.standardizedFileURL.path
        XCTAssertEqual(
            WorkspaceOrganization.categorization(of: convo, folders: folders, assignments: [path: growth.id]),
            ["lexirise", "product", "growth", "convo name"]
        )
    }

    func testTopLevelFolderNeverInventsAProjectAncestor() {
        var folders: [VirtualFolder] = []
        let inbox = WorkspaceOrganization.create(named: "inbox", in: &folders)!
        let child = WorkspaceOrganization.create(
            named: "child", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: inbox.id), in: &folders
        )!
        let convo = session(name: "convo", cwd: "/Users/vince/code/lexirise")
        let path = convo.fileURL.standardizedFileURL.path
        XCTAssertEqual(
            WorkspaceOrganization.categorization(of: convo, folders: folders, assignments: [path: child.id]),
            ["inbox", "child", "convo"]
        )
    }

    func testDanglingAndCyclicStateStayBoundedAndVisible() {
        let convo = session(name: "convo", cwd: "/Users/vince/code/lexirise")
        let path = convo.fileURL.standardizedFileURL.path

        // An assignment to a folder that no longer exists falls back to the project group, which
        // is exactly where `SidebarSnapshot` renders such a session.
        XCTAssertEqual(
            WorkspaceOrganization.categorization(of: convo, folders: [], assignments: [path: "gone"]),
            ["lexirise", "convo"]
        )

        // Hand-edited mutual parents: bounded output, no infinite walk.
        let a = VirtualFolder(id: "a", name: "a", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: "b"))
        let b = VirtualFolder(id: "b", name: "b", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: "a"))
        let cyclic = WorkspaceOrganization.categorization(of: convo, folders: [a, b], assignments: [path: "a"])
        XCTAssertEqual(cyclic.last, "convo")
        XCTAssertLessThanOrEqual(cyclic.count, 3)

        // A chain longer than the cap truncates instead of growing without bound.
        let deep = (0..<80).map {
            VirtualFolder(
                id: "f\($0)",
                name: "f\($0)",
                parentID: $0 == 79 ? nil : WorkspaceOrganization.groupID(forVirtualFolderID: "f\($0 + 1)")
            )
        }
        let bounded = WorkspaceOrganization.categorization(
            of: convo, folders: deep, assignments: [path: "f0"], maxDepth: 8
        )
        XCTAssertEqual(bounded.count, 9, "Eight ancestors plus the conversation")
        XCTAssertEqual(bounded.last, "convo")
    }
}

final class ElapsedFormattingTests: XCTestCase {
    func testCompactElapsedLabels() {
        let now = Date()
        XCTAssertEqual(NumberFormatting.elapsed(since: now.addingTimeInterval(-5), now: now), "5s")
        XCTAssertEqual(NumberFormatting.elapsed(since: now.addingTimeInterval(-125), now: now), "2m")
        XCTAssertEqual(NumberFormatting.elapsed(since: now.addingTimeInterval(-7_300), now: now), "2h")
        XCTAssertEqual(NumberFormatting.elapsed(since: now.addingTimeInterval(-200_000), now: now), "2d")
        XCTAssertEqual(NumberFormatting.elapsed(since: now.addingTimeInterval(60), now: now), "0s")
    }
}

final class SidebarFolderDefaultTests: XCTestCase {
    private func summary(modifiedAt: Date) -> SessionSummary {
        var value = SessionSummary(
            id: UUID().uuidString,
            fileURL: URL(fileURLWithPath: "/tmp/x.jsonl"),
            cwd: URL(fileURLWithPath: "/Users/vince/code", isDirectory: true),
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            name: "n",
            preview: "p",
            messageCount: 0,
            metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }

    func testRecentFoldersDefaultToExpandedAndOldOnesDoNot() {
        let now = Date()
        let recent = SessionFolderGroup(path: "/Users/vince/code", sessions: [summary(modifiedAt: now)])
        let stale = SessionFolderGroup(
            path: "/Users/vince/old",
            sessions: [summary(modifiedAt: now.addingTimeInterval(-30 * 24 * 60 * 60))]
        )
        XCTAssertTrue(recent.isRecent(now: now))
        XCTAssertFalse(stale.isRecent(now: now))
        XCTAssertFalse(SessionFolderGroup(path: "/empty", sessions: []).isRecent(now: now))
    }

    func testGroupNameFallsBackToThePathWhenThereIsNoLastComponent() {
        XCTAssertEqual(SessionFolderGroup(path: "/", sessions: []).name, "/")
        XCTAssertEqual(SessionFolderGroup(path: "/Users/vince/code", sessions: []).name, "code")
    }

    func testStatusSectionsRenderInFixedOrderAndHideEmptyOnes() {
        let now = Date()
        var running = summary(modifiedAt: now); running.name = "running"
        var automated = summary(modifiedAt: now); automated.name = "automated"
        let groups = SidebarStatusGroup.groups(
            [automated, running],
            isRunning: { $0.name == "running" },
            isUnread: { _ in false },
            isAutomated: { $0.name == "automated" },
            runningAt: \.modifiedAt,
            modifiedAt: \.modifiedAt
        )
        XCTAssertEqual(groups.map(\.section), [.running, .automated], "Unread and Done are empty, so they do not render")
        XCTAssertEqual(SidebarStatusSection.allCases, [.running, .unread, .done, .automated], "Done is shown before Automated")
    }

    func testEveryConversationIsFiledExactlyOnceByPriority() {
        let now = Date()
        var all = summary(modifiedAt: now); all.name = "all"          // running + unread + automated
        var unread = summary(modifiedAt: now); unread.name = "unread" // unread + automated
        var automated = summary(modifiedAt: now); automated.name = "automated"
        var done = summary(modifiedAt: now); done.name = "done"
        var archived = summary(modifiedAt: now); archived.name = "archived"; archived.isArchived = true

        let groups = SidebarStatusGroup.groups(
            [all, unread, automated, done, archived],
            isRunning: { $0.name == "all" },
            isUnread: { ["all", "unread"].contains($0.name) },
            isAutomated: { ["all", "unread", "automated"].contains($0.name) },
            runningAt: \.modifiedAt,
            modifiedAt: \.modifiedAt
        )
        XCTAssertEqual(groups.map(\.section), [.running, .unread, .done, .automated])
        XCTAssertEqual(groups.map { $0.sessions.map(\.name) }, [["all"], ["unread"], ["done"], ["automated"]])
        XCTAssertEqual(groups.flatMap(\.sessions).count, 4, "Archived stays out and nothing is filed twice")
    }

    func testRunningSortStaysOnTurnStartWhileOtherSectionsFollowLiveUpdates() {
        let now = Date()
        var early = summary(modifiedAt: now); early.name = "early"
        var late = summary(modifiedAt: now); late.name = "late"
        var old = summary(modifiedAt: now); old.name = "old"
        var fresh = summary(modifiedAt: now); fresh.name = "fresh"
        // Live writes favor the early run, but its older turn must stay below the later run.
        let running: [String: Date] = ["early": now.addingTimeInterval(-500), "late": now]
        let live: [String: Date] = [
            "early": now, "late": now.addingTimeInterval(-500),
            "old": now.addingTimeInterval(-500), "fresh": now
        ]
        let groups = SidebarStatusGroup.groups(
            [early, late, old, fresh],
            isRunning: { ["early", "late"].contains($0.name) },
            isUnread: { _ in false },
            isAutomated: { _ in false },
            runningAt: { running[$0.name] ?? $0.modifiedAt },
            modifiedAt: { live[$0.name] ?? $0.modifiedAt }
        )
        XCTAssertEqual(groups.first { $0.section == .running }?.sessions.map(\.name), ["late", "early"])
        XCTAssertEqual(groups.first { $0.section == .done }?.sessions.map(\.name), ["fresh", "old"])
    }

    func testSnapshotGroupsAndFiltersOnTheBoundedSearchKey() {
        var first = summary(modifiedAt: Date())
        first.name = "chart work"
        first.prepareSearchKey()
        var second = summary(modifiedAt: Date().addingTimeInterval(-10))
        second.name = "unrelated"
        second.prepareSearchKey()

        let all = SidebarSnapshot(sessions: [first, second], query: "")
        XCTAssertEqual(all.all.count, 2)
        XCTAssertEqual(all.activeGroups.count, 1, "Both sessions share one folder")
        XCTAssertFalse(all.isFiltering)

        let filtered = SidebarSnapshot(sessions: [first, second], query: "CHART")
        XCTAssertEqual(filtered.all.map(\.name), ["chart work"])
        XCTAssertTrue(filtered.isFiltering)
    }
}
