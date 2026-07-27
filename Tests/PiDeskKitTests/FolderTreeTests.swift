import XCTest
@testable import PiDeskKit

/// `FolderTree` is a port of the app's `WorkspaceOrganization` hierarchy rules, so these tests
/// mirror `Tests/PiDesktopTests/WorkspaceOrganizationTests.swift`'s intent: the two must agree on
/// the group-id scheme, on what a cycle or a dangling parent degrades to, and on ordering.
final class FolderTreeTests: XCTestCase {
    private func folder(_ id: String, _ name: String, parent: String? = nil, createdAt: TimeInterval = 0) -> StoredVirtualFolder {
        StoredVirtualFolder(id: id, name: name, parentID: parent, createdAt: Date(timeIntervalSince1970: createdAt))
    }

    func testGroupIDSchemeRoundTripsAndAProjectPathIsNotAFolderID() {
        XCTAssertEqual(FolderTree.groupID(forFolderID: "abc"), "virtual:abc")
        XCTAssertEqual(FolderTree.folderID(fromGroupID: "virtual:abc"), "abc")
        XCTAssertNil(FolderTree.folderID(fromGroupID: "/Users/x/code"))
    }

    func testNoFoldersProducesAnEmptyTreeRatherThanFailing() {
        let response = FolderTree.response(folders: [], assignments: ["/s/a.jsonl": "gone"])
        XCTAssertTrue(response.folders.isEmpty)
        XCTAssertTrue(response.assignments.isEmpty, "an assignment naming no surviving folder is dropped")
    }

    func testLegacyFoldersWithNoParentKeyDecodeAsTopLevel() throws {
        // State written before nesting existed has no `parentID` at all.
        let json = Data(#"[{"id":"f1","name":"Review","createdAt":0}]"#.utf8)
        let decoded = try JSONDecoder().decode([StoredVirtualFolder].self, from: json)
        XCTAssertNil(decoded[0].parentID)

        let nodes = FolderTree.nodes(from: decoded)
        XCTAssertEqual(nodes.map(\.id), ["f1"])
        XCTAssertNil(nodes[0].parentId)
        XCTAssertEqual(nodes[0].depth, 0)
    }

    func testNestingProducesDepthFirstOrderWithDepths() {
        let nodes = FolderTree.nodes(from: [
            folder("a", "A", createdAt: 1),
            folder("b", "B", parent: "virtual:a", createdAt: 2),
            folder("c", "C", parent: "virtual:b", createdAt: 3),
            folder("d", "D", createdAt: 4)
        ])
        XCTAssertEqual(nodes.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(nodes[1].parentId, "virtual:a")
    }

    func testFoldersHostedByAFilesystemProjectComeAfterTheTopLevelSubtree() {
        let nodes = FolderTree.nodes(from: [
            folder("p", "InProject", parent: "/Users/x/code", createdAt: 1),
            folder("t", "TopLevel", createdAt: 2)
        ])
        XCTAssertEqual(nodes.map(\.id), ["t", "p"])
        XCTAssertEqual(nodes.last?.parentId, "/Users/x/code")
    }

    func testATwoFolderCycleDegradesToTopLevelInsteadOfRecursingForever() {
        let folders = [
            folder("a", "A", parent: "virtual:b"),
            folder("b", "B", parent: "virtual:a")
        ]
        let nodes = FolderTree.nodes(from: folders)
        XCTAssertEqual(Set(nodes.map(\.id)), ["a", "b"], "both folders stay visible")
        XCTAssertTrue(nodes.allSatisfy { $0.depth == 0 }, "a cycle resolves to top level")
    }

    func testASelfParentedFolderDegradesToTopLevel() {
        let nodes = FolderTree.nodes(from: [folder("a", "A", parent: "virtual:a")])
        XCTAssertEqual(nodes.map(\.depth), [0])
    }

    func testADanglingVirtualParentDegradesToTopLevel() {
        let nodes = FolderTree.nodes(from: [folder("a", "A", parent: "virtual:missing")])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertNil(nodes[0].parentId)
    }

    func testDepthIsCappedAndDeeperFoldersAreDroppedNotMisplaced() {
        var folders = [folder("f0", "F0", createdAt: 0)]
        for index in 1...(FolderTree.maxDepth + 5) {
            folders.append(folder("f\(index)", "F\(index)", parent: "virtual:f\(index - 1)", createdAt: TimeInterval(index)))
        }
        let nodes = FolderTree.nodes(from: folders)
        XCTAssertEqual(nodes.count, FolderTree.maxDepth)
        XCTAssertEqual(nodes.map(\.depth).max(), FolderTree.maxDepth - 1)

        // An assignment into a folder past the cap is dropped, so no thread is filed somewhere
        // the tree cannot show.
        let response = FolderTree.response(folders: folders, assignments: ["/s/a.jsonl": "f\(FolderTree.maxDepth + 3)"])
        XCTAssertTrue(response.assignments.isEmpty)
    }

    func testDuplicateFolderIDsRenderOnce() {
        let nodes = FolderTree.nodes(from: [folder("a", "First", createdAt: 1), folder("a", "Second", createdAt: 2)])
        XCTAssertEqual(nodes.map(\.name), ["First"])
    }

    func testSiblingsOrderByCreationThenID() {
        let nodes = FolderTree.nodes(from: [
            folder("z", "Z", createdAt: 5),
            folder("a", "A", createdAt: 1),
            folder("m", "M", createdAt: 5)
        ])
        XCTAssertEqual(nodes.map(\.id), ["a", "m", "z"])
    }

    func testValidAssignmentsSurvive() {
        let response = FolderTree.response(
            folders: [folder("f1", "Review")],
            assignments: ["/s/a.jsonl": "f1", "/s/b.jsonl": "nope"]
        )
        XCTAssertEqual(response.assignments, ["/s/a.jsonl": "f1"])
    }
}
