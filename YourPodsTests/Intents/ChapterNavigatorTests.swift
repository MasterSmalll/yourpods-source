import XCTest
@testable import YourPods

final class ChapterNavigatorTests: XCTestCase {
    private let chapters = [
        Chapter(startTime: 0, title: "Intro", img: nil, url: nil),
        Chapter(startTime: 120, title: "Topic A", img: nil, url: nil),
        Chapter(startTime: 600, title: "Topic B", img: nil, url: nil),
    ]

    func test_next_returnsFollowingChapter_perPosition() {
        let cases: [(position: TimeInterval, expected: String?)] = [
            (0, "Topic A"), (119, "Topic A"), (120, "Topic B"),
            (599, "Topic B"), (600, nil), (9999, nil),
        ]
        for c in cases {
            XCTAssertEqual(ChapterNavigator.next(in: chapters, after: c.position)?.title,
                           c.expected, "position \(c.position)")
        }
    }

    func test_previous_restartsCurrentChapter_orStepsBack_perPosition() {
        // Within the first `restartThreshold` seconds of a chapter → previous chapter;
        // deeper into a chapter → restart the current one (standard player behavior).
        let cases: [(position: TimeInterval, expected: String?)] = [
            (130, "Topic A"),   // 10s into Topic A → restart Topic A
            (121, "Intro"),     // 1s into Topic A (≤ threshold) → back to Intro
            (2, nil),           // 2s into Intro, nothing before → nil (caller seeks to 0)
            (50, "Intro"),      // deep in Intro → restart Intro
            (700, "Topic B"),
        ]
        for c in cases {
            XCTAssertEqual(ChapterNavigator.previous(in: chapters, before: c.position,
                                                     restartThreshold: 3)?.title,
                           c.expected, "position \(c.position)")
        }
    }

    func test_next_returnsNil_whenChaptersEmpty() {
        XCTAssertNil(ChapterNavigator.next(in: [], after: 10))
        XCTAssertNil(ChapterNavigator.previous(in: [], before: 10, restartThreshold: 3))
    }

    // MARK: - Ordering independence (callers may pass unsorted arrays)

    /// `next` sorts internally — callers must not have to pre-sort. The
    /// scrambled order places the chronologically FIRST-after-position
    /// chapter (Topic B, 600s) at raw index 0, so an implementation that
    /// dropped the internal `.sorted` would return it immediately instead of
    /// the correct nearer chapter (Topic A, 120s).
    func test_next_doesNotDependOnCallerOrdering() {
        let scrambled = [
            Chapter(startTime: 600, title: "Topic B", img: nil, url: nil),
            Chapter(startTime: 0, title: "Intro", img: nil, url: nil),
            Chapter(startTime: 120, title: "Topic A", img: nil, url: nil),
        ]
        XCTAssertEqual(ChapterNavigator.next(in: scrambled, after: 30)?.title, "Topic A")
    }

    /// Same guarantee for `previous`. The scrambled order places
    /// chronologically-first "Intro" (0s) LAST in the raw array, so an
    /// unsorted `lastIndex(where:)` scan (which walks from the end) would
    /// hit it first and wrongly resolve it as "current" at position 650 —
    /// the correct current chapter there is Topic B (600s), which should
    /// restart (650 - 600 = 50 > threshold).
    func test_previous_doesNotDependOnCallerOrdering() {
        let scrambled = [
            Chapter(startTime: 120, title: "Topic A", img: nil, url: nil),
            Chapter(startTime: 600, title: "Topic B", img: nil, url: nil),
            Chapter(startTime: 0, title: "Intro", img: nil, url: nil),
        ]
        XCTAssertEqual(ChapterNavigator.previous(in: scrambled, before: 650, restartThreshold: 3)?.title, "Topic B")
    }

    // MARK: - Restart-threshold boundary (both sides + the boundary itself)

    /// position - chapterStart == restartThreshold exactly. The comparison
    /// in `previous` is strictly `>`, so equality must still step BACK
    /// rather than restart — the existing table only exercised each side of
    /// the threshold, never the boundary value itself.
    func test_previous_atExactRestartThreshold_stepsBack_notRestart() {
        XCTAssertEqual(ChapterNavigator.previous(in: chapters, before: 123, restartThreshold: 3)?.title, "Intro")
    }

    /// One hundredth of a second past the same boundary must flip to restart.
    func test_previous_justOverRestartThreshold_restartsCurrentChapter() {
        XCTAssertEqual(ChapterNavigator.previous(in: chapters, before: 123.01, restartThreshold: 3)?.title, "Topic A")
    }

    // MARK: - Position before the first chapter

    func test_previous_returnsNil_whenPositionPrecedesAllChapters() {
        let lateChapters = [Chapter(startTime: 30, title: "Late", img: nil, url: nil)]
        XCTAssertNil(ChapterNavigator.previous(in: lateChapters, before: 10, restartThreshold: 3))
    }
}
