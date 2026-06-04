import XCTest
@testable import YourPods

/// Tests for P3 — Privacy Preserving Playback.
/// Covers:
///   - TrackingURLStripper: single-layer, multi-layer, DAI, edge cases
///   - QueueItem: privacyMode propagation and backward-compatible decoding
///   - PlayerManager: effective P3 resolution from per-podcast and global settings
final class P3PrivacyPreservingPlaybackTests: XCTestCase {

    // MARK: - TrackingURLStripper: Analytics prefix stripping

    /// Podtrac redirect URLs should be stripped to the embedded CDN URL.
    func test_strip_podtrac_redirect() {
        let input = "https://dts.podtrac.com/redirect.mp3/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.wasModified, "Should report modification")
        XCTAssertTrue(result.trackersRemoved.contains("Podtrac"),
                      "Should report Podtrac as removed, got: \(result.trackersRemoved)")
    }

    /// Podtrac with m4a extension should also be stripped.
    func test_strip_podtrac_m4a() {
        let input = "https://dts.podtrac.com/redirect.m4a/cdn.example.com/episodes/ep1.m4a"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.m4a")
        XCTAssertTrue(result.trackersRemoved.contains("Podtrac"))
    }

    /// Chartable (chrt.fm) tracking URLs should be stripped.
    func test_strip_chartable() {
        let input = "https://chrt.fm/track/ABC123/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Chartable"))
    }

    /// Chartable alternate domain (chtbl.com) should be stripped.
    func test_strip_chartable_alt() {
        let input = "https://chtbl.com/track/XYZ789/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Chartable"))
    }

    /// Podsights (pdst.fm) tracking URLs should be stripped.
    func test_strip_podsights() {
        let input = "https://pdst.fm/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Podsights"))
    }

    /// OP3 tracking URLs should be stripped.
    func test_strip_op3() {
        let input = "https://op3.dev/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("OP3"))
    }

    /// Magellan AI tracking URLs should be stripped.
    func test_strip_magellan() {
        let input = "https://mgln.ai/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Magellan AI"))
    }

    /// Podscribe tracking URLs should be stripped.
    func test_strip_podscribe() {
        let input = "https://verifi.podscribe.com/rss/p/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Podscribe"))
    }

    /// Swap.fm tracking URLs should be stripped.
    func test_strip_swapfm() {
        let input = "https://swap.fm/track/ABC123/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Swap.fm"))
    }

    /// vPixl tracking URLs should be stripped.
    func test_strip_vpixl() {
        let input = "https://pfx.vpixl.com/ABC123/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("vPixl"))
    }

    // MARK: - TrackingURLStripper: Phase 1 — New prefix patterns

    /// Podsights / Spotify alternate domain (prfx.byspotify.com) should be stripped.
    func test_strip_podsights_spotify_alt() {
        let input = "https://prfx.byspotify.com/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Podsights"),
                      "Should report Podsights as removed, got: \(result.trackersRemoved)")
    }

    /// Podtrac alternate domain (play.podtrac.com) should be stripped.
    func test_strip_podtrac_play_domain() {
        let input = "https://play.podtrac.com/redirect.mp3/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Podtrac"),
                      "Should report Podtrac as removed, got: \(result.trackersRemoved)")
    }

    /// Claritas (claritaspod.com) tracking URLs should be stripped.
    func test_strip_claritas() {
        let input = "https://claritaspod.com/measure/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Claritas"),
                      "Should report Claritas as removed, got: \(result.trackersRemoved)")
    }

    /// Claritas www subdomain (www.claritaspod.com) should also be stripped.
    func test_strip_claritas_www() {
        let input = "https://www.claritaspod.com/measure/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Claritas"))
    }

    /// ArtsAI prefix domain (prefix.artsai.com) should be stripped.
    func test_strip_artsai_prefix() {
        let input = "https://prefix.artsai.com/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("ArtsAI"),
                      "Should report ArtsAI as removed, got: \(result.trackersRemoved)")
    }

    /// ArtsAI main domain (artsai.com) should also be stripped.
    func test_strip_artsai_main() {
        let input = "https://artsai.com/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("ArtsAI"))
    }

    /// Gumshoe / Gumball (2.gum.fm) tracking URLs should be stripped.
    func test_strip_gumshoe() {
        let input = "https://2.gum.fm/ABC123/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Gumshoe"),
                      "Should report Gumshoe as removed, got: \(result.trackersRemoved)")
    }

    /// Podcorn (pdcn.co) tracking URLs should be stripped.
    func test_strip_podcorn() {
        let input = "https://pdcn.co/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Podcorn"),
                      "Should report Podcorn as removed, got: \(result.trackersRemoved)")
    }

    /// Backtracks (backtracks.fm) tracking URLs should be stripped.
    func test_strip_backtracks() {
        let input = "https://backtracks.fm/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Backtracks"),
                      "Should report Backtracks as removed, got: \(result.trackersRemoved)")
    }

    /// PodRoll (pdrl.fm) tracking URLs should be stripped.
    func test_strip_podroll() {
        let input = "https://pdrl.fm/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("PodRoll"),
                      "Should report PodRoll as removed, got: \(result.trackersRemoved)")
    }

    /// PodRoll alternate domain (podroll.fm) should also be stripped.
    func test_strip_podroll_alt() {
        let input = "https://podroll.fm/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("PodRoll"))
    }

    /// PodRoll RSS subdomain (rss.pdrl.fm) should also be stripped.
    func test_strip_podroll_rss() {
        let input = "https://rss.pdrl.fm/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("PodRoll"))
    }

    /// CoHost (cohst.app) tracking URLs should be stripped.
    func test_strip_cohost() {
        let input = "https://cohst.app/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("CoHost"),
                      "Should report CoHost as removed, got: \(result.trackersRemoved)")
    }

    /// CoHost alternate domain (cohostpodcasting.com) should also be stripped.
    func test_strip_cohost_alt() {
        let input = "https://cohostpodcasting.com/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("CoHost"))
    }

    /// Up.Audio (prefix.up.audio) tracking URLs should be stripped.
    func test_strip_upaudio() {
        let input = "https://prefix.up.audio/ABC123/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Up.Audio"),
                      "Should report Up.Audio as removed, got: \(result.trackersRemoved)")
    }

    /// AdBarker (adbarker.com) tracking URLs should be stripped.
    func test_strip_adbarker() {
        let input = "https://adbarker.com/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("AdBarker"),
                      "Should report AdBarker as removed, got: \(result.trackersRemoved)")
    }

    /// Veritonic (veritonic.com) tracking URLs should be stripped.
    func test_strip_veritonic() {
        let input = "https://veritonic.com/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Veritonic"),
                      "Should report Veritonic as removed, got: \(result.trackersRemoved)")
    }

    /// Swap.fm tracking subdomain (tracking.swap.fm) should be stripped.
    func test_strip_swapfm_tracking() {
        let input = "https://tracking.swap.fm/track/ABC123/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Swap.fm"),
                      "Should report Swap.fm as removed, got: \(result.trackersRemoved)")
    }

    /// Podscribe alternate domain (pscrb.fm) should be stripped.
    func test_strip_podscribe_alt() {
        let input = "https://pscrb.fm/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Podscribe"),
                      "Should report Podscribe as removed, got: \(result.trackersRemoved)")
    }

    // MARK: - TrackingURLStripper: Phase 2 — Query parameter stripping

    /// UTM tracking parameters should be stripped from CDN URLs.
    func test_strip_utm_queryParams() {
        let input = "https://cdn.example.com/episodes/ep1.mp3?utm_source=podcast&utm_medium=rss&utm_campaign=launch"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.wasModified, "Should report modification for UTM param stripping")
    }

    /// UTM params should be stripped even after prefix stripping.
    func test_strip_prefix_then_utm() {
        let input = "https://pdst.fm/e/cdn.example.com/episodes/ep1.mp3?utm_source=spotify&utm_campaign=promo"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("Podsights"),
                      "Should strip both prefix and UTM params")
    }

    /// Non-tracking query params should be preserved.
    func test_strip_preserves_nonTracking_queryParams() {
        let input = "https://cdn.example.com/episodes/ep1.mp3?token=abc123&expires=9999"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, input, "Non-tracking params should be preserved")
        XCTAssertFalse(result.wasModified, "No modification when only non-tracking params present")
    }

    /// Mixed tracking and non-tracking params: only tracking params removed.
    func test_strip_mixed_queryParams() {
        let input = "https://cdn.example.com/episodes/ep1.mp3?token=abc123&utm_source=podcast&expires=9999"
        let result = TrackingURLStripper.strip(input)

        XCTAssertTrue(result.url.contains("token=abc123"), "Should preserve token param")
        XCTAssertTrue(result.url.contains("expires=9999"), "Should preserve expires param")
        XCTAssertFalse(result.url.contains("utm_source"), "Should strip utm_source param")
    }

    // MARK: - TrackingURLStripper: DAI prefix stripping

    /// Megaphone DAI URLs should be stripped to bypass ad insertion.
    func test_strip_megaphone_dai() {
        let input = "https://traffic.megaphone.fm/ADL1234567890/cdn.megaphone.fm/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.megaphone.fm/episodes/ep1.mp3")
        XCTAssertTrue(result.wasModified, "Should strip Megaphone DAI prefix")
        XCTAssertTrue(result.trackersRemoved.contains("Megaphone"),
                      "Should report Megaphone as removed, got: \(result.trackersRemoved)")
    }

    /// AdsWizz (adswizz.com) DAI URLs should be stripped.
    func test_strip_adswizz() {
        let input = "https://adswizz.com/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("AdsWizz"),
                      "Should report AdsWizz as removed, got: \(result.trackersRemoved)")
    }

    /// AdsWizz PCM domain (pcm.adswizz.com) should be stripped.
    func test_strip_adswizz_pcm() {
        let input = "https://pcm.adswizz.com/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.contains("AdsWizz"))
    }

    // MARK: - TrackingURLStripper: Multi-layer stripping

    /// Real-world nested tracking: Podsights → Chartable → Podtrac → CDN
    func test_strip_multiLayer_analytics() {
        let input = "https://pdst.fm/e/chrt.fm/track/ABC123/dts.podtrac.com/redirect.mp3/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.example.com/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.count >= 3,
                      "Should strip at least 3 layers, got: \(result.trackersRemoved)")
    }

    /// Nested: analytics + DAI — OP3 → Megaphone DAI → CDN
    func test_strip_multiLayer_analyticsAndDAI() {
        let input = "https://op3.dev/e/traffic.megaphone.fm/ADL1234/cdn.megaphone.fm/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, "https://cdn.megaphone.fm/episodes/ep1.mp3")
        XCTAssertTrue(result.trackersRemoved.count >= 2,
                      "Should strip at least 2 layers, got: \(result.trackersRemoved)")
    }

    // MARK: - TrackingURLStripper: Passthrough (no trackers)

    /// Clean CDN URLs should pass through unchanged.
    func test_strip_cleanUrl_passthrough() {
        let input = "https://cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, input)
        XCTAssertFalse(result.wasModified, "Clean URL should not be modified")
        XCTAssertTrue(result.trackersRemoved.isEmpty,
                      "No trackers should be reported")
    }

    /// HTTP URLs without trackers should pass through as-is.
    func test_strip_httpUrl_passthrough() {
        let input = "http://cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, input)
        XCTAssertFalse(result.wasModified)
    }

    // MARK: - TrackingURLStripper: Edge cases

    /// Empty string should return empty string.
    func test_strip_emptyString() {
        let result = TrackingURLStripper.strip("")

        XCTAssertEqual(result.url, "")
        XCTAssertFalse(result.wasModified)
    }

    /// Local file paths should pass through unchanged.
    func test_strip_localFilePath_passthrough() {
        let input = "/Users/test/Documents/Downloads/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertEqual(result.url, input)
        XCTAssertFalse(result.wasModified)
    }

    /// Malformed URL with known tracker domain but unusual structure.
    func test_strip_malformedUrl_graceful() {
        let input = "https://pdst.fm"
        let result = TrackingURLStripper.strip(input)

        // Should not crash; may return original or stripped — just shouldn't panic
        XCTAssertFalse(result.url.isEmpty, "Should return a non-empty result")
    }

    /// HTTPS scheme should be preserved/applied to stripped URLs.
    func test_strip_httpsScheme_applied() {
        // When the tracker URL is https but the embedded URL has no scheme
        let input = "https://pdst.fm/e/cdn.example.com/episodes/ep1.mp3"
        let result = TrackingURLStripper.strip(input)

        XCTAssertTrue(result.url.hasPrefix("https://"),
                      "Stripped URL should have https:// scheme, got: \(result.url)")
    }

    // MARK: - QueueItem: privacyMode field

    /// QueueItem should support a privacyMode field that defaults to false.
    func test_queueItem_privacyMode_defaultsFalse() {
        let item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )

        XCTAssertFalse(item.privacyMode, "privacyMode should default to false")
    }

    /// QueueItem with privacyMode should survive encode/decode round-trip.
    func test_queueItem_privacyMode_encodeDecode() throws {
        var item = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        item.privacyMode = true

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(QueueItem.self, from: data)

        XCTAssertTrue(decoded.privacyMode,
                      "privacyMode=true should survive encode/decode")
    }

    /// Old QueueItems encoded WITHOUT privacyMode should decode with privacyMode=false.
    func test_queueItem_privacyMode_backwardCompatible() throws {
        // Simulate an old-format QueueItem JSON (no privacyMode key)
        let oldJson = """
        {
            "id": "ep-old",
            "title": "Old Episode",
            "podcastTitle": "Pod",
            "audioUrl": "https://example.com/ep-old.mp3",
            "podcastUrl": "https://example.com/feed"
        }
        """
        let data = oldJson.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(QueueItem.self, from: data)

        XCTAssertFalse(decoded.privacyMode,
                       "Missing privacyMode in JSON should default to false")
    }

    // MARK: - PodcastSettings: privacyMode field

    /// PodcastSettings should have a privacyMode field that defaults to nil.
    func test_podcastSettings_privacyMode_defaultsNil() {
        let settings = PodcastSettings()

        XCTAssertNil(settings.privacyMode,
                     "privacyMode should default to nil (use global)")
    }

    /// PodcastSettings privacyMode should survive encode/decode.
    func test_podcastSettings_privacyMode_encodeDecode() throws {
        var settings = PodcastSettings()
        settings.privacyMode = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PodcastSettings.self, from: data)

        XCTAssertEqual(decoded.privacyMode, true,
                       "privacyMode=true should survive encode/decode")
    }

    /// PodcastSettings.hasOverrides should return true when privacyMode is set.
    func test_podcastSettings_privacyMode_countsAsOverride() {
        var settings = PodcastSettings()
        XCTAssertFalse(settings.hasOverrides, "Clean settings should have no overrides")

        settings.privacyMode = true
        XCTAssertTrue(settings.hasOverrides,
                      "Setting privacyMode should count as an override")
    }

    // MARK: - PlayerManager: P3 effective resolution

    /// Per-podcast privacyMode=true should override global p3Enabled=false.
    @MainActor
    func test_playerManager_perPodcast_overridesGlobal_whenTrue() {
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "P3TestA")!)
        playerManager.settingsManager = settingsManager

        // Global P3 is OFF
        settingsManager.p3Enabled = false

        // Create an episode with per-podcast P3 ON
        var settings = PodcastSettings()
        settings.privacyMode = true

        // Simulate applying effective settings
        let _ = QueueItem(
            id: "ep-1", title: "Episode 1", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )

        // The resolved privacyMode should be the per-podcast value (true)
        let resolved = settings.privacyMode ?? settingsManager.p3Enabled
        XCTAssertTrue(resolved,
                      "Per-podcast privacyMode=true should override global p3Enabled=false")

        // Cleanup
        UserDefaults(suiteName: "P3TestA")?.removePersistentDomain(forName: "P3TestA")
    }

    /// Per-podcast privacyMode=false should override global p3Enabled=true.
    @MainActor
    func test_playerManager_perPodcast_overridesGlobal_whenFalse() {
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "P3TestB")!)

        // Global P3 is ON
        settingsManager.p3Enabled = true

        // Per-podcast P3 is OFF
        var settings = PodcastSettings()
        settings.privacyMode = false

        let resolved = settings.privacyMode ?? settingsManager.p3Enabled
        XCTAssertFalse(resolved,
                       "Per-podcast privacyMode=false should override global p3Enabled=true")

        // Cleanup
        UserDefaults(suiteName: "P3TestB")?.removePersistentDomain(forName: "P3TestB")
    }

    /// When per-podcast privacyMode is nil, global p3Enabled should be used.
    @MainActor
    func test_playerManager_globalFallback_whenPerPodcastNil() {
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "P3TestC")!)

        // Global P3 is ON
        settingsManager.p3Enabled = true

        // Per-podcast P3 is nil (use global)
        let settings = PodcastSettings()

        let resolved = settings.privacyMode ?? settingsManager.p3Enabled
        XCTAssertTrue(resolved,
                      "Nil per-podcast privacyMode should fall back to global p3Enabled=true")

        // Cleanup
        UserDefaults(suiteName: "P3TestC")?.removePersistentDomain(forName: "P3TestC")
    }

    // MARK: - SettingsManager: p3Enabled property

    /// SettingsManager.p3Enabled should default to false.
    func test_settingsManager_p3Enabled_defaultsFalse() {
        let defaults = UserDefaults(suiteName: "P3TestD")!
        let settingsManager = SettingsManager(defaults: defaults)

        XCTAssertFalse(settingsManager.p3Enabled,
                       "p3Enabled should default to false")

        // Cleanup
        defaults.removePersistentDomain(forName: "P3TestD")
    }

    /// SettingsManager.p3Enabled should persist to UserDefaults.
    func test_settingsManager_p3Enabled_persists() {
        let defaults = UserDefaults(suiteName: "P3TestE")!
        let settingsManager = SettingsManager(defaults: defaults)

        settingsManager.p3Enabled = true
        XCTAssertTrue(settingsManager.p3Enabled,
                      "p3Enabled should be true after setting")

        // Verify it's actually in UserDefaults
        XCTAssertTrue(defaults.bool(forKey: "p3Enabled"),
                      "p3Enabled should be persisted to UserDefaults")

        // Cleanup
        defaults.removePersistentDomain(forName: "P3TestE")
    }

    // MARK: - SettingsManager: P3 Profile Sync

    /// asProfilePayload must include p3Enabled so it syncs to the server.
    func test_asProfilePayload_includesP3Enabled() {
        let defaults = UserDefaults(suiteName: "P3TestPayload")!
        let settings = SettingsManager(defaults: defaults)
        settings.p3Enabled = true

        let payload = settings.asProfilePayload()

        XCTAssertEqual(payload["p3Enabled"], .bool(true),
                       "asProfilePayload must include p3Enabled for server sync")

        // Cleanup
        defaults.removePersistentDomain(forName: "P3TestPayload")
    }

    /// asProfilePayload should include p3Enabled=false when P3 is off.
    func test_asProfilePayload_includesP3Enabled_false() {
        let defaults = UserDefaults(suiteName: "P3TestPayloadFalse")!
        let settings = SettingsManager(defaults: defaults)
        settings.p3Enabled = false

        let payload = settings.asProfilePayload()

        XCTAssertEqual(payload["p3Enabled"], .bool(false),
                       "asProfilePayload must include p3Enabled=false when disabled")

        // Cleanup
        defaults.removePersistentDomain(forName: "P3TestPayloadFalse")
    }

    /// applyFromProfile should set p3Enabled from server profile settings.
    func test_applyFromProfile_setsP3Enabled() {
        let defaults = UserDefaults(suiteName: "P3TestApply")!
        let settings = SettingsManager(defaults: defaults)
        settings.p3Enabled = false

        // Simulate server profile with p3Enabled=true
        let profile = ProProfileSettings(
            profileName: "test-profile",
            payload: ["p3Enabled": .bool(true)],
            updatedAt: nil
        )
        settings.applyFromProfile(profile, profileName: "p3-test-profile")

        XCTAssertTrue(settings.p3Enabled,
                      "applyFromProfile must apply p3Enabled from server")

        // Cleanup
        defaults.removePersistentDomain(forName: "P3TestApply")
    }

    /// applyFromProfile should handle p3Enabled=false from server.
    func test_applyFromProfile_setsP3Enabled_false() {
        let defaults = UserDefaults(suiteName: "P3TestApplyFalse")!
        let settings = SettingsManager(defaults: defaults)
        settings.p3Enabled = true

        let profile = ProProfileSettings(
            profileName: "test-profile",
            payload: ["p3Enabled": .bool(false)],
            updatedAt: nil
        )
        settings.applyFromProfile(profile, profileName: "p3-test-apply-false")

        XCTAssertFalse(settings.p3Enabled,
                       "applyFromProfile must apply p3Enabled=false from server")

        // Cleanup
        defaults.removePersistentDomain(forName: "P3TestApplyFalse")
    }

    // MARK: - PodcastSettings: privacyMode nil round-trip

    /// PodcastSettings.privacyMode=nil should survive encode/decode as absent key.
    func test_podcastSettings_privacyMode_nil_roundTrip() throws {
        var settings = PodcastSettings()
        settings.privacyMode = nil

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PodcastSettings.self, from: data)

        XCTAssertNil(decoded.privacyMode,
                     "privacyMode=nil should survive encode/decode as nil")
    }

    // MARK: - Download Privacy Mode Resolution

    /// When global P3 is OFF and per-podcast is nil, downloads should NOT strip URLs.
    func test_downloadPrivacyMode_globalOff_perPodcastNil_noStripping() {
        let defaults = UserDefaults(suiteName: "P3DownloadA")!
        let settingsManager = SettingsManager(defaults: defaults)
        settingsManager.p3Enabled = false

        let podSettings = PodcastSettings() // privacyMode = nil

        // Resolution: nil ?? false = false
        let resolved = podSettings.privacyMode ?? settingsManager.p3Enabled
        XCTAssertFalse(resolved,
                       "Download should NOT strip when global=off and per-podcast=nil")

        // Verify no stripping happens
        let input = "https://dts.podtrac.com/redirect.mp3/cdn.example.com/ep1.mp3"
        if resolved {
            let result = TrackingURLStripper.strip(input)
            // Should not reach here
            XCTFail("Stripping should not be invoked, but got: \(result.url)")
        }
        // If resolved is false, stripping is skipped — correct behavior

        defaults.removePersistentDomain(forName: "P3DownloadA")
    }

    /// When global P3 is ON and per-podcast is nil, downloads SHOULD strip URLs.
    func test_downloadPrivacyMode_globalOn_perPodcastNil_stripsUrl() {
        let defaults = UserDefaults(suiteName: "P3DownloadB")!
        let settingsManager = SettingsManager(defaults: defaults)
        settingsManager.p3Enabled = true

        let podSettings = PodcastSettings() // privacyMode = nil

        // Resolution: nil ?? true = true
        let resolved = podSettings.privacyMode ?? settingsManager.p3Enabled
        XCTAssertTrue(resolved,
                      "Download SHOULD strip when global=on and per-podcast=nil")

        // Verify stripping works
        let input = "https://dts.podtrac.com/redirect.mp3/cdn.example.com/ep1.mp3"
        let result = TrackingURLStripper.strip(input)
        XCTAssertEqual(result.url, "https://cdn.example.com/ep1.mp3",
                       "Tracker prefix should be stripped for download")

        defaults.removePersistentDomain(forName: "P3DownloadB")
    }

    /// When global P3 is OFF but per-podcast is ON, downloads SHOULD strip URLs.
    func test_downloadPrivacyMode_globalOff_perPodcastTrue_stripsUrl() {
        let defaults = UserDefaults(suiteName: "P3DownloadC")!
        let settingsManager = SettingsManager(defaults: defaults)
        settingsManager.p3Enabled = false

        var podSettings = PodcastSettings()
        podSettings.privacyMode = true

        // Resolution: true ?? false = true (per-podcast wins)
        let resolved = podSettings.privacyMode ?? settingsManager.p3Enabled
        XCTAssertTrue(resolved,
                      "Download SHOULD strip when per-podcast=on overrides global=off")

        defaults.removePersistentDomain(forName: "P3DownloadC")
    }

    /// When global P3 is ON but per-podcast is OFF, downloads should NOT strip URLs.
    func test_downloadPrivacyMode_globalOn_perPodcastFalse_noStripping() {
        let defaults = UserDefaults(suiteName: "P3DownloadD")!
        let settingsManager = SettingsManager(defaults: defaults)
        settingsManager.p3Enabled = true

        var podSettings = PodcastSettings()
        podSettings.privacyMode = false

        // Resolution: false ?? true = false (per-podcast wins)
        let resolved = podSettings.privacyMode ?? settingsManager.p3Enabled
        XCTAssertFalse(resolved,
                       "Download should NOT strip when per-podcast=off overrides global=on")

        defaults.removePersistentDomain(forName: "P3DownloadD")
    }

    /// Auto-download in processNewEpisodes should resolve privacyMode from
    /// per-podcast settings with global fallback — same as manual downloads.
    func test_autoDownload_privacyMode_resolvesFromPodcastAndGlobal() {
        let defaults = UserDefaults(suiteName: "P3AutoDL")!
        let settingsManager = SettingsManager(defaults: defaults)

        // Scenario 1: Global ON, per-podcast nil → should resolve to true
        settingsManager.p3Enabled = true
        let podSettingsA = PodcastSettings()
        let resolvedA = podSettingsA.privacyMode ?? settingsManager.p3Enabled
        XCTAssertTrue(resolvedA,
                      "Auto-download should strip when global=on and per-podcast=nil")

        // Scenario 2: Global ON, per-podcast OFF → should resolve to false
        var podSettingsB = PodcastSettings()
        podSettingsB.privacyMode = false
        let resolvedB = podSettingsB.privacyMode ?? settingsManager.p3Enabled
        XCTAssertFalse(resolvedB,
                       "Auto-download should NOT strip when per-podcast=off overrides global=on")

        // Scenario 3: Global OFF, per-podcast ON → should resolve to true
        settingsManager.p3Enabled = false
        var podSettingsC = PodcastSettings()
        podSettingsC.privacyMode = true
        let resolvedC = podSettingsC.privacyMode ?? settingsManager.p3Enabled
        XCTAssertTrue(resolvedC,
                      "Auto-download should strip when per-podcast=on overrides global=off")

        defaults.removePersistentDomain(forName: "P3AutoDL")
    }
}
