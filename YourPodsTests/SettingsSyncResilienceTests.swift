import XCTest
@testable import YourPods

/// Tests for Bug 4: Settings sync resilience.
///
/// Covers:
///   - clearSyncStateForStoreRecovery preserves proFirstSyncCompleted keys
///   - Prevents accidental settings overwrite after store recovery
final class SettingsSyncResilienceTests: XCTestCase {

    override func tearDown() {
        // Clean up any keys we set
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            if key.hasPrefix("proFirstSyncCompleted_") ||
               key.hasPrefix("proSettingsBase_") ||
               key.hasPrefix("subscriptionUrls_") ||
               key.hasPrefix("lastSubscriptionSync_") ||
               key.hasPrefix("lastEpisodeActionSync_") ||
               key.hasPrefix("syncConflictCounts") ||
               key == "episodeActionMap" {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    /// clearSyncStateForStoreRecovery should NOT clear proFirstSyncCompleted keys.
    /// These keys prevent settings from being overwritten on the next sync after
    /// store recovery. Clearing them causes the "first sync" path to re-run,
    /// which overwrites local settings with server defaults.
    func test_clearSyncState_preservesProFirstSyncCompleted() {
        let defaults = UserDefaults.standard

        // GIVEN: proFirstSyncCompleted is set for two profiles
        defaults.set(true, forKey: "proFirstSyncCompleted_profile-abc")
        defaults.set(true, forKey: "proFirstSyncCompleted_profile-xyz")

        // Also set other sync keys that SHOULD be cleared
        defaults.set(["test": "data"], forKey: "episodeActionMap")
        defaults.set(["conflict": 3], forKey: "syncConflictCounts")
        defaults.set(12345, forKey: "lastSubscriptionSync_profile-abc")
        defaults.set(67890, forKey: "lastEpisodeActionSync_profile-abc")

        // WHEN: clearSyncStateForStoreRecovery runs
        YourPodsApp.clearSyncStateForStoreRecovery()

        // THEN: proFirstSyncCompleted keys must be PRESERVED
        XCTAssertTrue(defaults.bool(forKey: "proFirstSyncCompleted_profile-abc"),
                      "proFirstSyncCompleted must survive store recovery — clearing it causes settings overwrite")
        XCTAssertTrue(defaults.bool(forKey: "proFirstSyncCompleted_profile-xyz"),
                      "proFirstSyncCompleted must survive store recovery for all profiles")

        // AND: Other sync state should be cleared
        XCTAssertNil(defaults.object(forKey: "episodeActionMap"),
                     "episodeActionMap should be cleared during store recovery")
        XCTAssertNil(defaults.object(forKey: "syncConflictCounts"),
                     "syncConflictCounts should be cleared during store recovery")
        // Timestamps are reset to 0, not removed
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_profile-abc"), 0,
                       "Sync timestamps should be reset to 0")
    }

    /// A server payload whose numeric skip value overflows Int64 must NOT crash the app.
    ///
    /// `AnyCodableValue.init(from:)` lands any JSON number too large for `Int64` in the
    /// `.double` case. `applyServerValues` coerces skip keys via `asInt`, which used to do
    /// an unguarded `Int(v.rounded())` — an *uncatchable* Swift fatal error for out-of-range
    /// doubles. This path runs on every Pro sync (incl. BGAppRefreshTask), so a malformed or
    /// hostile server response would crash during background playback. The bad value must be
    /// ignored (local value preserved), not applied or trapped.
    func test_applyFromProfile_ignoresOutOfRangeSkipValue_doesNotCrash() {
        let settings = SettingsManager()
        let testProfile = "proSettingsBase_overflow_\(UUID().uuidString)"

        settings.skipForwardSeconds = 30   // known local value to assert preservation

        // skipForwardSec is far beyond Int64.max; skipBackwardSec is a normal double.
        let serverSettings = ProProfileSettings(
            profileName: testProfile,
            payload: [
                "skipForwardSec": .double(1e308),   // overflow — must be ignored, not trapped
                "skipBackwardSec": .double(15.0)    // in-range — must still coerce to 15
            ],
            updatedAt: nil
        )

        // Must not trap. Pre-fix, this line crashes the test process with
        // "Double value cannot be converted to Int because the result would be greater than Int.max".
        settings.applyFromProfile(serverSettings, profileName: testProfile)

        XCTAssertEqual(settings.skipForwardSeconds, 30,
                       "An out-of-range server skip value must be ignored, leaving the local value intact")
        XCTAssertEqual(settings.skipBackwardSeconds, 15,
                       "A normal in-range double server value must still coerce and apply")
    }
}
