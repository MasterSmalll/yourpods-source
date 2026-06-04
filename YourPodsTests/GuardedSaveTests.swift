import XCTest
import SwiftData
@testable import YourPods

/// TDD tests for guarded ModelContext.save() in EpisodeActionSyncService.
///
/// Two crash vectors:
/// 1. WAL checkpoint crash (guarded_pwrite_np / pread) — Core Data's WAL checkpoint
///    hits corrupt pages during modelContext.save(). Uncatchable signal crash.
///    Fix: pre-validate with StoreHealthProbe.rawWriteProbe() before saving.
///
/// 2. __CFStringEqual crash — modelContext.save() inside autoreleasepool drains
///    temporary NSString bridge objects before Core Data finishes column comparison.
///    Fix: move modelContext.save() outside the autoreleasepool.
@MainActor
final class GuardedSaveTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    private let testProfileId = "guarded-save-test"
    
    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
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
    
    // MARK: - Helpers
    
    private func makeService(
        storeHealthCheck: @escaping () -> Bool = { true }
    ) -> EpisodeActionSyncService {
        let svc = EpisodeActionSyncService(
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
        return svc
    }
    
    @discardableResult
    private func insertPodcast(url: String = "https://example.com/pod", episodeCount: Int = 3) -> (Podcast, [Episode]) {
        let podcast = Podcast(url: url, title: "Test Podcast")
        context.insert(podcast)
        var episodes: [Episode] = []
        for i in 1...episodeCount {
            let ep = Episode(
                guid: "ep-\(i)-\(url.hashValue)",
                title: "Episode \(i)",
                audioUrl: "https://cdn.example.com/ep\(i)-\(url.hashValue).mp3",
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
    
    // MARK: - Crash 1: WAL Checkpoint Guard (storeHealthCheck)
    
    /// When the store health check reports corruption, applyEpisodeActionsCore
    /// must bail out with zero saves — no modelContext.save() calls at all.
    func test_applyEpisodeActionsCore_skipsWhenStoreUnhealthy() async {
        let (_, episodes) = insertPodcast(episodeCount: 5)
        
        // Seed actions so there's work to do
        let service = makeService(storeHealthCheck: { false }) // simulate corrupt store
        for ep in episodes {
            let action = EpisodeAction(
                podcast: "https://example.com/pod",
                episode: ep.audioUrl ?? "",
                guid: ep.guid,
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 500,
                started: 0,
                total: 3600,
                device: "other"
            )
            service.sendActionLocally(action)
        }
        
        let (conflicts, saveCount) = await service.applyEpisodeActionsCore(
            strategy: .serverWins,
            cooperative: false
        )
        
        XCTAssertEqual(saveCount, 0, "Corrupt store: must NOT attempt any saves")
        XCTAssertTrue(conflicts.isEmpty, "Corrupt store: must not produce conflicts")
        
        // Verify episodes were NOT modified
        for ep in episodes {
            XCTAssertEqual(ep.listenedSeconds, 0,
                           "Corrupt store: episode position must remain unchanged")
        }
    }
    
    /// When the store health check reports corruption, the synchronous
    /// applyEpisodeActionsWithStats path must also bail out.
    func test_applyEpisodeActionsWithStats_skipsWhenStoreUnhealthy() {
        let (_, episodes) = insertPodcast(episodeCount: 2)
        
        let service = makeService(storeHealthCheck: { false })
        for ep in episodes {
            service.sendActionLocally(EpisodeAction(
                podcast: "https://example.com/pod",
                episode: ep.audioUrl ?? "",
                guid: ep.guid,
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 300,
                started: 0,
                total: 3600,
                device: "other"
            ))
        }
        
        let (conflicts, saveCount) = service.applyEpisodeActionsWithStats(strategy: .serverWins)
        
        XCTAssertEqual(saveCount, 0, "Corrupt store: sync path must skip saves")
        XCTAssertTrue(conflicts.isEmpty)
    }
    
    /// When the store is healthy, saves proceed normally.
    func test_applyEpisodeActionsCore_proceedsWhenStoreHealthy() async {
        let (_, episodes) = insertPodcast(episodeCount: 2)
        
        let service = makeService(storeHealthCheck: { true }) // healthy
        for ep in episodes {
            service.sendActionLocally(EpisodeAction(
                podcast: "https://example.com/pod",
                episode: ep.audioUrl ?? "",
                guid: ep.guid,
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 750,
                started: 0,
                total: 3600,
                device: "other"
            ))
        }
        
        let (_, saveCount) = await service.applyEpisodeActionsCore(
            strategy: .serverWins,
            cooperative: false
        )
        
        XCTAssertGreaterThan(saveCount, 0, "Healthy store: must perform saves")
        
        // Verify positions were updated
        for ep in episodes {
            XCTAssertEqual(ep.listenedSeconds, 750,
                           "Healthy store: episode position should be updated to 750")
        }
    }
    
    /// The health check should only be called ONCE per applyEpisodeActionsCore
    /// invocation, not per-podcast (efficiency requirement).
    func test_healthCheckCalledOncePerInvocation() async {
        // Insert multiple podcasts
        insertPodcast(url: "https://example.com/pod1", episodeCount: 2)
        insertPodcast(url: "https://example.com/pod2", episodeCount: 2)
        insertPodcast(url: "https://example.com/pod3", episodeCount: 2)
        
        var checkCount = 0
        let service = makeService(storeHealthCheck: {
            checkCount += 1
            return true
        })
        
        let _ = await service.applyEpisodeActionsCore(
            strategy: .serverWins,
            cooperative: false
        )
        
        XCTAssertEqual(checkCount, 1,
                       "Store health check must be called exactly once, not per-podcast")
    }
    
    // MARK: - Crash 2: autoreleasepool / __CFStringEqual
    
    /// This is a structural test — verifying that saves complete successfully
    /// even with large batches of episode updates that previously triggered
    /// __CFStringEqual crashes inside autoreleasepool.
    ///
    /// The fix moves modelContext.save() outside the autoreleasepool so
    /// temporary NSString bridge objects aren't drained before Core Data
    /// finishes its column comparison during the save.
    func test_largeBatchSave_doesNotCrash() async {
        // Create a podcast with enough episodes to trigger batching (batchSize = 50)
        let (_, episodes) = insertPodcast(url: "https://example.com/large", episodeCount: 120)
        
        let service = makeService()
        for ep in episodes {
            service.sendActionLocally(EpisodeAction(
                podcast: "https://example.com/large",
                episode: ep.audioUrl ?? "",
                guid: ep.guid,
                action: "play",
                timestamp: Int(Date().timeIntervalSince1970),
                position: 999,
                started: 0,
                total: 3600,
                device: "other"
            ))
        }
        
        let (_, saveCount) = await service.applyEpisodeActionsCore(
            strategy: .serverWins,
            cooperative: false
        )
        
        // With 120 episodes and batchSize=50, we need at least 3 save calls
        // (batches of 50, 50, 20 — but saves are per-podcast, and all 120
        // belong to one podcast so it's batched within that podcast)
        XCTAssertGreaterThan(saveCount, 0, "Large batch must complete saves")
        
        // All episodes should have their positions updated
        let updated = episodes.filter { $0.listenedSeconds == 999 }
        XCTAssertEqual(updated.count, 120,
                       "All 120 episodes must have position updated to 999")
    }
}
