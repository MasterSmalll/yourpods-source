import XCTest
@testable import YourPods

// MARK: - Remote Command Action Tests

@MainActor
final class RemoteCommandActionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "nextTrackAction")
        UserDefaults.standard.removeObject(forKey: "previousTrackAction")
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "nextTrackAction")
        UserDefaults.standard.removeObject(forKey: "previousTrackAction")
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    // MARK: - Enum Raw Values

    func test_remoteCommandAction_rawValues() {
        XCTAssertEqual(RemoteCommandAction.skipBack.rawValue, "skipBack")
        XCTAssertEqual(RemoteCommandAction.skipForward.rawValue, "skipForward")
        XCTAssertEqual(RemoteCommandAction.previousEpisode.rawValue, "previousEpisode")
        XCTAssertEqual(RemoteCommandAction.nextEpisode.rawValue, "nextEpisode")
    }

    func test_remoteCommandAction_roundTrip() {
        for action in RemoteCommandAction.allCases {
            let decoded = RemoteCommandAction(rawValue: action.rawValue)
            XCTAssertEqual(decoded, action, "Round-trip failed for \(action)")
        }
    }

    func test_remoteCommandAction_displayNames() {
        XCTAssertEqual(RemoteCommandAction.skipBack.displayName, "Skip Back")
        XCTAssertEqual(RemoteCommandAction.skipForward.displayName, "Skip Forward")
        XCTAssertEqual(RemoteCommandAction.previousEpisode.displayName, "Restart Episode")
        XCTAssertEqual(RemoteCommandAction.nextEpisode.displayName, "Next Episode")
    }

    // MARK: - SettingsManager Defaults

    func test_nextTrackAction_defaultsToNextEpisode() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.nextTrackAction, .nextEpisode,
                       "Next track should default to nextEpisode")
    }

    func test_previousTrackAction_defaultsToSkipBack() {
        let settings = SettingsManager()
        XCTAssertEqual(settings.previousTrackAction, .skipBack,
                       "Previous track should default to skipBack (Apple Podcasts convention)")
    }

    // MARK: - SettingsManager Persistence

    func test_nextTrackAction_persists() {
        let settings1 = SettingsManager()
        settings1.nextTrackAction = .skipForward

        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.nextTrackAction, .skipForward,
                       "nextTrackAction must persist across SettingsManager instances")
    }

    func test_previousTrackAction_persists() {
        let settings1 = SettingsManager()
        settings1.previousTrackAction = .previousEpisode

        let settings2 = SettingsManager()
        XCTAssertEqual(settings2.previousTrackAction, .previousEpisode,
                       "previousTrackAction must persist across SettingsManager instances")
    }

    // MARK: - AudioManager Action Properties

    func test_audioManager_defaultActions() {
        let manager = AudioManager()
        XCTAssertEqual(manager.nextTrackAction, .nextEpisode,
                       "AudioManager nextTrackAction should default to nextEpisode")
        XCTAssertEqual(manager.previousTrackAction, .skipBack,
                       "AudioManager previousTrackAction should default to skipBack")
    }

    func test_audioManager_actionsCanBeUpdated() {
        let manager = AudioManager()
        manager.nextTrackAction = .skipForward
        manager.previousTrackAction = .previousEpisode

        XCTAssertEqual(manager.nextTrackAction, .skipForward)
        XCTAssertEqual(manager.previousTrackAction, .previousEpisode)
    }
}
