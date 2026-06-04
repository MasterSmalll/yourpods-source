import XCTest
@testable import YourPods

/// Regression tests: sync conflict resolution must update AudioManager's position
/// metadata (currentItem.positionSeconds and currentPosition) EXPLICITLY —
/// not relying on AVPlayer.seek() which silently fails on cold start.
///
/// Bug: "Selected server in sync conflict → tapped play on mini player
/// → episode started at local time → sync conflict fired again."
///
/// Root cause: resolveConflictIfPlaying/resolveQueueConflict only call
/// seek(to:), which is a no-op when AVPlayer has no loaded item. The
/// metadata (currentPosition, currentItem.positionSeconds) is never
/// explicitly updated, so cold-start play() uses the stale local position.
///
/// Additional symptom: After quitting/relaunching, local time is wrong
/// because progress tracker overwrites Episode.listenedSeconds with stale
/// currentPosition after the conflict was "resolved".
final class SyncConflictResolutionPlaybackTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Clean queue keys to prevent test order dependencies
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
    
    /// Helper: create a SyncConflict for a given episode GUID
    private func makeConflict(
        episodeGuid: String,
        localPosition: Int,
        serverPosition: Int
    ) -> SyncConflict {
        SyncConflict(
            episodeGuid: episodeGuid,
            episodeTitle: "Test Episode",
            podcastTitle: "Pod",
            podcastUrl: "https://example.com/feed",
            artworkUrl: nil,
            audioUrl: "https://example.com/ep.mp3",
            localPosition: localPosition,
            serverPosition: serverPosition,
            serverTimestamp: Int(Date().timeIntervalSince1970),
            totalDuration: 3600,
            occurrenceCount: 1
        )
    }
    
    /// Helper: create a QueueItem
    private func makeItem(id: String, positionSeconds: Int) -> QueueItem {
        QueueItem(
            id: id,
            title: "Test Episode",
            podcastTitle: "Pod",
            audioUrl: "https://example.com/ep.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: positionSeconds,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }
    
    // MARK: - Core bug: resolveConflictIfPlaying must EXPLICITLY update metadata
    
    /// The fix MUST update currentItem.positionSeconds directly (not via seek)
    /// so that the value survives cold start, queue persistence, and relaunch.
    @MainActor
    func test_resolveConflictIfPlaying_explicitlyUpdatesCurrentItemPosition() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1", positionSeconds: 200)
        audioManager.testableSetPlaybackState(position: 200, duration: 3600)
        
        let conflict = makeConflict(episodeGuid: "ep-1", localPosition: 200, serverPosition: 1500)
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 1500)
        
        // The fix must set this directly — NOT rely on AVPlayer.seek().
        // In production, AVPlayer.seek() is a no-op when there's no loaded item.
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 1500,
                       "resolveConflictIfPlaying must explicitly update positionSeconds to 1500")
    }
    
    /// The fix MUST update currentPosition directly so that:
    /// 1. Cold-start play() uses the correct position
    /// 2. Progress tracker doesn't overwrite Episode.listenedSeconds with stale value
    @MainActor
    func test_resolveConflictIfPlaying_explicitlyUpdatesCurrentPosition() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1", positionSeconds: 200)
        audioManager.testableSetPlaybackState(position: 200, duration: 3600)
        
        let conflict = makeConflict(episodeGuid: "ep-1", localPosition: 200, serverPosition: 1500)
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 1500)
        
        XCTAssertEqual(audioManager.currentPosition, 1500,
                       "resolveConflictIfPlaying must explicitly update currentPosition to 1500")
    }
    
    // MARK: - resolveQueueConflict for currentItem
    
    @MainActor
    func test_resolveQueueConflict_explicitlyUpdatesCurrentItemPosition() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-1", positionSeconds: 300)
        audioManager.testableSetPlaybackState(position: 300, duration: 3600)
        
        let conflict = makeConflict(episodeGuid: "ep-1", localPosition: 300, serverPosition: 1800)
        playerManager.resolveQueueConflict(conflict, chosenPosition: 1800)
        
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 1800,
                       "resolveQueueConflict must update currentItem.positionSeconds when episode is current")
    }
    
    // MARK: - End-to-end: cold start play after resolution
    
    /// Simulate the exact production bug path:
    /// 1. Episode restored, paused at local position
    /// 2. Sync fires, conflict resolved with server position
    /// 3. User taps play → cold start path
    /// 4. Episode MUST start at server position
    @MainActor
    func test_coldStartPlayAfterConflictResolution_usesServerPosition() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-cold", positionSeconds: 200)
        audioManager.testableSetPlaybackState(position: 200, duration: 3600)
        
        // Step 2: Resolve conflict with server position
        let conflict = makeConflict(episodeGuid: "ep-cold", localPosition: 200, serverPosition: 1500)
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 1500)
        
        // Step 3: Cold start play → playEpisode(item, initialPosition: currentPosition)
        let currentPosition = audioManager.currentPosition
        let currentItem = audioManager.currentItem!
        let targetPosition = audioManager.testablePlayEpisodePositionResume(
            currentItem, initialPosition: currentPosition
        )
        
        // Step 4: MUST be 1500
        XCTAssertEqual(Int(targetPosition), 1500,
                       "Cold-start play must use resolved position 1500, not stale 200")
    }
    
    // MARK: - App relaunch symptom: positionSeconds persisted correctly
    
    /// After conflict resolution, if the user quits and relaunches, the queue
    /// is restored from UserDefaults. The positionSeconds must be the RESOLVED
    /// value, not the stale local one.
    @MainActor
    func test_resolvedPositionSurvivesQueuePersistence() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-persist", positionSeconds: 200)
        audioManager.testableSetPlaybackState(position: 200, duration: 3600)
        
        let conflict = makeConflict(episodeGuid: "ep-persist", localPosition: 200, serverPosition: 1500)
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 1500)
        
        // When the queue is persisted (every 30s or on app background), it reads
        // currentItem.positionSeconds. This must be the resolved value.
        let persistedPosition = audioManager.currentItem?.positionSeconds
        XCTAssertEqual(persistedPosition, 1500,
                       "Persisted positionSeconds must be 1500 so relaunch uses resolved position")
    }
    
    // MARK: - Negative: different episode unaffected
    
    @MainActor
    func test_resolveConflictIfPlaying_noOpForDifferentEpisode() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        audioManager.currentItem = makeItem(id: "ep-other", positionSeconds: 500)
        audioManager.testableSetPlaybackState(position: 500, duration: 3600)
        
        let conflict = makeConflict(episodeGuid: "ep-different", localPosition: 100, serverPosition: 900)
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 900)
        
        XCTAssertEqual(audioManager.currentItem?.positionSeconds, 500)
        XCTAssertEqual(audioManager.currentPosition, 500)
    }
    
    @MainActor
    func test_resolveConflictIfPlaying_noOpWhenNothingPlaying() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        XCTAssertNil(audioManager.currentItem)
        
        let conflict = makeConflict(episodeGuid: "ep-none", localPosition: 100, serverPosition: 900)
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: 900)
        
        XCTAssertNil(audioManager.currentItem)
    }
}
