import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for per-batch store health re-validation in EpisodeActionSyncService.
///
/// Root cause: `applyEpisodeActionsCore()` called `storeHealthCheck()` once at the
/// top, then executed 10+ batch saves via bare `try modelContext.save()`. When the
/// store becomes unhealthy mid-loop (e.g., iOS revoking file access during
/// BGAppRefreshTask expiration), the bare save crashes with a `guarded_pwrite_np`
/// signal in `sqlite3WalCheckpoint`.
///
/// Fix:
/// 1. Re-check `storeHealthCheck()` before each batch save.
/// 2. Replace bare `try modelContext.save()` with `modelContext.safeSave()`.
/// 3. If the health check fails mid-loop, bail out immediately.
@MainActor
final class PerBatchHealthCheckTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let testProfileId = "per-batch-health-test"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        context.autosaveEnabled = false
        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")
    }

    override func tearDown() {
        clearTestDefaults()
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "episodeActionMap",
            "syncConflictCounts",
            "lastEpisodeActionSync_\(testProfileId)",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func makeService(
        storeHealthCheck: @escaping () -> Bool = { true }
    ) -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [weak self] in
                let descriptor = FetchDescriptor<Podcast>()
                return (try? self?.context.fetch(descriptor)) ?? []
            },
            syncClientProvider: { nil },
            profileIdProvider: { self.testProfileId },
            deviceIdProvider: { "test-device" },
            storeHealthCheck: storeHealthCheck
        )
    }

    @discardableResult
    private func insertPodcast(
        url: String,
        episodeCount: Int
    ) -> (Podcast, [Episode]) {
        let podcast = Podcast(url: url, title: "Podcast \(url)")
        context.insert(podcast)
        var episodes: [Episode] = []
        for i in 0..<episodeCount {
            let ep = Episode(
                guid: "\(url)-ep-\(i)",
                title: "Episode \(i)",
                audioUrl: "https://cdn.example.com/\(url.hashValue)-ep-\(i).mp3",
                pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
            episodes.append(ep)
        }
        try! context.save()
        return (podcast, episodes)
    }

    private func seedActions(for episodes: [Episode], podcastUrl: String, service: EpisodeActionSyncService, position: Int = 500) {
        for ep in episodes {
            service.sendActionLocally(EpisodeAction(
                podcast: podcastUrl,
                episode: ep.audioUrl ?? "",
                guid: ep.guid,
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: position,
                started: 0,
                total: 3600,
                device: "other-device"
            ))
        }
    }

    // MARK: - Per-Batch Health Check (Crash 3 Fix)

    /// When the health check transitions from healthy → unhealthy mid-loop,
    /// applyEpisodeActionsCore must stop saving and bail out early.
    /// This simulates iOS revoking file access during background execution.
    func test_applyEpisodeActionsCore_bailsOutWhenStoreBecomesUnhealthy() async {
        // GIVEN: Multiple podcasts with enough episodes to trigger batch saves
        // crossPodcastSaveBatchSize = 500, so we need >500 episodes across podcasts
        // to trigger at least one intermediate batch save.
        // Use 3 podcasts × 200 episodes = 600 total to trigger one intermediate save.
        for i in 0..<3 {
            let url = "https://example.com/batch-health-\(i)"
            let (_, episodes) = insertPodcast(url: url, episodeCount: 200)
            seedActions(for: episodes, podcastUrl: url, service: makeService())
        }

        var checkCount = 0
        // Healthy on first call (initial gate), unhealthy on second call (pre-save)
        let service = makeService(storeHealthCheck: {
            checkCount += 1
            return checkCount <= 1 // only first call is healthy
        })

        // Re-seed actions on this service instance
        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try! context.fetch(descriptor)
        for podcast in podcasts {
            seedActions(for: podcast.episodes, podcastUrl: podcast.url, service: service)
        }

        // WHEN: Apply episode actions
        let (_, saveCount) = await service.applyEpisodeActionsCore(
            strategy: .serverWins,
            cooperative: false
        )

        // THEN: The health check was called more than once (per-batch)
        XCTAssertGreaterThan(checkCount, 1,
            "Health check must be called before each batch save, not just once at the top")

        // AND: saves were skipped after the health check failed
        XCTAssertEqual(saveCount, 0,
            "No saves should complete when health check fails before the first batch save")
    }

    /// When the health check stays healthy throughout, all batch saves succeed.
    func test_applyEpisodeActionsCore_allBatchesSaveWhenHealthy() async {
        // GIVEN: Enough episodes to trigger multiple batch saves
        for i in 0..<3 {
            let url = "https://example.com/healthy-batch-\(i)"
            let (_, episodes) = insertPodcast(url: url, episodeCount: 200)
            seedActions(for: episodes, podcastUrl: url, service: makeService())
        }

        var checkCount = 0
        let service = makeService(storeHealthCheck: {
            checkCount += 1
            return true // always healthy
        })

        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try! context.fetch(descriptor)
        for podcast in podcasts {
            seedActions(for: podcast.episodes, podcastUrl: podcast.url, service: service)
        }

        // WHEN
        let (_, saveCount) = await service.applyEpisodeActionsCore(
            strategy: .serverWins,
            cooperative: false
        )

        // THEN: Health check was called more than once
        XCTAssertGreaterThan(checkCount, 1,
            "Health check must be called before each batch save")

        // AND: All saves completed
        XCTAssertGreaterThan(saveCount, 0,
            "Healthy store: all batch saves must succeed")
    }

    /// The synchronous `applyEpisodeActionsWithStats` path must also
    /// re-check health before each batch save.
    func test_applyEpisodeActionsWithStats_bailsOutWhenStoreBecomesUnhealthy() {
        // GIVEN: Enough episodes to trigger batch saves
        for i in 0..<3 {
            let url = "https://example.com/stats-batch-\(i)"
            let (_, episodes) = insertPodcast(url: url, episodeCount: 200)
            seedActions(for: episodes, podcastUrl: url, service: makeService())
        }

        var checkCount = 0
        let service = makeService(storeHealthCheck: {
            checkCount += 1
            return checkCount <= 1
        })

        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try! context.fetch(descriptor)
        for podcast in podcasts {
            seedActions(for: podcast.episodes, podcastUrl: podcast.url, service: service)
        }

        // WHEN
        let (_, saveCount) = service.applyEpisodeActionsWithStats(strategy: .serverWins)

        // THEN
        XCTAssertGreaterThan(checkCount, 1,
            "Health check must be called before each batch save (sync path)")
        XCTAssertEqual(saveCount, 0,
            "No saves should complete when health check fails")
    }
}
