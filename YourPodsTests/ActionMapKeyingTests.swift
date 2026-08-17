import XCTest
import SwiftData
@testable import YourPods

/// Tests for canonical actionMap keying.
///
/// Root cause R6: gpodder.net strips GUIDs from actions, so server actions
/// are keyed by audio URL while local actions are keyed by GUID. This creates
/// split-brain entries in the actionMap.
@MainActor
final class ActionMapKeyingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var syncStore: SyncStore!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        syncStore = SyncStore(container: container)
        UserDefaults.standard.set("test-keying", forKey: "activeProfileId")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "activeProfileId")
        syncStore = nil
        context = nil
        container = nil
        super.tearDown()
    }

    /// Build a service with given podcasts available for index lookup.
    private func makeService(podcasts: [Podcast] = []) -> EpisodeActionSyncService {
        EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { podcasts },
            syncClientProvider: { nil },
            profileIdProvider: { "test-keying" },
            deviceIdProvider: { "test-device" },
            storeHealthCheck: { true },
            syncStore: syncStore
        )
    }

    /// Create a podcast with one episode (guid + audioUrl).
    private func makePodcast(guid: String, audioUrl: String) -> (Podcast, Episode) {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        let episode = Episode(guid: guid, title: "Ep", audioUrl: audioUrl)
        episode.podcast = podcast
        podcast.episodes.append(episode)
        context.insert(podcast)
        return (podcast, episode)
    }

    private func makeAction(
        episode: String,
        guid: String?,
        device: String = "test-device",
        position: Int = 100
    ) -> EpisodeAction {
        EpisodeAction(
            podcast: "https://example.com/feed",
            episode: episode,
            guid: guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: position,
            started: 0,
            total: 3600,
            device: device
        )
    }

    // MARK: - 5.1 canonicalActionKey

    /// When the action has a GUID matching a known local episode, the key is the GUID.
    func test_canonicalKey_prefersGuid_whenEpisodeKnownLocally() {
        let (podcast, _) = makePodcast(guid: "ep-123", audioUrl: "https://example.com/ep.mp3")
        let svc = makeService(podcasts: [podcast])
        let index = svc.buildEpisodeIndex()

        let action = makeAction(episode: "https://example.com/ep.mp3", guid: "ep-123")
        let key = svc.canonicalActionKey(for: action, index: index)
        XCTAssertEqual(key, "ep-123", "Must use GUID when episode is known locally")
    }

    /// When the action has no GUID but its audio URL matches a known episode, resolve to GUID.
    func test_canonicalKey_resolvesUrlToGuid_viaEpisodeIndex() {
        let (podcast, _) = makePodcast(guid: "ep-123", audioUrl: "https://example.com/ep.mp3")
        let svc = makeService(podcasts: [podcast])
        let index = svc.buildEpisodeIndex()

        // gpodder.net stripped the GUID — action only has episode URL
        let action = makeAction(episode: "https://example.com/ep.mp3", guid: nil, device: "server-device")
        let key = svc.canonicalActionKey(for: action, index: index)
        XCTAssertEqual(key, "ep-123",
                       "Must resolve audio URL to GUID via episode index")
    }

    /// When the episode is completely unknown locally, fall back to whatever the action provides.
    func test_canonicalKey_fallsBackToUrl_whenEpisodeUnknown() {
        let svc = makeService(podcasts: [])
        let index = svc.buildEpisodeIndex()

        let action = makeAction(episode: "https://unknown.com/episode.mp3", guid: nil, device: "other-device")
        let key = svc.canonicalActionKey(for: action, index: index)
        XCTAssertEqual(key, "https://unknown.com/episode.mp3",
                       "Must fall back to URL when episode is unknown")
    }

    /// When the action has a GUID but the episode is NOT known locally,
    /// fall back to the GUID itself.
    func test_canonicalKey_fallsBackToGuid_whenEpisodeNotInIndex() {
        let svc = makeService(podcasts: [])
        let index = svc.buildEpisodeIndex()

        let action = makeAction(episode: "https://example.com/ep.mp3", guid: "orphan-guid")
        let key = svc.canonicalActionKey(for: action, index: index)
        XCTAssertEqual(key, "orphan-guid",
                       "Must fall back to GUID when episode is not in index")
    }
}
