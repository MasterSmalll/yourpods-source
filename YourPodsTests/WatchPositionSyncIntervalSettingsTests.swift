import XCTest
@testable import YourPods

// MARK: - Settings Manager: Watch Position Sync Interval

final class WatchPositionSyncIntervalSettingsTests: XCTestCase {
    
    private let defaults = UserDefaults.standard
    
    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: "watchPositionSyncInterval")
    }
    
    override func tearDown() {
        defaults.removeObject(forKey: "watchPositionSyncInterval")
        super.tearDown()
    }
    
    func test_watchPositionSyncInterval_defaultIs30() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.watchPositionSyncInterval, 30,
                       "Default watch position sync interval should be 30 seconds")
    }
    
    func test_watchPositionSyncInterval_persistsCustomValue() {
        let settings = SettingsManager()
        settings.watchPositionSyncInterval = 60
        
        // Read from a fresh instance to verify persistence
        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.watchPositionSyncInterval, 60,
                       "Custom interval should be persisted to UserDefaults")
    }
    
    func test_watchPositionSyncInterval_clampsBelow10() {
        // Position sync less than 10s would be too aggressive for battery
        let settings = SettingsManager()
        settings.watchPositionSyncInterval = 5
        XCTAssertGreaterThanOrEqual(settings.watchPositionSyncInterval, 10,
                                     "Interval should not go below 10 seconds")
    }
}
