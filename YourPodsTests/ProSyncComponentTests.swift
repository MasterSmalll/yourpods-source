import XCTest
@testable import YourPods

// MARK: - Component 3: ServerProfile.proProfileName

/// Tests for the `proProfileName` field added to `ServerProfile`.
/// Ensures backward-compatible decoding (nil → "yourpodssync") and
/// correct default in new profiles.
final class ServerProfileProNameTests: XCTestCase {

    func test_proProfileName_decodesDefault_whenFieldMissing() throws {
        // Simulate a profile saved before proProfileName was added
        let json = """
        {
            "id": "abc-123",
            "name": "My Profile",
            "deviceId": "yourpods-ios",
            "profileType": "yourpodsPro"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(ServerProfile.self, from: json)
        XCTAssertEqual(profile.proProfileName, "yourpodssync",
                       "Missing proProfileName must decode as 'yourpodssync'")
    }

    func test_proProfileName_decodesCustomValue_whenFieldPresent() throws {
        let json = """
        {
            "id": "abc-123",
            "name": "My Profile",
            "deviceId": "yourpods-ios",
            "profileType": "yourpodsPro",
            "proProfileName": "my-team"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(ServerProfile.self, from: json)
        XCTAssertEqual(profile.proProfileName, "my-team")
    }

    func test_proProfileName_defaultInit_isYourpodssync() {
        let profile = ServerProfile(name: "New Pro Profile", profileType: .yourpodsPro)
        XCTAssertEqual(profile.proProfileName, "yourpodssync",
                       "New Pro profiles must default to 'yourpodssync'")
    }

    func test_proProfileName_roundTripsViaJSON() throws {
        let original = ServerProfile(
            name: "Test",
            profileType: .yourpodsPro,
            proProfileName: "team-alpha"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertEqual(decoded.proProfileName, "team-alpha")
    }
}

// MARK: - Component 6: SettingsManager Profile Sync

/// Tests for `applyFromProfile(_:profileName:)`, `asProfilePayload()`,
/// and the `proFirstSyncCompleted` guard in SettingsManager.
///
/// `ProProfileSettings.payload` is a `[String: AnyCodableValue]` dict,
/// so applyFromProfile reads keys by name.
final class SettingsManagerProfileSyncTests: XCTestCase {

    private var defaults: UserDefaults!
    private var manager: SettingsManager!
    private let suiteName = "test.settings.profile.sync"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        manager = SettingsManager(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        manager = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeProfile(
        profileName: String = "yourpodspro",
        playbackSpeed: Double = 1.5,
        skipForwardSec: Int = 45,
        skipBackwardSec: Int = 10,
        skipIntroSec: Int = 30,
        skipOutroSec: Int = 0,
        autoQueueMode: String = "playNext",
        autoDownload: Bool = true,
        archiveOnComplete: Bool = false
    ) -> ProProfileSettings {
        let payload: [String: AnyCodableValue] = [
            "playbackSpeed": .double(playbackSpeed),
            "skipForwardSec": .int(skipForwardSec),
            "skipBackwardSec": .int(skipBackwardSec),
            "skipIntroSec": .int(skipIntroSec),
            "skipOutroSec": .int(skipOutroSec),
            "autopilot": .string(autoQueueMode),
            "autoDownload": .bool(autoDownload),
            "archiveOnComplete": .bool(archiveOnComplete)
        ]
        return ProProfileSettings(profileName: profileName, payload: payload, updatedAt: nil)
    }

    // MARK: - applyFromProfile

    func test_applyFromProfile_setsSettings_whenFirstSyncNotCompleted() {
        let profile = makeProfile()

        manager.applyFromProfile(profile, profileName: "yourpodspro")

        XCTAssertEqual(manager.playbackSpeed, 1.5, accuracy: 0.01)
        XCTAssertEqual(manager.skipForwardSeconds, 45)
        XCTAssertEqual(manager.skipBackwardSeconds, 10)
        XCTAssertEqual(manager.skipIntroSeconds, 30)
        XCTAssertEqual(manager.defaultAutoQueueMode, .priority)
        XCTAssertTrue(manager.defaultAutoDownload)
    }

    func test_applyFromProfile_isNoOp_whenFirstSyncAlreadyCompleted() {
        manager.markProFirstSyncCompleted(profileName: "yourpodspro")
        manager.playbackSpeed = 2.0
        manager.skipForwardSeconds = 15

        let profile = makeProfile(playbackSpeed: 1.0, skipForwardSec: 30)
        manager.applyFromProfile(profile, profileName: "yourpodspro")

        XCTAssertEqual(manager.playbackSpeed, 2.0, accuracy: 0.01,
                       "applyFromProfile must not overwrite after first sync completes")
        XCTAssertEqual(manager.skipForwardSeconds, 15)
    }

    func test_proFirstSyncCompleted_isPerProfileName() {
        manager.markProFirstSyncCompleted(profileName: "team-a")
        XCTAssertTrue(manager.proFirstSyncCompleted(profileName: "team-a"))
        XCTAssertFalse(manager.proFirstSyncCompleted(profileName: "team-b"),
                       "First-sync guard must be keyed per profile name")
    }

    func test_applyFromProfile_marksFirstSyncCompleted() {
        XCTAssertFalse(manager.proFirstSyncCompleted(profileName: "yourpodspro"))
        manager.applyFromProfile(makeProfile(), profileName: "yourpodspro")
        XCTAssertTrue(manager.proFirstSyncCompleted(profileName: "yourpodspro"),
                      "applyFromProfile must mark first sync done after applying")
    }

    // MARK: - asProfilePayload

    func test_asProfilePayload_includesExpectedKeys() {
        manager.playbackSpeed = 1.25
        manager.skipForwardSeconds = 45
        manager.skipBackwardSeconds = 10
        manager.skipIntroSeconds = 60
        manager.skipOutroSeconds = 0
        manager.defaultAutoQueueMode = .normal
        manager.defaultAutoDownload = true
        manager.defaultArchiveOnComplete = false

        let payload = manager.asProfilePayload()

        XCTAssertEqual(payload["playbackSpeed"], .double(1.25))
        XCTAssertEqual(payload["skipForwardSec"], .int(45))
        XCTAssertEqual(payload["skipBackwardSec"], .int(10))
        XCTAssertEqual(payload["skipIntroSec"], .int(60))
        XCTAssertEqual(payload["skipOutroSec"], .int(0))
        XCTAssertEqual(payload["autopilot"], .string("addToQueue"))
        XCTAssertEqual(payload["autoDownload"], .bool(true))
        XCTAssertEqual(payload["archiveOnComplete"], .bool(false))
    }

    func test_asProfilePayload_includesAllRequiredKeys() {
        let payload = manager.asProfilePayload()
        let requiredKeys = [
            "playbackSpeed", "skipForwardSec", "skipBackwardSec",
            "skipIntroSec", "skipOutroSec", "autopilot",
            "autoDownload", "archiveOnComplete"
        ]
        for key in requiredKeys {
            XCTAssertNotNil(payload[key], "Payload missing required key: \(key)")
        }
    }
}
