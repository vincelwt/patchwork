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
