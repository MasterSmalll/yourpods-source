import XCTest
import SwiftData
import CoreData
@testable import YourPods

/// Residual re-persist churn.
///
/// The `dirtyKeys[...]` diagnostic on the device build named exactly which rows
/// a no-genuine-change sync still re-writes: `Episode.listenedSeconds` (the
/// episode-actions apply) and `Podcast.settings` (the per-podcast settings
/// apply). Both paths assign UNCONDITIONALLY — and Core Data marks a row dirty
/// on ANY setter call, even `x = x`, then re-writes it (Z_OPT version bump ≈ 2
/// WAL pages). With a `since=0` full-history re-pull the action map covers the
/// whole library, so a single sync cycle re-writes ~1488 unchanged rows.
///
/// Fix: compare-before-assign in both apply paths — the same discipline the
/// feed mappers already use (see `FeedRefreshRegressionTests`).
@MainActor
final class SyncApplyChurnTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!
    private let testProfileId = "test-sync-apply-churn"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
        manager = PodcastManager(modelContext: context)
    }

    override func tearDown() {
        clearTestDefaults()
        manager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "subscriptionUrls_\(testProfileId)",
            "episodeActionMap",
            "syncConflictCounts",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: EpisodeActionSyncService.actionMapFileURL)
    }

    // MARK: - Helpers

    @discardableResult
    private func insertPodcast(url: String) -> (Podcast, Episode) {
        let podcast = Podcast(url: url, title: "Churn Pod")
        context.insert(podcast)
        let ep = Episode(
            guid: "ep-churn-1",
            title: "Episode",
            audioUrl: "https://example.com/churn1.mp3",
            pubDate: Date(),
            durationSeconds: 3600,
            podcast: podcast
        )
        context.insert(ep)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return (podcast, ep)
    }

    private func seedActionMap(_ entries: [String: EpisodeAction]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        manager.loadActionMap()
    }

    private func playAction(guid: String, audioUrl: String, position: Int, total: Int = 3600) -> EpisodeAction {
        EpisodeAction(
            podcast: "https://example.com/feed",
            episode: audioUrl,
            guid: guid,
            action: "play",
            timestamp: 1000,
            position: position,
            started: 0,
            total: total,
            device: "ios-device"
        )
    }

    /// Number of rows the context flags dirty at the moment it flushes. This is
    /// the Core Data layer that re-writes a row for ANY setter call — including
    /// an identical-value assignment whose `changedValues()` is empty — so it is
    /// the ground truth for re-persist churn (and what the on-device
    /// `dirtyKeys` diagnostic samples).
    private func dirtyRowCount(during work: () -> Void) -> Int {
        var maxDirty = 0
        let token = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave, object: nil, queue: nil
        ) { note in
            guard let moc = note.object as? NSManagedObjectContext else { return }
            maxDirty = max(maxDirty, moc.updatedObjects.count + moc.insertedObjects.count + moc.deletedObjects.count)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        work()
        return maxDirty
    }

    // MARK: - Episode-actions apply (Episode.listenedSeconds / isPlayed)

    /// Re-applying a server action whose position already matches the local
    /// episode must not re-write the row. This is the dominant driver: under a
    /// full re-pull every episode has a matching action, so `serverWins`
    /// re-assigns `listenedSeconds` for the whole library — all no-ops.
    func test_applyEpisodeActions_doesNotDirtyContext_whenPositionUnchanged() {
        let (_, episode) = insertPodcast(url: "https://example.com/feed")
        episode.listenedSeconds = 3600
        episode.isPlayed = true
        try! context.save()
        XCTAssertFalse(context.hasChanges, "baseline: context is clean after the first persist")

        seedActionMap([
            episode.guid: playAction(guid: episode.guid, audioUrl: episode.audioUrl!, position: 3600)
        ])

        let dirty = dirtyRowCount {
            _ = manager.applyEpisodeActionsWithStats(strategy: .serverWins)
        }

        XCTAssertEqual(dirty, 0,
                       "Re-applying an identical server position must not re-write any row — episode-actions churn")
    }

    /// Guard the other branch: a genuinely-new server position must still apply.
    func test_applyEpisodeActions_stillUpdates_whenPositionChanged() {
        let (_, episode) = insertPodcast(url: "https://example.com/feed-changed")
        episode.listenedSeconds = 600
        try! context.save()

        seedActionMap([
            episode.guid: playAction(guid: episode.guid, audioUrl: episode.audioUrl!, position: 1800)
        ])

        _ = manager.applyEpisodeActionsWithStats(strategy: .serverWins)

        XCTAssertEqual(episode.listenedSeconds, 1800,
                       "A genuinely-new server position must still be applied")
    }

    // MARK: - Per-podcast settings apply (Podcast.settings)

    /// Re-applying identical per-podcast settings overrides must not dirty the
    /// row. `applyPerPodcastOverridesFromServer` assigns `effectiveSettings`
    /// unconditionally; with no server change the merged value is identical, so
    /// it must be a no-op.
    func test_applyPerPodcastOverrides_doesNotDirtyContext_whenUnchanged() throws {
        let (podcast, _) = insertPodcast(url: "https://example.com/settings-feed")
        let overrides = [
            ProPodcastSetting(
                podcastUrl: podcast.url,
                payload: ["skipIntroSec": .int(15), "playbackSpeed": .double(1.5)],
                settings: nil,
                updatedAt: nil
            )
        ]

        manager.applyPerPodcastOverridesFromServer(overrides)
        try context.save()
        XCTAssertFalse(context.hasChanges, "baseline: context is clean after the first persist")

        // Re-apply the IDENTICAL overrides — must write nothing.
        manager.applyPerPodcastOverridesFromServer(overrides)
        XCTAssertFalse(context.hasChanges,
                       "Re-applying identical per-podcast settings must not dirty the row — settings churn")
    }

    /// Guard the other branch: a genuinely-changed setting must still update.
    /// The field-level merge keeps the LOCAL value for fields the user already
    /// set, so a real cross-device change is a server value for a field that is
    /// nil locally — here `skipOutroSec`, which the merge must adopt.
    func test_applyPerPodcastOverrides_stillUpdates_whenChanged() throws {
        let (podcast, _) = insertPodcast(url: "https://example.com/settings-changed")

        manager.applyPerPodcastOverridesFromServer([
            ProPodcastSetting(podcastUrl: podcast.url, payload: ["skipIntroSec": .int(15)], settings: nil, updatedAt: nil)
        ])
        try context.save()

        manager.applyPerPodcastOverridesFromServer([
            ProPodcastSetting(podcastUrl: podcast.url,
                              payload: ["skipIntroSec": .int(15), "skipOutroSec": .int(30)],
                              settings: nil, updatedAt: nil)
        ])

        XCTAssertTrue(context.hasChanges, "A real settings change must still dirty the row")
        XCTAssertEqual(podcast.effectiveSettings.skipOutroSeconds, 30, "The newly-synced value must be applied")
    }
}
