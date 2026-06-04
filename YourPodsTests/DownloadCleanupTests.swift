import XCTest
@testable import YourPods

@MainActor
final class DownloadCleanupTests: XCTestCase {
    
    // MARK: - PodcastSettings migration
    
    func test_podcastSettings_migratesLegacyBoolTrue() throws {
        // GIVEN: JSON with the old removeDownloadAfterPlay = true
        let json = """
        {"removeDownloadAfterPlay": true}
        """
        let data = json.data(using: .utf8)!
        
        // WHEN: Decoded as PodcastSettings
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: Should migrate to .oncePlayed
        XCTAssertEqual(settings.downloadCleanupPolicy, .oncePlayed)
    }
    
    func test_podcastSettings_migratesLegacyBoolFalse() throws {
        // GIVEN: JSON with the old removeDownloadAfterPlay = false
        let json = """
        {"removeDownloadAfterPlay": false}
        """
        let data = json.data(using: .utf8)!
        
        // WHEN: Decoded
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: Should be nil (use global default)
        XCTAssertNil(settings.downloadCleanupPolicy)
    }
    
    func test_podcastSettings_decodesNewPolicy() throws {
        // GIVEN: JSON with the new downloadCleanupPolicy
        let json = """
        {"downloadCleanupPolicy": "afterOneWeek"}
        """
        let data = json.data(using: .utf8)!
        
        // WHEN: Decoded
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: Should decode correctly
        XCTAssertEqual(settings.downloadCleanupPolicy, .afterOneWeek)
    }
    
    func test_podcastSettings_newPolicyTakesPrecedenceOverLegacy() throws {
        // GIVEN: JSON with BOTH old and new keys (shouldn't happen, but defensive)
        let json = """
        {"removeDownloadAfterPlay": true, "downloadCleanupPolicy": "never"}
        """
        let data = json.data(using: .utf8)!
        
        // WHEN: Decoded
        let settings = try JSONDecoder().decode(PodcastSettings.self, from: data)
        
        // THEN: New key should win
        XCTAssertEqual(settings.downloadCleanupPolicy, .never)
    }
    
    func test_podcastSettings_encodesNewKeyOnly() throws {
        // GIVEN: Settings with a cleanup policy
        var settings = PodcastSettings()
        settings.downloadCleanupPolicy = .afterOneMonth
        
        // WHEN: Encoded
        let data = try JSONEncoder().encode(settings)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        // THEN: Should use new key, not legacy
        XCTAssertEqual(json["downloadCleanupPolicy"] as? String, "afterOneMonth")
        XCTAssertNil(json["removeDownloadAfterPlay"])
    }
    
    // MARK: - DownloadCleanupPolicy display names
    
    func test_policyDisplayNames() {
        XCTAssertEqual(DownloadCleanupPolicy.oncePlayed.displayName, "Once Played")
        XCTAssertEqual(DownloadCleanupPolicy.afterOneWeek.displayName, "After 1 Week")
        XCTAssertEqual(DownloadCleanupPolicy.afterOneMonth.displayName, "After 1 Month")
        XCTAssertEqual(DownloadCleanupPolicy.never.displayName, "Never")
    }
    
    // MARK: - DownloadManager.cleanupExpiredDownloads
    
    func test_cleanupExpiredDownloads_deletesWeekOld() {
        // GIVEN: A download manager with a download played 8 days ago
        let dm = DownloadManager()
        let guid = "test-ep-1"
        
        // Simulate a downloaded file
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testFile = testDir.appendingPathComponent("test.mp3")
        try? Data("fake audio".utf8).write(to: testFile)
        dm.downloadedFiles[guid] = testFile
        
        // Set played date to 8 days ago
        dm.playedDates[guid] = Date().addingTimeInterval(-8 * 24 * 3600)
        
        // WHEN: Cleanup runs with afterOneWeek policy
        dm.cleanupExpiredDownloads(globalPolicy: .afterOneWeek, podcastPolicies: [:])
        
        // THEN: Download should be removed
        XCTAssertNil(dm.downloadedFiles[guid], "Week-old download should be cleaned up")
        XCTAssertNil(dm.playedDates[guid], "Played date should be cleaned up")
        
        // Cleanup
        try? FileManager.default.removeItem(at: testDir)
    }
    
    func test_cleanupExpiredDownloads_keepsRecentDownload() {
        // GIVEN: A download manager with a download played 3 days ago
        let dm = DownloadManager()
        let guid = "test-ep-2"
        
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testFile = testDir.appendingPathComponent("test2.mp3")
        try? Data("fake audio".utf8).write(to: testFile)
        dm.downloadedFiles[guid] = testFile
        
        dm.playedDates[guid] = Date().addingTimeInterval(-3 * 24 * 3600)
        
        // WHEN: Cleanup runs with afterOneWeek policy
        dm.cleanupExpiredDownloads(globalPolicy: .afterOneWeek, podcastPolicies: [:])
        
        // THEN: Download should be kept (only 3 days old)
        XCTAssertNotNil(dm.downloadedFiles[guid], "3-day-old download should be kept under 1-week policy")
        
        // Cleanup
        try? FileManager.default.removeItem(at: testDir)
    }
    
    func test_cleanupExpiredDownloads_perPodcastOverridesGlobal() {
        // GIVEN: Global policy is .never, but per-podcast is .oncePlayed
        let dm = DownloadManager()
        let guid = "test-ep-3"
        
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testFile = testDir.appendingPathComponent("test3.mp3")
        try? Data("fake audio".utf8).write(to: testFile)
        dm.downloadedFiles[guid] = testFile
        
        dm.playedDates[guid] = Date() // Just played
        
        // WHEN: Cleanup with global=never but per-podcast=oncePlayed
        dm.cleanupExpiredDownloads(
            globalPolicy: .never,
            podcastPolicies: [guid: .oncePlayed]
        )
        
        // THEN: Per-podcast policy wins — download should be deleted
        XCTAssertNil(dm.downloadedFiles[guid], "Per-podcast .oncePlayed should override global .never")
        
        try? FileManager.default.removeItem(at: testDir)
    }
    
    func test_cleanupExpiredDownloads_neverPolicyKeepsEverything() {
        // GIVEN: A download played months ago with .never policy
        let dm = DownloadManager()
        let guid = "test-ep-4"
        
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testFile = testDir.appendingPathComponent("test4.mp3")
        try? Data("fake audio".utf8).write(to: testFile)
        dm.downloadedFiles[guid] = testFile
        
        dm.playedDates[guid] = Date().addingTimeInterval(-365 * 24 * 3600) // 1 year ago
        
        // WHEN: Cleanup with .never
        dm.cleanupExpiredDownloads(globalPolicy: .never, podcastPolicies: [:])
        
        // THEN: Should not delete
        XCTAssertNotNil(dm.downloadedFiles[guid], "Never policy should keep downloads forever")
        
        try? FileManager.default.removeItem(at: testDir)
    }
    
    // MARK: - markPlayed guard
    
    func test_markPlayed_ignoresNonDownloadedEpisode() {
        // GIVEN: A download manager with no downloads
        let dm = DownloadManager()
        
        // WHEN: markPlayed is called for a non-downloaded episode
        dm.markPlayed(guid: "not-downloaded")
        
        // THEN: Should not track it
        XCTAssertNil(dm.playedDates["not-downloaded"])
    }
}
