import Foundation

/// Maps user-configured skip intervals to SF Symbol names for the watch UI.
enum WatchSkipIntervals {
    enum Direction { case forward, backward }

    private static let numberedVariants: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]

    static func symbolName(for seconds: Int, direction: Direction) -> String {
        let base = direction == .forward ? "goforward" : "gobackward"
        return numberedVariants.contains(seconds) ? "\(base).\(seconds)" : base
    }
}
