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

    // MARK: - applyFromProfile: reconcile model (bidirectional settings)

    /// Scenario: after the first sync, a server change to a key the user did NOT
    /// change locally is adopted on a later pull (web→iOS settings propagation —
    /// the headline fix; the old first-sync guard blocked this forever).
    func test_applyFromProfile_adoptsServerChange_forKeyNotChangedLocally() {
        let pname = "reconcile-adopt"
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)
        XCTAssertEqual(manager.playbackSpeed, 1.0, accuracy: 0.001)

        // Web changes playbackSpeed to 2.0; local was not touched since the seed.
        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(2.0)], updatedAt: nil), profileName: pname)

        XCTAssertEqual(manager.playbackSpeed, 2.0, accuracy: 0.001,
            "A server change to an untouched key must be adopted on a later pull (web→iOS)")
        XCTAssertNil(push["playbackSpeed"],
            "A key adopted from the server must not be echoed back as a push")
    }

    /// A key the user changed locally is NOT stomped by an unchanged server value;
    /// it is returned as a sparse push so the server adopts it.
    func test_applyFromProfile_keepsLocalChange_andPushesIt_whenServerUnchanged() {
        let pname = "reconcile-keep-local"
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        manager.playbackSpeed = 1.75   // local edit since base

        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        XCTAssertEqual(manager.playbackSpeed, 1.75, accuracy: 0.001,
            "A locally-changed key must not be stomped by an unchanged server value")
        XCTAssertEqual(push["playbackSpeed"], .double(1.75),
            "A locally-changed key must be pushed (sparsely) to the server")
    }

    /// The push payload is SPARSE — only locally-changed keys, never the full blob.
    /// A full-blob PATCH clobbers other devices' keys under the server's shallow merge.
    func test_applyFromProfile_pushesOnlyChangedKeys_notFullBlob() {
        let pname = "reconcile-sparse"
        manager.playbackSpeed = 1.0
        manager.skipForwardSeconds = 30
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0), "skipForwardSec": .int(30)], updatedAt: nil),
            profileName: pname)

        manager.skipForwardSeconds = 45   // change ONLY skipForward locally

        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0), "skipForwardSec": .int(30)], updatedAt: nil),
            profileName: pname)

        XCTAssertEqual(push["skipForwardSec"], .int(45))
        XCTAssertNil(push["playbackSpeed"],
            "Unchanged keys must NOT be in the push payload (sparse PATCH protects other devices' keys)")
    }

    /// Genuine same-key conflict (both changed since base): serverWins adopts server.
    func test_applyFromProfile_conflict_serverWins_adoptsServer() {
        let pname = "reconcile-conflict-server"
        manager.syncConflictStrategy = .serverWins
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        manager.playbackSpeed = 1.5   // local change
        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(2.0)], updatedAt: nil), profileName: pname)

        XCTAssertEqual(manager.playbackSpeed, 2.0, accuracy: 0.001,
            "serverWins: a genuine same-key conflict resolves to the server value")
        XCTAssertNil(push["playbackSpeed"])
    }

    /// Genuine same-key conflict: deviceWins keeps + pushes the local value.
    func test_applyFromProfile_conflict_deviceWins_keepsLocal() {
        let pname = "reconcile-conflict-device"
        manager.syncConflictStrategy = .deviceWins
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        manager.playbackSpeed = 1.5
        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(2.0)], updatedAt: nil), profileName: pname)

        XCTAssertEqual(manager.playbackSpeed, 1.5, accuracy: 0.001,
            "deviceWins: local value is kept on conflict")
        XCTAssertEqual(push["playbackSpeed"], .double(1.5),
            "deviceWins: local value is pushed on conflict")
    }

    /// `.ask` resolves settings conflicts server-canonically (no per-key prompt;
    /// locked server-canonical decision — settings must never raise a conflict sheet).
    func test_applyFromProfile_conflict_ask_isServerCanonical() {
        let pname = "reconcile-conflict-ask"
        manager.syncConflictStrategy = .ask
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        manager.playbackSpeed = 1.5
        _ = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(2.0)], updatedAt: nil), profileName: pname)

        XCTAssertEqual(manager.playbackSpeed, 2.0, accuracy: 0.001,
            ".ask resolves settings conflicts server-canonically (no UI prompt for settings)")
    }

    /// Migration from the legacy local-wins-forever model: the first reconcile run
    /// while `proFirstSyncCompleted` is already set (and no base snapshot exists yet)
    /// must PRESERVE local (never adopt server) and re-assert local to the server.
    func test_applyFromProfile_migration_preservesLocal_whenLegacyGuardSet() {
        let pname = "reconcile-migration"
        manager.markProFirstSyncCompleted(profileName: pname)   // legacy state, no base snapshot
        manager.playbackSpeed = 2.0

        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        XCTAssertEqual(manager.playbackSpeed, 2.0, accuracy: 0.001,
            "Migration must not let a server value overwrite an existing local pref on upgrade")
        XCTAssertEqual(push["playbackSpeed"], .double(2.0),
            "Migration re-asserts local to the server (matches the legacy local-wins push)")
    }

    /// Fresh device (no base, no legacy guard): adopt server wholesale and seed keys
    /// the server lacks with the local value (so the server gets a full baseline).
    func test_applyFromProfile_freshDevice_adoptsServer_andSeedsMissingKeys() {
        let pname = "reconcile-fresh"
        manager.appBadgeEnabled = true   // a key the server payload will NOT contain

        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.25)], updatedAt: nil), profileName: pname)

        XCTAssertEqual(manager.playbackSpeed, 1.25, accuracy: 0.001,
            "Fresh device adopts server values wholesale")
        XCTAssertEqual(push["appBadgeEnabled"], .bool(true),
            "Fresh device seeds keys the server lacks with the local value")
        XCTAssertNil(push["playbackSpeed"],
            "A key already present on the server is not re-pushed on fresh adopt")
    }

    /// Free tier / offline (server pull returned nil): keep local, push dirty keys
    /// (accumulate-while-free), never wipe local.
    func test_applyFromProfile_nilServer_keepsLocal_pushesDirty() {
        let pname = "reconcile-nil-server"
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)
        manager.playbackSpeed = 1.5

        let push = manager.applyFromProfile(nil, profileName: pname)

        XCTAssertEqual(manager.playbackSpeed, 1.5, accuracy: 0.001)
        XCTAssertEqual(push["playbackSpeed"], .double(1.5),
            "With no server view, a dirty key is still pushed (free-tier accumulate)")
    }

    /// Forward-compat: an unparseable/unknown remote enum value (e.g. a newer web
    /// `glassAppearance` this build predates) must NOT be applied locally, and must
    /// NOT be pushed back over the server on the next sync (which would clobber the
    /// web's newer choice with this build's stale fallback).
    func test_applyFromProfile_unknownRemoteEnum_notAppliedAndNotClobbered() {
        let pname = "reconcile-unknown-enum"
        manager.glassAppearance = .regular
        // Fresh adopt with an enum value this build does not recognise.
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["glassAppearance": .string("ultraGlass")], updatedAt: nil), profileName: pname)
        XCTAssertEqual(manager.glassAppearance, .regular,
            "An unparseable remote enum value must not change the local setting")

        // Next sync: server still reports the unknown value — we must not push the
        // local fallback over it.
        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["glassAppearance": .string("ultraGlass")], updatedAt: nil), profileName: pname)
        XCTAssertNil(push["glassAppearance"],
            "Must not clobber an unparseable remote enum value with the local fallback")
    }

    /// Free tier / offline first sync (no server view): push only the user's actual
    /// customizations (keys differing from factory defaults), never the full default
    /// blob — a full blob would clobber another free device's customized keys via the
    /// server's shallow per-key merge.
    func test_applyFromProfile_freshNoServer_pushesOnlyCustomizations_notFullBlob() {
        let pname = "reconcile-fresh-free"
        manager.playbackSpeed = 1.7   // one customization away from factory defaults

        let push = manager.applyFromProfile(nil, profileName: pname)

        XCTAssertEqual(push["playbackSpeed"], .double(1.7),
            "A real customization is still pushed on a fresh free-tier device")
        XCTAssertNil(push["skipForwardSec"],
            "A key left at its factory default must NOT be pushed (would clobber peers)")
        XCTAssertLessThan(push.count, 13,
            "Fresh free-tier push must be sparse (customizations only), not the full blob")
    }

    /// Int/double representation drift must not create phantom dirtiness: a whole-number
    /// speed stored as `.int` on the server equals the local `.double`.
    func test_applyFromProfile_noFalseDirty_acrossIntDoubleRepresentation() {
        let pname = "reconcile-numeric"
        manager.playbackSpeed = 2.0
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .int(2)], updatedAt: nil), profileName: pname)

        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .int(2)], updatedAt: nil), profileName: pname)

        XCTAssertNil(push["playbackSpeed"],
            ".int(2) and .double(2.0) are the same value — must not be pushed as a phantom change")
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

    // MARK: - Global pref ports (#2): startPage / autoHide* / queueRemoval / syncIntervalSec

    /// The five newly-synced global prefs must serialize with the web wire key + vocab.
    func test_asProfilePayload_includesGlobalPrefs_withWireMapping() {
        manager.queueRemovalAction = .removeAndMarkPlayed
        manager.autoHideOldEpisodes = false
        manager.autoHideKeepRecentCount = 5
        manager.defaultStartPage = "upnext"   // iOS local vocab
        manager.syncInterval = 45             // seconds (matches web syncIntervalSec unit)

        let payload = manager.asProfilePayload()

        XCTAssertEqual(payload["queueRemoval"], .string("removeAndMark"),
                       "iOS .removeAndMarkPlayed must map to the web wire vocab 'removeAndMark'")
        XCTAssertEqual(payload["autoHideOldEpisodes"], .bool(false))
        XCTAssertEqual(payload["autoHideKeepRecentCount"], .int(5))
        XCTAssertEqual(payload["startPage"], .string("upNext"),
                       "iOS 'upnext' must map to the web wire vocab 'upNext'")
        XCTAssertEqual(payload["syncIntervalSec"], .int(45))
    }

    /// web→iOS: a server change to these globals (untouched locally) is adopted on pull,
    /// translating the web wire vocab back to the iOS local vocab.
    func test_applyFromProfile_adoptsGlobalPrefs_fromServer_withVocabMapping() {
        let pname = "reconcile-global-prefs"
        // First sync seeds base from local defaults.
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        // Web sets these globals; local untouched since seed → adopt on pull.
        _ = manager.applyFromProfile(ProProfileSettings(profileName: pname, payload: [
            "queueRemoval": .string("removeAndMark"),
            "autoHideOldEpisodes": .bool(false),
            "autoHideKeepRecentCount": .int(7),
            "startPage": .string("upNext"),
            "syncIntervalSec": .int(20),
        ], updatedAt: nil), profileName: pname)

        XCTAssertEqual(manager.queueRemovalAction, .removeAndMarkPlayed)
        XCTAssertFalse(manager.autoHideOldEpisodes)
        XCTAssertEqual(manager.autoHideKeepRecentCount, 7)
        XCTAssertEqual(manager.defaultStartPage, "upnext",
                       "web 'upNext' must translate back to the iOS local vocab 'upnext'")
        XCTAssertEqual(manager.syncInterval, 20)
    }

    /// iOS→web: a locally-changed global pref the server did NOT change is returned as a
    /// sparse push, in the web wire vocab.
    func test_applyFromProfile_pushesLocalGlobalPrefChange_withWireMapping() {
        let pname = "reconcile-push-global"
        manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        manager.queueRemovalAction = .removeAndMarkPlayed   // local change after seed

        let push = manager.applyFromProfile(ProProfileSettings(profileName: pname,
            payload: ["playbackSpeed": .double(1.0)], updatedAt: nil), profileName: pname)

        XCTAssertEqual(push["queueRemoval"], .string("removeAndMark"),
                       "A locally-changed global pref must be pushed in the web wire vocab")
    }
}
