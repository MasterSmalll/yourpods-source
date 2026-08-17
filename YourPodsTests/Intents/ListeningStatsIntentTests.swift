import XCTest
@testable import YourPods

final class ListeningStatsIntentTests: XCTestCase {

    // MARK: - Day-key helpers (pure)

    func test_dayKey_matchesISO8601StartOfDay() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let expected = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: date))
        XCTAssertEqual(ListeningStatsService.dayKey(for: date), expected)
    }

    func test_minutes_sumsRequestedWindow() {
        let now = Date()
        let cal = Calendar.current
        var daily: [String: Int] = [:]
        daily[ListeningStatsService.dayKey(for: now)] = 600                                   // 10 min today
        daily[ListeningStatsService.dayKey(for: cal.date(byAdding: .day, value: -1, to: now)!)] = 1200 // 20 min yesterday
        daily[ListeningStatsService.dayKey(for: cal.date(byAdding: .day, value: -8, to: now)!)] = 6000 // outside window

        XCTAssertEqual(ListeningStatsService.minutes(in: daily, daysBack: 1, from: now), 10)
        XCTAssertEqual(ListeningStatsService.minutes(in: daily, daysBack: 7, from: now), 30)
    }

    func test_minutes_returnsZero_whenDailyEmpty() {
        XCTAssertEqual(ListeningStatsService.minutes(in: [:], daysBack: 7, from: Date()), 0)
    }
}
