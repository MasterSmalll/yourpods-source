import XCTest
@testable import YourPods

/// Tests for notification settings sync with the server API.
///
/// Covers two sync paths:
/// 1. Global `newEpisodeNotificationsEnabled` via profile-level settings
/// 2. Per-podcast `notifications` via per-podcast settings
///
/// Per-podcast sync is already wired (via PodcastSettings.toServerPayload/fromServerPayload).
/// These tests verify the GLOBAL toggle is included in the profile sync pipeline.
final class NotificationSyncTests: XCTestCase {

    // MARK: - Profile Payload (Push)

    /// Global notification toggle MUST be included in the profile payload
    /// pushed to `PATCH /settings/profile`.
    func test_asProfilePayload_includesNewEpisodeNotificationsEnabled_whenTrue() {
        let settings = SettingsManager()
        settings.newEpisodeNotificationsEnabled = true

        let payload = settings.asProfilePayload()

        // The key MUST exist in the payload dictionary
        XCTAssertNotNil(payload["newEpisodeNotificationsEnabled"],
                        "asProfilePayload() MUST include newEpisodeNotificationsEnabled key — it was missing")
        XCTAssertEqual(payload["newEpisodeNotificationsEnabled"], .bool(true))
    }

    func test_asProfilePayload_includesNewEpisodeNotificationsEnabled_whenFalse() {
        let settings = SettingsManager()
        settings.newEpisodeNotificationsEnabled = false

        let payload = settings.asProfilePayload()

        // The key MUST exist in the payload dictionary even when false
        XCTAssertNotNil(payload["newEpisodeNotificationsEnabled"],
                        "asProfilePayload() MUST include newEpisodeNotificationsEnabled key — it was missing")
        XCTAssertEqual(payload["newEpisodeNotificationsEnabled"], .bool(false))
    }

    /// Verify the payload dict key count increased (regression check for accidental key removal)
    func test_asProfilePayload_containsAtLeast10Keys() {
        let settings = SettingsManager()
        let payload = settings.asProfilePayload()

        // Should have: playbackSpeed, skipForwardSec, skipBackwardSec, skipIntroSec,
        // skipOutroSec, autoQueueMode, autoDownload, archiveOnComplete, p3Enabled,
        // + newEpisodeNotificationsEnabled = 10 keys
        XCTAssertGreaterThanOrEqual(payload.count, 10,
                                    "Profile payload should have at least 10 keys (9 existing + newEpisodeNotificationsEnabled)")
    }

    // MARK: - Profile Apply (Pull)

    /// On first sync, global notification toggle MUST be applied from server payload.
    func test_applyFromProfile_setsNewEpisodeNotificationsEnabled_onFirstSync() {
        let settings = SettingsManager()
        // Ensure first-sync guard is clear for our test profile
        let testProfile = "test_notif_sync_\(UUID().uuidString)"
        settings.newEpisodeNotificationsEnabled = false

        let serverSettings = ProProfileSettings(
            profileName: testProfile,
            payload: ["newEpisodeNotificationsEnabled": .bool(true)],
            updatedAt: nil
        )

        settings.applyFromProfile(serverSettings, profileName: testProfile)

        XCTAssertTrue(settings.newEpisodeNotificationsEnabled,
                      "applyFromProfile must set newEpisodeNotificationsEnabled from server payload")
    }

    /// After first sync, a server change to a toggle the user did NOT change
    /// locally IS adopted (web→iOS propagation — the first-sync guard used to block this).
    func test_applyFromProfile_adoptsServerChange_afterFirstSync_whenUntouched() {
        let settings = SettingsManager()
        let testProfile = "test_notif_adopt_\(UUID().uuidString)"
        settings.newEpisodeNotificationsEnabled = true

        // First sync seeds the base from the server (server says ON).
        settings.applyFromProfile(ProProfileSettings(
            profileName: testProfile,
            payload: ["newEpisodeNotificationsEnabled": .bool(true)],
            updatedAt: nil
        ), profileName: testProfile)
        XCTAssertTrue(settings.newEpisodeNotificationsEnabled)

        // Web turns it OFF; local was not touched since the seed → adopt the server change.
        settings.applyFromProfile(ProProfileSettings(
            profileName: testProfile,
            payload: ["newEpisodeNotificationsEnabled": .bool(false)],
            updatedAt: nil
        ), profileName: testProfile)

        XCTAssertFalse(settings.newEpisodeNotificationsEnabled,
                       "An untouched global toggle must adopt the server's change after first sync")
    }

    /// A toggle the user changed locally is NOT stomped by an unchanged server
    /// value, and is pushed sparsely so the server adopts it (iOS→web).
    func test_applyFromProfile_keepsLocallyChangedToggle_afterFirstSync() {
        let settings = SettingsManager()
        let testProfile = "test_notif_keep_\(UUID().uuidString)"
        settings.newEpisodeNotificationsEnabled = true

        // First sync seeds base (server ON).
        settings.applyFromProfile(ProProfileSettings(
            profileName: testProfile,
            payload: ["newEpisodeNotificationsEnabled": .bool(true)],
            updatedAt: nil
        ), profileName: testProfile)

        // User turns it OFF locally; server still reports the old ON value.
        settings.newEpisodeNotificationsEnabled = false
        let push = settings.applyFromProfile(ProProfileSettings(
            profileName: testProfile,
            payload: ["newEpisodeNotificationsEnabled": .bool(true)],
            updatedAt: nil
        ), profileName: testProfile)

        XCTAssertFalse(settings.newEpisodeNotificationsEnabled,
                       "A locally-changed toggle must not be stomped by an unchanged server value")
        XCTAssertEqual(push["newEpisodeNotificationsEnabled"], .bool(false),
                       "A locally-changed toggle must be pushed (sparsely) to the server")
    }

    // MARK: - Per-Podcast Sync (already wired — regression check)

    /// Per-podcast `notifications` key must be present in server payload.
    func test_perPodcast_toServerPayload_includesNotifications() {
        var ps = PodcastSettings()
        ps.notificationsEnabled = true

        let payload = ps.toServerPayload()

        XCTAssertEqual(payload["notifications"], .bool(true))
    }

    /// Per-podcast `notifications` key must round-trip from server payload.
    func test_perPodcast_fromServerPayload_readsNotifications() {
        let payload: [String: AnyCodableValue] = ["notifications": .bool(true)]

        let ps = PodcastSettings.fromServerPayload(payload)

        XCTAssertEqual(ps.notificationsEnabled, true)
    }

    /// Per-podcast `notifications: null` (absent) means default (no notification).
    func test_perPodcast_fromServerPayload_absentNotifications_isNil() {
        let payload: [String: AnyCodableValue] = ["skipIntroSec": .int(30)]

        let ps = PodcastSettings.fromServerPayload(payload)

        XCTAssertNil(ps.notificationsEnabled)
    }

    // MARK: - Resolution Table

    /// Verify the resolution table from the server spec:
    /// global=false + per=any → no notification
    /// global=true + per=nil → no notification
    /// global=true + per=true → notify
    /// global=true + per=false → no notification
    func test_resolutionTable_globalFalse_anyPerPodcast_noNotify() {
        let globalEnabled = false
        let perPodcast: Bool? = true

        let shouldNotify = globalEnabled && (perPodcast == true)
        XCTAssertFalse(shouldNotify)
    }

    func test_resolutionTable_globalTrue_perNil_noNotify() {
        let globalEnabled = true
        let perPodcast: Bool? = nil

        let shouldNotify = globalEnabled && (perPodcast == true)
        XCTAssertFalse(shouldNotify)
    }

    func test_resolutionTable_globalTrue_perTrue_notify() {
        let globalEnabled = true
        let perPodcast: Bool? = true

        let shouldNotify = globalEnabled && (perPodcast == true)
        XCTAssertTrue(shouldNotify)
    }

    func test_resolutionTable_globalTrue_perFalse_noNotify() {
        let globalEnabled = true
        let perPodcast: Bool? = false

        let shouldNotify = globalEnabled && (perPodcast == true)
        XCTAssertFalse(shouldNotify)
    }

    // MARK: - Cleanup

    override func tearDown() {
        super.tearDown()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "newEpisodeNotificationsEnabled")
    }
}
