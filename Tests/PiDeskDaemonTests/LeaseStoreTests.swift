import XCTest
@testable import PiDeskDaemon

final class LeaseStoreTests: XCTestCase {
    private func key(_ name: String) -> ThreadInstanceKey {
        ThreadInstanceKey(path: "/tmp/\(name).jsonl")
    }

    func testAcquireThenIsLeased() async {
        let store = LeaseStore()
        _ = await store.acquire(thread: key("t1"), owner: "app", ttlSeconds: 60)
        let leased = await store.isLeased(thread: key("t1"))
        XCTAssertTrue(leased)
    }

    func testUnleasedThreadIsNotLeased() async {
        let store = LeaseStore()
        let leased = await store.isLeased(thread: key("never-leased"))
        XCTAssertFalse(leased)
    }

    func testLeaseExpiresAfterItsTTL() async {
        let store = LeaseStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = await store.acquire(thread: key("t1"), owner: "app", ttlSeconds: 10, now: now)
        let leasedSoonAfter = await store.isLeased(thread: key("t1"), now: now.addingTimeInterval(5))
        let leasedAfterExpiry = await store.isLeased(thread: key("t1"), now: now.addingTimeInterval(11))
        XCTAssertTrue(leasedSoonAfter)
        XCTAssertFalse(leasedAfterExpiry)
    }

    func testReleaseByTheHolderRemovesTheLease() async {
        let store = LeaseStore()
        _ = await store.acquire(thread: key("t1"), owner: "app", ttlSeconds: 60)
        await store.release(thread: key("t1"), owner: "app")
        let leased = await store.isLeased(thread: key("t1"))
        XCTAssertFalse(leased)
    }

    func testReleaseByADifferentOwnerIsIgnored() async {
        let store = LeaseStore()
        _ = await store.acquire(thread: key("t1"), owner: "app", ttlSeconds: 60)
        await store.release(thread: key("t1"), owner: "someone-else")
        let leased = await store.isLeased(thread: key("t1"))
        XCTAssertTrue(leased, "an unrelated caller must not be able to evict another owner's lease")
    }

    func testLeasedThreadKeysPrunesExpiredEntries() async {
        let store = LeaseStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = await store.acquire(thread: key("still-leased"), owner: "app", ttlSeconds: 100, now: now)
        _ = await store.acquire(thread: key("expired"), owner: "app", ttlSeconds: 1, now: now)
        let keys = await store.leasedThreadKeys(now: now.addingTimeInterval(5))
        XCTAssertEqual(keys, [key("still-leased")])
    }

    func testAcquireIfAvailableRenewsTheOwnerButNeverStealsAnotherRuntime() async {
        let store = LeaseStore()
        let first = await store.acquireIfAvailable(thread: key("t1"), owner: "app", ttlSeconds: 60)
        let renewed = await store.acquireIfAvailable(thread: key("t1"), owner: "app", ttlSeconds: 120)
        let stolen = await store.acquireIfAvailable(thread: key("t1"), owner: "web", ttlSeconds: 60)

        XCTAssertNotNil(first)
        XCTAssertNotNil(renewed)
        XCTAssertNil(stolen)
        let current = await store.current(thread: key("t1"))
        XCTAssertEqual(current?.owner, "app")
    }

    func testRunAdmissionClosesTheLeaseRaceUntilQueueStateTakesOver() async throws {
        let store = LeaseStore()
        let pendingToken = await store.beginRunAdmission(thread: key("t1"))
        let token = try XCTUnwrap(pendingToken)

        let racedLease = await store.acquireIfAvailable(
            thread: key("t1"), owner: "app", ttlSeconds: 60
        )
        XCTAssertNil(racedLease)

        await store.endRunAdmission(token)
        let acquiredAfterAdmission = await store.acquireIfAvailable(
            thread: key("t1"), owner: "app", ttlSeconds: 60
        )
        XCTAssertNotNil(acquiredAfterAdmission)
    }

    func testReacquiringOverwritesTheOwnerAndExpiry() async {
        let store = LeaseStore()
        _ = await store.acquire(thread: key("t1"), owner: "first", ttlSeconds: 60)
        _ = await store.acquire(thread: key("t1"), owner: "second", ttlSeconds: 60)
        let current = await store.current(thread: key("t1"))
        XCTAssertEqual(current?.owner, "second")
    }

    func testCopiedHistoriesWithTheSameSessionIDLeaseIndependentlyByPath() async {
        let store = LeaseStore()
        let first = key("copy-a")
        let second = key("copy-b")

        _ = await store.acquire(thread: first, owner: "first-window", ttlSeconds: 60)
        let firstLeased = await store.isLeased(thread: first)
        let secondLeased = await store.isLeased(thread: second)
        let secondLease = await store.acquireIfAvailable(
            thread: second, owner: "second-window", ttlSeconds: 60
        )

        XCTAssertTrue(firstLeased)
        XCTAssertFalse(secondLeased)
        XCTAssertNotNil(secondLease)
    }
}
