import XCTest
@testable import YourPods

// MARK: - CarPlay Rate Stepping Tests

@MainActor
final class CarPlayRateTests: XCTestCase {

    // MARK: - availableRates sanity

    func test_availableRates_isAscending() {
        let rates = AudioManager.availableRates
        XCTAssertEqual(rates, rates.sorted(), "availableRates must be in ascending order")
        XCTAssertFalse(rates.isEmpty)
    }

    // MARK: - nearestRateIndex (via AudioManager indirectly)

    /// Helper: find nearest rate index — mirrors CarPlayService.nearestRateIndex
    private func nearestRateIndex(for rate: Float) -> Int {
        let rates = AudioManager.availableRates
        return rates.enumerated().min(by: { abs($0.element - rate) < abs($1.element - rate) })?.offset ?? 2
    }

    func test_nearestRateIndex_exactMatch() {
        XCTAssertEqual(nearestRateIndex(for: 1.0), 2) // index of 1.0 in [0.5, 0.75, 1.0, ...]
        XCTAssertEqual(nearestRateIndex(for: 0.5), 0)
        XCTAssertEqual(nearestRateIndex(for: 3.0), AudioManager.availableRates.count - 1)
    }

    func test_nearestRateIndex_snapsToClosest() {
        // 1.1 is between 1.0 (idx 2) and 1.25 (idx 3), closer to 1.0
        XCTAssertEqual(nearestRateIndex(for: 1.1), 2)
        // 1.15 is closer to 1.25 (diff 0.1) than 1.0 (diff 0.15)
        XCTAssertEqual(nearestRateIndex(for: 1.15), 3)
    }

    func test_nearestRateIndex_belowMinimum() {
        XCTAssertEqual(nearestRateIndex(for: 0.1), 0)
    }

    func test_nearestRateIndex_aboveMaximum() {
        XCTAssertEqual(nearestRateIndex(for: 5.0), AudioManager.availableRates.count - 1)
    }

    // MARK: - Rate stepping via AudioManager

    func test_increaseRate_stepsUp() {
        let manager = AudioManager()
        manager.setPlaybackRate(1.0) // index 2
        // Simulate stepping up
        let rates = AudioManager.availableRates
        let idx = nearestRateIndex(for: manager.playbackRate)
        XCTAssertTrue(idx < rates.count - 1, "Should not be at max to step up")
        let newRate = rates[idx + 1]
        manager.setPlaybackRate(newRate)
        XCTAssertEqual(manager.playbackRate, 1.25)
    }

    func test_decreaseRate_stepsDown() {
        let manager = AudioManager()
        manager.setPlaybackRate(1.0) // index 2
        let rates = AudioManager.availableRates
        let idx = nearestRateIndex(for: manager.playbackRate)
        XCTAssertTrue(idx > 0, "Should not be at min to step down")
        let newRate = rates[idx - 1]
        manager.setPlaybackRate(newRate)
        XCTAssertEqual(manager.playbackRate, 0.75)
    }

    func test_increaseRate_clampsAtMax() {
        let rates = AudioManager.availableRates
        let idx = nearestRateIndex(for: rates.last!)
        XCTAssertEqual(idx, rates.count - 1, "Max rate should be at last index")
        // Attempting to go higher should stay at max
        XCTAssertFalse(idx < rates.count - 1, "Should NOT step beyond max — clamp")
    }

    func test_decreaseRate_clampsAtMin() {
        let rates = AudioManager.availableRates
        let idx = nearestRateIndex(for: rates.first!)
        XCTAssertEqual(idx, 0, "Min rate should be at index 0")
        // Attempting to go lower should stay at min
        XCTAssertFalse(idx > 0, "Should NOT step below min — clamp")
    }

    // MARK: - Rate change callback

    func test_setPlaybackRate_firesCallback() {
        let manager = AudioManager()
        var callbackRate: Float?
        manager.onPlaybackRateChanged = { rate in
            callbackRate = rate
        }

        manager.setPlaybackRate(1.5)

        XCTAssertEqual(callbackRate, 1.5, "Callback should fire with the new rate")
    }
}

// MARK: - CarPlay Chapter Seek Tests

@MainActor
final class CarPlayChapterSeekTests: XCTestCase {

    /// Mirrors the chapter seek logic from CarPlayService
    private func seekTarget(chapters: [Chapter], currentPosition: Double, direction: ChapterDirection) -> Double? {
        guard !chapters.isEmpty else { return nil }

        let currentIdx = chapters.lastIndex(where: { $0.startTime <= currentPosition }) ?? 0

        switch direction {
        case .previous:
            let targetIdx = (currentPosition - chapters[currentIdx].startTime) < 3
                ? max(0, currentIdx - 1)
                : currentIdx
            return chapters[targetIdx].startTime
        case .next:
            guard currentIdx + 1 < chapters.count else { return nil }
            return chapters[currentIdx + 1].startTime
        }
    }

    enum ChapterDirection { case previous, next }

    private let testChapters: [Chapter] = [
        Chapter(startTime: 0, title: "Intro", img: nil, url: nil),
        Chapter(startTime: 60, title: "Topic A", img: nil, url: nil),
        Chapter(startTime: 180, title: "Topic B", img: nil, url: nil),
        Chapter(startTime: 360, title: "Outro", img: nil, url: nil),
    ]

    // MARK: - Next Chapter

    func test_nextChapter_seeksToNextStart() {
        let target = seekTarget(chapters: testChapters, currentPosition: 30, direction: .next)
        XCTAssertEqual(target, 60, "Should jump to Topic A start")
    }

    func test_nextChapter_atLastChapter_returnsNil() {
        let target = seekTarget(chapters: testChapters, currentPosition: 400, direction: .next)
        XCTAssertNil(target, "Already at last chapter — no next chapter")
    }

    func test_nextChapter_noChapters_returnsNil() {
        let target = seekTarget(chapters: [], currentPosition: 100, direction: .next)
        XCTAssertNil(target, "No chapters — should be nil")
    }

    // MARK: - Previous Chapter

    func test_prevChapter_after3s_restartsCurrentChapter() {
        // At 70s, 10s into Topic A (startTime=60) — more than 3s in → restart Topic A
        let target = seekTarget(chapters: testChapters, currentPosition: 70, direction: .previous)
        XCTAssertEqual(target, 60, "Should restart current chapter (Topic A)")
    }

    func test_prevChapter_within3s_jumpsToPrevious() {
        // At 62s, only 2s into Topic A — within 3s threshold → jump to Intro
        let target = seekTarget(chapters: testChapters, currentPosition: 62, direction: .previous)
        XCTAssertEqual(target, 0, "Should jump to previous chapter (Intro)")
    }

    func test_prevChapter_atFirstChapter_within3s_staysAtStart() {
        // At 1s, within 3s of Intro start — no previous chapter, clamp to 0
        let target = seekTarget(chapters: testChapters, currentPosition: 1, direction: .previous)
        XCTAssertEqual(target, 0, "Should stay at Intro start (no previous)")
    }

    func test_prevChapter_noChapters_returnsNil() {
        let target = seekTarget(chapters: [], currentPosition: 100, direction: .previous)
        XCTAssertNil(target, "No chapters — should be nil")
    }
}

// MARK: - Trim Silence Toggle Tests

@MainActor
final class CarPlayTrimSilenceTests: XCTestCase {

    func test_skipSilenceEnabled_defaultIsFalse() {
        let manager = AudioManager()
        XCTAssertFalse(manager.skipSilenceEnabled, "Skip silence should default to off")
    }

    func test_toggleSkipSilence_changesState() {
        let manager = AudioManager()
        manager.skipSilenceEnabled = true
        XCTAssertTrue(manager.skipSilenceEnabled)
        manager.skipSilenceEnabled = false
        XCTAssertFalse(manager.skipSilenceEnabled)
    }

    func test_skipSilenceChanged_firesCallback() {
        let manager = AudioManager()
        var callbackValue: Bool?
        manager.onSkipSilenceChanged = { enabled in
            callbackValue = enabled
        }

        manager.skipSilenceEnabled = true

        XCTAssertEqual(callbackValue, true, "Callback should fire with true")
    }

    func test_skipSilenceChanged_firesOnToggle() {
        let manager = AudioManager()
        var callbackValues: [Bool] = []
        manager.onSkipSilenceChanged = { enabled in
            callbackValues.append(enabled)
        }

        manager.skipSilenceEnabled = true
        manager.skipSilenceEnabled = false

        XCTAssertEqual(callbackValues, [true, false], "Callback should fire for both toggles")
    }
}

// MARK: - CarPlay Recently Updated Logic Tests

/// Tests the filtering/sorting logic used by the "Recently Updated" CarPlay tab.
/// Mirrors the approach in HomeView.recentEpisodes: unplayed, non-interacted,
/// sorted by pubDate descending, capped at a maximum count.
@MainActor
final class CarPlayRecentlyUpdatedTests: XCTestCase {

    // MARK: - Helper: mirrors CarPlayService.recentEpisodes logic

    /// Pure-logic filter that mirrors what CarPlayService.buildRecentlyUpdatedTab will use.
    /// Takes flat episode list (already extracted from subscriptions) and returns filtered+sorted results.
    private func recentEpisodes(from episodes: [Episode], limit: Int = 20) -> [Episode] {
        episodes
            .filter { !$0.isPlayed && !$0.isInteracted }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Convenience: create a test Episode with minimal fields.
    private func makeEpisode(
        guid: String,
        title: String = "Episode",
        pubDate: Date? = nil,
        isPlayed: Bool = false,
        isInteracted: Bool = false
    ) -> Episode {
        let ep = Episode(guid: guid, title: title, pubDate: pubDate)
        ep.isPlayed = isPlayed
        ep.isInteracted = isInteracted
        return ep
    }

    // MARK: - Filtering

    func test_recentEpisodes_excludesPlayedEpisodes() {
        let episodes = [
            makeEpisode(guid: "a", title: "Unplayed", pubDate: Date(), isPlayed: false),
            makeEpisode(guid: "b", title: "Played", pubDate: Date(), isPlayed: true),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.count, 1, "Should exclude played episodes")
        XCTAssertEqual(result.first?.guid, "a")
    }

    func test_recentEpisodes_excludesInteractedEpisodes() {
        let episodes = [
            makeEpisode(guid: "a", title: "Fresh", pubDate: Date(), isInteracted: false),
            makeEpisode(guid: "b", title: "Interacted", pubDate: Date(), isInteracted: true),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.count, 1, "Should exclude interacted episodes")
        XCTAssertEqual(result.first?.guid, "a")
    }

    func test_recentEpisodes_excludesBothPlayedAndInteracted() {
        let episodes = [
            makeEpisode(guid: "a", pubDate: Date(), isPlayed: true, isInteracted: true),
            makeEpisode(guid: "b", pubDate: Date(), isPlayed: true, isInteracted: false),
            makeEpisode(guid: "c", pubDate: Date(), isPlayed: false, isInteracted: true),
            makeEpisode(guid: "d", pubDate: Date(), isPlayed: false, isInteracted: false),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.guid, "d")
    }

    // MARK: - Sorting

    func test_recentEpisodes_sortedByPubDateDescending() {
        let old = Date(timeIntervalSince1970: 1000)
        let mid = Date(timeIntervalSince1970: 2000)
        let recent = Date(timeIntervalSince1970: 3000)

        let episodes = [
            makeEpisode(guid: "old", pubDate: old),
            makeEpisode(guid: "recent", pubDate: recent),
            makeEpisode(guid: "mid", pubDate: mid),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.map(\.guid), ["recent", "mid", "old"], "Should be newest first")
    }

    func test_recentEpisodes_nilPubDateSortsLast() {
        let episodes = [
            makeEpisode(guid: "no-date", pubDate: nil),
            makeEpisode(guid: "has-date", pubDate: Date()),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.first?.guid, "has-date", "Nil pubDate should sort after real dates")
    }

    // MARK: - Limit

    func test_recentEpisodes_limitsTo20() {
        let episodes = (0..<30).map { i in
            makeEpisode(guid: "ep-\(i)", pubDate: Date(timeIntervalSince1970: Double(i)))
        }
        let result = recentEpisodes(from: episodes)
        XCTAssertEqual(result.count, 20, "Should cap at 20 items for CarPlay")
    }

    // MARK: - Edge cases

    func test_recentEpisodes_emptyInput_returnsEmpty() {
        let result = recentEpisodes(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func test_recentEpisodes_allFiltered_returnsEmpty() {
        let episodes = [
            makeEpisode(guid: "a", pubDate: Date(), isPlayed: true),
            makeEpisode(guid: "b", pubDate: Date(), isInteracted: true),
        ]
        let result = recentEpisodes(from: episodes)
        XCTAssertTrue(result.isEmpty, "All filtered out — should be empty")
    }
}
