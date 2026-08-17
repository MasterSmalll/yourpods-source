import XCTest
@testable import YourPods

final class WatchSpeedPolicyTests: XCTestCase {

    func test_effectiveSpeed_prefersOverride() {
        XCTAssertEqual(WatchSpeedPolicy.effectiveSpeed(override: 1.5, phoneSpeed: 1.0), 1.5)
    }

    func test_effectiveSpeed_noOverride_usesPhoneSpeed() {
        XCTAssertEqual(WatchSpeedPolicy.effectiveSpeed(override: nil, phoneSpeed: 1.25), 1.25)
    }

    func test_next_cyclesThroughStepsAndWraps() {
        XCTAssertEqual(WatchSpeedPolicy.next(after: 1.0), 1.25)
        XCTAssertEqual(WatchSpeedPolicy.next(after: 2.0), 0.75)   // wrap to slowest
    }

    func test_next_offListSpeed_snapsToNearestStep() {
        // EDGE: phone speed 1.1 isn't a watch step — next tap lands on a real step.
        XCTAssertEqual(WatchSpeedPolicy.next(after: 1.1), 1.25)
    }
}
