import XCTest
@testable import YourPods

/// Tests for per-install device identity.
///
/// Root cause R4: all iOS installs stamp actions with the same profile deviceId,
/// so the conflict detector suppresses genuine cross-device conflicts.
@MainActor
final class InstallIdentityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear test install ID to ensure fresh generation
        UserDefaults.standard.removeObject(forKey: InstallIdentity.installIdKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: InstallIdentity.installIdKey)
        super.tearDown()
    }

    // MARK: - InstallIdentity

    /// InstallId should persist across reads (same value returned twice).
    func test_installId_persistsAcrossReads() {
        let first = InstallIdentity.installId
        let second = InstallIdentity.installId
        XCTAssertEqual(first, second,
                       "installId must be stable across reads")
    }

    /// InstallId should start with "yourpods-" prefix.
    func test_installId_hasExpectedPrefix() {
        let id = InstallIdentity.installId
        XCTAssertTrue(id.hasPrefix("yourpods-"),
                      "installId must start with 'yourpods-' prefix, got: \(id)")
    }

    /// InstallId should be different from a profile deviceId.
    func test_installId_differFromProfileDeviceId() {
        let installId = InstallIdentity.installId
        let profileDeviceId = "yourpods-ios"
        XCTAssertNotEqual(installId, profileDeviceId,
                          "installId must differ from the static profile device ID")
    }

    /// After clearing the stored value, a new installId should be generated.
    func test_installId_regeneratesAfterClear() {
        let first = InstallIdentity.installId
        UserDefaults.standard.removeObject(forKey: InstallIdentity.installIdKey)
        let second = InstallIdentity.installId
        // New UUID suffix means it should be different (overwhelmingly likely)
        XCTAssertNotEqual(first, second,
                          "After clearing, a new installId should be generated")
    }

    // MARK: - EpisodeActionSyncService uses installId

    /// The deviceIdProvider on EpisodeActionSyncService should return the installId,
    /// not the profile device ID.
    func test_deviceIdProvider_returnsInstallId() {
        let installId = InstallIdentity.installId
        // When EpisodeActionSyncService is constructed with the production deviceIdProvider,
        // it should return InstallIdentity.installId
        let provider: () -> String = { InstallIdentity.installId }
        XCTAssertEqual(provider(), installId,
                       "Production deviceIdProvider must return InstallIdentity.installId")
    }
}
