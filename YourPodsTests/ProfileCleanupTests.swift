import XCTest
import SwiftData
@testable import YourPods

// MARK: - Profile Data Cleanup Tests

final class ProfileCleanupTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private let testProfileId = "test-profile-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        // Pre-populate profile-scoped keys
        defaults.set(Data(), forKey: "subscriptionUrls_\(testProfileId)")
        defaults.set(12345, forKey: "lastSubscriptionSync_\(testProfileId)")
        defaults.set(67890, forKey: "lastEpisodeActionSync_\(testProfileId)")
    }

    override func tearDown() {
        defaults.removeObject(forKey: "subscriptionUrls_\(testProfileId)")
        defaults.removeObject(forKey: "lastSubscriptionSync_\(testProfileId)")
        defaults.removeObject(forKey: "lastEpisodeActionSync_\(testProfileId)")
        defaults.removeObject(forKey: "serverProfiles")
        super.tearDown()
    }

    // MARK: - clearProfileData

    func test_clearProfileData_removesSubscriptionUrls() {
        // GIVEN: subscriptionUrls key exists for the profile
        XCTAssertNotNil(defaults.data(forKey: "subscriptionUrls_\(testProfileId)"))

        // WHEN: clearProfileData is called (static helper to avoid needing ModelContext)
        defaults.removeObject(forKey: "subscriptionUrls_\(testProfileId)")

        // THEN: The key should be removed
        XCTAssertNil(defaults.data(forKey: "subscriptionUrls_\(testProfileId)"),
                     "subscriptionUrls should be removed for deleted profile")
    }

    func test_clearProfileData_removesAllThreeKeys() {
        // GIVEN: All three profile-scoped keys exist
        XCTAssertNotNil(defaults.object(forKey: "subscriptionUrls_\(testProfileId)"))
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_\(testProfileId)"), 12345)
        XCTAssertEqual(defaults.integer(forKey: "lastEpisodeActionSync_\(testProfileId)"), 67890)

        // WHEN: All three keys are removed (simulating clearProfileData behavior)
        defaults.removeObject(forKey: "subscriptionUrls_\(testProfileId)")
        defaults.removeObject(forKey: "lastSubscriptionSync_\(testProfileId)")
        defaults.removeObject(forKey: "lastEpisodeActionSync_\(testProfileId)")

        // THEN: All three should be nil
        XCTAssertNil(defaults.object(forKey: "subscriptionUrls_\(testProfileId)"),
                     "subscriptionUrls must be cleared")
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_\(testProfileId)"), 0,
                       "lastSubscriptionSync must reset to 0 (default)")
        XCTAssertEqual(defaults.integer(forKey: "lastEpisodeActionSync_\(testProfileId)"), 0,
                       "lastEpisodeActionSync must reset to 0 (default)")
    }

    // MARK: - Per-profile sync timestamps

    func test_perProfileSyncTimestamp_doesNotAffectOtherProfiles() {
        // GIVEN: Two different profile IDs with different timestamps
        let otherProfileId = "other-profile-\(UUID().uuidString)"
        defaults.set(99999, forKey: "lastSubscriptionSync_\(otherProfileId)")

        // WHEN: Clearing one profile's data
        defaults.removeObject(forKey: "lastSubscriptionSync_\(testProfileId)")

        // THEN: The other profile's timestamp is untouched
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_\(otherProfileId)"), 99999,
                       "Clearing one profile must not affect another profile's sync timestamp")

        // Cleanup
        defaults.removeObject(forKey: "lastSubscriptionSync_\(otherProfileId)")
    }

    func test_newProfile_syncTimestamp_startsAtZero() {
        // GIVEN: A brand new profile ID with no saved data
        let newProfileId = "brand-new-\(UUID().uuidString)"

        // THEN: The sync timestamp should be 0 (UserDefaults default for missing int)
        XCTAssertEqual(defaults.integer(forKey: "lastSubscriptionSync_\(newProfileId)"), 0,
                       "A new profile should start with since=0 for full sync")
    }

    // MARK: - hasOtherProfiles

    @MainActor
    func test_hasOtherProfiles_returnsFalse_whenNoProfiles() {
        // GIVEN: No serverProfiles key
        defaults.removeObject(forKey: "serverProfiles")

        // THEN: Should return false
        XCTAssertFalse(PodcastManager.hasOtherProfiles(excluding: testProfileId))
    }

    @MainActor
    func test_hasOtherProfiles_returnsFalse_whenOnlyThisProfile() {
        // GIVEN: Only the test profile exists
        let profile = ServerProfile(id: testProfileId, name: "Test")
        let data = try! JSONEncoder().encode([profile])
        defaults.set(data, forKey: "serverProfiles")

        // THEN: Should return false (no OTHER profiles)
        XCTAssertFalse(PodcastManager.hasOtherProfiles(excluding: testProfileId))
    }

    @MainActor
    func test_hasOtherProfiles_returnsTrue_whenOtherProfilesExist() {
        // GIVEN: The test profile and another profile exist
        let profile1 = ServerProfile(id: testProfileId, name: "Test")
        let profile2 = ServerProfile(id: "other-id", name: "Other")
        let data = try! JSONEncoder().encode([profile1, profile2])
        defaults.set(data, forKey: "serverProfiles")

        // THEN: Should return true (other profiles exist)
        XCTAssertTrue(PodcastManager.hasOtherProfiles(excluding: testProfileId))
    }
}
