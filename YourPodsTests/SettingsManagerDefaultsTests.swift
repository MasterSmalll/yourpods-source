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
}
