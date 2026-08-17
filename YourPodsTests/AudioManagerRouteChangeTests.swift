import XCTest
import AVFoundation
@testable import YourPods

// MARK: - Audio Route Change (pause-on-unplug) Tests

@MainActor
final class AudioManagerRouteChangeTests: XCTestCase {

    private func makeItem(id: String) -> QueueItem {
        QueueItem(
            id: id,
            title: "Episode",
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

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

    // MARK: - Pure decision (table-driven)

    func test_routeChangeShouldPause_onlyForOldDeviceUnavailable() {
        let cases: [(AVAudioSession.RouteChangeReason, Bool)] = [
            (.oldDeviceUnavailable, true),
            (.newDeviceAvailable, false),
            (.categoryChange, false),
            (.override, false),
            (.routeConfigurationChange, false),
            (.wakeFromSleep, false),
            (.noSuitableRouteForCategory, false),
            (.unknown, false),
        ]
        for (reason, expected) in cases {
            XCTAssertEqual(
                AudioManager.routeChangeShouldPause(reason: reason), expected,
                "reason \(reason.rawValue) should\(expected ? "" : " not") pause"
            )
        }
    }

    // MARK: - Testable handler

    func test_handleRouteChange_pausesWhenPlaying_andOldDeviceUnavailable() {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = true

        let didPause = manager.testableHandleRouteChange(reason: .oldDeviceUnavailable)

        XCTAssertTrue(didPause, "Should pause when playing and the old device became unavailable")
        XCTAssertFalse(manager.isPlaying, "Playback should be paused after the route disappeared")
    }

    func test_handleRouteChange_noOpWhenAlreadyPaused() {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = false

        let didPause = manager.testableHandleRouteChange(reason: .oldDeviceUnavailable)

        XCTAssertFalse(didPause, "Nothing to pause when already paused")
        XCTAssertFalse(manager.isPlaying)
    }

    func test_handleRouteChange_neverPausesOnOtherReasons_andNeverResumes() {
        let manager = AudioManager()
        manager.currentItem = makeItem(id: "ep-1")
        manager.isPlaying = true

        // A legitimate output switch (headphones -> AirPlay) fires newDeviceAvailable, never oldDeviceUnavailable.
        let didPause = manager.testableHandleRouteChange(reason: .newDeviceAvailable)

        XCTAssertFalse(didPause, "Route switches (new device available) must not pause")
        XCTAssertTrue(manager.isPlaying, "Playback must be untouched — and the handler must never resume")
    }
}
