import XCTest
@testable import YourPods

final class RecentGridLayoutTests: XCTestCase {

    // MARK: - Cross-platform screen width

    /// `screenWidth` must be a usable positive width on every platform the
    /// layout code compiles into. The macOS build previously failed outright
    /// here (`cannot find 'UIScreen' in scope`), so this asserts the value is
    /// real rather than merely that it compiles.
    func test_screenWidth_isPositiveOnAllPlatforms() {
        XCTAssertGreaterThan(RecentGridLayout.screenWidth, 0,
            "screenWidth must resolve to a real width on this platform")
    }

    /// A plausibility floor. Any modern phone, watch, or Mac display is wider
    /// than one card plus its padding; a zero or near-zero value would silently
    /// collapse the Recently Updated grid to a single column.
    func test_screenWidth_isWideEnoughForOneCard() {
        let minimum = RecentGridLayout.cardWidth + (RecentGridLayout.horizontalPadding * 2)
        XCTAssertGreaterThanOrEqual(RecentGridLayout.screenWidth, minimum,
            "screenWidth (\(RecentGridLayout.screenWidth)) is narrower than a single card plus padding (\(minimum))")
    }

    /// `gridHeight` must stay finite and positive when fed the real
    /// `screenWidth` — the exact call `HomeView.swift:214` makes.
    func test_gridHeight_isFinite_whenFedRealScreenWidth() {
        let height = RecentGridLayout.gridHeight(episodeCount: 7, availableWidth: RecentGridLayout.screenWidth)
        XCTAssertTrue(height.isFinite, "gridHeight returned a non-finite value")
        XCTAssertGreaterThan(height, 0, "gridHeight returned a non-positive value")
    }
}
