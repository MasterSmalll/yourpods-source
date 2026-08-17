import XCTest
import MediaPlayer
@testable import YourPods

// MARK: - Now Playing Artwork Race Tests (Regression)

/// Tests that the lock-screen / Dynamic Island now-playing artwork survives the
/// auto-advance race. Before the fix, updateNowPlayingInfo() spawned an async
/// artwork load that overwrote the ENTIRE MPNowPlayingInfoCenter dict with no
/// staleness guard — so a slow load from the *previous* episode could land last
/// and replace the new episode's metadata/artwork, and a completed load clobbered
/// the elapsed time that the periodic observer had written in the meantime.
@MainActor
final class NowPlayingInfoRaceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    override func tearDown() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        super.tearDown()
    }

    private func makeItem(id: String) -> QueueItem {
        QueueItem(
            id: id,
            title: "Ep \(id)",
            podcastTitle: "Podcast",
            audioUrl: "https://example.com/\(id).mp3",
            artworkUrl: "https://example.com/\(id).jpg",
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
    }

    private func solidImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    // MARK: - Stale load dropped on episode change

    func test_staleArtworkLoad_isDropped_whenItemChanged_REGRESSION() {
        // GIVEN: episode A's now-playing metadata is published
        let manager = AudioManager()
        let epA = makeItem(id: "A")
        manager.currentItem = epA
        manager.testableSetPlaybackState(position: 0, duration: 3600)
        manager.testableUpdateNowPlayingInfo(for: epA)
        let staleToken = manager.testableNowPlayingLoadToken

        // WHEN: the episode auto-advances to B (bumps token, B is now current)
        let epB = makeItem(id: "B")
        manager.currentItem = epB
        manager.testableUpdateNowPlayingInfo(for: epB)

        // ...and a SLOW artwork load for the *previous* episode A finally completes
        manager.testableApplyNowPlayingArtwork(solidImage(), forItemId: "A", token: staleToken)

        // THEN: the stale load is dropped — B's metadata stays, A's artwork is not adopted
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Ep B",
                       "Stale artwork load must not overwrite the new episode's metadata")
        XCTAssertNotEqual(manager.testableCurrentArtworkItemId, "A",
                          "Stale artwork load for the previous episode must be dropped")
    }

    // MARK: - Artwork apply preserves live timing

    func test_artworkApply_doesNotClobberElapsedTime_REGRESSION() {
        // GIVEN: now-playing is published for episode A
        let manager = AudioManager()
        let epA = makeItem(id: "A")
        manager.currentItem = epA
        manager.testableSetPlaybackState(position: 0, duration: 3600)
        manager.testableUpdateNowPlayingInfo(for: epA)
        let token = manager.testableNowPlayingLoadToken

        // ...and the periodic progress observer advances the elapsed time AFTER
        // the metadata update but BEFORE the async artwork load completes.
        var live = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        live[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 120.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = live

        // WHEN: the artwork load completes and applies
        manager.testableApplyNowPlayingArtwork(solidImage(), forItemId: "A", token: token)

        // THEN: the elapsed time is preserved (merge, not full overwrite) and artwork is set
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 120.0,
                       "Applying artwork must merge into the live dict, not reset elapsed time")
        XCTAssertNotNil(info?[MPMediaItemPropertyArtwork],
                        "Artwork should be applied for the current episode")
    }
}
