import XCTest
@testable import YourPods

// MARK: - SettingsManager Defaults Tests

/// Tests that global defaults in SettingsManager persist correctly to UserDefaults
/// and return expected fallback values when nothing is set.
final class SettingsManagerDefaultsTests: XCTestCase {
    
    private let defaults = UserDefaults.standard
    
    override func setUp() {
        super.setUp()
        // Clean keys we test
        defaults.removeObject(forKey: "defaultAutoQueueMode")
        defaults.removeObject(forKey: "defaultDownloadCleanupPolicy")
        defaults.removeObject(forKey: "defaultRemoveAfterPlay")
        defaults.removeObject(forKey: "defaultAutoDownload")
        defaults.removeObject(forKey: "defaultArchiveOnComplete")
        defaults.removeObject(forKey: "playbackSpeed")
    }
    
    override func tearDown() {
        defaults.removeObject(forKey: "defaultAutoQueueMode")
        defaults.removeObject(forKey: "defaultDownloadCleanupPolicy")
        defaults.removeObject(forKey: "defaultRemoveAfterPlay")
        defaults.removeObject(forKey: "defaultAutoDownload")
        defaults.removeObject(forKey: "defaultArchiveOnComplete")
        defaults.removeObject(forKey: "playbackSpeed")
        super.tearDown()
    }
    
    func test_defaultAutoQueueMode_defaultsToOff() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.defaultAutoQueueMode, .off,
                       "Global auto-queue should default to .off when nothing is set")
    }
    
    func test_defaultAutoQueueMode_persistsRoundTrip() {
        let settings = SettingsManager()
        settings.defaultAutoQueueMode = .normal
        
        // Read from a fresh instance to verify UserDefaults persistence
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.defaultAutoQueueMode, .normal,
                       "Auto-queue mode must persist across SettingsManager instances")
    }
    
    func test_defaultDownloadCleanupPolicy_defaultsToOncePlayed() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.defaultDownloadCleanupPolicy, .oncePlayed,
                       "Global download cleanup should default to .oncePlayed")
    }
    
    func test_defaultDownloadCleanupPolicy_persistsRoundTrip() {
        let settings = SettingsManager()
        settings.defaultDownloadCleanupPolicy = .never
        
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.defaultDownloadCleanupPolicy, .never,
                       "Download cleanup policy must persist across instances")
    }
    
    func test_defaultAutoDownload_defaultsToFalse() {
        let settings = SettingsManager()
        XCTAssertFalse(settings.defaultAutoDownload,
                       "Auto-download should default to false")
    }
    
    func test_playbackSpeed_defaultsToOne() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.playbackSpeed, 1.0, accuracy: 0.01,
                       "Playback speed should default to 1.0x")
    }
    
    // MARK: - Auto-Hide Defaults
    
    func test_autoHideUnplayedEnabled_defaultsToFalse() {
        defaults.removeObject(forKey: "autoHideUnplayedEnabled")
        let settings = SettingsManager()
        XCTAssertFalse(settings.autoHideUnplayedEnabled,
                       "Auto-hide should default to disabled (opt-in)")
    }
    
    func test_autoHideUnplayedDays_defaultsTo30() {
        defaults.removeObject(forKey: "autoHideUnplayedDays")
        let settings = SettingsManager()
        XCTAssertEqual(settings.autoHideUnplayedDays, 30,
                       "Auto-hide threshold should default to 30 days")
    }
    
    func test_recentlyUpdatedLimit_defaultsTo27() {
        defaults.removeObject(forKey: "recentlyUpdatedLimit")
        let settings = SettingsManager()
        XCTAssertEqual(settings.recentlyUpdatedLimit, 27,
                       "Recently updated limit should default to 27")
    }
    
    func test_autoHideUnplayedEnabled_persistsRoundTrip() {
        defaults.removeObject(forKey: "autoHideUnplayedEnabled")
        let settings = SettingsManager()
        settings.autoHideUnplayedEnabled = true
        
        let settings2 = SettingsManager()
        XCTAssertTrue(settings2.autoHideUnplayedEnabled,
                      "Auto-hide enabled must persist across instances")
    }
    
    func test_autoHideUnplayedDays_persistsRoundTrip() {
        defaults.removeObject(forKey: "autoHideUnplayedDays")
        let settings = SettingsManager()
        settings.autoHideUnplayedDays = 14
        
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.autoHideUnplayedDays, 14,
                       "Auto-hide days must persist across instances")
    }
    
    func test_recentlyUpdatedLimit_persistsRoundTrip() {
        defaults.removeObject(forKey: "recentlyUpdatedLimit")
        let settings = SettingsManager()
        settings.recentlyUpdatedLimit = 15
        
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.recentlyUpdatedLimit, 15,
                       "Recently updated limit must persist across instances")
    }
}
