import XCTest
@testable import YourPods

/// Exhaustive tests for all SettingsManager properties.
/// Supplements SettingsManagerDefaultsTests (which covers 6 properties)
/// to ensure ALL 25+ settings have default + persistence coverage.
final class SettingsManagerFullTests: XCTestCase {
    
    private let defaults = UserDefaults.standard
    
    /// All UserDefaults keys that SettingsManager touches.
    /// Used in setUp/tearDown to guarantee clean state.
    private let allKeys: [String] = [
        "playbackSpeed", "skipIntroSeconds", "skipOutroSeconds",
        "skipForwardSeconds", "skipBackwardSeconds",
        "nextTrackAction", "previousTrackAction",
        "syncInterval", "syncConflictStrategy", "queueSyncStrategy",
        "appearance", "showPercentListened", "tabBarDisplayMode",
        "defaultAutoQueueMode", "defaultArchiveOnComplete",
        "defaultAutoDownload", "defaultDownloadCleanupPolicy", "defaultRemoveAfterPlay",
        "queueRemovalAction", "hasChosenQueueRemovalAction",
        "feedCacheDurationHours",
        "searchProvider", "podcastIndexApiKey", "podcastIndexApiSecret",
        "watchSyncEnabled", "watchSyncPodcastLimit",
        "backgroundRefreshEnabled", "backgroundRefreshInterval",
        "hidePlayedEpisodes", "saveGPodderPassword",
        "defaultStartPage", "activeProfileId", "hasCompletedOnboarding"
    ]
    
    override func setUp() {
        super.setUp()
        for key in allKeys { defaults.removeObject(forKey: key) }
        // Clean Keychain entries for Podcast Index credentials (now stored there instead of UserDefaults)
        KeychainHelper.shared.deletePodcastIndexCredential(forAccount: "apiKey")
        KeychainHelper.shared.deletePodcastIndexCredential(forAccount: "apiSecret")
    }
    
    override func tearDown() {
        for key in allKeys { defaults.removeObject(forKey: key) }
        KeychainHelper.shared.deletePodcastIndexCredential(forAccount: "apiKey")
        KeychainHelper.shared.deletePodcastIndexCredential(forAccount: "apiSecret")
        super.tearDown()
    }
    
    // MARK: - Playback Settings
    
    func test_skipIntroSeconds_defaultsToZero() {
        let s = SettingsManager()
        XCTAssertEqual(s.skipIntroSeconds, 0)
    }
    
    func test_skipIntroSeconds_persists() {
        let s1 = SettingsManager()
        s1.skipIntroSeconds = 30
        let s2 = SettingsManager()
        XCTAssertEqual(s2.skipIntroSeconds, 30)
    }
    
    func test_skipOutroSeconds_defaultsToZero() {
        let s = SettingsManager()
        XCTAssertEqual(s.skipOutroSeconds, 0)
    }
    
    func test_skipOutroSeconds_persists() {
        let s1 = SettingsManager()
        s1.skipOutroSeconds = 15
        let s2 = SettingsManager()
        XCTAssertEqual(s2.skipOutroSeconds, 15)
    }
    
    func test_skipForwardSeconds_defaultsTo30() {
        let s = SettingsManager()
        XCTAssertEqual(s.skipForwardSeconds, 30)
    }
    
    func test_skipForwardSeconds_persists() {
        let s1 = SettingsManager()
        s1.skipForwardSeconds = 45
        let s2 = SettingsManager()
        XCTAssertEqual(s2.skipForwardSeconds, 45)
    }
    
    func test_skipBackwardSeconds_defaultsTo15() {
        let s = SettingsManager()
        XCTAssertEqual(s.skipBackwardSeconds, 15)
    }
    
    func test_skipBackwardSeconds_persists() {
        let s1 = SettingsManager()
        s1.skipBackwardSeconds = 10
        let s2 = SettingsManager()
        XCTAssertEqual(s2.skipBackwardSeconds, 10)
    }
    
    // MARK: - Sync Settings
    
    func test_syncInterval_defaultsTo30() {
        let s = SettingsManager()
        XCTAssertEqual(s.syncInterval, 30)
    }
    
    func test_syncInterval_persists() {
        let s1 = SettingsManager()
        s1.syncInterval = 60
        let s2 = SettingsManager()
        XCTAssertEqual(s2.syncInterval, 60)
    }
    
    func test_syncConflictStrategy_defaultsToAsk() {
        let s = SettingsManager()
        XCTAssertEqual(s.syncConflictStrategy, .ask)
    }
    
    func test_syncConflictStrategy_persists() {
        let s1 = SettingsManager()
        s1.syncConflictStrategy = .serverWins
        let s2 = SettingsManager()
        XCTAssertEqual(s2.syncConflictStrategy, .serverWins)
    }
    
    func test_queueSyncStrategy_defaultsToAsk() {
        let s = SettingsManager()
        XCTAssertEqual(s.queueSyncStrategy, .ask)
    }
    
    func test_queueSyncStrategy_persists() {
        let s1 = SettingsManager()
        s1.queueSyncStrategy = .serverWins
        let s2 = SettingsManager()
        XCTAssertEqual(s2.queueSyncStrategy, .serverWins)
    }
    
    // MARK: - Display Settings
    
    func test_appearance_defaultsToSystem() {
        let s = SettingsManager()
        XCTAssertEqual(s.appearance, .system)
    }
    
    func test_appearance_persists() {
        let s1 = SettingsManager()
        s1.appearance = .dark
        let s2 = SettingsManager()
        XCTAssertEqual(s2.appearance, .dark)
    }
    
    func test_showPercentListened_defaultsToTrue() {
        let s = SettingsManager()
        XCTAssertTrue(s.showPercentListened)
    }
    
    func test_showPercentListened_persists() {
        let s1 = SettingsManager()
        s1.showPercentListened = false
        let s2 = SettingsManager()
        XCTAssertFalse(s2.showPercentListened)
    }
    
    func test_tabBarDisplayMode_defaultsToTextAndIcon() {
        let s = SettingsManager()
        XCTAssertEqual(s.tabBarDisplayMode, .textAndIcon)
    }
    
    func test_tabBarDisplayMode_persists() {
        let s1 = SettingsManager()
        s1.tabBarDisplayMode = .iconOnly
        let s2 = SettingsManager()
        XCTAssertEqual(s2.tabBarDisplayMode, .iconOnly)
    }
    
    // MARK: - Queue Management
    
    func test_queueRemovalAction_defaultsToAsk() {
        let s = SettingsManager()
        XCTAssertEqual(s.queueRemovalAction, .ask)
    }
    
    func test_queueRemovalAction_persists() {
        let s1 = SettingsManager()
        s1.queueRemovalAction = .removeAndMarkPlayed
        let s2 = SettingsManager()
        XCTAssertEqual(s2.queueRemovalAction, .removeAndMarkPlayed)
    }
    
    func test_hasChosenQueueRemovalAction_defaultsToFalse() {
        let s = SettingsManager()
        XCTAssertFalse(s.hasChosenQueueRemovalAction)
    }
    
    func test_hasChosenQueueRemovalAction_persists() {
        let s1 = SettingsManager()
        s1.hasChosenQueueRemovalAction = true
        let s2 = SettingsManager()
        XCTAssertTrue(s2.hasChosenQueueRemovalAction)
    }
    
    // MARK: - Feed Cache
    
    func test_feedCacheDurationHours_defaultsTo4() {
        let s = SettingsManager()
        XCTAssertEqual(s.feedCacheDurationHours, 4)
    }
    
    func test_feedCacheDurationHours_persists() {
        let s1 = SettingsManager()
        s1.feedCacheDurationHours = 12
        let s2 = SettingsManager()
        XCTAssertEqual(s2.feedCacheDurationHours, 12)
    }
    
    // MARK: - Search Provider
    
    func test_searchProvider_defaultsToItunes() {
        let s = SettingsManager()
        XCTAssertEqual(s.searchProvider, .itunes)
    }
    
    func test_searchProvider_persists() {
        let s1 = SettingsManager()
        s1.searchProvider = .podcastIndex
        let s2 = SettingsManager()
        XCTAssertEqual(s2.searchProvider, .podcastIndex)
    }
    
    func test_podcastIndexApiKey_defaultsToNil() {
        let s = SettingsManager()
        XCTAssertNil(s.podcastIndexApiKey)
    }
    
    func test_podcastIndexApiKey_persists() {
        let s1 = SettingsManager()
        s1.podcastIndexApiKey = "test-key-123"
        let s2 = SettingsManager()
        XCTAssertEqual(s2.podcastIndexApiKey, "test-key-123")
    }
    
    func test_podcastIndexApiSecret_defaultsToNil() {
        let s = SettingsManager()
        XCTAssertNil(s.podcastIndexApiSecret)
    }
    
    func test_podcastIndexApiSecret_persists() {
        let s1 = SettingsManager()
        s1.podcastIndexApiSecret = "secret-456"
        let s2 = SettingsManager()
        XCTAssertEqual(s2.podcastIndexApiSecret, "secret-456")
    }
    
    // MARK: - Apple Watch
    
    func test_watchSyncEnabled_defaultsToTrue() {
        let s = SettingsManager()
        XCTAssertTrue(s.watchSyncEnabled)
    }
    
    func test_watchSyncEnabled_persists() {
        let s1 = SettingsManager()
        s1.watchSyncEnabled = false
        let s2 = SettingsManager()
        XCTAssertFalse(s2.watchSyncEnabled)
    }
    
    func test_watchSyncPodcastLimit_defaultsTo5() {
        let s = SettingsManager()
        XCTAssertEqual(s.watchSyncPodcastLimit, 5)
    }
    
    func test_watchSyncPodcastLimit_persists() {
        let s1 = SettingsManager()
        s1.watchSyncPodcastLimit = 10
        let s2 = SettingsManager()
        XCTAssertEqual(s2.watchSyncPodcastLimit, 10)
    }
    
    // MARK: - Background Refresh
    
    func test_backgroundRefreshEnabled_defaultsToTrue() {
        let s = SettingsManager()
        XCTAssertTrue(s.backgroundRefreshEnabled)
    }
    
    func test_backgroundRefreshEnabled_persists() {
        let s1 = SettingsManager()
        s1.backgroundRefreshEnabled = false
        let s2 = SettingsManager()
        XCTAssertFalse(s2.backgroundRefreshEnabled)
    }
    
    func test_backgroundRefreshInterval_defaultsTo60() {
        let s = SettingsManager()
        XCTAssertEqual(s.backgroundRefreshInterval, 60)
    }
    
    func test_backgroundRefreshInterval_persists() {
        let s1 = SettingsManager()
        s1.backgroundRefreshInterval = 120
        let s2 = SettingsManager()
        XCTAssertEqual(s2.backgroundRefreshInterval, 120)
    }
    
    // MARK: - gPodder Settings
    
    func test_hidePlayedEpisodes_defaultsToFalse() {
        let s = SettingsManager()
        XCTAssertFalse(s.hidePlayedEpisodes)
    }
    
    func test_hidePlayedEpisodes_persists() {
        let s1 = SettingsManager()
        s1.hidePlayedEpisodes = true
        let s2 = SettingsManager()
        XCTAssertTrue(s2.hidePlayedEpisodes)
    }
    
    func test_saveGPodderPassword_defaultsToFalse() {
        let s = SettingsManager()
        XCTAssertFalse(s.saveGPodderPassword)
    }
    
    func test_saveGPodderPassword_persists() {
        let s1 = SettingsManager()
        s1.saveGPodderPassword = true
        let s2 = SettingsManager()
        XCTAssertTrue(s2.saveGPodderPassword)
    }
    
    // MARK: - App Settings
    
    func test_defaultStartPage_defaultsToHome() {
        let s = SettingsManager()
        XCTAssertEqual(s.defaultStartPage, "home")
    }
    
    func test_defaultStartPage_persists() {
        let s1 = SettingsManager()
        s1.defaultStartPage = "library"
        let s2 = SettingsManager()
        XCTAssertEqual(s2.defaultStartPage, "library")
    }
    
    // MARK: - Active Profile
    
    func test_activeProfileId_defaultsToNil() {
        let s = SettingsManager()
        XCTAssertNil(s.activeProfileId)
    }
    
    func test_activeProfileId_persists() {
        let s1 = SettingsManager()
        s1.activeProfileId = "profile-abc"
        let s2 = SettingsManager()
        XCTAssertEqual(s2.activeProfileId, "profile-abc")
    }
    
    // MARK: - Onboarding
    
    func test_hasCompletedOnboarding_defaultsToFalse() {
        let s = SettingsManager()
        XCTAssertFalse(s.hasCompletedOnboarding)
    }
    
    func test_hasCompletedOnboarding_persists() {
        let s1 = SettingsManager()
        s1.hasCompletedOnboarding = true
        let s2 = SettingsManager()
        XCTAssertTrue(s2.hasCompletedOnboarding)
    }
    
    // MARK: - Legacy Migration
    
    func test_defaultDownloadCleanupPolicy_migratesFromLegacyBoolTrue() {
        // Set only the legacy key
        defaults.set(true, forKey: "defaultRemoveAfterPlay")
        defaults.removeObject(forKey: "defaultDownloadCleanupPolicy")
        
        let s = SettingsManager()
        XCTAssertEqual(s.defaultDownloadCleanupPolicy, .oncePlayed,
                       "Legacy removeAfterPlay=true should map to .oncePlayed")
    }
    
    func test_defaultDownloadCleanupPolicy_migratesFromLegacyBoolFalse() {
        defaults.set(false, forKey: "defaultRemoveAfterPlay")
        defaults.removeObject(forKey: "defaultDownloadCleanupPolicy")
        
        let s = SettingsManager()
        XCTAssertEqual(s.defaultDownloadCleanupPolicy, .never,
                       "Legacy removeAfterPlay=false should map to .never")
    }
    
    func test_defaultDownloadCleanupPolicy_newKeyTakesPrecedence() {
        // Both keys present — new key should win
        defaults.set(true, forKey: "defaultRemoveAfterPlay")
        defaults.set("afterOneWeek", forKey: "defaultDownloadCleanupPolicy")
        
        let s = SettingsManager()
        XCTAssertEqual(s.defaultDownloadCleanupPolicy, .afterOneWeek,
                       "New key should take precedence over legacy")
    }
}
