import Foundation
import XCTest
@testable import PiDesktop

/// Regression coverage for sidebar concerns that were pulled out into pure, view-independent
/// logic specifically so they are testable without standing up any UI: the archive/active
/// partition the pinned-at-the-bottom layout relies on, and the branch-indicator rule.
final class SidebarPresentationTests: XCTestCase {
    private func summary(id: String, cwd: String, archived: Bool, modifiedAt: Date = Date()) -> SessionSummary {
        var result = SessionSummary(
            id: id,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            cwd: URL(fileURLWithPath: cwd, isDirectory: true),
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            name: id,
            preview: "",
            messageCount: 0,
            metrics: TokenMetrics(),
            isArchived: archived
        )
        result.prepareSearchKey()
        return result
    }

    /// The pinned archive section at the bottom of the sidebar and the scrolling list above it
    /// now render two structurally separate slices of one snapshot (no longer siblings inside
    /// the same `LazyVStack`). If a session ever leaked into both, or neither, it would render
    /// twice or vanish the moment the archive stopped sharing a container with the active list.
    func testActiveAndArchivedGroupsPartitionEverySessionExactlyOnce() {
        let sessions = [
            summary(id: "a", cwd: "/tmp/project", archived: false),
            summary(id: "b", cwd: "/tmp/project", archived: true),
            summary(id: "c", cwd: "/tmp/other", archived: true),
            summary(id: "d", cwd: "/tmp/other", archived: false)
        ]
        let snapshot = SidebarSnapshot(sessions: sessions, query: "")

        let active = snapshot.activeGroups.flatMap(\.sessions)
        let archived = snapshot.archivedGroups.flatMap(\.sessions)

        XCTAssertEqual(Set(active.map(\.id)), ["a", "d"])
        XCTAssertEqual(Set(archived.map(\.id)), ["b", "c"])
        XCTAssertTrue(
            Set(active.map(\.id)).isDisjoint(with: Set(archived.map(\.id))),
            "A session must never appear in both the scrolling list and the pinned archive"
        )
        XCTAssertEqual(active.count + archived.count, sessions.count, "Every session is projected exactly once across the two")
    }

    func testArchivedGroupsNeverLeakIntoTheActivePartitionEvenWithVirtualFolders() {
        let folder = VirtualFolder(id: "focus", name: "Focus")
        let sessions = [
            summary(id: "kept", cwd: "/tmp/project", archived: false),
            summary(id: "shelved", cwd: "/tmp/project", archived: true)
        ]
        let assignments = [sessions[1].fileURL.standardizedFileURL.path: folder.id]
        let snapshot = SidebarSnapshot(sessions: sessions, query: "", virtualFolders: [folder], assignments: assignments)

        XCTAssertEqual(snapshot.activeGroups.flatMap(\.sessions).map(\.id), ["kept"])
        XCTAssertEqual(snapshot.archivedGroups.flatMap(\.sessions).map(\.id), ["shelved"])
    }
}

/// Task 2: the sidebar's whole type scale collapses onto three named roles (see
/// `SidebarTypography.swift`), each a direct alias of a `Theme.swift` `PiFont` constant —
/// mirrors the metric-pinning style of `ThemeGridTests.swift`, but for type instead of layout.
final class SidebarTypographyTests: XCTestCase {
    func testConversationTitleUsesRowWeightBySelection() {
        XCTAssertEqual(SidebarTypography.conversationTitle(selected: false), PiFont.row)
        XCTAssertEqual(SidebarTypography.conversationTitle(selected: true), PiFont.rowEmphasis)
    }

    func testFolderHeaderConversationRowAndMetadataAreThreeDistinctSizes() {
        let conversationRow = SidebarTypography.conversationTitle(selected: false)
        XCTAssertNotEqual(SidebarTypography.folderHeader, conversationRow, "Folder headers and conversation rows must read as distinct sizes")
        XCTAssertNotEqual(SidebarTypography.folderHeader, SidebarTypography.metadata, "Folder headers and metadata must read as distinct sizes")
        XCTAssertNotEqual(conversationRow, SidebarTypography.metadata, "Conversation rows and metadata must read as distinct sizes")
    }

    func testEveryRoleResolvesToATypeScaleConstantNotAnAdHocLiteral() {
        // Pins each role to the exact shared constant the SidebarView.swift/QuickSwitcherView.swift
        // audit standardized on, so a future edit cannot quietly reintroduce a bespoke size.
        XCTAssertEqual(SidebarTypography.folderHeader, PiFont.captionEmphasis)
        XCTAssertEqual(SidebarTypography.metadata, PiFont.micro)
        XCTAssertEqual(SidebarTypography.status, PiFont.caption)
    }
}

final class GitIndicatorPolicyTests: XCTestCase {
    private func dirtySnapshot(branch: String?, detached: Bool = false) -> GitSnapshot {
        var snapshot = GitSnapshot(isRepository: true)
        snapshot.branch = branch
        snapshot.isDetached = detached
        snapshot.files = [GitFileChange(path: "a.swift", additions: 1, deletions: 0, isBinary: false, isUntracked: false)]
        return snapshot
    }

    func testHidesTheIndicatorOnMainOrMasterRegardlessOfCase() {
        XCTAssertFalse(GitIndicatorPolicy.showsBranchIndicator(dirtySnapshot(branch: "main")))
        XCTAssertFalse(GitIndicatorPolicy.showsBranchIndicator(dirtySnapshot(branch: "Master")))
        XCTAssertFalse(GitIndicatorPolicy.showsBranchIndicator(dirtySnapshot(branch: "MAIN")))
    }

    func testShowsTheIndicatorOnAnyOtherDirtyBranch() {
        XCTAssertTrue(GitIndicatorPolicy.showsBranchIndicator(dirtySnapshot(branch: "feat/sidebar-quickswitch")))
    }

    func testShowsTheIndicatorOnADetachedDirtyCheckout() {
        XCTAssertTrue(GitIndicatorPolicy.showsBranchIndicator(dirtySnapshot(branch: "a1b2c3d", detached: true)))
    }

    func testHidesTheIndicatorWhenTheWorktreeIsClean() {
        var snapshot = GitSnapshot(isRepository: true)
        snapshot.branch = "feat/x"
        XCTAssertTrue(snapshot.files.isEmpty)
        XCTAssertFalse(GitIndicatorPolicy.showsBranchIndicator(snapshot))
    }

    func testHidesTheIndicatorOutsideARepository() {
        XCTAssertFalse(GitIndicatorPolicy.showsBranchIndicator(.none))
    }
}
