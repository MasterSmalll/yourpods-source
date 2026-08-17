import Foundation

/// Pure chapter-navigation math. Mirrors standard player behavior: "previous"
/// restarts the current chapter unless you're within `restartThreshold` seconds
/// of its start, in which case it goes to the chapter before it.
enum ChapterNavigator {
    static func next(in chapters: [Chapter], after position: TimeInterval) -> Chapter? {
        chapters
            .sorted { $0.startTime < $1.startTime }
            .first { $0.startTime > position }
    }

    static func previous(in chapters: [Chapter],
                         before position: TimeInterval,
                         restartThreshold: TimeInterval) -> Chapter? {
        let sorted = chapters.sorted { $0.startTime < $1.startTime }
        guard let currentIndex = sorted.lastIndex(where: { $0.startTime <= position }) else {
            return nil
        }
        let current = sorted[currentIndex]
        if position - current.startTime > restartThreshold {
            return current                                    // restart current chapter
        }
        return currentIndex > 0 ? sorted[currentIndex - 1] : nil
    }
}
