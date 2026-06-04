/// Per-Episode/Podcast Playback Settings & Bug Regression Tests
import XCTest
@testable import YourPods

// MARK: - From PerEpisodePlaybackSettingsTests.swift

// MARK: - Per-Episode Skip/Speed Settings Tests

@MainActor
final class PerEpisodePlaybackSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(
        id: String,
        title: String = "Episode",
        skipIntro: Int = 0,
        skipOutro: Int = 0,
        playbackSpeed: Float = 1.0
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil,
            skipIntroSeconds: skipIntro,
            skipOutroSeconds: skipOutro,
            playbackSpeed: playbackSpeed
        )
    }

    // MARK: - QueueItem carries settings

    func test_queueItem_carriesSkipIntroSeconds() {
        let item = makeItem(id: "ep1", skipIntro: 30)
        XCTAssertEqual(item.skipIntroSeconds, 30)
    }

    func test_queueItem_carriesSkipOutroSeconds() {
        let item = makeItem(id: "ep1", skipOutro: 20)
        XCTAssertEqual(item.skipOutroSeconds, 20)
    }

    func test_queueItem_carriesPlaybackSpeed() {
        let item = makeItem(id: "ep1", playbackSpeed: 1.5)
        XCTAssertEqual(item.playbackSpeed, 1.5)
    }

    func test_queueItem_defaultsToZeroSkipAndNormalSpeed() {
        let item = QueueItem(
            id: "ep1", title: "Episode", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        XCTAssertEqual(item.skipIntroSeconds, 0, "Default skipIntro should be 0")
        XCTAssertEqual(item.skipOutroSeconds, 0, "Default skipOutro should be 0")
        XCTAssertEqual(item.playbackSpeed, 1.0, "Default playbackSpeed should be 1.0")
    }

    // MARK: - Encode/Decode round-trip (backward compat)

    func test_queueItem_skipSettings_surviveEncodeDecode() {
        let original = makeItem(id: "ep1", skipIntro: 45, skipOutro: 15, playbackSpeed: 2.0)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try! encoder.encode(original)
        let decoded = try! decoder.decode(QueueItem.self, from: data)

        XCTAssertEqual(decoded.skipIntroSeconds, 45)
        XCTAssertEqual(decoded.skipOutroSeconds, 15)
        XCTAssertEqual(decoded.playbackSpeed, 2.0)
    }

    func test_queueItem_decodesWithMissingSkipFields_defaultsToZero() {
        // Simulates a QueueItem persisted BEFORE skip fields were added
        let json = """
        {
            "id": "old-ep",
            "title": "Old Episode",
            "podcastTitle": "Pod",
            "audioUrl": "https://example.com/old.mp3",
            "durationSeconds": 3600,
            "positionSeconds": 100,
            "podcastUrl": "https://example.com/feed"
        }
        """.data(using: .utf8)!

        let decoded = try! JSONDecoder().decode(QueueItem.self, from: json)
        XCTAssertEqual(decoded.skipIntroSeconds, 0, "Missing skipIntro should default to 0")
        XCTAssertEqual(decoded.skipOutroSeconds, 0, "Missing skipOutro should default to 0")
        XCTAssertEqual(decoded.playbackSpeed, 1.0, "Missing playbackSpeed should default to 1.0")
    }

    // MARK: - Auto-advance carries per-episode settings

    func test_autoAdvance_nextItemCarriesItsOwnSkipSettings() {
        // GIVEN: Current item with skipIntro=0, next item with skipIntro=30
        let manager = AudioManager()
        let currentItem = makeItem(id: "ep-a", skipIntro: 0, skipOutro: 0)
        let nextItem = makeItem(id: "ep-b", skipIntro: 30, skipOutro: 20, playbackSpeed: 1.5)

        manager.currentItem = currentItem
        manager.appendToQueue([nextItem])
        manager.testableSetPlaybackState(position: 3595, duration: 3600)

        // WHEN: Auto-advance fires
        let result = manager.testableHandlePlaybackCompleted()

        // THEN: The new current item carries its own skip settings
        XCTAssertEqual(result.next?.id, "ep-b")
        XCTAssertEqual(result.next?.skipIntroSeconds, 30,
                       "Next item should carry its own skipIntro, not the previous item's")
        XCTAssertEqual(result.next?.skipOutroSeconds, 20,
                       "Next item should carry its own skipOutro")
        XCTAssertEqual(result.next?.playbackSpeed, 1.5,
                       "Next item should carry its own playbackSpeed")
        XCTAssertEqual(manager.currentItem?.skipIntroSeconds, 30)
    }

    func test_differentPodcasts_carryDifferentSkipValues() {
        // GIVEN: A queue with items from two different podcasts
        let manager = AudioManager()
        let podA_ep = makeItem(id: "podA-ep1", title: "Podcast A Ep", skipIntro: 45, skipOutro: 10)
        let podB_ep = makeItem(id: "podB-ep1", title: "Podcast B Ep", skipIntro: 0, skipOutro: 0)

        manager.appendToQueue([podA_ep, podB_ep])

        // THEN: Each item in the queue retains its own settings
        XCTAssertEqual(manager.queue[0].skipIntroSeconds, 45)
        XCTAssertEqual(manager.queue[0].skipOutroSeconds, 10)
        XCTAssertEqual(manager.queue[1].skipIntroSeconds, 0)
        XCTAssertEqual(manager.queue[1].skipOutroSeconds, 0)
    }

    // MARK: - Skip outro detection uses currentItem field

    func test_skipOutro_detectsFromCurrentItemSetting() {
        // Verify the currentItem's skipOutroSeconds is accessible for detection
        let manager = AudioManager()
        let item = makeItem(id: "ep1", skipOutro: 15)
        manager.currentItem = item
        manager.testableSetPlaybackState(position: 3585, duration: 3600)

        // The skip outro detection should use currentItem.skipOutroSeconds
        let outroSeconds = manager.currentItem?.skipOutroSeconds ?? 0
        let shouldSkip = outroSeconds > 0 &&
            manager.currentDuration > 0 &&
            manager.currentPosition >= manager.currentDuration - Double(outroSeconds)

        XCTAssertTrue(shouldSkip,
                      "Should detect outro when position is within skipOutroSeconds of the end")
    }

    func test_skipOutro_doesNotTrigger_whenSettingIsZero() {
        let manager = AudioManager()
        let item = makeItem(id: "ep1", skipOutro: 0)
        manager.currentItem = item
        manager.testableSetPlaybackState(position: 3595, duration: 3600)

        let outroSeconds = manager.currentItem?.skipOutroSeconds ?? 0
        let shouldSkip = outroSeconds > 0 &&
            manager.currentDuration > 0 &&
            manager.currentPosition >= manager.currentDuration - Double(outroSeconds)

        XCTAssertFalse(shouldSkip,
                       "Should NOT detect outro when skipOutroSeconds is 0")
    }

    // MARK: - Bug fix: Skip outro must use instance var, not stale QueueItem value

    /// Reproduces the core bug: QueueItem.skipOutroSeconds is 0 (global setting,
    /// no per-podcast override), but the settingsResolver correctly resolved the
    /// global setting and stored it in AudioManager.skipOutroSeconds.
    /// The time observer's detection must use the instance var, not the QueueItem.
    func test_skipOutro_usesInstanceVarOverStaleQueueItem() {
        let manager = AudioManager()

        // QueueItem has skipOutroSeconds = 0 (no per-podcast override)
        let item = makeItem(id: "ep1", skipOutro: 0)
        manager.currentItem = item

        // Simulate what settingsResolver does in playEpisode:
        // it resolves the GLOBAL skip outro setting and sets the instance var
        manager.skipOutroSeconds = 30

        // Position is within 30s of the end
        manager.testableSetPlaybackState(position: 3575, duration: 3600)

        // Use the testable method that mirrors the exact production detection logic.
        // BEFORE FIX: testableShouldSkipOutro reads currentItem?.skipOutroSeconds (= 0)
        //   and the ?? fallback never fires because 0 is not nil → returns false
        // AFTER FIX: testableShouldSkipOutro reads self.skipOutroSeconds (= 30) → returns true
        XCTAssertTrue(manager.testableShouldSkipOutro(),
                       "Skip outro MUST trigger when instance var is set by resolver, even if QueueItem.skipOutroSeconds is 0")
    }

    /// Verifies that after settingsResolver updates the instance var,
    /// the detection logic correctly identifies the outro region.
    func test_skipOutro_instanceVarUpdatedByResolver_triggersDetection() {
        let manager = AudioManager()

        // Wire a resolver that returns skipOutro = 45 (global setting)
        manager.settingsResolver = { _ in
            return (skipIntro: 0, skipOutro: 45, speed: 1.0, skipForward: 30, skipBackward: 15)
        }

        // QueueItem has skipOutroSeconds = 0 (stale enqueue-time value)
        let item = makeItem(id: "ep1", skipOutro: 0)
        manager.currentItem = item

        // Simulate what playEpisode does: call resolver and apply
        if let resolver = manager.settingsResolver {
            let resolved = resolver(item)
            manager.skipOutroSeconds = resolved.skipOutro
        }

        // Position: 3560s of 3600s → 40s from end → within 45s outro
        manager.testableSetPlaybackState(position: 3560, duration: 3600)

        // Detection must use the resolver-updated instance var (45), not QueueItem (0)
        XCTAssertTrue(manager.testableShouldSkipOutro(),
                       "After resolver sets skipOutroSeconds to 45, detection at 3560/3600 must trigger")
    }

    // MARK: - Queue persistence with skip settings

    func test_queuePersistence_preservesSkipSettings() {
        // GIVEN: Queue items with skip settings
        let manager1 = AudioManager()
        let item = makeItem(id: "ep1", skipIntro: 30, skipOutro: 15, playbackSpeed: 1.75)
        manager1.appendToQueue([item])

        // WHEN: A new AudioManager restores the queue
        let manager2 = AudioManager()
        manager2.restoreQueue()

        // THEN: Skip settings survive the round-trip
        XCTAssertEqual(manager2.queue.count, 1)
        XCTAssertEqual(manager2.queue[0].skipIntroSeconds, 30)
        XCTAssertEqual(manager2.queue[0].skipOutroSeconds, 15)
        XCTAssertEqual(manager2.queue[0].playbackSpeed, 1.75)
    }
}

// MARK: - From PerPodcastPlaybackBugTests.swift

// MARK: - Per-Podcast Playback Settings Bug Fix Tests
//
// These tests verify that per-podcast playback settings (skip intro, skip outro,
// playback speed) are correctly applied during all playback paths:
// - Direct play (via PlayerManager.playEpisode)
// - Auto-advance (via AudioManager.handlePlaybackCompleted → playEpisode)
// - Queue restore (via AudioManager.restoreQueue → playEpisode)
//
// The fixes are account-type agnostic — they apply in AudioManager, which is
// used identically by Vault, gPodder, and YourPods Sync modes.

@MainActor
final class PerPodcastPlaybackBugTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    private func makeItem(
        id: String,
        title: String = "Episode",
        podcastUrl: String = "https://example.com/feed",
        skipIntro: Int = 0,
        skipOutro: Int = 0,
        playbackSpeed: Float = 1.0
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: title,
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: podcastUrl,
            pubDate: nil,
            skipIntroSeconds: skipIntro,
            skipOutroSeconds: skipOutro,
            playbackSpeed: playbackSpeed
        )
    }

    // MARK: - Bug 1: Playback speed not reset during auto-advance
    //
    // testablePlayEpisodePositionResume mirrors the position/skip-intro logic
    // from the real playEpisode, but it must ALSO mirror playbackRate and
    // instance-level skip var updates to catch these bugs.
    //
    // After the fix, testablePlayEpisodePositionResume will update:
    //   - skipIntroSeconds (instance var)
    //   - skipOutroSeconds (instance var)
    //   - playbackRate

    /// Podcast A plays at 1.5x. Podcast B should play at 1.0x.
    /// Without the fix, podcast B inherits 1.5x because the test helper
    /// (mirroring real playEpisode) doesn't unconditionally set playbackRate.
    func test_autoAdvance_resetsPlaybackSpeedTo1x_whenNextItemHasDefaultSpeed() {
        let manager = AudioManager()

        // Podcast A at 1.5x
        let podcastA = makeItem(id: "podA-ep1", podcastUrl: "https://podA.com/feed", playbackSpeed: 1.5)
        // Podcast B at default 1.0x
        let podcastB = makeItem(id: "podB-ep1", podcastUrl: "https://podB.com/feed", playbackSpeed: 1.0)

        // Simulate playing podcast A — sets playbackRate to 1.5
        manager.testablePlayEpisodePositionResume(podcastA)
        manager.playbackRate = 1.5  // Mimic what real playEpisode does

        // Now simulate auto-advance to podcast B
        manager.testablePlayEpisodePositionResume(podcastB)

        // THE BUG: playbackRate stays at 1.5 because the test helper (and the
        // real playEpisode) only sets it when != 1.0.
        // After fix: playbackRate must be 1.0.
        XCTAssertEqual(manager.playbackRate, 1.0,
                       "After auto-advance to 1.0x podcast, rate must reset to 1.0 — not stay at 1.5x from previous podcast")
    }

    /// Podcast A at 1.0x → Podcast B at 2.0x. Verify rate changes.
    func test_autoAdvance_appliesPerPodcastSpeed_whenNextItemHasCustomSpeed() {
        let manager = AudioManager()

        let podcastA = makeItem(id: "podA-ep1", playbackSpeed: 1.0)
        let podcastB = makeItem(id: "podB-ep1", playbackSpeed: 2.0)

        manager.testablePlayEpisodePositionResume(podcastA)
        manager.playbackRate = 1.0

        manager.testablePlayEpisodePositionResume(podcastB)

        // This should work even before the fix (2.0 != 1.0 triggers the old condition),
        // but we test it post-fix to prevent regression.
        XCTAssertEqual(manager.playbackRate, 2.0,
                       "After auto-advance to 2.0x podcast, rate must be 2.0")
    }

    // MARK: - Bug 2: Stale instance-level skip vars leak across podcasts

    /// After playing an item with skipIntro=30, the AudioManager's instance var
    /// must be updated to 30 (not left at whatever it was before).
    func test_skipIntro_instanceVarUpdated_onPlayEpisode() {
        let manager = AudioManager()
        manager.skipIntroSeconds = 0  // Start clean

        let item = makeItem(id: "ep1", skipIntro: 30)
        manager.testablePlayEpisodePositionResume(item)

        // THE BUG: testablePlayEpisodePositionResume (and real playEpisode)
        // doesn't update skipIntroSeconds instance var from the QueueItem.
        XCTAssertEqual(manager.skipIntroSeconds, 30,
                       "Instance-level skipIntroSeconds must be updated from QueueItem on play")
    }

    /// Podcast A has skipIntro=30. Podcast B has skipIntro=0.
    /// After auto-advance to B, the instance var must be 0 — not stale at 30.
    func test_skipIntro_instanceVarReset_whenNextItemHasNoSkip() {
        let manager = AudioManager()

        let podcastA = makeItem(id: "podA-ep1", skipIntro: 30)
        let podcastB = makeItem(id: "podB-ep1", skipIntro: 0)

        // Play podcast A
        manager.testablePlayEpisodePositionResume(podcastA)
        // Manually set to simulate what the fix should do
        manager.skipIntroSeconds = 30

        // Auto-advance to podcast B
        manager.testablePlayEpisodePositionResume(podcastB)

        // THE BUG: skipIntroSeconds remains 30 from podcast A.
        // After fix: must be 0.
        XCTAssertEqual(manager.skipIntroSeconds, 0,
                       "Instance-level skipIntroSeconds must reset to 0 for podcast B, not stay at 30 from podcast A")
    }

    /// Same pattern for skip outro
    func test_skipOutro_instanceVarUpdated_onPlayEpisode() {
        let manager = AudioManager()
        manager.skipOutroSeconds = 0

        let item = makeItem(id: "ep1", skipOutro: 15)
        manager.testablePlayEpisodePositionResume(item)

        XCTAssertEqual(manager.skipOutroSeconds, 15,
                       "Instance-level skipOutroSeconds must be updated from QueueItem on play")
    }

    /// Podcast A has skipOutro=15 → Podcast B has skipOutro=0.
    func test_skipOutro_instanceVarReset_whenNextItemHasNoSkip() {
        let manager = AudioManager()

        let podcastA = makeItem(id: "podA-ep1", skipOutro: 15)
        let podcastB = makeItem(id: "podB-ep1", skipOutro: 0)

        manager.testablePlayEpisodePositionResume(podcastA)
        manager.skipOutroSeconds = 15

        manager.testablePlayEpisodePositionResume(podcastB)

        XCTAssertEqual(manager.skipOutroSeconds, 0,
                       "Instance-level skipOutroSeconds must reset to 0 for podcast B")
    }

    // MARK: - Playback speed always applied

    /// Verify playbackRate is always set from the QueueItem, even when 1.0.
    func test_playEpisode_alwaysSetsPlaybackRate() {
        let manager = AudioManager()
        manager.playbackRate = 2.5  // Artificial stale rate

        let item = makeItem(id: "ep1", playbackSpeed: 1.0)
        manager.testablePlayEpisodePositionResume(item)

        // THE BUG: playbackRate remains 2.5 because real playEpisode
        // (and test helper) skips setting it when speed == 1.0.
        XCTAssertEqual(manager.playbackRate, 1.0,
                       "playbackRate must be set to item's speed (1.0), not remain at stale 2.5")
    }
}
