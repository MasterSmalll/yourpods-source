import Foundation

/// Pure next-episode selection for the watch player. Mirrors the historical
/// inline logic in WatchAudioManager.handleEpisodeCompleted so it can be tested
/// from YourPodsTests (the watch target has no test bundle).
enum WatchAdvancePlanner {
    static func next(after completedId: String, inQueue ids: [String]) -> String? {
        if let index = ids.firstIndex(of: completedId) {
            let nextIndex = index + 1
            return nextIndex < ids.count ? ids[nextIndex] : nil
        }
        // Completed id no longer in the queue — fall back to the head,
        // unless the head IS the completed episode.
        if let first = ids.first, first != completedId { return first }
        return nil
    }
}
