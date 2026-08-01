import XCTest
@testable import PatchworkDaemon

final class LeaseStoreTests: XCTestCase {
    func testAcquireThenIsLeased() async {
        let store = LeaseStore()
        _ = await store.acquire(threadId: "t1", owner: "app", ttlSeconds: 60)
        let leased = await store.isLeased(threadId: "t1")
        XCTAssertTrue(leased)
    }

    func testUnleasedThreadIsNotLeased() async {
        let store = LeaseStore()
        let leased = await store.isLeased(threadId: "never-leased")
        XCTAssertFalse(leased)
    }

    func testLeaseExpiresAfterItsTTL() async {
        let store = LeaseStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = await store.acquire(threadId: "t1", owner: "app", ttlSeconds: 10, now: now)
        let leasedSoonAfter = await store.isLeased(threadId: "t1", now: now.addingTimeInterval(5))
        let leasedAfterExpiry = await store.isLeased(threadId: "t1", now: now.addingTimeInterval(11))
        XCTAssertTrue(leasedSoonAfter)
        XCTAssertFalse(leasedAfterExpiry)
    }

    func testReleaseByTheHolderRemovesTheLease() async {
        let store = LeaseStore()
        _ = await store.acquire(threadId: "t1", owner: "app", ttlSeconds: 60)
        await store.release(threadId: "t1", owner: "app")
        let leased = await store.isLeased(threadId: "t1")
        XCTAssertFalse(leased)
    }

    func testReleaseByADifferentOwnerIsIgnored() async {
        let store = LeaseStore()
        _ = await store.acquire(threadId: "t1", owner: "app", ttlSeconds: 60)
        await store.release(threadId: "t1", owner: "someone-else")
        let leased = await store.isLeased(threadId: "t1")
        XCTAssertTrue(leased, "an unrelated caller must not be able to evict another owner's lease")
    }

    func testLeasedThreadIDsPrunesExpiredEntries() async {
        let store = LeaseStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = await store.acquire(threadId: "still-leased", owner: "app", ttlSeconds: 100, now: now)
        _ = await store.acquire(threadId: "expired", owner: "app", ttlSeconds: 1, now: now)
        let ids = await store.leasedThreadIDs(now: now.addingTimeInterval(5))
        XCTAssertEqual(ids, ["still-leased"])
    }

    func testAcquireIfAvailableRenewsTheOwnerButNeverStealsAnotherRuntime() async {
        let store = LeaseStore()
        let first = await store.acquireIfAvailable(threadId: "t1", owner: "app", ttlSeconds: 60)
        let renewed = await store.acquireIfAvailable(threadId: "t1", owner: "app", ttlSeconds: 120)
        let stolen = await store.acquireIfAvailable(threadId: "t1", owner: "web", ttlSeconds: 60)

        XCTAssertNotNil(first)
        XCTAssertNotNil(renewed)
        XCTAssertNil(stolen)
        let current = await store.current(threadId: "t1")
        XCTAssertEqual(current?.owner, "app")
    }

    func testReacquiringOverwritesTheOwnerAndExpiry() async {
        let store = LeaseStore()
        _ = await store.acquire(threadId: "t1", owner: "first", ttlSeconds: 60)
        _ = await store.acquire(threadId: "t1", owner: "second", ttlSeconds: 60)
        let current = await store.current(threadId: "t1")
        XCTAssertEqual(current?.owner, "second")
    }
}
