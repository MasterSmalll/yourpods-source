import Foundation

/// Watch playback-speed steps and override resolution. The phone syncs a global
/// speed via applicationContext; a watch-local override (persisted) wins when set.
enum WatchSpeedPolicy {
    static let steps: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    static func effectiveSpeed(override: Double?, phoneSpeed: Double) -> Double {
        override ?? phoneSpeed
    }

    /// Next step after `speed`, wrapping past the fastest. Off-list speeds
    /// advance to the first step strictly greater, so the cycle self-heals.
    static func next(after speed: Double) -> Double {
        steps.first(where: { $0 > speed + 0.001 }) ?? steps[0]
    }
}
