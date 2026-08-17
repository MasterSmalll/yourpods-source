import Foundation

/// Pure sleep-timer state for the watch player.
enum WatchSleepTimerModel: Equatable {
    case duration(minutes: Int, startedAt: Date)
    case endOfEpisode

    var stopsAtTrackEnd: Bool { self == .endOfEpisode }

    func isExpired(at now: Date) -> Bool {
        switch self {
        case .duration(let minutes, let startedAt):
            return now >= startedAt.addingTimeInterval(TimeInterval(minutes * 60))
        case .endOfEpisode:
            return false
        }
    }

    func remainingMinutes(at now: Date) -> Int? {
        switch self {
        case .duration(let minutes, let startedAt):
            let deadline = startedAt.addingTimeInterval(TimeInterval(minutes * 60))
            return max(0, Int(ceil(deadline.timeIntervalSince(now) / 60)))
        case .endOfEpisode:
            return nil
        }
    }
}
