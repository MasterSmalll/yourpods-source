import XCTest
@testable import YourPods

/// Tests for KeychainHelper — save, read, update, and delete passwords in Keychain.
/// These tests use the real Keychain on the simulator, which is the most reliable
/// way to verify Security framework interactions.
final class KeychainHelperTests: XCTestCase {
    
    private let helper = KeychainHelper.shared
    private let testProfileId = "test-keychain-\(UUID().uuidString)"
    
    override func tearDown() {
        // Clean up any test entries
        helper.deletePassword(forProfileId: testProfileId)
        super.tearDown()
    }
    
    // MARK: - Save & Read
    
    func test_saveAndRetrievePassword() {
        // GIVEN: A password saved to Keychain
        let saved = helper.save(password: "s3cret!", forProfileId: testProfileId)
        XCTAssertTrue(saved, "save() should return true on success")
        
        // WHEN: Reading it back
        let result = helper.password(forProfileId: testProfileId)
        
        // THEN: It matches
        XCTAssertEqual(result, "s3cret!", "Password should round-trip through Keychain")
    }
    
    // MARK: - Overwrite
    
    func test_overwritePassword_updatesValue() {
        // GIVEN: An existing password
        helper.save(password: "old_pass", forProfileId: testProfileId)
        
        // WHEN: Overwriting with a new value
        let saved = helper.save(password: "new_pass", forProfileId: testProfileId)
        XCTAssertTrue(saved, "Overwrite should succeed")
        
        // THEN: The new value is returned
        XCTAssertEqual(helper.password(forProfileId: testProfileId), "new_pass")
    }
    
    // MARK: - Delete
    
    func test_deletePassword_removesEntry() {
        // GIVEN: A saved password
        helper.save(password: "to_delete", forProfileId: testProfileId)
        XCTAssertNotNil(helper.password(forProfileId: testProfileId))
        
        // WHEN: Deleting it
        helper.deletePassword(forProfileId: testProfileId)
        
        // THEN: It's gone
        XCTAssertNil(helper.password(forProfileId: testProfileId),
                     "Password should be nil after deletion")
    }
    
    // MARK: - Non-existent
    
    func test_passwordForNonexistentProfile_returnsNil() {
        // WHEN: Reading a password that was never saved
        let result = helper.password(forProfileId: "does-not-exist-\(UUID().uuidString)")
        
        // THEN: nil
        XCTAssertNil(result, "Should return nil for a profile that was never saved")
    }
    
    // MARK: - Delete non-existent (should not crash)
    
    func test_deleteNonexistentPassword_doesNotCrash() {
        // WHEN: Deleting a password that doesn't exist
        // THEN: No crash or error
        helper.deletePassword(forProfileId: "non-existent-\(UUID().uuidString)")
    }
    
    // MARK: - Empty password
    
    func test_saveEmptyPassword_roundTrips() {
        // Edge case: saving an empty string
        let saved = helper.save(password: "", forProfileId: testProfileId)
        XCTAssertTrue(saved)
        XCTAssertEqual(helper.password(forProfileId: testProfileId), "")
    }
}

// MARK: - Migration Tests

final class KeychainMigrationTests: XCTestCase {
    
    private let defaults = UserDefaults.standard
    private let helper = KeychainHelper.shared
    private let migrationKey = "keychainPasswordMigrationCompleted"
    private let testProfileId = "migration-test-\(UUID().uuidString)"
    
    override func setUp() {
        super.setUp()
        // Reset migration flag
        defaults.removeObject(forKey: migrationKey)
    }
    
    override func tearDown() {
        // Clean up
        defaults.removeObject(forKey: migrationKey)
        defaults.removeObject(forKey: "gpodder_password_\(testProfileId)")
        defaults.removeObject(forKey: "serverProfiles")
        helper.deletePassword(forProfileId: testProfileId)
        super.tearDown()
    }
    
    func test_migration_movesPasswordFromUserDefaultsToKeychain() {
        // GIVEN: A profile with a password in UserDefaults
        let profile = ServerProfile(
            id: testProfileId,
            name: "Test Server",
            baseUrl: "https://example.com",
            username: "user"
        )
        let encoded = try! JSONEncoder().encode([profile])
        defaults.set(encoded, forKey: "serverProfiles")
        defaults.set("secret_password", forKey: "gpodder_password_\(testProfileId)")
        
        // WHEN: Running migration
        KeychainHelper.migrateFromUserDefaultsIfNeeded()
        
        // THEN: Password is in Keychain
        XCTAssertEqual(helper.password(forProfileId: testProfileId), "secret_password",
                       "Password should be moved to Keychain")
        
        // AND: Removed from UserDefaults
        XCTAssertNil(defaults.string(forKey: "gpodder_password_\(testProfileId)"),
                     "Password should be removed from UserDefaults after migration")
        
        // AND: Migration flag is set
        XCTAssertTrue(defaults.bool(forKey: migrationKey))
    }
    
    func test_migration_skipsIfAlreadyDone() {
        // GIVEN: Migration flag is already set
        defaults.set(true, forKey: migrationKey)
        defaults.set("should_stay", forKey: "gpodder_password_\(testProfileId)")
        
        // WHEN: Running migration
        KeychainHelper.migrateFromUserDefaultsIfNeeded()
        
        // THEN: UserDefaults password is untouched (migration was skipped)
        XCTAssertEqual(defaults.string(forKey: "gpodder_password_\(testProfileId)"), "should_stay",
                       "Migration should be skipped when flag is already set")
    }
}

// MARK: - Feed Credential Tests

final class FeedCredentialTests: XCTestCase {
    
    private let helper = KeychainHelper.shared
    private let testFeedUrl = "https://example.com/feed-\(UUID().uuidString)"
    
    override func tearDown() {
        helper.deleteFeedCredentials(forPodcastUrl: testFeedUrl)
        super.tearDown()
    }
    
    // MARK: - Save & Read
    
    func test_saveFeedCredentials_roundTrips() {
        // GIVEN: Credentials saved for a feed URL
        let saved = helper.saveFeedCredentials(username: "alice", password: "t0p$ecret", forPodcastUrl: testFeedUrl)
        XCTAssertTrue(saved, "saveFeedCredentials should return true on success")
        
        // WHEN: Reading them back
        let creds = helper.feedCredentials(forPodcastUrl: testFeedUrl)
        
        // THEN: They match
        XCTAssertNotNil(creds, "Credentials should be retrievable")
        XCTAssertEqual(creds?.username, "alice")
        XCTAssertEqual(creds?.password, "t0p$ecret")
    }
    
    // MARK: - Overwrite
    
    func test_overwriteFeedCredentials_updatesValue() {
        // GIVEN: Existing credentials
        helper.saveFeedCredentials(username: "old_user", password: "old_pass", forPodcastUrl: testFeedUrl)
        
        // WHEN: Overwriting
        let saved = helper.saveFeedCredentials(username: "new_user", password: "new_pass", forPodcastUrl: testFeedUrl)
        XCTAssertTrue(saved)
        
        // THEN: New values returned
        let creds = helper.feedCredentials(forPodcastUrl: testFeedUrl)
        XCTAssertEqual(creds?.username, "new_user")
        XCTAssertEqual(creds?.password, "new_pass")
    }
    
    // MARK: - Delete
    
    func test_deleteFeedCredentials_removesEntry() {
        // GIVEN: Saved credentials
        helper.saveFeedCredentials(username: "user", password: "pass", forPodcastUrl: testFeedUrl)
        XCTAssertNotNil(helper.feedCredentials(forPodcastUrl: testFeedUrl))
        
        // WHEN: Deleting
        helper.deleteFeedCredentials(forPodcastUrl: testFeedUrl)
        
        // THEN: Gone
        XCTAssertNil(helper.feedCredentials(forPodcastUrl: testFeedUrl),
                     "Credentials should be nil after deletion")
    }
    
    // MARK: - Basic Auth Header
    
    func test_buildBasicAuthHeader_encodesCorrectly() {
        // GIVEN: Stored credentials
        helper.saveFeedCredentials(username: "user", password: "pass", forPodcastUrl: testFeedUrl)
        
        // WHEN: Building the auth header
        let header = helper.buildBasicAuthHeader(forPodcastUrl: testFeedUrl)
        
        // THEN: It's a valid Basic auth header with correct Base64
        XCTAssertNotNil(header)
        let expected = "Basic " + Data("user:pass".utf8).base64EncodedString()
        XCTAssertEqual(header, expected)
    }
    
    func test_buildBasicAuthHeader_returnsNil_whenNoCredentials() {
        // WHEN: No credentials stored
        let header = helper.buildBasicAuthHeader(forPodcastUrl: "https://no-creds-\(UUID().uuidString)")
        
        // THEN: nil
        XCTAssertNil(header, "Should return nil when no credentials stored")
    }
    
    // MARK: - QueueItem authHeaders serialization
    
    func test_queueItem_authHeaders_notSerialized() {
        // GIVEN: A QueueItem with authHeaders set
        var item = QueueItem(
            id: "test-guid",
            title: "Test Episode",
            podcastTitle: "Test Podcast",
            audioUrl: "https://example.com/ep.mp3",
            artworkUrl: nil,
            durationSeconds: 3600,
            positionSeconds: 0,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        item.authHeaders = ["Authorization": "Basic dXNlcjpwYXNz"]
        
        // WHEN: Encoding and decoding
        let data = try! JSONEncoder().encode(item)
        let decoded = try! JSONDecoder().decode(QueueItem.self, from: data)
        
        // THEN: authHeaders is nil after decode (excluded from CodingKeys)
        XCTAssertNil(decoded.authHeaders,
                     "authHeaders must not be persisted — they should be re-populated from Keychain")
    }
    
    // MARK: - Delete non-existent (should not crash)
    
    func test_deleteNonexistentFeedCredentials_doesNotCrash() {
        // WHEN/THEN: No crash
        helper.deleteFeedCredentials(forPodcastUrl: "https://no-such-feed-\(UUID().uuidString)")
    }
}
