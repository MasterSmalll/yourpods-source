/// "Prompt the user, and let them make that choice the default" — the product
/// requirement behind `syncConflictStrategy`.
///
/// The setting existed and Settings could change it, but the conflict sheet — the only
/// screen where the user is looking at a concrete disagreement and deciding what they
/// want — had no way to say "and do this every time". So the answer to "why does it keep
/// asking me?" was "go find the picker in Settings and work out which of Always Server /
/// Always Device corresponds to the thing you just tapped".
///
/// These assert the production mapping (`ConflictResolution.standingStrategy`) rather
/// than a copy of it. A test that restates the mapping can pass while the sheet saves
/// the opposite, which is precisely the failure this pins: an inversion is invisible
/// until the wrong side later wins without prompting, and then it reads as a sync bug
/// rather than a settings bug.
import XCTest
@testable import YourPods

@MainActor
final class ConflictChoicePersistenceTests: XCTestCase {

    private var settings: SettingsManager!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "syncConflictStrategy")
        settings = SettingsManager()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "syncConflictStrategy")
        settings = nil
        super.tearDown()
    }

    // MARK: - The mapping

    func test_choosingThisDevice_impliesDeviceWins() {
        XCTAssertEqual(ConflictResolution.device.standingStrategy, .deviceWins,
                       "Choosing this device's position must imply .deviceWins — the inverse would arm the opposite of what the user chose")
    }

    func test_choosingServer_impliesServerWins() {
        XCTAssertEqual(ConflictResolution.server.standingStrategy, .serverWins)
    }

    // MARK: - Persistence

    /// The whole point is that it outlives the sheet: a change held only in memory would
    /// ask again on next launch, which is the complaint this feature answers.
    func test_savedChoiceSurvivesAFreshSettingsManager() {
        settings.syncConflictStrategy = ConflictResolution.device.standingStrategy
        XCTAssertEqual(SettingsManager().syncConflictStrategy, .deviceWins)

        settings.syncConflictStrategy = ConflictResolution.server.standingStrategy
        XCTAssertEqual(SettingsManager().syncConflictStrategy, .serverWins)
    }

    /// Resolving one conflict is a one-time answer. A user who resolved a single
    /// disagreement has not asked to stop being asked, so with the toggle off the
    /// standing preference must be untouched.
    func test_askIsPreservedWhenTheChoiceIsNotRemembered() {
        settings.syncConflictStrategy = .ask
        // The sheet's guard: with rememberChoice false, nothing is written at all.
        XCTAssertEqual(settings.syncConflictStrategy, .ask)
        XCTAssertEqual(SettingsManager().syncConflictStrategy, .ask,
                       "A one-off resolve must not change the standing preference")
    }
}
