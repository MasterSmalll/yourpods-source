import XCTest
import MediaPlayer
@testable import YourPods

/// Tests for the CarPlay offline "black play screen" fix: tapping an
/// undownloaded episode with no network must still show title, saved play
/// position, feed duration, honest status text, and cached/placeholder
/// artwork on the system Now Playing surface (MPNowPlayingInfoCenter),
/// which is what CPNowPlayingTemplate renders.
@MainActor
final class CarPlayOfflineNowPlayingTests: XCTestCase {

    override func setUp() async throws {
        // Now Playing center is process-global — start each test clean so
        // artwork/timing assertions can't pass on a previous test's leftovers.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Test QueueItem pointing at an unreachable host (fails fast, no real audio).
    private func makeTestItem(
        id: String = "offline-ep",
        title: String = "Garage Episode",
        podcastTitle: String = "Garage Podcast",
        audioUrl: String = "https://unreachable.invalid/episode.mp3",
        artworkUrl: String? = nil,
        fallbackArtworkUrl: String? = nil,
        durationSeconds: Int? = 1800,
        positionSeconds: Int = 600,
        skipIntroSeconds: Int = 0
    ) -> QueueItem {
        var item = QueueItem(
            id: id, title: title, podcastTitle: podcastTitle,
            audioUrl: audioUrl,
            artworkUrl: artworkUrl,
            durationSeconds: durationSeconds, positionSeconds: positionSeconds,
            podcastUrl: "https://example.com/feed", pubDate: nil,
            podcastAuthor: "Garage Author",
            skipIntroSeconds: skipIntroSeconds
        )
        item.fallbackArtworkUrl = fallbackArtworkUrl
        return item
    }

    private func makeOfflineManager() -> AudioManager {
        let manager = AudioManager()
        manager.networkMonitor = MockNetworkMonitor(isConnected: false)
        return manager
    }

    // MARK: - Seeded position + duration

    /// Offline, the AVAsset never loads, so the player can never supply
    /// position/duration. playEpisode must seed them from the QueueItem.
    func test_playEpisode_offline_seedsResumePositionAndFeedDuration() async {
        let manager = makeOfflineManager()
        let item = makeTestItem(durationSeconds: 1800, positionSeconds: 600)

        await manager.playEpisode(item)

        XCTAssertEqual(manager.currentPosition, 600, accuracy: 0.1,
                       "Saved resume position must seed currentPosition offline")
        XCTAssertEqual(manager.currentDuration, 1800, accuracy: 0.1,
                       "Feed duration must seed currentDuration offline")
    }

    /// The seeded values must actually reach the system Now Playing center —
    /// that dict is the ONLY thing CarPlay's Now Playing screen renders.
    func test_playEpisode_offline_nowPlayingCenterShowsSeededTiming() async {
        let manager = makeOfflineManager()
        let item = makeTestItem(title: "Garage Episode",
                                durationSeconds: 1800, positionSeconds: 600)

        await manager.playEpisode(item)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Garage Episode")
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1,
                       600, accuracy: 0.1,
                       "Elapsed time on CarPlay must show the resume position")
        XCTAssertEqual(info?[MPMediaItemPropertyPlaybackDuration] as? Double ?? -1,
                       1800, accuracy: 0.1,
                       "Duration on CarPlay must come from feed metadata when the asset can't load")
    }

    func test_playEpisode_offline_initialPositionWinsOverStoredPosition() async {
        let manager = makeOfflineManager()
        let item = makeTestItem(positionSeconds: 600)

        await manager.playEpisode(item, initialPosition: 90)

        XCTAssertEqual(manager.currentPosition, 90, accuracy: 0.1,
                       "Explicit initialPosition must override the item's stored position")
    }

    /// EDGE: starting from zero with a skip-intro configured — the seeded
    /// position shown on CarPlay must already reflect the intro skip.
    func test_EDGE_playEpisode_skipIntroSeedsPosition_whenResumeIsBeforeIntroEnd() async {
        let manager = makeOfflineManager()
        let item = makeTestItem(positionSeconds: 0, skipIntroSeconds: 45)

        await manager.playEpisode(item)

        XCTAssertEqual(manager.currentPosition, 45, accuracy: 0.1,
                       "Seeded position must fold in skip-intro (no settingsResolver → QueueItem values)")
    }

    /// EDGE: feeds without a <itunes:duration> — seed 0, never the previous episode's duration.
    func test_EDGE_playEpisode_nilFeedDuration_seedsZeroDuration() async {
        let manager = makeOfflineManager()
        // Simulate a previous episode's leftovers
        manager.currentDuration = 4321
        let item = makeTestItem(durationSeconds: nil, positionSeconds: 30)

        await manager.playEpisode(item)

        XCTAssertEqual(manager.currentDuration, 0,
                       "Unknown feed duration must seed 0, not leak the previous episode's duration")
        XCTAssertEqual(manager.currentPosition, 30, accuracy: 0.1)
    }

    // MARK: - Stale-swap currentItem→nil must not trigger completion

    /// After a play()/skip swap, removeAllItems() emits a transient currentItem→nil
    /// that Combine delivers AFTER the swap and after isLoadingNewEpisode resets. By
    /// then the LIVE player.currentItem is the new item, so the completion decision —
    /// keyed on the live item, not the stale published nil — must reject it. This is
    /// what stops a spurious start-of-episode recovery / wrong auto-advance now that
    /// currentDuration is seeded nonzero before the swap.
    func test_isQueueExhaustion_rejectsStaleSwapNil_firesOnRealExhaustion() {
        let cases: [(liveNil: Bool, playing: Bool, loading: Bool, advancing: Bool, expected: Bool, note: String)] = [
            (true,  true,  false, false, true,  "real end-of-queue: live item nil, playing, idle → fire"),
            (false, true,  false, false, false, "stale swap nil: live item is the NEW item → reject (THE FIX)"),
            (true,  true,  true,  false, false, "still loading the swap → reject"),
            (true,  true,  false, true,  false, "mid auto-advance → reject"),
            (true,  false, false, false, false, "not playing → reject"),
        ]
        for c in cases {
            XCTAssertEqual(
                AudioManager.isQueueExhaustion(
                    liveCurrentItemIsNil: c.liveNil, isPlaying: c.playing,
                    isLoadingNewEpisode: c.loading, isAdvancingQueue: c.advancing),
                c.expected, c.note)
        }
    }

    // MARK: - Buffering flag must not mask offline/error status

    /// nowPlayingStatusSubtitle gives buffering priority over errorMessage.
    /// The offline recovery gate must therefore clear isBuffering, or CarPlay
    /// pins "Connecting…" forever while nothing is connecting.
    func test_offlineRecoveryGate_clearsBuffering_soOfflineMessageShows() {
        let manager = makeOfflineManager()
        manager.currentItem = makeTestItem()
        manager.isBuffering = true   // stuck state left by playEpisode

        manager.testableAttemptStreamRecovery()

        XCTAssertFalse(manager.isBuffering,
                       "Offline gate must clear isBuffering — nothing is connecting")
        XCTAssertTrue(manager.nowPlayingStatusSubtitle.contains("No connection"),
                      "CarPlay subtitle must show the offline message, got: \(manager.nowPlayingStatusSubtitle)")
    }

    /// Terminal failure (recovery exhausted) must also clear isBuffering and
    /// surface the failure text.
    func test_enterPlaybackFailedState_clearsBuffering_andSurfacesError() {
        let manager = AudioManager()
        manager.currentItem = makeTestItem()
        manager.isBuffering = true

        manager.enterPlaybackFailedState()

        XCTAssertFalse(manager.isBuffering)
        XCTAssertEqual(manager.errorMessage, "Playback failed. Check your connection.")
        XCTAssertTrue(manager.nowPlayingStatusSubtitle.contains("Playback failed"),
                      "got: \(manager.nowPlayingStatusSubtitle)")
    }

    // MARK: - I1: error/offline screen must publish a PAUSED rate (0) even if isPlaying is still true

    /// Clearing `isBuffering` (for an honest subtitle) leaves `isPlaying`
    /// true, and a paused-by-failure stall may never emit a rate=0 KVO — so the
    /// published Now Playing rate must ALSO gate on there being no error/offline
    /// message, or CarPlay shows a creeping "playing" progress bar + play glyph
    /// under "No connection". This pins `AudioManager.nowPlayingRate`, the single
    /// rule both `updateNowPlayingInfo` and `updateNowPlayingPlaybackState` use.
    /// (Tested directly rather than via MPNowPlayingInfoCenter: its NSNumber
    /// bridging makes the stored numeric type unreliable to read back in-process.)
    func test_nowPlayingRate_pausedWhenErrorOrBuffering_playsOnlyWhenHealthy() {
        typealias A = AudioManager
        // healthy, actively playing → real rate
        XCTAssertEqual(A.nowPlayingRate(isPlaying: true, isBuffering: false, errorMessage: nil, playbackRate: 1.5), 1.5)
        // offline error, isPlaying still true → paused (THE I1 FIX)
        XCTAssertEqual(A.nowPlayingRate(isPlaying: true, isBuffering: false, errorMessage: "No connection. Will retry when network returns.", playbackRate: 1.5), 0.0)
        // terminal failure, isPlaying still true → paused (THE I1 FIX)
        XCTAssertEqual(A.nowPlayingRate(isPlaying: true, isBuffering: false, errorMessage: "Playback failed. Check your connection.", playbackRate: 1.25), 0.0)
        // buffering a healthy stream → paused ("Connecting…")
        XCTAssertEqual(A.nowPlayingRate(isPlaying: true, isBuffering: true, errorMessage: nil, playbackRate: 1.5), 0.0)
        // genuinely paused → paused
        XCTAssertEqual(A.nowPlayingRate(isPlaying: false, isBuffering: false, errorMessage: nil, playbackRate: 1.5), 0.0)
    }

    // MARK: - Artwork fallback chain

    #if canImport(UIKit)
    private func solidImage(side: CGFloat) -> UIImage {
        // Pin scale to 1 so pixel size == point size. Otherwise the renderer uses
        // the screen scale (3× on iPhone 17), the disk JPEG is written at side×3
        // pixels, and UIImage(data:) reloads it at scale 1 → size side×3, which
        // would break the exact `art.bounds.size == side×side` assertion below.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
    #endif

    /// Table-driven: candidate ordering, dedupe, and nil handling.
    func test_artworkCandidates_orderingDedupeAndNils() {
        let cases: [(art: String?, fallback: String?, expected: [String], note: String)] = [
            ("https://a/ep.jpg", "https://a/logo.jpg",
             ["https://a/ep.jpg", "https://a/logo.jpg"], "episode art first, logo second"),
            ("https://a/same.jpg", "https://a/same.jpg",
             ["https://a/same.jpg"], "identical URLs dedupe"),
            (nil, "https://a/logo.jpg",
             ["https://a/logo.jpg"], "nil episode art falls through to logo"),
            ("https://a/ep.jpg", nil,
             ["https://a/ep.jpg"], "nil logo leaves episode art alone"),
            (nil, nil, [], "no URLs at all"),
        ]
        for c in cases {
            let item = makeTestItem(artworkUrl: c.art, fallbackArtworkUrl: c.fallback)
            XCTAssertEqual(AudioManager.artworkCandidates(for: item), c.expected, c.note)
        }
    }

    /// Scenario: offline in the garage — the per-episode art URL is unreachable,
    /// but the podcast logo sits in the disk cache from normal app browsing.
    /// The Now Playing screen must show the cached logo.
    func test_playEpisode_offline_appliesDiskCachedPodcastLogo_whenEpisodeArtUnreachable() async {
        let logoKey = "https://cached.example/logo-\(UUID().uuidString).jpg"
        ImageCacheStore.shared.saveToDisk(image: solidImage(side: 10), key: logoKey)
        defer {
            ImageCacheStore.shared.removeFromDisk(key: logoKey)
            ImageCacheStore.shared.cache.removeObject(forKey: logoKey as NSString)
        }

        let manager = makeOfflineManager()
        let item = makeTestItem(artworkUrl: "https://unreachable.invalid/ep.jpg",
                                fallbackArtworkUrl: logoKey)
        await manager.playEpisode(item)

        let logoApplied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let art = MPNowPlayingInfoCenter.default()
                .nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
            else { return false }
            return art.bounds.size == CGSize(width: 10, height: 10)
        }, object: nil)
        await fulfillment(of: [logoApplied], timeout: 10)
    }

    /// Nothing cached and no URLs: apply the branded placeholder so CarPlay
    /// never shows the system's grey music note.
    func test_playEpisode_offline_appliesPlaceholderArtwork_whenNothingCached() async {
        let manager = makeOfflineManager()
        let item = makeTestItem(artworkUrl: nil, fallbackArtworkUrl: nil)
        await manager.playEpisode(item)

        let placeholderApplied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MPNowPlayingInfoCenter.default()
                .nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil
        }, object: nil)
        await fulfillment(of: [placeholderApplied], timeout: 10)
    }

    /// EDGE: legacy persisted queues predate fallbackArtworkUrl — must decode as nil.
    func test_EDGE_queueItem_decodesLegacyPayload_missingFallbackArtworkKey() throws {
        let legacyJSON = """
        {"id":"e1","title":"T","podcastTitle":"P","audioUrl":"https://a/e.mp3",
         "positionSeconds":0,"podcastUrl":"https://a/feed"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(QueueItem.self, from: legacyJSON)
        XCTAssertNil(item.fallbackArtworkUrl)
    }

    // MARK: - Synchronous seed decision + bounded artwork fetch

    func test_synchronousArtworkSeed_picksFirstCachedCandidate_episodeArtWins() {
        let cache: [String: UIImage] = [
            "ep": solidImage(side: 20),
            "logo": solidImage(side: 10),
        ]
        let seed = AudioManager.synchronousArtworkSeed(candidates: ["ep", "logo"]) { cache[$0] }
        XCTAssertEqual(seed?.url, "ep")
        XCTAssertEqual(seed?.image.size, CGSize(width: 20, height: 20))
    }

    func test_synchronousArtworkSeed_fallsToLogo_whenEpisodeArtUncached() {
        let cache: [String: UIImage] = ["logo": solidImage(side: 10)]
        let seed = AudioManager.synchronousArtworkSeed(candidates: ["ep", "logo"]) { cache[$0] }
        XCTAssertEqual(seed?.url, "logo")
        XCTAssertEqual(seed?.image.size, CGSize(width: 10, height: 10))
    }

    func test_synchronousArtworkSeed_returnsNil_whenNothingCached() {
        let seed = AudioManager.synchronousArtworkSeed(candidates: ["ep", "logo"]) { _ in nil }
        XCTAssertNil(seed)
    }

    func test_synchronousArtworkSeed_returnsNil_whenNoCandidates() {
        let seed = AudioManager.synchronousArtworkSeed(candidates: []) { _ in self.solidImage(side: 5) }
        XCTAssertNil(seed)
    }

    func test_artworkRequest_isBoundedToEightSeconds() {
        let req = AudioManager.artworkRequest(for: URL(string: "https://x.example/a.jpg")!)
        XCTAssertEqual(req.timeoutInterval, 8, accuracy: 0.001)
        XCTAssertEqual(AudioManager.artworkFetchTimeout, 8, accuracy: 0.001)
    }

    func test_cachedImageSynchronously_returnsMemoryCachedImage() {
        let key = "https://cached.example/mem-\(UUID().uuidString).jpg"
        ImageCacheStore.shared.cache.setObject(solidImage(side: 7), forKey: key as NSString)
        defer { ImageCacheStore.shared.cache.removeObject(forKey: key as NSString) }
        XCTAssertEqual(AudioManager.cachedImageSynchronously(key)?.size, CGSize(width: 7, height: 7))
        XCTAssertNil(AudioManager.cachedImageSynchronously("https://cached.example/absent-\(UUID().uuidString).jpg"))
    }

    // MARK: - Artwork seeded synchronously (never blank)

    func test_playEpisode_seedsEpisodeArt_synchronously_whenCached() async {
        let epKey = "https://cached.example/ep-\(UUID().uuidString).jpg"
        ImageCacheStore.shared.saveToDisk(image: solidImage(side: 22), key: epKey)
        defer {
            ImageCacheStore.shared.removeFromDisk(key: epKey)
            ImageCacheStore.shared.cache.removeObject(forKey: epKey as NSString)
        }
        let manager = makeOfflineManager()
        let item = makeTestItem(artworkUrl: epKey, fallbackArtworkUrl: nil)
        await manager.playEpisode(item)

        // Read immediately — no expectation wait. The disk-cached episode art
        // must already be on the surface, proving the synchronous seed.
        let art = MPNowPlayingInfoCenter.default()
            .nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        XCTAssertEqual(art?.bounds.size, CGSize(width: 22, height: 22))
        // Episode's own art → real, not placeholder → no upgrade needed.
        XCTAssertEqual(manager.currentArtworkKind, .episode)
    }

    func test_playEpisode_seedsCachedLogo_synchronously_whenEpisodeArtUncached() async {
        let logoKey = "https://cached.example/logo-\(UUID().uuidString).jpg"
        ImageCacheStore.shared.saveToDisk(image: solidImage(side: 11), key: logoKey)
        defer {
            ImageCacheStore.shared.removeFromDisk(key: logoKey)
            ImageCacheStore.shared.cache.removeObject(forKey: logoKey as NSString)
        }
        let manager = makeOfflineManager()
        let item = makeTestItem(artworkUrl: "https://unreachable.invalid/ep.jpg",
                                fallbackArtworkUrl: logoKey)
        await manager.playEpisode(item)

        let art = MPNowPlayingInfoCenter.default()
            .nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        XCTAssertEqual(art?.bounds.size, CGSize(width: 11, height: 11),
                       "cached logo must be seeded synchronously, before the async fetch")
    }

    func test_playEpisode_seedsPlaceholder_synchronously_whenNothingCached() async {
        let manager = makeOfflineManager()
        let item = makeTestItem(artworkUrl: nil, fallbackArtworkUrl: nil)
        await manager.playEpisode(item)

        let art = MPNowPlayingInfoCenter.default()
            .nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        XCTAssertNotNil(art, "branded placeholder must be seeded synchronously")
        // No candidates to upgrade from → stays a placeholder.
        XCTAssertEqual(manager.currentArtworkKind, .placeholder)
    }

    // MARK: - Shared classification rule for seed + async load

    /// Table-driven: the shared classification helper used by both the
    /// synchronous seed and the async load loop. Chapter art is identified by
    /// the `chapterart:` cache-key namespace rather than a URL — that's the
    /// reason a boolean `isPlaceholder` was insufficient: under the old
    /// `loadedUrl != episodeArtworkUrl` rule, chapter art (never equal to the
    /// episode's own art) would have been classified as an upgradeable
    /// placeholder and clobbered by the next artwork update.
    func test_artworkKind_classifiesLoadedArtwork() {
        let cases: [(loadedUrl: String, episodeArtworkUrl: String?, expected: NowPlayingArtworkKind, note: String)] = [
            ("ep", "ep", .episode, "episode's own art → .episode (real, done)"),
            ("logo", "ep", .placeholder, "podcast logo differs from episode art → .placeholder, upgradeable"),
            ("logo", nil, .placeholder, "EDGE: no episode art at all → any loaded image stays a placeholder"),
            ("chapterart:abc123:2", "https://e.g/ep.jpg", .chapter,
             "chapter cache key → .chapter, even though it never equals episodeArtworkUrl"),
            ("chapterart:abc123:0", nil, .chapter,
             "EDGE: chapter cache key → .chapter even when there's no episode art to compare against"),
        ]
        for c in cases {
            XCTAssertEqual(AudioManager.artworkKind(loadedUrl: c.loadedUrl, episodeArtworkUrl: c.episodeArtworkUrl),
                           c.expected, c.note)
        }
    }

    /// Pins `testableApplyNowPlayingArtwork`'s `.episode` default. This default
    /// exists to reproduce the default that predated the artwork-kind
    /// classification (`isPlaceholder: Bool = false`, i.e. "real art") for
    /// callers that don't care which kind — flipping it to `.placeholder`
    /// would silently reintroduce the exact defaulted-parameter inversion
    /// that classification work found and fixed, and neither existing caller
    /// of this seam (`NowPlayingInfoRaceTests`) asserts on the resulting
    /// kind, so nothing else would catch the regression.
    func test_testableApplyNowPlayingArtwork_defaultsToEpisodeKind() {
        let manager = makeOfflineManager()
        let item = makeTestItem(id: "pin-default")
        manager.currentItem = item
        let token = manager.testableNowPlayingLoadToken

        manager.testableApplyNowPlayingArtwork(solidImage(side: 4), forItemId: item.id, token: token)

        XCTAssertEqual(manager.currentArtworkKind, .episode)
    }

    /// The async load loop must apply the SAME classification rule as the
    /// synchronous seed: when only the podcast logo is available (no episode
    /// art), loading it through the async `Task` must NOT mark it as the
    /// episode's real art — otherwise `currentArtworkKind` flips to
    /// .episode and the early-return guard in `updateNowPlayingInfo` blocks ever
    /// fetching the real episode art on a later call.
    func test_playEpisode_logoFallback_staysUpgradeable_afterAsyncLoad() async {
        let logoKey = "https://cached.example/logo-\(UUID().uuidString).jpg"
        ImageCacheStore.shared.saveToDisk(image: solidImage(side: 12), key: logoKey)
        ImageCacheStore.shared.cache.removeObject(forKey: logoKey as NSString)  // memory cold at start
        defer {
            ImageCacheStore.shared.removeFromDisk(key: logoKey)
            ImageCacheStore.shared.cache.removeObject(forKey: logoKey as NSString)
        }
        let manager = makeOfflineManager()
        // Only the podcast logo is a candidate (no episode art) — the async loop
        // will load the logo and must NOT mark it as the episode's real art.
        let item = makeTestItem(artworkUrl: nil, fallbackArtworkUrl: logoKey)
        await manager.playEpisode(item)

        // cachedImageSynchronously (used by the seed) never populates the in-memory
        // cache on a disk hit — only the async loadImage(from:) does, on a successful
        // load. So the in-memory cache for logoKey starts cold and is populated ONLY
        // once the async branch has run; waiting on it gates on that branch executing,
        // not on the synchronous seed.
        let asyncLoadRan = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ImageCacheStore.shared.cache.object(forKey: logoKey as NSString) != nil
        }, object: nil)
        await fulfillment(of: [asyncLoadRan], timeout: 10)
        // Now verify the async branch left the fallback marked as a placeholder — i.e.
        // it did NOT mistake the podcast logo for the episode's own real art.
        XCTAssertEqual(manager.currentArtworkKind, .placeholder,
                      "a podcast-logo fallback (not the episode's own art) must stay .placeholder so a later update can upgrade to the episode art")
    }

    // MARK: - Chapter artwork

    /// Basic positive case: a resolvable chapter-art key is applied with
    /// `.chapter` kind, and the chapter index it belongs to is recorded.
    func test_applyChapterArtwork_setsChapterKindAndIndex() throws {
        let manager = makeOfflineManager()
        let item = makeTestItem(id: "ch-basic", audioUrl: "https://e.g/ch-basic-\(UUID().uuidString).mp3")
        manager.currentItem = item
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 0))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }

        manager.applyChapterArtwork(key: key, chapterIndex: 0, forItemId: item.id)

        XCTAssertEqual(manager.currentArtworkKind, .chapter)
        XCTAssertEqual(manager.currentArtworkChapterIndex, 0)
    }

    /// `ChapterArtworkStore.image(forKey:)` returns nil once a key has been
    /// evicted from both cache layers. The key is re-derivable (a cheap
    /// re-extract), so an unresolvable key must fall back quietly rather
    /// than blank whatever artwork is already showing. Applies real chapter
    /// art FIRST so there's something to blank — a bare call with nothing
    /// showing can't prove "didn't blank" (both assertions would hold
    /// trivially even if the unresolvable-key branch DID blank the dict).
    func test_applyChapterArtwork_ignoresUnresolvableKey() throws {
        let manager = makeOfflineManager()
        let item = makeTestItem(id: "ch-evicted", audioUrl: "https://e.g/ch-evicted-\(UUID().uuidString).mp3")
        manager.currentItem = item
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 0))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }
        manager.applyChapterArtwork(key: key, chapterIndex: 0, forItemId: item.id)
        XCTAssertEqual(manager.currentArtworkKind, .chapter, "precondition: chapter art must be showing")
        let artworkBefore = try XCTUnwrap(MPNowPlayingInfoCenter.default()
            .nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)

        manager.applyChapterArtwork(key: "chapterart:evicted-\(UUID().uuidString):1", chapterIndex: 1,
                                    forItemId: item.id)

        XCTAssertEqual(manager.currentArtworkKind, .chapter,
                       "an evicted key must fall back, not blank the artwork")
        XCTAssertEqual(manager.currentArtworkChapterIndex, 0,
                      "an unresolvable key must not advance the displayed chapter index")
        let artworkAfter = try XCTUnwrap(MPNowPlayingInfoCenter.default()
            .nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertEqual(artworkAfter.bounds.size, artworkBefore.bounds.size,
                      "the previously-applied chapter artwork must still be in the live dict")
    }

    /// The real revert round trip. `updateNowPlayingInfo`'s artwork-upgrade
    /// guard (`currentArtworkKind != .placeholder` + artwork already present
    /// -> early return, AudioManager.swift ~line 1401) exists so a real
    /// episode art doesn't get needlessly re-fetched — but chapter art
    /// leaves `currentArtworkKind == .chapter`, which ALSO satisfies that
    /// guard. A naive revert that calls `updateNowPlayingInfo(for:)` without
    /// first clearing `currentArtworkKind` hits that early return and the
    /// chapter image stays stuck on screen forever after the chapter ends.
    /// Seeds a real episode artwork URL in `ImageCacheStore` and asserts the
    /// exact `.episode` kind (not merely `!= .chapter`) so deleting the
    /// actual `updateNowPlayingInfo(for:)` call — not just the kind reset
    /// before it — turns this red.
    func test_chapterArtworkRevert_actuallyReappliesEpisodeArt() throws {
        let epKey = "https://cached.example/ch-revert-ep-\(UUID().uuidString).jpg"
        ImageCacheStore.shared.saveToDisk(image: solidImage(side: 20), key: epKey)
        defer {
            ImageCacheStore.shared.removeFromDisk(key: epKey)
            ImageCacheStore.shared.cache.removeObject(forKey: epKey as NSString)
        }
        let manager = makeOfflineManager()
        let item = makeTestItem(id: "ch-revert", audioUrl: "https://e.g/ch-revert-\(UUID().uuidString).mp3",
                                artworkUrl: epKey)
        manager.currentItem = item
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 0))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }
        manager.applyChapterArtwork(key: key, chapterIndex: 0, forItemId: item.id)
        XCTAssertEqual(manager.currentArtworkKind, .chapter, "precondition: chapter art must be showing")

        manager.applyChapterArtwork(key: nil, chapterIndex: nil, forItemId: item.id)

        XCTAssertEqual(manager.currentArtworkKind, .episode,
                       "clearing chapter art must actually re-run the episode-art pipeline and pick up the cached episode art, not get silently suppressed by the artwork-upgrade guard")
        XCTAssertNil(manager.currentArtworkChapterIndex)
    }

    /// EDGE / backward seek. `chapterIndex` alone cannot distinguish "the
    /// user legitimately scrubbed backward" from "a stale, late-arriving
    /// call for an earlier chapter" — both present as a lower index than
    /// what's currently displayed. Rejecting on magnitude
    /// (`displayed > chapterIndex`) makes a backward seek get stuck showing
    /// the highest chapter's art ever reached for the rest of the episode,
    /// which is a worse, persistent, user-visible bug — so a lower index
    /// must be honored exactly like a higher one. That reasoning is why this
    /// test replaces an earlier index-ratchet test.
    func test_EDGE_applyChapterArtwork_backwardSeek_appliesLowerChapterIndex() throws {
        let manager = makeOfflineManager()
        let item = makeTestItem(id: "ch-seek", audioUrl: "https://e.g/ch-seek-\(UUID().uuidString).mp3")
        manager.currentItem = item
        let key4 = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                            audioUrl: item.audioUrl, index: 4))
        let key2 = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                            audioUrl: item.audioUrl, index: 2))
        defer {
            ImageCacheStore.shared.removeFromDisk(key: key4)
            ImageCacheStore.shared.removeFromDisk(key: key2)
        }
        manager.applyChapterArtwork(key: key4, chapterIndex: 4, forItemId: item.id)
        XCTAssertEqual(manager.currentArtworkChapterIndex, 4)

        manager.applyChapterArtwork(key: key2, chapterIndex: 2, forItemId: item.id)   // user scrubs back

        XCTAssertEqual(manager.currentArtworkChapterIndex, 2,
                       "scrubbing back to an earlier chapter must show that chapter's art, not stay pinned to the highest index ever reached")
        XCTAssertEqual(manager.currentArtworkKind, .chapter)
    }

    /// The genuine same-episode staleness race this mechanism protects
    /// against: an episode-art network fetch that was already in flight
    /// (captured the OLD now-playing token) must not land after chapter art
    /// has since applied and clobber it with lower-priority episode art.
    /// This reuses "the token mechanism the episode-scoped guard already
    /// uses" (`nowPlayingLoadToken` + `currentItem?.id`) rather than
    /// comparing chapter indices.
    func test_chapterArtworkApply_invalidatesStaleInFlightEpisodeLoad() throws {
        let manager = makeOfflineManager()
        let item = makeTestItem(id: "ch-race", audioUrl: "https://e.g/ch-race-\(UUID().uuidString).mp3")
        manager.currentItem = item
        let staleToken = manager.testableNowPlayingLoadToken   // "captured" before the chapter apply
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 2))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }

        manager.applyChapterArtwork(key: key, chapterIndex: 2, forItemId: item.id)
        XCTAssertEqual(manager.currentArtworkKind, .chapter)

        // Simulate the stale episode-art fetch (started before the chapter
        // art applied) finally resolving.
        manager.testableApplyNowPlayingArtwork(solidImage(side: 4), forItemId: item.id,
                                               token: staleToken, kind: .episode)

        XCTAssertEqual(manager.currentArtworkKind, .chapter,
                       "a stale episode-art load started before the chapter art applied must not clobber it")
    }

    /// The cross-episode variant of the staleness race: a delayed call
    /// carrying a PREVIOUS episode's chapter-art key must not apply once
    /// the user has switched to a new episode. Without validating
    /// `forItemId` against `currentItem`, this call would resolve the old
    /// episode's image, bump `nowPlayingLoadToken` (killing the new
    /// episode's own in-flight artwork fetch), and paint the wrong
    /// episode's chapter art onto the new episode's Now Playing entry.
    func test_applyChapterArtwork_rejectsStaleCallForPreviousEpisode() async throws {
        let manager = makeOfflineManager()
        let itemA = makeTestItem(id: "ch-cross-a", audioUrl: "https://e.g/ch-cross-a-\(UUID().uuidString).mp3")
        manager.currentItem = itemA
        let keyA = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                            audioUrl: itemA.audioUrl, index: 0))
        defer { ImageCacheStore.shared.removeFromDisk(key: keyA) }

        let itemB = makeTestItem(id: "ch-cross-b", audioUrl: "https://e.g/ch-cross-b-\(UUID().uuidString).mp3")
        await manager.playEpisode(itemB)
        XCTAssertNotEqual(manager.currentArtworkKind, .chapter, "precondition: B has no chapter art of its own")
        let tokenBeforeStaleCall = manager.testableNowPlayingLoadToken

        // A's chapter-art resolution finally lands, carrying A's stale id.
        manager.applyChapterArtwork(key: keyA, chapterIndex: 0, forItemId: itemA.id)

        XCTAssertNotEqual(manager.currentArtworkKind, .chapter,
                          "episode A's chapter art must not apply once B is playing")
        XCTAssertNil(manager.currentArtworkChapterIndex,
                    "B has no chapter index of its own yet — A's stale call must not set one")
        XCTAssertEqual(manager.testableNowPlayingLoadToken, tokenBeforeStaleCall,
                      "a rejected stale call must not bump the shared token and kill B's own in-flight artwork load")
    }

    /// Chapter index is episode-scoped state — a new episode must not
    /// inherit the previous episode's displayed chapter index. Exercised
    /// through the real production reset path (`playEpisode`), not a raw
    /// property assignment, since `currentItem` itself has no reset side effect.
    func test_chapterArtwork_clearedWhenEpisodeChanges() async throws {
        let manager = makeOfflineManager()
        let item1 = makeTestItem(id: "ch-ep1", audioUrl: "https://e.g/ch-ep1-\(UUID().uuidString).mp3")
        manager.currentItem = item1
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item1.audioUrl, index: 0))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }
        manager.applyChapterArtwork(key: key, chapterIndex: 0, forItemId: item1.id)
        XCTAssertEqual(manager.currentArtworkChapterIndex, 0)

        let item2 = makeTestItem(id: "ch-ep2", audioUrl: "https://e.g/ch-ep2-\(UUID().uuidString).mp3")
        await manager.playEpisode(item2)

        XCTAssertNil(manager.currentArtworkChapterIndex,
                    "a new episode must not inherit the previous episode's displayed chapter index")
    }

    /// Full stop must also clear the chapter index — otherwise a later
    /// `playEpisode` racing ahead of `applyChapterArtwork`'s own clears
    /// could briefly read a stale index left over from the stopped episode.
    func test_chapterArtwork_clearedOnStop() throws {
        let manager = makeOfflineManager()
        let item = makeTestItem(id: "ch-stop", audioUrl: "https://e.g/ch-stop-\(UUID().uuidString).mp3")
        manager.currentItem = item
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 1))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }
        manager.applyChapterArtwork(key: key, chapterIndex: 1, forItemId: item.id)
        XCTAssertEqual(manager.currentArtworkChapterIndex, 1)

        manager.stop()

        XCTAssertNil(manager.currentArtworkChapterIndex)
    }

    /// A stale chapter index must not survive a call with no current item
    /// (e.g. a delayed chapter-art resolution landing after `stop()`), even
    /// though there's nothing to display artwork for.
    func test_applyChapterArtwork_noCurrentItem_clearsStaleChapterIndex() throws {
        let manager = makeOfflineManager()
        let item = makeTestItem(id: "ch-gone", audioUrl: "https://e.g/ch-gone-\(UUID().uuidString).mp3")
        manager.currentItem = item
        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 8),
                                                           audioUrl: item.audioUrl, index: 1))
        defer { ImageCacheStore.shared.removeFromDisk(key: key) }
        manager.applyChapterArtwork(key: key, chapterIndex: 1, forItemId: item.id)
        XCTAssertEqual(manager.currentArtworkChapterIndex, 1)
        manager.currentItem = nil   // e.g. mid-transition, no current item

        manager.applyChapterArtwork(key: key, chapterIndex: 1, forItemId: item.id)

        XCTAssertNil(manager.currentArtworkChapterIndex,
                    "a stale chapter index must not survive a call with no current item")
    }
}
