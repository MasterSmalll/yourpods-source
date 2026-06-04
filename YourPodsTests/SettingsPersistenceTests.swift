import XCTest
@testable import YourPods

// MARK: - Settings Persistence Tests

final class SettingsPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "hidePlayedEpisodes")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hidePlayedEpisodes")
        super.tearDown()
    }

    func test_hidePlayedEpisodes_persistsInUserDefaults() {
        // GIVEN: A SettingsManager with hidePlayedEpisodes set to true
        let settings = SettingsManager()
        settings.hidePlayedEpisodes = true

        // WHEN: A new SettingsManager is created
        let settings2 = SettingsManager()

        // THEN: The value should persist
        XCTAssertTrue(settings2.hidePlayedEpisodes,
                      "hidePlayedEpisodes must persist across SettingsManager instances")
    }

    func test_hidePlayedEpisodes_defaultsFalse() {
        // GIVEN: No saved value
        let settings = SettingsManager()

        // THEN: Default should be false
        XCTAssertFalse(settings.hidePlayedEpisodes,
                       "hidePlayedEpisodes should default to false")
    }
}
