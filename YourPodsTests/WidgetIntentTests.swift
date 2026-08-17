import XCTest
@testable import YourPods

/// TDD tests for the Home Screen widget playback controls.
///
/// The interactive controls are `AudioPlaybackIntent`s; the system runs their
/// `perform()` in the *app's* process, where they must drive the live audio
/// engine **directly and awaitably** via `WidgetPlaybackBridge` — NOT via a
/// fire-and-forget `NotificationCenter` post. A notification returns before any
/// audio starts, so when the app was suspended iOS foregrounds it to begin
/// playback, which users saw as "tapping the widget opens the app." These tests
/// pin the intents to the bridge so that regression can't return.
final class WidgetIntentTests: XCTestCase {

    /// Records the commands the bridge handler receives during a test.
    @MainActor
    private final class CommandRecorder {
        var commands: [WidgetPlaybackCommand] = []
        var asyncWorkFinished = false
    }

    override func tearDown() async throws {
        await MainActor.run { WidgetPlaybackBridge.shared.handler = nil }
        try await super.tearDown()
    }

    // MARK: - Bridge dispatch

    @MainActor
    func test_bridge_dispatchesCommandToHandler() async {
        let rec = CommandRecorder()
        WidgetPlaybackBridge.shared.handler = { rec.commands.append($0) }

        await WidgetPlaybackBridge.shared.perform(.skipForward)

        XCTAssertEqual(rec.commands, [.skipForward])
    }

    // MARK: - Test 1: Toggle intent drives the bridge (not a notification)

    @available(iOS 17.0, *)
    @MainActor
    func test_togglePlayIntent_drivesBridgeWithTogglePlay() async throws {
        ComplicationDataStore.shared.write(.empty)
        let rec = CommandRecorder()
        WidgetPlaybackBridge.shared.handler = { rec.commands.append($0) }

        _ = try await WidgetTogglePlayIntent().perform()

        XCTAssertEqual(rec.commands, [.togglePlay],
                       "Toggle must drive audio in-process via the bridge, not a fire-and-forget notification")
    }

    // MARK: - Test 1b: Toggle intent AWAITS the bridge before completing

    @available(iOS 17.0, *)
    @MainActor
    func test_togglePlayIntent_awaitsBridgeBeforeReturning() async throws {
        let rec = CommandRecorder()
        WidgetPlaybackBridge.shared.handler = { _ in
            await Task.yield()          // stand-in for async audio start (resumePlayback)
            rec.asyncWorkFinished = true
        }

        _ = try await WidgetTogglePlayIntent().perform()

        XCTAssertTrue(rec.asyncWorkFinished,
                      "perform() must await the audio action so playback is established before the intent returns — otherwise iOS foregrounds the app")
    }

    // MARK: - Test 2: Skip forward drives the bridge

    @available(iOS 17.0, *)
    @MainActor
    func test_skipForwardIntent_drivesBridgeWithSkipForward() async throws {
        let rec = CommandRecorder()
        WidgetPlaybackBridge.shared.handler = { rec.commands.append($0) }

        _ = try await WidgetSkipForwardIntent().perform()

        XCTAssertEqual(rec.commands, [.skipForward])
    }

    // MARK: - Test 3: Skip backward drives the bridge

    @available(iOS 17.0, *)
    @MainActor
    func test_skipBackwardIntent_drivesBridgeWithSkipBackward() async throws {
        let rec = CommandRecorder()
        WidgetPlaybackBridge.shared.handler = { rec.commands.append($0) }

        _ = try await WidgetSkipBackwardIntent().perform()

        XCTAssertEqual(rec.commands, [.skipBackward])
    }
    
    // MARK: - Test 4: Widget artwork path round-trips through ComplicationDataStore
    
    func test_artworkPath_roundTrips() {
        let testDefaults = UserDefaults(suiteName: "WidgetIntentTests_artwork")!
        testDefaults.removePersistentDomain(forName: "WidgetIntentTests_artwork")
        let store = ComplicationDataStore(defaults: testDefaults)
        
        let data = ComplicationData(
            nowPlayingTitle: "Test Episode",
            nowPlayingPodcast: "Test Podcast",
            isPlaying: true,
            upNextTitle: nil,
            upNextPodcast: nil,
            queueCount: 0,
            lastUpdated: Date(),
            artworkPath: "/shared/container/widget_art.jpg",
            positionSeconds: 100,
            durationSeconds: 3600,
            upNextItems: []
        )
        
        store.write(data)
        let read = store.read()
        
        XCTAssertEqual(read.artworkPath, "/shared/container/widget_art.jpg",
                       "Artwork path must survive write→read round-trip")
    }
    
    // MARK: - Test 5: pushWidgetUpdate should pass artwork path (not nil)
    //
    // This test verifies the bug fix: pushWidgetUpdate() was always passing
    // artworkPath: nil. After the fix, it should write artwork path from the
    // shared container when available.
    
    func test_widgetData_artworkPathNotNilWhenAvailable() {
        // Write widget data with an artwork path
        LiveActivityService.shared.updateWidgetData(
            episodeTitle: "Art Test",
            podcastName: "Art Podcast",
            artworkPath: "/shared/container/widget_art.jpg",
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 100,
            upNextItems: []
        )
        
        let data = ComplicationDataStore.shared.read()
        XCTAssertEqual(data.artworkPath, "/shared/container/widget_art.jpg",
                       "Artwork path must be stored in widget data when provided")
    }
    
    // MARK: - Test 6: Up Next items preserve artwork paths
    
    func test_widgetData_upNextArtworkPaths() {
        LiveActivityService.shared.updateWidgetData(
            episodeTitle: "Current",
            podcastName: "Podcast",
            artworkPath: nil,
            isPlaying: true,
            positionSeconds: 0,
            durationSeconds: 100,
            upNextItems: [
                (title: "Next1", podcastTitle: "Pod1", artworkPath: "/shared/art1.jpg", artworkUrl: nil, episodeId: nil),
                (title: "Next2", podcastTitle: "Pod2", artworkPath: nil, artworkUrl: nil, episodeId: nil),
            ]
        )
        
        let data = ComplicationDataStore.shared.read()
        XCTAssertEqual(data.upNextItems.count, 2)
        XCTAssertEqual(data.upNextItems[0].artworkPath, "/shared/art1.jpg")
        XCTAssertNil(data.upNextItems[1].artworkPath)
    }
    
    // MARK: - Test 7: Toggle intent optimistically updates data store
    
    @available(iOS 17.0, *)
    func test_togglePlayIntent_flipsIsPlayingInStore() async throws {
        // Start as playing
        var data = ComplicationData.empty
        data.isPlaying = true
        data.nowPlayingTitle = "Test"
        ComplicationDataStore.shared.write(data)
        
        let intent = WidgetTogglePlayIntent()
        _ = try await intent.perform()
        
        // After perform, the store should reflect the toggled state
        let updated = ComplicationDataStore.shared.read()
        XCTAssertFalse(updated.isPlaying,
                       "Toggle intent must flip isPlaying in data store for instant widget feedback")
    }
    
    // MARK: - Test 8: Skip forward optimistically advances position
    
    @available(iOS 17.0, *)
    func test_skipForwardIntent_advancesPositionInStore() async throws {
        var data = ComplicationData.empty
        data.isPlaying = true
        data.positionSeconds = 100
        data.durationSeconds = 3600
        ComplicationDataStore.shared.write(data)
        
        let intent = WidgetSkipForwardIntent()
        _ = try await intent.perform()
        
        let updated = ComplicationDataStore.shared.read()
        XCTAssertEqual(updated.positionSeconds, 130,
                       "Skip forward must advance position by 30s in data store")
    }
    
    // MARK: - Test 9: Skip backward optimistically rewinds position
    
    @available(iOS 17.0, *)
    func test_skipBackwardIntent_rewindsPositionInStore() async throws {
        var data = ComplicationData.empty
        data.isPlaying = true
        data.positionSeconds = 100
        data.durationSeconds = 3600
        ComplicationDataStore.shared.write(data)
        
        let intent = WidgetSkipBackwardIntent()
        _ = try await intent.perform()
        
        let updated = ComplicationDataStore.shared.read()
        XCTAssertEqual(updated.positionSeconds, 85,
                       "Skip backward must rewind position by 15s in data store")
    }

    // MARK: - Test 10: Intents do not open app when run
    
    @available(iOS 17.0, *)
    func test_widgetIntents_doNotOpenAppWhenRun() {
        XCTAssertFalse(WidgetTogglePlayIntent.openAppWhenRun, "WidgetTogglePlayIntent should not open the app")
        XCTAssertFalse(WidgetSkipForwardIntent.openAppWhenRun, "WidgetSkipForwardIntent should not open the app")
        XCTAssertFalse(WidgetSkipBackwardIntent.openAppWhenRun, "WidgetSkipBackwardIntent should not open the app")
    }
}
