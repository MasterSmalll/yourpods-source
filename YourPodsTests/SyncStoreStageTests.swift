import XCTest
import SwiftData
@testable import YourPods

/// Tests for `SyncStore` Stages 1–3: episode action apply, feed result apply,
/// and subscription persistence.
///
/// These tests verify the actual background-actor paths that production uses,
/// including cross-context visibility (main sees background writes after reconcile).
///
/// NOT `@MainActor` — exercises the actor in its natural isolation.
final class SyncStoreStageTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, configurations: config)
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - Helpers

    /// Seed a podcast with episodes on the MAIN context, save, return URL.
    private func seedPodcast(
        url: String,
        title: String = "Test Podcast",
        episodeCount: Int = 3,
        durationSeconds: Int = 3600,
        listenedSeconds: Int = 0
    ) async -> String {
        await MainActor.run {
            let podcast = Podcast(url: url, title: title)
            container.mainContext.insert(podcast)
            for i in 1...episodeCount {
                let ep = Episode(
                    guid: "ep-\(i)-\(url)",
                    title: "Episode \(i)",
                    audioUrl: "https://example.com/\(url)/ep\(i).mp3",
                    pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                    durationSeconds: durationSeconds,
                    podcast: podcast
                )
                ep.listenedSeconds = listenedSeconds
                container.mainContext.insert(ep)
            }
            try! container.mainContext.save()
        }
        return url
    }

    private func mainContextEpisodes(forPodcastUrl url: String) async -> [Episode] {
        await MainActor.run {
            // Fetch Episodes DIRECTLY — don't traverse the Podcast.episodes
            // relationship, which may be stale in in-memory stores after
            // cross-context saves (relationship cache isn't invalidated).
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.podcast?.url == url },
                sortBy: [SortDescriptor(\.guid)]
            )
            return (try? container.mainContext.fetch(descriptor)) ?? []
        }
    }

    private func mainContextPodcasts() async -> [Podcast] {
        await MainActor.run {
            let descriptor = FetchDescriptor<Podcast>()
            return try! container.mainContext.fetch(descriptor)
        }
    }

    // MARK: - Stage 1: Episode Action Apply

    /// SyncStore.applyEpisodeActions with serverWins should update positions
    /// on the background context, and those changes should be visible to
    /// the main context after refreshAllFromStore.
    func test_applyEpisodeActions_serverWins_updatesPositions() async {
        let url = await seedPodcast(url: "https://example.com/feed1")
        let store = SyncStore(container: container)

        // Build action map keyed by GUID
        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        var actionMap: [String: EpisodeAction] = [:]
        for ep in episodes {
            actionMap[ep.guid] = EpisodeAction(
                podcast: url, episode: ep.audioUrl ?? "",
                guid: ep.guid, action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 500, started: 0, total: 3600, device: "test"
            )
        }

        let outcome = await store.applyEpisodeActions(
            actionMap: actionMap, strategy: .serverWins, deviceId: "test"
        )

        XCTAssertEqual(outcome.updatedCount, 3, "All 3 episodes should be processed")
        XCTAssertTrue(outcome.conflicts.isEmpty, "serverWins produces no conflicts")
        XCTAssertGreaterThan(outcome.saveCount, 0, "At least one save should happen")

        // Main context must see updated positions after refresh
        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let refreshed = await mainContextEpisodes(forPodcastUrl: url)
        for ep in refreshed {
            XCTAssertEqual(ep.listenedSeconds, 500,
                           "Episode \(ep.guid) should have position 500 after refresh")
        }
    }

    /// deviceWins with local at 0 should adopt server position.
    func test_applyEpisodeActions_deviceWins_adoptsFromZero() async {
        let url = await seedPodcast(url: "https://example.com/feed-dw", listenedSeconds: 0)
        let store = SyncStore(container: container)

        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        var actionMap: [String: EpisodeAction] = [:]
        for ep in episodes {
            actionMap[ep.guid] = EpisodeAction(
                podcast: url, episode: ep.audioUrl ?? "",
                guid: ep.guid, action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 200, started: 0, total: 3600, device: "test"
            )
        }

        let outcome = await store.applyEpisodeActions(
            actionMap: actionMap, strategy: .deviceWins, deviceId: "test"
        )

        XCTAssertTrue(outcome.conflicts.isEmpty)

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let refreshed = await mainContextEpisodes(forPodcastUrl: url)
        for ep in refreshed {
            XCTAssertEqual(ep.listenedSeconds, 200,
                           "deviceWins from 0 should adopt server position")
        }
    }

    /// deviceWins with local > 0 should NOT overwrite.
    func test_applyEpisodeActions_deviceWins_keepsLocalWhenAhead() async {
        let url = await seedPodcast(url: "https://example.com/feed-dw2", listenedSeconds: 300)
        let store = SyncStore(container: container)

        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        var actionMap: [String: EpisodeAction] = [:]
        for ep in episodes {
            actionMap[ep.guid] = EpisodeAction(
                podcast: url, episode: ep.audioUrl ?? "",
                guid: ep.guid, action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 100, started: 0, total: 3600, device: "test"
            )
        }

        let outcome = await store.applyEpisodeActions(
            actionMap: actionMap, strategy: .deviceWins, deviceId: "test"
        )

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let refreshed = await mainContextEpisodes(forPodcastUrl: url)
        for ep in refreshed {
            XCTAssertEqual(ep.listenedSeconds, 300,
                           "deviceWins should keep local position when > 0")
        }
    }

    /// Currently-playing GUID should be skipped during apply.
    func test_applyEpisodeActions_skipsCurrentlyPlayingGuid() async {
        let url = await seedPodcast(url: "https://example.com/feed-playing")
        let store = SyncStore(container: container)

        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        let playingGuid = episodes[0].guid

        var actionMap: [String: EpisodeAction] = [:]
        for ep in episodes {
            actionMap[ep.guid] = EpisodeAction(
                podcast: url, episode: ep.audioUrl ?? "",
                guid: ep.guid, action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 999, started: 0, total: 3600, device: "test"
            )
        }

        let outcome = await store.applyEpisodeActions(
            actionMap: actionMap, strategy: .serverWins, deviceId: "test",
            currentlyPlayingGuidProvider: { playingGuid }
        )

        // Only 2 episodes should be processed (the playing one is skipped)
        XCTAssertEqual(outcome.updatedCount, 2,
                       "Should skip the currently-playing episode")

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let refreshed = await mainContextEpisodes(forPodcastUrl: url)
        let playingEp = refreshed.first(where: { $0.guid == playingGuid })
        XCTAssertEqual(playingEp?.listenedSeconds, 0,
                       "Currently-playing episode should not be modified")

        let otherEps = refreshed.filter { $0.guid != playingGuid }
        for ep in otherEps {
            XCTAssertEqual(ep.listenedSeconds, 999,
                           "Non-playing episodes should be updated")
        }
    }

    /// The now-playing exclusion must track an episode SWITCH that happens while the
    /// apply loop is running — not just the episode that was playing when the loop
    /// started. The GUID is read from a provider that is re-evaluated per podcast,
    /// so a user who skips to another episode mid-sync does not get that episode's
    /// live position clobbered by a stale server value (the two-writer race).
    ///
    /// Models a switch from an episode in feed-A (playing at sync start) to an episode
    /// in feed-B (switched-to mid-loop). With a one-shot snapshot, feed-B's episode
    /// would be written; with per-podcast re-evaluation it is correctly skipped.
    func test_applyEpisodeActions_excludesEpisodeSwitchedToMidLoop() async {
        // Insertion order = process order for the in-memory store: A is processed first.
        let urlA = await seedPodcast(url: "https://example.com/feed-switch-A", episodeCount: 1)
        let urlB = await seedPodcast(url: "https://example.com/feed-switch-B", episodeCount: 1)
        let store = SyncStore(container: container)

        let epsA = await mainContextEpisodes(forPodcastUrl: urlA)
        let epsB = await mainContextEpisodes(forPodcastUrl: urlB)
        let guidA = epsA[0].guid
        let guidB = epsB[0].guid

        var actionMap: [String: EpisodeAction] = [:]
        for ep in epsA + epsB {
            actionMap[ep.guid] = EpisodeAction(
                podcast: ep.podcast?.url ?? "", episode: ep.audioUrl ?? "",
                guid: ep.guid, action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 999, started: 0, total: 3600, device: "test"
            )
        }

        // Provider models the mid-loop switch: the first read (processing feed-A) sees
        // the user on A; the next read (processing feed-B) sees them switched to B.
        let box = ProviderCallBox()
        let provider: @MainActor @Sendable () -> String? = {
            box.next() == 1 ? guidA : guidB
        }

        let outcome = await store.applyEpisodeActions(
            actionMap: actionMap, strategy: .serverWins, deviceId: "test",
            currentlyPlayingGuidProvider: provider
        )

        XCTAssertEqual(box.count, 2,
                       "Provider must be re-read once per podcast (live now-playing), not snapshotted once")
        XCTAssertEqual(outcome.updatedCount, 0,
                       "Both the originally-playing and the switched-to episode must be excluded")

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let refreshedB = await mainContextEpisodes(forPodcastUrl: urlB)
        XCTAssertEqual(refreshedB[0].listenedSeconds, 0,
                       "The episode switched-to mid-loop must NOT be clobbered by the server value")

        // Both skipped actions are surfaced so the main actor can apply them safely.
        let skippedGuids = Set(outcome.skippedActionsForPlayingEpisodes.compactMap { $0.guid })
        XCTAssertTrue(skippedGuids.contains(guidA) && skippedGuids.contains(guidB),
                      "Both excluded episodes' actions must be returned for main-actor application")
    }

    /// Position >= 95% of total should mark episode as played.
    func test_applyEpisodeActions_marksPlayedAtCompletionThreshold() async {
        let url = await seedPodcast(url: "https://example.com/feed-played", episodeCount: 1)
        let store = SyncStore(container: container)

        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        let ep = episodes[0]

        let actionMap: [String: EpisodeAction] = [
            ep.guid: EpisodeAction(
                podcast: url, episode: ep.audioUrl ?? "",
                guid: ep.guid, action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 3500, started: 0, total: 3600, device: "test"
            )
        ]

        let outcome = await store.applyEpisodeActions(
            actionMap: actionMap, strategy: .serverWins, deviceId: "test"
        )

        XCTAssertEqual(outcome.newlyPlayedGuids, [ep.guid],
                       "Should report newly played GUID")

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let refreshed = await mainContextEpisodes(forPodcastUrl: url)
        XCTAssertTrue(refreshed[0].isPlayed,
                      "Episode at 97% should be marked played")
    }

    /// Ask strategy with large diff from different device should produce conflict.
    func test_applyEpisodeActions_ask_producesConflict() async {
        let url = await seedPodcast(url: "https://example.com/feed-ask",
                                    episodeCount: 1, listenedSeconds: 300)
        let store = SyncStore(container: container)

        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        let ep = episodes[0]

        let actionMap: [String: EpisodeAction] = [
            ep.guid: EpisodeAction(
                podcast: url, episode: ep.audioUrl ?? "",
                guid: ep.guid, action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 1500, started: 0, total: 3600, device: "other-device"
            )
        ]

        let outcome = await store.applyEpisodeActions(
            actionMap: actionMap, strategy: .ask, deviceId: "my-device"
        )

        XCTAssertEqual(outcome.conflicts.count, 1,
                       "Large position diff from different device should create conflict")
        XCTAssertEqual(outcome.conflicts[0].episodeGuid, ep.guid)
        XCTAssertEqual(outcome.conflicts[0].localPosition, 300)
        XCTAssertEqual(outcome.conflicts[0].serverPosition, 1500)
    }

    /// Cancellation before start should return empty.
    func test_applyEpisodeActions_respectsCancellation() async {
        let url = await seedPodcast(url: "https://example.com/feed-cancel")
        let store = SyncStore(container: container)

        let task = Task {
            return await store.applyEpisodeActions(
                actionMap: ["dummy": EpisodeAction(
                    podcast: url, episode: "", guid: "dummy",
                    action: "play", timestamp: 0, position: 999,
                    started: nil, total: nil, device: nil
                )],
                strategy: .serverWins, deviceId: "test"
            )
        }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome.updatedCount, 0,
                       "Cancelled task should produce empty outcome")
    }

    /// Store health check failure should return empty.
    func test_applyEpisodeActions_skipsOnHealthCheckFailure() async {
        let url = await seedPodcast(url: "https://example.com/feed-health")
        let store = SyncStore(
            container: container,
            storeHealthCheck: { false }  // Always fail
        )

        let outcome = await store.applyEpisodeActions(
            actionMap: ["x": EpisodeAction(
                podcast: url, episode: "", guid: "x",
                action: "play", timestamp: 0, position: 100,
                started: nil, total: nil, device: nil
            )],
            strategy: .serverWins, deviceId: "test"
        )

        XCTAssertEqual(outcome.updatedCount, 0,
                       "Health check failure should skip apply")
    }

    // MARK: - Stage 2: Feed Result Apply

    /// applyFeedResults should insert new episodes visible to main context.
    func test_applyFeedResults_insertsNewEpisodes() async {
        let url = await seedPodcast(url: "https://example.com/feed-fr", episodeCount: 1)
        let store = SyncStore(container: container)

        let feedResult = FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: ParsedPodcast(title: "Updated Title"),
            episodes: [
                ParsedEpisode(guid: "ep-1-\(url)", title: "Existing"),
                ParsedEpisode(guid: "new-ep-1", title: "New Episode",
                              audioUrl: "https://example.com/new.mp3"),
                ParsedEpisode(guid: "new-ep-2", title: "New Episode 2",
                              audioUrl: "https://example.com/new2.mp3"),
            ]
        )

        let outcome = await store.applyFeedResults([feedResult])

        XCTAssertEqual(outcome.newEpisodeGuids.count, 2,
                       "Should report 2 new episode GUIDs")
        XCTAssertTrue(outcome.newEpisodeGuids.contains("new-ep-1"))
        XCTAssertTrue(outcome.newEpisodeGuids.contains("new-ep-2"))
        XCTAssertTrue(outcome.urlMigrations.isEmpty)

        // Main context should see new episodes after refresh
        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        XCTAssertEqual(episodes.count, 3,
                       "Main context should see all 3 episodes after refresh")
    }

    /// applyFeedResults should update podcast metadata.
    func test_applyFeedResults_updatesMetadata() async {
        let url = await seedPodcast(url: "https://example.com/feed-meta", episodeCount: 1)
        let store = SyncStore(container: container)

        let feedResult = FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: ParsedPodcast(
                title: "New Title",
                description: "New Description",
                author: "New Author",
                language: "en-us"
            ),
            episodes: [ParsedEpisode(guid: "ep-1-\(url)", title: "Existing")]
        )

        _ = await store.applyFeedResults([feedResult])

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let podcasts = await mainContextPodcasts()
        let podcast = podcasts.first(where: { $0.url == url })
        XCTAssertEqual(podcast?.title, "New Title")
        XCTAssertEqual(podcast?.podcastDescription, "New Description")
        XCTAssertEqual(podcast?.author, "New Author")
        XCTAssertEqual(podcast?.language, "en-us")
    }

    /// Episodes not in the feed should be marked stale.
    func test_applyFeedResults_marksStaleEpisodes() async {
        let url = await seedPodcast(url: "https://example.com/feed-stale", episodeCount: 3)
        let store = SyncStore(container: container)

        // Feed only contains episode 1, not 2 or 3
        let feedResult = FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: ParsedPodcast(title: "Test Podcast"),
            episodes: [ParsedEpisode(guid: "ep-1-\(url)", title: "Episode 1")]
        )

        _ = await store.applyFeedResults([feedResult])

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        let ep1 = episodes.first(where: { $0.guid == "ep-1-\(url)" })
        let ep2 = episodes.first(where: { $0.guid == "ep-2-\(url)" })
        let ep3 = episodes.first(where: { $0.guid == "ep-3-\(url)" })

        XCTAssertFalse(ep1?.isStale ?? true, "Episode still in feed should NOT be stale")
        XCTAssertTrue(ep2?.isStale ?? false, "Episode missing from feed should be stale")
        XCTAssertTrue(ep3?.isStale ?? false, "Episode missing from feed should be stale")
    }

    /// A feed declaring itunes:new-feed-url should produce a URL migration.
    func test_applyFeedResults_detectsURLMigration() async {
        let url = await seedPodcast(url: "https://example.com/old-feed", episodeCount: 1)
        let store = SyncStore(container: container)

        let feedResult = FeedFetchResult(
            url: url,
            authHeader: nil,
            parsed: ParsedPodcast(
                title: "Migrating Pod",
                newFeedUrl: "https://example.com/new-feed"
            ),
            episodes: [ParsedEpisode(guid: "ep-1-\(url)", title: "Episode 1")]
        )

        let outcome = await store.applyFeedResults([feedResult])

        XCTAssertEqual(outcome.urlMigrations.count, 1)
        XCTAssertEqual(outcome.urlMigrations[0].oldUrl, "https://example.com/old-feed")
        XCTAssertEqual(outcome.urlMigrations[0].newUrl, "https://example.com/new-feed")

        // Podcast URL should be updated on background context
        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let podcasts = await mainContextPodcasts()
        let migrated = podcasts.first(where: { $0.url == "https://example.com/new-feed" })
        XCTAssertNotNil(migrated, "Podcast URL should be updated to new URL")
    }

    /// Un-stale: a previously stale episode should become non-stale when it
    /// reappears in the feed.
    func test_applyFeedResults_unstalesWhenFeedReaddsEpisode() async {
        let url = "https://example.com/feed-unstale"
        // Seed with stale episode
        await MainActor.run {
            let podcast = Podcast(url: url, title: "Unstale Test")
            container.mainContext.insert(podcast)
            let ep = Episode(guid: "stale-ep", title: "Was Stale",
                             audioUrl: "https://example.com/stale.mp3",
                             durationSeconds: 3600, podcast: podcast)
            ep.isStale = true
            container.mainContext.insert(ep)
            try! container.mainContext.save()
        }

        let store = SyncStore(container: container)
        let feedResult = FeedFetchResult(
            url: url, authHeader: nil,
            parsed: ParsedPodcast(title: "Unstale Test"),
            episodes: [ParsedEpisode(guid: "stale-ep", title: "Was Stale",
                                     audioUrl: "https://example.com/stale.mp3")]
        )

        _ = await store.applyFeedResults([feedResult])

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let episodes = await mainContextEpisodes(forPodcastUrl: url)
        XCTAssertFalse(episodes[0].isStale,
                       "Stale episode should become non-stale when feed re-adds it")
    }

    /// Cancellation should return empty.
    func test_applyFeedResults_respectsCancellation() async {
        let url = await seedPodcast(url: "https://example.com/feed-cancel-fr")
        let store = SyncStore(container: container)

        let task = Task {
            await store.applyFeedResults([
                FeedFetchResult(url: url, authHeader: nil,
                               parsed: ParsedPodcast(title: "X"),
                               episodes: [ParsedEpisode(guid: "new", title: "New")])
            ])
        }
        task.cancel()
        let outcome = await task.value

        XCTAssertTrue(outcome.newEpisodeGuids.isEmpty,
                      "Cancelled task should return empty outcome")
    }

    // MARK: - Stage 3: Subscription Persistence

    /// persistNewPodcasts should insert a podcast with episodes visible to main.
    func test_persistNewPodcasts_insertsWithEpisodes() async {
        let store = SyncStore(container: container)

        let payload = NewPodcastPayload(
            url: "https://example.com/new-pod",
            parsed: ParsedPodcast(title: "New Podcast", author: "Author"),
            episodes: [
                ParsedEpisode(guid: "np-ep-1", title: "EP 1",
                              audioUrl: "https://example.com/ep1.mp3"),
                ParsedEpisode(guid: "np-ep-2", title: "EP 2",
                              audioUrl: "https://example.com/ep2.mp3"),
            ],
            sortOrder: 5
        )

        let inserted = await store.persistNewPodcasts([payload])

        XCTAssertEqual(inserted, ["https://example.com/new-pod"])

        // Main context should see the podcast after refresh
        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let podcasts = await mainContextPodcasts()
        let pod = podcasts.first(where: { $0.url == "https://example.com/new-pod" })
        XCTAssertNotNil(pod, "New podcast should be visible to main context")
        XCTAssertEqual(pod?.title, "New Podcast")
        XCTAssertEqual(pod?.author, "Author")
        XCTAssertEqual(pod?.sortOrder, 5)
        XCTAssertEqual(pod?.episodes.count, 2)
        XCTAssertNotNil(pod?.effectiveSettings.markedPlayedBefore,
                        "markedPlayedBefore should be stamped")
    }

    /// Duplicate URL should be skipped (dedup guard).
    func test_persistNewPodcasts_skipsDuplicate() async {
        let url = await seedPodcast(url: "https://example.com/existing")
        let store = SyncStore(container: container)

        let payload = NewPodcastPayload(
            url: url,
            parsed: ParsedPodcast(title: "Duplicate"),
            episodes: [],
            sortOrder: 0
        )

        let inserted = await store.persistNewPodcasts([payload])

        XCTAssertTrue(inserted.isEmpty,
                      "Duplicate URL should not be inserted")

        // Should still have exactly 1 podcast with that URL
        let podcasts = await mainContextPodcasts()
        let matching = podcasts.filter { $0.url == url }
        XCTAssertEqual(matching.count, 1, "Should not create duplicates")
    }

    /// deletePodcasts should remove the podcast and cascade-delete episodes.
    func test_deletePodcasts_cascadesEpisodes() async {
        let url = await seedPodcast(url: "https://example.com/to-delete", episodeCount: 5)
        let store = SyncStore(container: container)

        await store.deletePodcasts(urls: [url])

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let podcasts = await mainContextPodcasts()
        let deleted = podcasts.first(where: { $0.url == url })
        XCTAssertNil(deleted, "Deleted podcast should not be visible")

        // Episodes should also be gone (cascade)
        let allEpisodes = await MainActor.run {
            try! container.mainContext.fetch(FetchDescriptor<Episode>())
        }
        let orphans = allEpisodes.filter { $0.podcastUrl == url }
        XCTAssertTrue(orphans.isEmpty,
                      "Cascade delete should remove all episodes")
    }

    /// deletePodcasts with non-matching URL should be a no-op.
    func test_deletePodcasts_ignoresNonexistent() async {
        _ = await seedPodcast(url: "https://example.com/keep")
        let store = SyncStore(container: container)

        await store.deletePodcasts(urls: ["https://example.com/nonexistent"])

        let podcasts = await mainContextPodcasts()
        XCTAssertEqual(podcasts.count, 1, "Existing podcast should survive")
    }

    /// Batch insert: multiple payloads should all be inserted in one operation.
    func test_persistNewPodcasts_batchInsert() async {
        let store = SyncStore(container: container)

        let payloads = (1...3).map { i in
            NewPodcastPayload(
                url: "https://example.com/batch-\(i)",
                parsed: ParsedPodcast(title: "Batch \(i)"),
                episodes: [ParsedEpisode(guid: "batch-\(i)-ep", title: "EP")],
                sortOrder: i
            )
        }

        let inserted = await store.persistNewPodcasts(payloads)

        XCTAssertEqual(inserted.count, 3, "All 3 should be inserted")

        await MainActor.run { container.mainContext.refreshAllFromStore() }
        let podcasts = await mainContextPodcasts()
        XCTAssertEqual(podcasts.count, 3)
        // Verify sort orders
        for (i, url) in inserted.enumerated() {
            let pod = podcasts.first(where: { $0.url == url })
            XCTAssertEqual(pod?.sortOrder, i + 1)
        }
    }
}

/// Thread-safe call counter for a `@Sendable` provider closure invoked across the
/// MainActor boundary from the SyncStore background actor.
private final class ProviderCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// Increment and return the new call number (1-based).
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    /// Total number of calls so far.
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
