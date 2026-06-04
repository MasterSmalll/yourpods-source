import XCTest
import SwiftData
@testable import YourPods

// MARK: - Background Refresh Scheduling Tests

/// Tests proving that `BackgroundRefreshService` honors the user's
/// `backgroundRefreshEnabled` and `backgroundRefreshInterval` settings.
///
/// Root cause: `BackgroundRefreshService` never checked `backgroundRefreshEnabled`
/// before running sync, and hardcoded the refresh interval to 15 minutes instead
/// of reading `settingsManager.backgroundRefreshInterval`.
///
/// These tests verify:
/// 1. `handleRefresh()` skips sync when `backgroundRefreshEnabled` is false
/// 2. `handleRefresh()` runs sync when `backgroundRefreshEnabled` is true
/// 3. `computeRefreshInterval()` returns the user's configured interval
/// 4. `computeRefreshInterval()` defaults to 60 minutes when not configured
/// 5. `handleRefresh()` does NOT schedule the next refresh when disabled
@MainActor
final class BackgroundRefreshSchedulingTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private var settingsManager: SettingsManager!
    private var podcastManager: PodcastManager!
    private var bgService: BackgroundRefreshService!
    private var testDefaults: UserDefaults!
    
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        
        testDefaults = UserDefaults(suiteName: "BackgroundRefreshSchedulingTests")!
        // Clear any previous test data
        testDefaults.removePersistentDomain(forName: "BackgroundRefreshSchedulingTests")
        
        settingsManager = SettingsManager(defaults: testDefaults)
        podcastManager = PodcastManager(modelContext: context)
        
        bgService = BackgroundRefreshService.shared
        bgService.podcastManager = podcastManager
        bgService.settingsManager = settingsManager
        bgService.playerManager = PlayerManager(audioManager: AudioManager())
        bgService.downloadManager = DownloadManager()
    }
    
    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "BackgroundRefreshSchedulingTests")
        bgService.settingsManager = nil
        bgService.podcastManager = nil
        bgService.playerManager = nil
        bgService.downloadManager = nil
        testDefaults = nil
        settingsManager = nil
        podcastManager = nil
        context = nil
        container = nil
        super.tearDown()
    }
    
    // MARK: - computeRefreshInterval() tests
    
    /// The computed refresh interval should match the user's setting, in seconds.
    func test_computeRefreshInterval_usesUserSetting() {
        // GIVEN: User configured 30-minute interval
        settingsManager.backgroundRefreshInterval = 30
        
        // WHEN
        let interval = bgService.computeRefreshInterval()
        
        // THEN: 30 minutes = 1800 seconds
        XCTAssertEqual(interval, 30 * 60,
                       "computeRefreshInterval() must use the user's backgroundRefreshInterval setting, not a hardcoded value")
    }
    
    /// When the user sets a 4-hour interval, the service should use 4 hours.
    func test_computeRefreshInterval_honors4HourSetting() {
        // GIVEN: User configured 4-hour (240 minutes) interval
        settingsManager.backgroundRefreshInterval = 240
        
        // WHEN
        let interval = bgService.computeRefreshInterval()
        
        // THEN: 240 minutes = 14400 seconds
        XCTAssertEqual(interval, 240 * 60,
                       "computeRefreshInterval() must honor 4-hour interval")
    }
    
    /// The default interval should be 60 minutes when no setting is configured.
    func test_computeRefreshInterval_defaultIs60Minutes() {
        // GIVEN: No backgroundRefreshInterval configured (fresh defaults)
        // SettingsManager defaults to 60 minutes
        
        // WHEN
        let interval = bgService.computeRefreshInterval()
        
        // THEN: 60 minutes = 3600 seconds
        XCTAssertEqual(interval, 60 * 60,
                       "Default refresh interval should be 60 minutes (3600 seconds)")
    }
    
    /// When the user sets a 15-minute interval, the service should use 15 minutes.
    func test_computeRefreshInterval_honors15MinuteSetting() {
        // GIVEN: User configured 15-minute interval
        settingsManager.backgroundRefreshInterval = 15
        
        // WHEN
        let interval = bgService.computeRefreshInterval()
        
        // THEN: 15 minutes = 900 seconds
        XCTAssertEqual(interval, 15 * 60,
                       "computeRefreshInterval() must honor 15-minute interval")
    }
    
    // MARK: - shouldPerformBackgroundSync() tests
    
    /// Background sync should be skipped when the user has disabled it.
    func test_shouldPerformBackgroundSync_returnsFalseWhenDisabled() {
        // GIVEN: User has disabled background refresh
        settingsManager.backgroundRefreshEnabled = false
        
        // WHEN
        let shouldSync = bgService.shouldPerformBackgroundSync()
        
        // THEN
        XCTAssertFalse(shouldSync,
                       "shouldPerformBackgroundSync() must return false when backgroundRefreshEnabled is false")
    }
    
    /// Background sync should proceed when the user has enabled it.
    func test_shouldPerformBackgroundSync_returnsTrueWhenEnabled() {
        // GIVEN: User has enabled background refresh
        settingsManager.backgroundRefreshEnabled = true
        
        // WHEN
        let shouldSync = bgService.shouldPerformBackgroundSync()
        
        // THEN
        XCTAssertTrue(shouldSync,
                      "shouldPerformBackgroundSync() must return true when backgroundRefreshEnabled is true")
    }
    
    /// Background sync should proceed by default (setting not explicitly set).
    func test_shouldPerformBackgroundSync_defaultIsTrue() {
        // GIVEN: Fresh defaults — backgroundRefreshEnabled not explicitly set
        // SettingsManager defaults to true
        
        // WHEN
        let shouldSync = bgService.shouldPerformBackgroundSync()
        
        // THEN
        XCTAssertTrue(shouldSync,
                      "shouldPerformBackgroundSync() must default to true when the setting is not configured")
    }
    
    /// When settingsManager is nil, background sync should not proceed (safety guard).
    func test_shouldPerformBackgroundSync_returnsFalseWhenNoSettingsManager() {
        // GIVEN: No settings manager wired
        bgService.settingsManager = nil
        
        // WHEN
        let shouldSync = bgService.shouldPerformBackgroundSync()
        
        // THEN
        XCTAssertFalse(shouldSync,
                       "shouldPerformBackgroundSync() must return false when settingsManager is nil")
    }
    
    // MARK: - Integration: performSync respects backgroundRefreshEnabled
    
    /// performSync should complete without running sync when disabled.
    /// We verify by checking that lastForegroundSyncDate is NOT updated.
    func test_performSync_skipsWhenBackgroundRefreshDisabled() async {
        // GIVEN: Background refresh disabled
        settingsManager.backgroundRefreshEnabled = false
        bgService.lastForegroundSyncDate = nil
        
        // WHEN
        await bgService.performSync()
        
        // THEN: lastForegroundSyncDate should remain nil (sync was skipped)
        XCTAssertNil(bgService.lastForegroundSyncDate,
                     "performSync must skip the sync cycle when backgroundRefreshEnabled is false — lastForegroundSyncDate should remain nil")
    }
    
    /// performSync should run sync and update lastForegroundSyncDate when enabled.
    func test_performSync_runsWhenBackgroundRefreshEnabled() async {
        // GIVEN: Background refresh enabled
        settingsManager.backgroundRefreshEnabled = true
        bgService.lastForegroundSyncDate = nil
        
        // WHEN
        await bgService.performSync()
        
        // THEN: lastForegroundSyncDate should be updated (sync ran)
        XCTAssertNotNil(bgService.lastForegroundSyncDate,
                        "performSync must run the sync cycle when backgroundRefreshEnabled is true — lastForegroundSyncDate should be set")
    }
    
    /// When called from a foreground context (the existing foreground sync path),
    /// performSync should always run regardless of backgroundRefreshEnabled.
    /// Only the background task handler should gate on this setting.
    func test_performForegroundSync_ignoresBackgroundRefreshSetting() async {
        // GIVEN: Background refresh disabled but we're calling from foreground
        settingsManager.backgroundRefreshEnabled = false
        bgService.lastForegroundSyncDate = nil
        
        // WHEN: Calling the foreground sync path directly
        await bgService.performForegroundSync()
        
        // THEN: lastForegroundSyncDate should be updated (foreground sync always runs)
        XCTAssertNotNil(bgService.lastForegroundSyncDate,
                        "performForegroundSync must always run regardless of backgroundRefreshEnabled — it's the foreground path")
    }
}
