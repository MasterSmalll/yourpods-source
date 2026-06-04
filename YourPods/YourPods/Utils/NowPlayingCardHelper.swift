import Foundation

/// Pure-logic helpers for the Now Playing card on the Home screen.
/// Extracted for testability — formatting and state calculations without SwiftUI dependencies.
enum NowPlayingCardHelper {
    
    /// Build a condensed single-line metadata string for the Now Playing card.
    /// Combines pub date and duration/progress into one compact line.
    ///
    /// Examples:
    /// - "Jan 5, 2026 · 1:23:45" (not currently playing, position == 0)
    /// - "Jan 5, 2026 · 50% listened" (currently playing with known position > 0)
    /// - "1:23:45" (no pub date, full duration)
    static func condensedMetadata(
        pubDate: Date?,
        durationSeconds: Int?,
        position: Double,
        totalDuration: Double
    ) -> String {
        var parts: [String] = []
        
        // Date portion
        if let pubDate {
            parts.append(pubDate.formatted(date: .abbreviated, time: .omitted))
        }
        
        // Duration / progress portion
        if let durationSeconds, durationSeconds > 0 {
            if position > 0 && totalDuration > 0 {
                let percent = Int((position / totalDuration) * 100)
                parts.append("\(percent)% listened")
            } else {
                parts.append(PlayerManager.formatTimestamp(TimeInterval(durationSeconds)))
            }
        }
        
        return parts.joined(separator: " · ")
    }
}
