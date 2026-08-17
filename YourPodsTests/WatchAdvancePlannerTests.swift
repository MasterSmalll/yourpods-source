// YourPodsTests/WatchAdvancePlannerTests.swift
import XCTest
@testable import YourPods

final class WatchAdvancePlannerTests: XCTestCase {

    func test_next_returnsFollowingEpisode() {
        XCTAssertEqual(WatchAdvancePlanner.next(after: "b", inQueue: ["a", "b", "c"]), "c")
    }

    func test_next_atTail_returnsNil() {
        XCTAssertNil(WatchAdvancePlanner.next(after: "c", inQueue: ["a", "b", "c"]))
    }

    func test_next_completedNotInQueue_returnsFirst() {
        // EDGE: the queue re-synced while playing; completed id vanished.
        XCTAssertEqual(WatchAdvancePlanner.next(after: "gone", inQueue: ["a", "b"]), "a")
    }

    func test_next_completedNotInQueue_singleItemIsItself_returnsNil() {
        XCTAssertNil(WatchAdvancePlanner.next(after: "a", inQueue: ["a"]))
    }

    func test_next_emptyQueue_returnsNil() {
        XCTAssertNil(WatchAdvancePlanner.next(after: "a", inQueue: []))
    }
}
