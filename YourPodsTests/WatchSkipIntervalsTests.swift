import XCTest
@testable import YourPods

final class WatchSkipIntervalsTests: XCTestCase {

    func test_symbolName_knownIntervalsUseNumberedSymbols() {
        XCTAssertEqual(WatchSkipIntervals.symbolName(for: 30, direction: .forward), "goforward.30")
        XCTAssertEqual(WatchSkipIntervals.symbolName(for: 15, direction: .backward), "gobackward.15")
    }

    func test_symbolName_unknownIntervalFallsBackToGeneric() {
        // EDGE: SF Symbols only ship numbered variants for 5/10/15/30/45/60/75/90.
        XCTAssertEqual(WatchSkipIntervals.symbolName(for: 20, direction: .forward), "goforward")
    }
}
