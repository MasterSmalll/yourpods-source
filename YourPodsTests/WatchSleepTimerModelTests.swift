import XCTest
@testable import YourPods

final class WatchSleepTimerModelTests: XCTestCase {

    func test_durationTimer_expiresAtDeadline() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timer = WatchSleepTimerModel.duration(minutes: 30, startedAt: start)
        XCTAssertFalse(timer.isExpired(at: start.addingTimeInterval(29 * 60)))
        XCTAssertTrue(timer.isExpired(at: start.addingTimeInterval(30 * 60 + 1)))
    }

    func test_endOfEpisode_neverExpiresByClock() {
        let timer = WatchSleepTimerModel.endOfEpisode
        XCTAssertFalse(timer.isExpired(at: .distantFuture))
        XCTAssertTrue(timer.stopsAtTrackEnd)
    }

    func test_remainingMinutes_roundsUp() {
        let start = Date(timeIntervalSince1970: 0)
        let timer = WatchSleepTimerModel.duration(minutes: 15, startedAt: start)
        XCTAssertEqual(timer.remainingMinutes(at: start.addingTimeInterval(61)), 14)
    }
}
