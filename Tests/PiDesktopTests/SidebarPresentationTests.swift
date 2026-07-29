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
        let archived = snapshot.archivedSessions

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
        XCTAssertEqual(snapshot.archivedSessions.map(\.id), ["shelved"])
    }

    func testGlobalDesktopConversationsAppearFirstUnderRecents() {
        let desktop = WorkspaceOrganization.globalWorkingDirectory.standardizedFileURL.path
        let snapshot = SidebarSnapshot(sessions: [
            summary(id: "project", cwd: "/tmp/project", archived: false, modifiedAt: Date()),
            summary(id: "global", cwd: desktop, archived: false, modifiedAt: .distantPast)
        ], query: "")

        XCTAssertEqual(snapshot.activeGroups.first?.name, "Recents")
        XCTAssertTrue(snapshot.activeGroups.first?.isGlobal == true)
        XCTAssertEqual(snapshot.activeGroups.first?.sessions.map(\.id), ["global"])
    }

    func testRunningLabelShowsElapsedTimeUntilTheRowIsHovered() {
        let now = Date()
        let startedAt = now.addingTimeInterval(-125)
        let usage = ThreadResourceUsage(cpuPercent: 12.5, memoryBytes: 1_048_576)

        XCTAssertEqual(
            SidebarRunningLabel.text(since: startedAt, now: now, usage: usage, hovering: false),
            "2m"
        )
        XCTAssertEqual(
            SidebarRunningLabel.text(since: startedAt, now: now, usage: usage, hovering: true),
            NumberFormatting.resources(usage)
        )
        XCTAssertEqual(
            SidebarRunningLabel.text(since: startedAt, now: now, usage: nil, hovering: true),
            "2m",
            "A running thread without heartbeat resource data must keep its elapsed time"
        )
        XCTAssertEqual(
            SidebarRunningLabel.text(since: nil, now: now, usage: nil, hovering: false),
            "working",
            "Never substitute an old conversation timestamp before the current run is observed"
        )
    }

    func testNewFolderActionLivesInTheSidebarContextMenu() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/PiDesktop/SidebarView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("title: \"New folder\""))
        XCTAssertTrue(source.contains(".contextMenu {\n            Button(\"New Folder…\")"))
    }
}

/// The sidebar retains semantic roles for weight and colour, but all roles resolve to the app's
/// one literal point size.
final class SidebarTypographyTests: XCTestCase {
    func testConversationTitleUsesRowWeightBySelection() {
        XCTAssertEqual(SidebarTypography.conversationTitle(selected: false), PiFont.row)
        XCTAssertEqual(SidebarTypography.conversationTitle(selected: true), PiFont.rowEmphasis)
    }

    func testFolderHeaderConversationAndMetadataShareOnePointSize() {
        XCTAssertEqual(PiFont.bodySize, PiFont.size)
        XCTAssertEqual(PiFont.metaSize, PiFont.size)
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
