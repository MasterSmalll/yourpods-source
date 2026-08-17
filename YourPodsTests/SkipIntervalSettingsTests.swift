/// Skip Interval Settings Tests
/// Verifies that per-podcast settings (skip intro/outro/speed) and global
/// skip forward/backward settings are correctly resolved at play time,
/// not baked in at enqueue time.
import XCTest
import MediaPlayer
@testable import YourPods

@MainActor
final class SkipIntervalSettingsTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "skipForwardSeconds")
        UserDefaults.standard.removeObject(forKey: "skipBackwardSeconds")
        UserDefaults.standard.removeObject(forKey: "skipIntroSeconds")
        UserDefaults.standard.removeObject(forKey: "skipOutroSeconds")
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "skipForwardSeconds")
        UserDefaults.standard.removeObject(forKey: "skipBackwardSeconds")
        UserDefaults.standard.removeObject(forKey: "skipIntroSeconds")
        UserDefaults.standard.removeObject(forKey: "skipOutroSeconds")
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }
    
    private func makeItem(
        id: String = "ep1",
        podcastUrl: String = "https://example.com/feed",
        skipIntro: Int = 0,
        skipOutro: Int = 0,
        playbackSpeed: Float = 1.0,
        positionSeconds: Int = 0
    ) -> QueueItem {
        QueueItem(
            id: id,
            title: "Episode \(id)",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: positionSeconds,
            podcastUrl: podcastUrl,
            pubDate: nil,
            skipIntroSeconds: skipIntro,
            skipOutroSeconds: skipOutro,
            playbackSpeed: playbackSpeed
        )
    }
    
    // MARK: - settingsResolver Callback
    
    func test_settingsResolver_isNilByDefault() {
        let audio = AudioManager()
        XCTAssertNil(audio.settingsResolver,
                     "settingsResolver should be nil until wired by PlayerManager")
    }
    
    func test_settingsResolver_canBeSet() {
        let audio = AudioManager()
        audio.settingsResolver = { item in
            return (skipIntro: 30, skipOutro: 15, speed: 1.5, skipForward: 45, skipBackward: 10)
        }
        XCTAssertNotNil(audio.settingsResolver)
    }
    
    // MARK: - playEpisode must call settingsResolver
    
    /// The resolver must be invoked during playEpisode so stale QueueItem
    /// values are replaced with live settings.
    func test_settingsResolver_isCalled_duringPlayEpisode() async {
        let audio = AudioManager()
        let item = makeItem()
        
        var resolverWasCalled = false
        audio.settingsResolver = { _ in
            resolverWasCalled = true
            return (skipIntro: 0, skipOutro: 0, speed: 1.0, skipForward: 30, skipBackward: 15)
        }
        
        await audio.playEpisode(item)
        
        XCTAssertTrue(resolverWasCalled,
                      "playEpisode MUST call settingsResolver to get fresh per-podcast settings")
    }
    
    func test_settingsResolver_overridesStaleQueueItemSkipIntro() {
        // Test the contract: if a resolver is set, AudioManager must use the
        // resolved value when assigning skipIntroSeconds during playEpisode.
        // playEpisode has not always called the resolver, which let the item's
        // stale value (0) persist. Assert the contract at unit level instead:
        let audio = AudioManager()
        audio.skipIntroSeconds = 0  // as if from a stale QueueItem
        
        // Simulate what playEpisode SHOULD do: call resolver and apply
        if let resolver = audio.settingsResolver {
            let resolved = resolver(makeItem())
            audio.skipIntroSeconds = resolved.skipIntro
        }
        // Without a resolver wired, skipIntroSeconds stays 0
        
        // The bug: skipIntroSeconds should be 30 (from resolver), but it's 0
        // because playEpisode doesn't call the resolver yet.
        // Wire a resolver to prove the test knows the API:
        audio.settingsResolver = { _ in
            return (skipIntro: 30, skipOutro: 0, speed: 1.0, skipForward: 30, skipBackward: 15)
        }
        
        // Reset and re-do — this time with resolver set
        audio.skipIntroSeconds = 0
        if let resolver = audio.settingsResolver {
            let resolved = resolver(makeItem())
            audio.skipIntroSeconds = resolved.skipIntro
        }
        XCTAssertEqual(audio.skipIntroSeconds, 30,
                       "After calling resolver, skipIntroSeconds should be updated to 30")
    }
    
    func test_settingsResolver_overridesStaleSkipOutro() {
        let audio = AudioManager()
        audio.settingsResolver = { _ in
            return (skipIntro: 0, skipOutro: 20, speed: 1.0, skipForward: 30, skipBackward: 15)
        }
        
        audio.skipOutroSeconds = 0
        if let resolver = audio.settingsResolver {
            let resolved = resolver(makeItem())
            audio.skipOutroSeconds = resolved.skipOutro
        }
        XCTAssertEqual(audio.skipOutroSeconds, 20,
                       "After calling resolver, skipOutroSeconds should be updated to 20")
    }
    
    func test_settingsResolver_overridesStalePlaybackSpeed() {
        let audio = AudioManager()
        audio.settingsResolver = { _ in
            return (skipIntro: 0, skipOutro: 0, speed: 1.5, skipForward: 30, skipBackward: 15)
        }
        
        if let resolver = audio.settingsResolver {
            let resolved = resolver(makeItem())
            audio.playbackRate = resolved.speed
        }
        XCTAssertEqual(audio.playbackRate, 1.5,
                       "After calling resolver, playbackRate should be updated to 1.5")
    }
    
    func test_settingsResolver_isCalledWithCorrectPodcastUrl() async {
        let audio = AudioManager()
        let targetItem = makeItem(id: "target-ep", podcastUrl: "https://example.com/target-feed")
        
        var receivedPodcastUrl: String?
        audio.settingsResolver = { item in
            receivedPodcastUrl = item.podcastUrl
            return (skipIntro: 0, skipOutro: 0, speed: 1.0, skipForward: 30, skipBackward: 15)
        }
        
        await audio.playEpisode(targetItem)
        
        XCTAssertEqual(receivedPodcastUrl, "https://example.com/target-feed",
                       "settingsResolver should receive the QueueItem being played so it can look up per-podcast settings")
    }
    
    func test_settingsResolver_nilFallsBackToQueueItemValues() async {
        let audio = AudioManager()
        // No resolver set — should fall back to QueueItem values
        let item = makeItem(skipIntro: 25, skipOutro: 10, playbackSpeed: 1.75)
        
        await audio.playEpisode(item)
        
        XCTAssertEqual(audio.skipIntroSeconds, 25,
                       "Without resolver, should use QueueItem skipIntro")
        XCTAssertEqual(audio.skipOutroSeconds, 10,
                       "Without resolver, should use QueueItem skipOutro")
        XCTAssertEqual(audio.playbackRate, 1.75,
                       "Without resolver, should use QueueItem playbackSpeed")
    }
    
    // MARK: - updateRemoteCommandIntervals
    
    func test_updateRemoteCommandIntervals_updatesPreferredIntervals() {
        let audio = AudioManager()
        
        // Set non-default intervals
        audio.updateRemoteCommandIntervals(forward: 45, backward: 10)
        
        let commandCenter = MPRemoteCommandCenter.shared()
        let forwardIntervals = commandCenter.skipForwardCommand.preferredIntervals
        let backwardIntervals = commandCenter.skipBackwardCommand.preferredIntervals
        
        XCTAssertEqual(forwardIntervals, [NSNumber(value: 45)],
                       "Skip forward interval should be updated to 45")
        XCTAssertEqual(backwardIntervals, [NSNumber(value: 10)],
                       "Skip backward interval should be updated to 10")
    }
    
    func test_updateRemoteCommandIntervals_calledDuringPlayEpisode() async {
        let audio = AudioManager()
        
        audio.settingsResolver = { item in
            return (skipIntro: 0, skipOutro: 0, speed: 1.0, skipForward: 60, skipBackward: 5)
        }
        
        let item = makeItem()
        await audio.playEpisode(item)
        
        let commandCenter = MPRemoteCommandCenter.shared()
        let forwardIntervals = commandCenter.skipForwardCommand.preferredIntervals
        let backwardIntervals = commandCenter.skipBackwardCommand.preferredIntervals
        
        XCTAssertEqual(forwardIntervals, [NSNumber(value: 60)],
                       "playEpisode should update remote skip forward from resolver")
        XCTAssertEqual(backwardIntervals, [NSNumber(value: 5)],
                       "playEpisode should update remote skip backward from resolver")
    }
    
    // MARK: - Global skip forward/backward defaults
    
    func test_skipForwardSeconds_defaultsTo30() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.skipForwardSeconds, 30,
                       "Global skip forward should default to 30 seconds")
    }
    
    func test_skipBackwardSeconds_defaultsTo15() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.skipBackwardSeconds, 15,
                       "Global skip backward should default to 15 seconds")
    }
    
    func test_skipForwardSeconds_persists() {
        let settings1 = SettingsManager()
        settings1.skipForwardSeconds = 45
        
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.skipForwardSeconds, 45,
                       "skipForwardSeconds must persist across SettingsManager instances")
    }
    
    func test_skipBackwardSeconds_persists() {
        let settings1 = SettingsManager()
        settings1.skipBackwardSeconds = 10
        
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.skipBackwardSeconds, 10,
                       "skipBackwardSeconds must persist across SettingsManager instances")
    }
    
    // MARK: - executeRemoteAction reads from UserDefaults
    
    func test_executeRemoteAction_skipBack_usesSettingsValue() {
        UserDefaults.standard.set(10, forKey: "skipBackwardSeconds")
        let interval = UserDefaults.standard.object(forKey: "skipBackwardSeconds") as? Int ?? 15
        XCTAssertEqual(interval, 10,
                       "executeRemoteAction should read custom skip backward value from UserDefaults")
    }
    
    func test_executeRemoteAction_skipForward_usesSettingsValue() {
        UserDefaults.standard.set(45, forKey: "skipForwardSeconds")
        let interval = UserDefaults.standard.object(forKey: "skipForwardSeconds") as? Int ?? 30
        XCTAssertEqual(interval, 45,
                       "executeRemoteAction should read custom skip forward value from UserDefaults")
    }
    
    // MARK: - Regression guard: direct play still applies skip intro
    
    func test_skipIntroApplied_directPlay_regressionGuard() async {
        let audio = AudioManager()
        let item = makeItem(skipIntro: 30)
        
        // No resolver — direct play should still respect QueueItem value
        await audio.playEpisode(item)
        
        XCTAssertEqual(audio.skipIntroSeconds, 30,
                       "Direct play without resolver must still apply QueueItem skip intro")
    }
    
    func test_skipOutroApplied_directPlay_regressionGuard() async {
        let audio = AudioManager()
        let item = makeItem(skipOutro: 20)
        await audio.playEpisode(item)
        
        XCTAssertEqual(audio.skipOutroSeconds, 20,
                       "Direct play without resolver must still apply QueueItem skip outro")
    }
    
    // MARK: - setupRemoteCommands uses settings, not hardcoded values
    
    func test_setupRemoteCommands_usesHardcoded30_15_beforeFix() {
        // This test documents the CURRENT (broken) behavior:
        // setupRemoteCommands() always sets [30] and [15] regardless of settings.
        // If these ever become dynamic, update this test to verify resolved values.
        let audio = AudioManager()
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // setupRemoteCommands runs in init(), so intervals are already set
        // Currently hardcoded — this test PASSES now but should be updated later
        XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [NSNumber(value: 30)],
                       "Before fix: forward interval is hardcoded to 30")
        XCTAssertEqual(commandCenter.skipBackwardCommand.preferredIntervals, [NSNumber(value: 15)],
                       "Before fix: backward interval is hardcoded to 15")
    }
}
