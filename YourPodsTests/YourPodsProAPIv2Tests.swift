import XCTest
import SwiftData
@testable import YourPods

// MARK: - Pro Models v2 — Codable Round-Trips

/// Tests for all new API v2 models added in the Groups + Settings v2 update.
final class YourPodsProModelsV2Tests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - ProGroup

    func test_proGroup_codableRoundTrip_preservesAllFields() throws {
        let group = ProGroup(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "News",
            sortOrder: 0,
            iconName: "newspaper.fill",
            colorHex: "#FF5733"
        )

        let data = try encoder.encode(group)
        let decoded = try decoder.decode(ProGroup.self, from: data)

        XCTAssertEqual(decoded.id, group.id)
        XCTAssertEqual(decoded.name, group.name)
        XCTAssertEqual(decoded.sortOrder, group.sortOrder)
        XCTAssertEqual(decoded.iconName, group.iconName)
        XCTAssertEqual(decoded.colorHex, group.colorHex)
    }

    func test_proGroup_decodesNullIconName_asNil() throws {
        let json = """
        {"id":"abc","name":"Comedy","sortOrder":1,"iconName":null,"colorHex":null}
        """.data(using: .utf8)!

        let decoded = try decoder.decode(ProGroup.self, from: json)
        XCTAssertNil(decoded.iconName)
        XCTAssertNil(decoded.colorHex)
    }

    // MARK: - ProGroupAssignment

    func test_proGroupAssignment_codableRoundTrip() throws {
        let assignment = ProGroupAssignment(
            podcastUrl: "https://feeds.example.com/news.xml",
            groupId: "550e8400-e29b-41d4-a716-446655440000"
        )

        let data = try encoder.encode(assignment)
        let decoded = try decoder.decode(ProGroupAssignment.self, from: data)

        XCTAssertEqual(decoded.podcastUrl, assignment.podcastUrl)
        XCTAssertEqual(decoded.groupId, assignment.groupId)
    }

    func test_proGroupAssignment_codableRoundTrip_nilGroupId() throws {
        let assignment = ProGroupAssignment(
            podcastUrl: "https://feeds.example.com/tech.xml",
            groupId: nil
        )

        let data = try encoder.encode(assignment)
        let decoded = try decoder.decode(ProGroupAssignment.self, from: data)

        XCTAssertNil(decoded.groupId, "nil groupId (ungrouped) must survive round-trip")
    }

    // MARK: - ProGroupsResponse

    func test_proGroupsResponse_decodesFromAPIShape() throws {
        let json = """
        {
            "profileName": "yourpodspro",
            "groups": [
                {"id":"aaa","name":"News","sortOrder":0,"iconName":"newspaper.fill","colorHex":null},
                {"id":"bbb","name":"Comedy","sortOrder":1,"iconName":"theatermasks.fill","colorHex":null}
            ],
            "timestamp": "2026-04-15T22:00:00Z"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProGroupsResponse.self, from: json)

        XCTAssertEqual(response.profileName, "yourpodspro")
        XCTAssertEqual(response.groups.count, 2)
        XCTAssertEqual(response.groups[0].name, "News")
        XCTAssertEqual(response.groups[1].name, "Comedy")
        XCTAssertEqual(response.timestamp, "2026-04-15T22:00:00Z")
    }

    // MARK: - ProGroupAssignmentsResponse

    func test_proGroupAssignmentsResponse_decodesFromAPIShape() throws {
        let json = """
        {
            "profileName": "yourpodspro",
            "assignments": [
                {"podcastUrl":"https://feeds.example.com/news.xml","groupId":"aaa"},
                {"podcastUrl":"https://feeds.example.com/tech.xml","groupId":"bbb"}
            ],
            "timestamp": "2026-04-15T22:00:00Z"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProGroupAssignmentsResponse.self, from: json)

        XCTAssertEqual(response.profileName, "yourpodspro")
        XCTAssertEqual(response.assignments.count, 2)
        XCTAssertEqual(response.assignments[0].podcastUrl, "https://feeds.example.com/news.xml")
        XCTAssertEqual(response.assignments[0].groupId, "aaa")
    }

    // MARK: - ProProfileSettings

    func test_proProfileSettings_decodesFromAPIShape() throws {
        let json = """
        {
            "profileName": "yourpodspro",
            "payload": {
                "playbackSpeed": 1.5,
                "trimSilence": true,
                "skipForwardSec": 30
            },
            "updatedAt": "2026-04-15T22:00:00Z"
        }
        """.data(using: .utf8)!

        let settings = try decoder.decode(ProProfileSettings.self, from: json)

        XCTAssertEqual(settings.profileName, "yourpodspro")
        XCTAssertNotNil(settings.payload)
        XCTAssertEqual(settings.payload?["playbackSpeed"], .double(1.5))
        XCTAssertEqual(settings.payload?["trimSilence"], .bool(true))
        XCTAssertEqual(settings.payload?["skipForwardSec"], .int(30))
    }

    func test_proProfileSettings_decodesNullPayload() throws {
        let json = """
        {"profileName":"yourpodspro","payload":null,"updatedAt":null}
        """.data(using: .utf8)!

        let settings = try decoder.decode(ProProfileSettings.self, from: json)
        XCTAssertNil(settings.payload)
    }

    // MARK: - ProPodcastSetting resolvedPayload

    func test_proPodcastSetting_resolvedPayload_prefersPayloadOverSettings() throws {
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "payload": {"skipIntroSec": 45},
            "settings": {"skipIntroSec": 10},
            "updatedAt": null
        }
        """.data(using: .utf8)!

        let setting = try decoder.decode(ProPodcastSetting.self, from: json)
        XCTAssertEqual(setting.resolvedPayload["skipIntroSec"], .int(45),
                       "payload field takes priority over legacy settings field")
    }

    func test_proPodcastSetting_resolvedPayload_fallsBackToSettings() throws {
        let json = """
        {
            "podcastUrl": "https://example.com/feed",
            "settings": {"skipIntroSec": 30},
            "updatedAt": null
        }
        """.data(using: .utf8)!

        let setting = try decoder.decode(ProPodcastSetting.self, from: json)
        XCTAssertEqual(setting.resolvedPayload["skipIntroSec"], .int(30),
                       "should fall back to legacy settings key when payload is absent")
    }

    // MARK: - ProSubscriptionRemoveRequest

    func test_proSubscriptionRemoveRequest_encodesCorrectly() throws {
        let request = ProSubscriptionRemoveRequest(podcastUrl: "https://feeds.example.com/podcast.xml")
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["podcastUrl"] as? String, "https://feeds.example.com/podcast.xml")
        XCTAssertNil(json?["url"], "should not encode extra url field")
        XCTAssertNil(json?["feedUrl"], "should not encode feedUrl field")
    }

    // MARK: - ProStatsResponse

    func test_proStatsResponse_decodesFromAPIShape() throws {
        let json = """
        {
            "tier": "pro",
            "streak": 12,
            "stats": {
                "totalListenTimeSec": 86400.0,
                "totalContentTimeSec": 172800.0,
                "totalSkippedSec": 3600.0,
                "manualSkipsSec": 2400.0,
                "autoSkipsSec": 1200.0,
                "chapterSkipsSec": 0.0,
                "manualSkipCount": 150,
                "autoSkipCount": 80,
                "chapterSkipCount": 0,
                "uniqueEpisodes": 42,
                "uniquePodcasts": 8
            },
            "topPodcasts": [
                {"podcastUrl": "https://example.com", "listenTimeSec": 36000.0, "episodeCount": 12}
            ],
            "since": "0001-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProStatsResponse.self, from: json)

        XCTAssertEqual(response.tier, "pro")
        XCTAssertEqual(response.streak, 12)
        XCTAssertEqual(response.stats.totalListenTimeSec, 86400.0)
        XCTAssertEqual(response.stats.manualSkipCount, 150)
        XCTAssertEqual(response.topPodcasts?.count, 1)
        XCTAssertEqual(response.topPodcasts?[0].episodeCount, 12)
    }

    func test_proStatsResponse_decodesSyncTierResponse() throws {
        let json = """
        {
            "tier": "sync",
            "since": "0001-01-01T00:00:00Z",
            "streak": 5,
            "stats": {
                "totalListenTimeSec": 86400.0,
                "uniqueEpisodes": 42,
                "uniquePodcasts": 8
            }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProStatsResponse.self, from: json)

        XCTAssertEqual(response.tier, "sync")
        XCTAssertEqual(response.streak, 5)
        XCTAssertEqual(response.stats.totalListenTimeSec, 86400.0)
        XCTAssertEqual(response.stats.uniqueEpisodes, 42)
        XCTAssertEqual(response.stats.uniquePodcasts, 8)
        // Pro-only fields must be nil for sync tier
        XCTAssertNil(response.stats.totalContentTimeSec,
                     "Sync tier must not include totalContentTimeSec")
        XCTAssertNil(response.stats.totalSkippedSec,
                     "Sync tier must not include totalSkippedSec")
        XCTAssertNil(response.stats.manualSkipCount,
                     "Sync tier must not include manualSkipCount")
        XCTAssertNil(response.topPodcasts,
                     "Sync tier must not include topPodcasts")
        XCTAssertNil(response.dailyTrend,
                     "Sync tier must not include dailyTrend")
    }

    func test_proStatsResponse_decodesProTierWithDailyTrend() throws {
        let json = """
        {
            "tier": "pro",
            "since": "2026-04-01T00:00:00Z",
            "streak": 30,
            "stats": {
                "totalListenTimeSec": 86400.0,
                "totalContentTimeSec": 90000.0,
                "totalSkippedSec": 3600.0,
                "manualSkipsSec": 1200.0,
                "autoSkipsSec": 1800.0,
                "chapterSkipsSec": 600.0,
                "manualSkipCount": 45,
                "autoSkipCount": 120,
                "chapterSkipCount": 15,
                "uniqueEpisodes": 42,
                "uniquePodcasts": 8
            },
            "topPodcasts": [
                {"podcastUrl": "https://feed.example.com/rss", "listenTimeSec": 14400.0, "episodeCount": 12}
            ],
            "dailyTrend": [
                {"date": "2026-05-04", "listenTimeSec": 3600.0, "episodeCount": 3},
                {"date": "2026-05-05", "listenTimeSec": 5400.0, "episodeCount": 5}
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ProStatsResponse.self, from: json)

        XCTAssertEqual(response.tier, "pro")
        XCTAssertEqual(response.streak, 30)
        XCTAssertEqual(response.dailyTrend?.count, 2)
        XCTAssertEqual(response.dailyTrend?[0].date, "2026-05-04")
        XCTAssertEqual(response.dailyTrend?[0].listenTimeSec, 3600.0)
        XCTAssertEqual(response.dailyTrend?[0].episodeCount, 3)
        XCTAssertEqual(response.dailyTrend?[1].listenTimeSec, 5400.0)
        XCTAssertEqual(response.topPodcasts?.count, 1)
        XCTAssertEqual(response.topPodcasts?[0].episodeCount, 12)
        // Pro-only fields present
        XCTAssertEqual(response.stats.totalContentTimeSec, 90000.0)
        XCTAssertEqual(response.stats.totalSkippedSec, 3600.0)
        XCTAssertEqual(response.stats.manualSkipCount, 45)
    }

    func test_dailyTrendEntry_decodesFromAPIShape() throws {
        let json = """
        {"date": "2026-05-05", "listenTimeSec": 7200.5, "episodeCount": 6}
        """.data(using: .utf8)!

        let entry = try decoder.decode(DailyTrendEntry.self, from: json)

        XCTAssertEqual(entry.date, "2026-05-05")
        XCTAssertEqual(entry.listenTimeSec, 7200.5)
        XCTAssertEqual(entry.episodeCount, 6)
        XCTAssertEqual(entry.id, "2026-05-05", "id should derive from date")
    }

    func test_statsPeriod_mapsToCorrectSinceDate() {
        // All time → nil
        XCTAssertNil(StatsPeriod.allTime.sinceDate,
                     "All Time should return nil since date")

        // Week → ~7 days ago
        let weekDate = StatsPeriod.week.sinceDate!
        let weekInterval = Date.now.timeIntervalSince(weekDate)
        XCTAssertEqual(weekInterval, 7 * 86400, accuracy: 120,
                       "Week period should be ~7 days ago")

        // Month → ~30 days ago
        let monthDate = StatsPeriod.month.sinceDate!
        let monthInterval = Date.now.timeIntervalSince(monthDate)
        XCTAssertGreaterThan(monthInterval, 27 * 86400,
                             "Month period should be at least 27 days ago")
        XCTAssertLessThan(monthInterval, 32 * 86400,
                          "Month period should be at most 31 days ago")

        // Year → ~365 days ago
        let yearDate = StatsPeriod.year.sinceDate!
        let yearInterval = Date.now.timeIntervalSince(yearDate)
        XCTAssertGreaterThan(yearInterval, 364 * 86400,
                             "Year period should be at least 364 days ago")
    }

    // MARK: - ProStatsEvent

    func test_proStatsEvent_listenEvent_encodesEventType() throws {
        let event = ProStatsEvent(
            podcastUrl: "https://feeds.example.com/podcast.xml",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: "abc-123",
            eventType: .listen,
            fromPosSec: 0,
            toPosSec: 120.5,
            durationSec: 60.25,
            contentSec: 120.5,
            speed: 2.0,
            deviceId: "yourpods-ios"
        )

        let data = try encoder.encode(event)
        let decoded = try decoder.decode(ProStatsEvent.self, from: data)

        XCTAssertEqual(decoded.eventType, .listen)
        XCTAssertEqual(decoded.speed, 2.0)
        XCTAssertEqual(decoded.toPosSec, 120.5)
    }

    func test_proStatsEvent_skipManual_encodesCorrectRawValue() throws {
        let event = ProStatsEvent(
            podcastUrl: nil,
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: nil,
            eventType: .skipManual,
            fromPosSec: 120.5,
            toPosSec: 150.5,
            durationSec: 0,
            contentSec: 30.0,
            speed: 1.0,
            deviceId: "yourpods-ios"
        )

        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["eventType"] as? String, "skip_manual",
                       "ProStatsEventType.skipManual must serialize as 'skip_manual'")
    }
}

// MARK: - StatsEventBuffer

/// TDD tests for the stats event buffer actor.
/// Phase 1 (Red): These will fail until StatsEventBuffer is implemented.
final class StatsEventBufferTests: XCTestCase {

    private func makeEvent(type: ProStatsEventType = .listen) -> ProStatsEvent {
        ProStatsEvent(
            podcastUrl: "https://feeds.example.com/podcast.xml",
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            episodeGuid: "abc-123",
            eventType: type,
            fromPosSec: 0,
            toPosSec: 60,
            durationSec: 30,
            contentSec: 60,
            speed: 2.0,
            deviceId: "yourpods-ios"
        )
    }

    func test_recordEvent_accumulatesInBuffer() async {
        let buffer = StatsEventBuffer()

        await buffer.record(makeEvent())
        await buffer.record(makeEvent())

        let pending = await buffer.pending
        XCTAssertEqual(pending.count, 2, "Should have 2 buffered events after 2 records")
    }

    func test_flush_returnsAllPendingEvents() async {
        let buffer = StatsEventBuffer()

        await buffer.record(makeEvent(type: .listen))
        await buffer.record(makeEvent(type: .skipManual))

        let flushed = await buffer.flush()

        XCTAssertEqual(flushed.count, 2)
        XCTAssertEqual(flushed[0].eventType, .listen)
        XCTAssertEqual(flushed[1].eventType, .skipManual)
    }

    func test_flush_clearsPendingBuffer() async {
        let buffer = StatsEventBuffer()

        await buffer.record(makeEvent())
        _ = await buffer.flush()

        let remaining = await buffer.pending
        XCTAssertTrue(remaining.isEmpty, "Buffer should be empty after successful flush")
    }

    func test_flush_emptyBuffer_returnsEmptyArray() async {
        let buffer = StatsEventBuffer()
        let flushed = await buffer.flush()
        XCTAssertTrue(flushed.isEmpty, "Flushing an empty buffer should return empty array")
    }

    func test_retainOnFailure_restoresEventsAfterFlushFailed() async {
        let buffer = StatsEventBuffer()

        let event1 = makeEvent(type: .listen)
        let event2 = makeEvent(type: .skipAuto)
        await buffer.record(event1)
        await buffer.record(event2)

        // Simulate flush that will "fail" — grab events, then restore
        let flushed = await buffer.flush()
        // Simulated failure: re-enqueue returned events
        await buffer.restore(flushed)

        let pending = await buffer.pending
        XCTAssertEqual(pending.count, 2, "Events should be restored after a failed flush")
    }
}

// MARK: - Groups Sync First-Pull Guard

/// Tests for the groups first-pull guard logic in PodcastManager.
/// Phase 1 (Red): These will fail until the sync logic is wired up.
@MainActor
final class GroupsFirstPullTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-groups"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "podcastGroups_\(testProfileId)")
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        manager = PodcastManager(modelContext: context)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "podcastGroups_\(testProfileId)")
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        manager = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    /// When local groups are empty, server groups should be applied on first pull.
    func test_applyServerGroups_whenLocalIsEmpty_appliesServerGroups() {
        let serverGroups = [
            ProGroup(id: "aaa", name: "News", sortOrder: 0, iconName: "newspaper.fill", colorHex: nil),
            ProGroup(id: "bbb", name: "Comedy", sortOrder: 1, iconName: "theatermasks.fill", colorHex: nil)
        ]

        manager.applyServerGroups(serverGroups, profileId: testProfileId)

        let local = PodcastGroup.loadGroups(forProfileId: testProfileId)
        XCTAssertEqual(local.count, 2, "Server groups should apply when local is empty")
        XCTAssertEqual(local[0].name, "News")
        XCTAssertEqual(local[1].name, "Comedy")
    }

    /// When local groups already exist, server groups should NOT overwrite them.
    func test_applyServerGroups_whenLocalExists_doesNotOverwrite() {
        // Pre-populate local groups
        let existingGroups = [PodcastGroup(name: "My Local Group", sortOrder: 0)]
        PodcastGroup.saveGroups(existingGroups, forProfileId: testProfileId)

        let serverGroups = [
            ProGroup(id: "aaa", name: "News (from server)", sortOrder: 0, iconName: nil, colorHex: nil)
        ]

        manager.applyServerGroups(serverGroups, profileId: testProfileId)

        let local = PodcastGroup.loadGroups(forProfileId: testProfileId)
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(local[0].name, "My Local Group",
                       "Local groups must win when they already exist (device wins)")
    }

    /// Server assignment should apply only for podcasts with nil groupId.
    func test_applyServerAssignments_onlyForUngroupedPodcasts() {
        // Insert two podcasts: one already has a group, one doesn't
        let podGrouped = Podcast(url: "https://already.com/feed", title: "Already Grouped")
        podGrouped.groupId = "existing-local-group"
        let podUngrouped = Podcast(url: "https://ungrouped.com/feed", title: "Ungrouped")

        context.insert(podGrouped)
        context.insert(podUngrouped)
        try! context.save()

        // Associate with profile so loadSubscriptions picks them up
        manager.associateWithCurrentProfile(url: "https://already.com/feed")
        manager.associateWithCurrentProfile(url: "https://ungrouped.com/feed")
        manager.loadSubscriptions()

        let assignments = [
            ProGroupAssignment(podcastUrl: "https://already.com/feed", groupId: "server-group"),
            ProGroupAssignment(podcastUrl: "https://ungrouped.com/feed", groupId: "server-group")
        ]

        manager.applyServerGroupAssignments(assignments)

        // The already-grouped podcast should keep its local groupId
        XCTAssertEqual(podGrouped.groupId, "existing-local-group",
                       "Server must not overwrite an existing local groupId")
        // The ungrouped podcast should get the server groupId
        XCTAssertEqual(podUngrouped.groupId, "server-group",
                       "Server groupId should apply for ungrouped podcasts")
    }

    /// Groups push should include all local groups as ProGroup array.
    func test_buildGroupsForSync_returnsAllLocalGroups() {
        let localGroups = [
            PodcastGroup(id: "ccc", name: "Tech", sortOrder: 0, iconName: "desktopcomputer"),
            PodcastGroup(id: "ddd", name: "Science", sortOrder: 1, iconName: "brain.head.profile")
        ]
        PodcastGroup.saveGroups(localGroups, forProfileId: testProfileId)

        let proGroups = manager.buildGroupsForSync(profileId: testProfileId)

        XCTAssertEqual(proGroups.count, 2)
        XCTAssertEqual(proGroups[0].id, "ccc")
        XCTAssertEqual(proGroups[1].id, "ddd")
    }

    /// Assignments push should include every subscribed podcast's groupId.
    func test_buildGroupAssignmentsForSync_includesAllPodcasts() {
        let pod1 = Podcast(url: "https://news.com/feed", title: "News Podcast")
        pod1.groupId = "aaa"
        let pod2 = Podcast(url: "https://tech.com/feed", title: "Tech Podcast")
        // pod2 ungrouped

        context.insert(pod1)
        context.insert(pod2)
        try! context.save()

        // Associate both with the test profile (required for loadSubscriptions to pick them up)
        manager.associateWithCurrentProfile(url: "https://news.com/feed")
        manager.associateWithCurrentProfile(url: "https://tech.com/feed")
        manager.loadSubscriptions()

        let assignments = manager.buildGroupAssignmentsForSync()

        // Only grouped podcasts should be included (ungrouped = omitted per spec)
        XCTAssertEqual(assignments.count, 1, "Only grouped podcasts should be in the sync payload")
        XCTAssertEqual(assignments[0].podcastUrl, "https://news.com/feed")
        XCTAssertEqual(assignments[0].groupId, "aaa")
    }
}

// MARK: - Groups Sync Order (Push-Before-Pull)

/// Regression tests for the "delete bounces back" bug.
///
/// **Root cause:** On first-time Pro sync, local groups are empty.
/// `applyServerGroups` fills local with the server's (possibly stale) state.
/// Then `buildGroupsForSync` pushes that stale state back — a deletion
/// made on another device is permanently lost.
///
/// **Correct order:** Always PUSH local first, then accept server response.
///
/// The fix lives in `PodcastManager.syncGroupsPushThenPull(profileName:client:)`,
/// a new method that:
///   1. Pushes local groups to server
///   2. Applies server response (server is now consistent with local)
///
/// Phase 1 (Red): `test_syncGroupsPushThenPull` will fail until that method exists.
@MainActor
final class GroupsSyncOrderTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-profile-order"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "podcastGroups_\(testProfileId)")
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        manager = PodcastManager(modelContext: context)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "podcastGroups_\(testProfileId)")
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        manager = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - First-time sync regression

    /// Scenario: Brand-new device has no local groups.
    /// Server has [News, Comedy] from another device.
    /// Expected (correct): Local adopts server groups (first-pull is fine here — no deletion to preserve).
    ///
    /// This is the VALID first-pull case — not a bug.
    func test_firstTimePull_adoptsServerGroups() {
        // Local is empty (first time)
        XCTAssertTrue(PodcastGroup.loadGroups(forProfileId: testProfileId).isEmpty)

        let serverGroups = [
            ProGroup(id: "aaa", name: "News", sortOrder: 0, iconName: nil, colorHex: nil),
            ProGroup(id: "bbb", name: "Comedy", sortOrder: 1, iconName: nil, colorHex: nil)
        ]

        // On first time: local is empty → build push payload is empty → push sends []
        let pushPayload = manager.buildGroupsForSync(profileId: testProfileId)
        XCTAssertTrue(pushPayload.isEmpty,
                      "First-time push payload must be empty (nothing local to send)")

        // After push (of nothing), server still returns its existing groups
        // Pull fills local for the first time
        manager.applyServerGroups(serverGroups, profileId: testProfileId)

        let local = PodcastGroup.loadGroups(forProfileId: testProfileId)
        XCTAssertEqual(local.count, 2, "First pull should adopt server groups when local is empty")
    }

    /// Scenario: User had [News, Comedy]. Deleted "News" locally → local: [Comedy].
    /// On next sync, server still has [News, Comedy].
    ///
    /// WRONG order: applyServerGroups first → local becomes [News, Comedy] → push sends stale state.
    /// CORRECT order: buildGroupsForSync → push [Comedy] → server returns [Comedy] → apply [Comedy].
    ///
    /// This test drives the implementation of `syncGroupsPushThenPull`.
    /// RED: Will fail because `syncGroupsPushThenPull` doesn't exist yet.
    func test_syncGroupsPushThenPull_deletionSurvivesSync() async {
        // GIVEN: local has [Comedy] only — "News" was deleted
        let localGroups = [PodcastGroup(id: "bbb", name: "Comedy", sortOrder: 0)]
        PodcastGroup.saveGroups(localGroups, forProfileId: testProfileId)

        // Spy client that records call order and returns the pushed groups on GET
        let spy = SpyGroupsProClient()
        // Server will return whatever the app pushes (correct server behavior after push)
        spy.groupsToReturn = [
            ProGroup(id: "bbb", name: "Comedy", sortOrder: 0, iconName: nil, colorHex: nil)
        ]

        // WHEN: sync using the correct push-then-pull method
        await manager.syncGroupsPushThenPull(profileName: testProfileId, client: spy)

        // THEN: call order must be push(syncGroups) before pull(getGroups)
        XCTAssertEqual(spy.callOrder, ["syncGroups", "getGroups"],
                       "Must push before pull — push-first is the invariant")

        // THEN: the push payload that was sent to the server must only contain Comedy
        XCTAssertEqual(spy.pushedGroups?.count, 1, "Should have pushed 1 group (Comedy)")
        XCTAssertEqual(spy.pushedGroups?.first?.name, "Comedy",
                       "Push must NOT include the deleted 'News' group")

        // THEN: local state after sync must still be [Comedy]
        let finalLocal = PodcastGroup.loadGroups(forProfileId: testProfileId)
        XCTAssertEqual(finalLocal.count, 1, "Local must remain [Comedy] after sync")
        XCTAssertFalse(finalLocal.contains(where: { $0.name == "News" }),
                       "Deleted 'News' must not bounce back")
    }
}

// MARK: - Spy Client for Order Testing

/// Records which groups methods were called and in which order.
/// Used by `GroupsSyncOrderTests.test_syncGroupsPushThenPull_deletionSurvivesSync`.
final class SpyGroupsProClient: GroupsSyncCapable {
    var callOrder: [String] = []
    var pushedGroups: [ProGroup]?
    var groupsToReturn: [ProGroup] = []

    func syncGroups(profileName: String, groups: [ProGroup]) async throws {
        callOrder.append("syncGroups")
        pushedGroups = groups
    }

    func getGroups(profileName: String) async throws -> ProGroupsResponse? {
        callOrder.append("getGroups")
        return ProGroupsResponse(
            profileName: profileName,
            groups: groupsToReturn,
            timestamp: "2026-04-16T00:00:00Z"
        )
    }
}
