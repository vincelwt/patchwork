import Foundation
import XCTest
@testable import PiDesktop

final class QuickSwitchScoringTests: XCTestCase {
    private func summary(
        _ name: String,
        folder: String = "code",
        preview: String = "",
        modifiedAt: Date = Date()
    ) -> SessionSummary {
        var value = SessionSummary(
            id: "\(name)-\(folder)",
            fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jsonl"),
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
