import XCTest
@testable import PatchworkKit

/// `FolderTree` is a port of the app's `WorkspaceOrganization` hierarchy rules, so these tests
/// mirror `Tests/PatchworkTests/WorkspaceOrganizationTests.swift`'s intent: the two must agree on
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

    func testLegacyResponseWithoutProjectAssignmentsDecodes() throws {
        let response = try JSONDecoder().decode(
            FolderTreeResponse.self,
            from: Data(#"{"folders":[],"assignments":{}}"#.utf8)
        )
        XCTAssertTrue(response.projectAssignments.isEmpty)
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

    func testARealProjectCanSitInsideAVirtualFolderAndHostAnotherVirtualFolder() {
        let nodes = FolderTree.nodes(
            from: [
                folder("clients", "Clients", createdAt: 1),
                folder("docs", "Docs", parent: "/Users/x/client-a", createdAt: 2)
            ],
            projectAssignments: ["/Users/x/client-a": "clients"]
        )

        XCTAssertEqual(nodes.map(\.id), ["clients", "docs"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1])
        XCTAssertEqual(nodes[1].parentId, "/Users/x/client-a")
        let response = FolderTree.response(
            folders: [folder("clients", "Clients")],
            assignments: [:],
            projectAssignments: ["/Users/x/client-a": "clients"]
        )
        XCTAssertEqual(response.projectAssignments, ["/Users/x/client-a": "clients"])
    }

    func testAlternatingProjectFolderCycleDegradesBothNodesToTopLevel() {
        let folders = [folder("clients", "Clients", parent: "/Users/x/client-a")]
        let response = FolderTree.response(
            folders: folders,
            assignments: [:],
            projectAssignments: ["/Users/x/client-a": "clients"]
        )

        XCTAssertNil(response.folders.first?.parentId)
        XCTAssertTrue(response.projectAssignments.isEmpty)
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

    /// A chain of `count` folders nested one inside the other, the outermost hosted by `parent`.
    private func chain(_ count: Int, under parent: String? = nil) -> [StoredVirtualFolder] {
        (0..<count).map { index in
            folder("f\(index)", "F\(index)", parent: index == 0 ? parent : "virtual:f\(index - 1)", createdAt: TimeInterval(index))
        }
    }

    func testDepthStopsExactlyWhereTheAppsSidebarStops() {
        // The Mac renders the folder *at* `sidebarMaxFolderDepth` and drops only its children
        // (`SidebarView.build`). Cutting one level earlier here would hide, from a phone, a folder
        // the same machine shows in its own sidebar.
        let folders = chain(FolderTree.maxDepth + 6)
        let nodes = FolderTree.nodes(from: folders)
        XCTAssertEqual(nodes.count, FolderTree.maxDepth + 1)
        XCTAssertEqual(nodes.map(\.depth).max(), FolderTree.maxDepth)
        XCTAssertEqual(nodes.last?.id, "f\(FolderTree.maxDepth)")

        // A session in the last visible folder keeps its assignment; one filed past the cap is
        // dropped, so no thread is filed somewhere the tree cannot show it.
        let response = FolderTree.response(folders: folders, assignments: [
            "/s/last.jsonl": "f\(FolderTree.maxDepth)",
            "/s/beyond.jsonl": "f\(FolderTree.maxDepth + 1)"
        ])
        XCTAssertEqual(response.assignments, ["/s/last.jsonl": "f\(FolderTree.maxDepth)"])
    }

    func testAProjectWrapperDoesNotCostAFolderLevel() {
        // A project group hosts folders; it is not itself one. The app starts a project's folders
        // at depth 0 exactly like top-level ones, so the same chain must survive either way.
        let nodes = FolderTree.nodes(from: chain(FolderTree.maxDepth + 6, under: "/Users/x/code"))
        XCTAssertEqual(nodes.count, FolderTree.maxDepth + 1)
        XCTAssertEqual(nodes.first?.parentId, "/Users/x/code")
        XCTAssertEqual(nodes.first?.depth, 0, "the project wrapper is not a level of nesting")
        XCTAssertEqual(nodes.map(\.depth).max(), FolderTree.maxDepth)
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
