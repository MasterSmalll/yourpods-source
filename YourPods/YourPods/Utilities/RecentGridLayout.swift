import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Layout calculator for the Recently Updated grid on the Home screen.
/// Extracted from HomeView so grid height accounts for actual available width.
struct RecentGridLayout {
    static let cardWidth: CGFloat = 110
    static let cardSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    static let rowHeight: CGFloat = 170
    static let rowSpacing: CGFloat = 14

    /// Width of the main screen.
    ///
    /// `HomeView` sets the grid's `.frame(height:)` from *outside* the
    /// `GeometryReader` that lays the grid out — a `GeometryReader` fills its
    /// parent, so its height has to be decided before its own width is known.
    /// That is why this reads the screen rather than the container.
    ///
    /// `UIScreen` does not exist on macOS, which broke the `YourPodsMac`
    /// build outright. Resolved per-platform here so the layout math has one
    /// home and `HomeView` stays platform-free.
    static var screenWidth: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width
        #elseif canImport(AppKit)
        // `NSScreen.main` is nil when no display is attached (headless CI,
        // some remote sessions). A 13" laptop width keeps the grid sane.
        return NSScreen.main?.frame.width ?? 1440
        #else
        return 390
        #endif
    }

    /// Number of columns that fit at the given container width.
    static func columnsPerRow(availableWidth: CGFloat) -> Int {
        let usable = availableWidth - (horizontalPadding * 2)
        return max(1, Int(usable / (cardWidth + cardSpacing)))
    }

    /// Whether all episodes fit in ≤2 rows (use centered grid vs. horizontal scroll).
    static func fitsOnScreen(episodeCount: Int, availableWidth: CGFloat) -> Bool {
        episodeCount <= columnsPerRow(availableWidth: availableWidth) * 2
    }

    /// Total height for the grid section.
    static func gridHeight(episodeCount: Int, availableWidth: CGFloat) -> CGFloat {
        let cols = columnsPerRow(availableWidth: availableWidth)
        let rows = CGFloat(min(Int(ceil(Double(episodeCount) / Double(cols))), 2))
        return (rowHeight * rows) + (rows > 1 ? rowSpacing : 0)
    }
}
