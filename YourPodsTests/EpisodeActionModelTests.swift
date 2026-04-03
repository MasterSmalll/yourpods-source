import XCTest
@testable import YourPods

/// Tests for model enums and EpisodeAction identity/lookup logic.
/// Supplements EpisodeActionTests in YourPodsTests.swift (which covers JSON parsing,
/// toUploadJSON, and Codable round-trip) with enum validation and lookup-key tests.
final class EpisodeActionModelTests: XCTestCase {
    
    // MARK: - EpisodeAction GUID Lookup Key
    
    func test_episodeAction_guidFallsBackToEpisode() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: nil,
            action: "play",
            timestamp: 1700000000,
            position: 500,
            started: nil,
            total: nil,
            device: nil
        )
        
        let key = action.guid ?? action.episode
        XCTAssertEqual(key, "https://example.com/ep1.mp3",
                       "When guid is nil, the episode URL should be the lookup key")
    }
    
    func test_episodeAction_guidUsedWhenPresent() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: "ep-guid-1",
            action: "play",
            timestamp: 1700000000,
            position: 500,
            started: nil,
            total: nil,
            device: nil
        )
        
        let key = action.guid ?? action.episode
        XCTAssertEqual(key, "ep-guid-1",
                       "When guid is present, it should be the lookup key")
    }
    
    func test_episodeAction_identifiable_id() {
        let action = EpisodeAction(
            podcast: "https://example.com/feed",
            episode: "https://example.com/ep1.mp3",
            guid: nil,
            action: "play",
            timestamp: 1700000000,
            position: nil,
            started: nil,
            total: nil,
            device: nil
        )
        
        XCTAssertEqual(action.id, "https://example.com/feed|https://example.com/ep1.mp3|1700000000")
    }
    
    // MARK: - SyncStrategy
    
    func test_syncStrategy_rawValues() {
        XCTAssertEqual(SyncStrategy.serverWins.rawValue, "serverWins")
        XCTAssertEqual(SyncStrategy.deviceWins.rawValue, "deviceWins")
        XCTAssertEqual(SyncStrategy.ask.rawValue, "ask")
    }
    
    func test_syncStrategy_roundTrip() {
        for strategy in SyncStrategy.allCases {
            let decoded = SyncStrategy(rawValue: strategy.rawValue)
            XCTAssertEqual(decoded, strategy, "Round-trip failed for \(strategy)")
        }
    }
    
    func test_syncStrategy_allCasesCount() {
        XCTAssertEqual(SyncStrategy.allCases.count, 3)
    }
    
    // MARK: - QueueSyncStrategy
    
    func test_queueSyncStrategy_rawValues() {
        XCTAssertEqual(QueueSyncStrategy.serverWins.rawValue, "serverWins")
        XCTAssertEqual(QueueSyncStrategy.deviceWins.rawValue, "deviceWins")
        XCTAssertEqual(QueueSyncStrategy.ask.rawValue, "ask")
    }
    
    func test_queueSyncStrategy_allCasesCount() {
        XCTAssertEqual(QueueSyncStrategy.allCases.count, 3)
    }
    
    // MARK: - AutoQueueMode
    
    func test_autoQueueMode_allCases() {
        let all = AutoQueueMode.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.contains(.off))
        XCTAssertTrue(all.contains(.normal))
        XCTAssertTrue(all.contains(.priority))
    }
    
    func test_autoQueueMode_rawValues() {
        XCTAssertEqual(AutoQueueMode.off.rawValue, "off")
        XCTAssertEqual(AutoQueueMode.normal.rawValue, "normal")
        XCTAssertEqual(AutoQueueMode.priority.rawValue, "priority")
    }
    
    // MARK: - DownloadCleanupPolicy
    
    func test_downloadCleanupPolicy_allCases() {
        let all = DownloadCleanupPolicy.allCases
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(all.contains(.oncePlayed))
        XCTAssertTrue(all.contains(.afterOneWeek))
        XCTAssertTrue(all.contains(.afterOneMonth))
        XCTAssertTrue(all.contains(.never))
    }
    
    func test_downloadCleanupPolicy_rawValues() {
        XCTAssertEqual(DownloadCleanupPolicy.oncePlayed.rawValue, "oncePlayed")
        XCTAssertEqual(DownloadCleanupPolicy.afterOneWeek.rawValue, "afterOneWeek")
        XCTAssertEqual(DownloadCleanupPolicy.afterOneMonth.rawValue, "afterOneMonth")
        XCTAssertEqual(DownloadCleanupPolicy.never.rawValue, "never")
    }
    
    // MARK: - QueueRemovalAction
    
    func test_queueRemovalAction_rawValues() {
        XCTAssertEqual(QueueRemovalAction.removeOnly.rawValue, "removeOnly")
        XCTAssertEqual(QueueRemovalAction.removeAndMarkPlayed.rawValue, "removeAndMarkPlayed")
        XCTAssertEqual(QueueRemovalAction.ask.rawValue, "ask")
    }
    
    func test_queueRemovalAction_allCasesCount() {
        XCTAssertEqual(QueueRemovalAction.allCases.count, 3)
    }
    
    // MARK: - AppAppearance
    
    func test_appAppearance_colorScheme() {
        XCTAssertNil(AppAppearance.system.colorScheme, "System should return nil")
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }
    
    func test_appAppearance_allCasesCount() {
        XCTAssertEqual(AppAppearance.allCases.count, 3)
    }
    
    // MARK: - TabBarDisplayMode
    
    func test_tabBarDisplayMode_allCases() {
        let all = TabBarDisplayMode.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.contains(.textOnly))
        XCTAssertTrue(all.contains(.iconOnly))
        XCTAssertTrue(all.contains(.textAndIcon))
    }
    
    // MARK: - SearchProvider
    
    func test_searchProvider_allCases() {
        let all = SearchProvider.allCases
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains(.itunes))
        XCTAssertTrue(all.contains(.podcastIndex))
    }
    
    // MARK: - SyncConflict
    
    func test_syncConflict_identifiable_byGuid() {
        let conflict = SyncConflict(
            episodeGuid: "ep-1",
            episodeTitle: "Episode 1",
            podcastTitle: "Podcast",
            podcastUrl: "https://example.com/feed",
            artworkUrl: nil,
            audioUrl: nil,
            localPosition: 300,
            serverPosition: 600,
            serverTimestamp: 1700000000,
            totalDuration: 3600,
            occurrenceCount: 2
        )
        XCTAssertEqual(conflict.id, "ep-1")
    }
    
    func test_syncConflict_occurrenceCount_tracked() {
        let conflict = SyncConflict(
            episodeGuid: "ep-1",
            episodeTitle: nil,
            podcastTitle: nil,
            podcastUrl: nil,
            artworkUrl: nil,
            audioUrl: nil,
            localPosition: 100,
            serverPosition: 500,
            serverTimestamp: 1700000000,
            totalDuration: nil,
            occurrenceCount: 5
        )
        XCTAssertEqual(conflict.occurrenceCount, 5)
    }
}
