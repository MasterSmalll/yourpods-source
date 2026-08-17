import XCTest
import SwiftData
@testable import YourPods

/// The sync contract — Playback Completion Authority:
///
///   "Clients MUST mark the episode played on pull (iOS: `CompletedStateChange`
///    side-channel → `applyCompletedChanges`) and **MUST NOT re-derive completion from a
///    local position-threshold heuristic.**"
///
/// iOS re-derives it anyway, on every apply, from `position >= 95%` (outro-adjusted).
/// For a gPodder or Vault profile that inference is the only completion signal there is —
/// those clients mark an episode played *solely* by reporting `position == total`, and the
/// contract keeps the fallback for exactly them. For a Pro profile it is a second,
/// competing authority, and the two disagree in the one case that matters.
///
/// ## The failure it causes
///
/// Un-mark an episode as played on another device. The server records `completed: false`
/// and — if only the flag was resolved — leaves the position where it was, say 2167s of a
/// 2280s episode. iOS pulls that: the side-channel says *not played*, and the position
/// heuristic says *played*, because 2167 is past 95%. The heuristic runs on every
/// subsequent apply, long after the one-shot side-channel change has been consumed, so it
/// wins by repetition. **The un-complete undoes itself.**
///
/// Raised in review of the server half with the mechanism spelled out, and the reason the
/// sync contract's step (0) makes an explicit un-complete carry position 0 *and* the flag:
/// "both fields, so the position≥threshold inference cannot re-complete it".
@MainActor
final class CompletionAuthorityTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var manager: PodcastManager!

    private let testProfileId = "test-completion-authority"

    override func setUp() {
        super.setUp()
        clearTestDefaults()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext
        // Without an active profile, `associateWithCurrentProfile` records nothing and
        // `loadSubscriptions` finds nothing — the apply walks an empty list and every
        // suppression assertion passes for the wrong reason.
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
            "lastSubscriptionSync_\(testProfileId)",
            "lastEpisodeActionSync_\(testProfileId)",
            "episodeActionMap",
            "syncConflictCounts",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Fixtures

    private final class StubAuthProvider: AuthProvider, @unchecked Sendable {
        var isAuthenticated: Bool { true }
        var currentUserEmail: String? { "test@example.com" }
        func signIn(email: String, password: String) async throws -> String { "stub-token" }
        func createUser(email: String, password: String) async throws -> String { "stub-token" }
        func getValidToken() async throws -> String { "stub-token" }
        func signOut() async {}
    }

    /// A real `YourPodsProClient` — the apply path decides by type, and no request is made.
    private func makeProClient() -> YourPodsProClient {
        YourPodsProClient(
            baseUrl: "https://api.yourpods.app",
            authProvider: StubAuthProvider(),
            session: URLSession(configuration: .ephemeral)
        )
    }

    /// Mirrors the working fixture in `ConflictResolutionTests`: an episode the context
    /// knows about is not enough — `applyEpisodeActions` walks `manager.subscriptions`, so
    /// without the profile association and the load the apply is a no-op and every
    /// assertion about suppression passes for the wrong reason.
    @discardableResult
    private func insertPodcast(url: String) -> Podcast {
        let podcast = Podcast(url: url, title: "Test Podcast")
        context.insert(podcast)
        let episode = Episode(
            guid: "ep-guid-1",
            title: "Episode One",
            audioUrl: "https://cdn.example.com/ep1.mp3",
            pubDate: Date(),
            durationSeconds: 2280,
            podcast: podcast
        )
        context.insert(episode)
        try! context.save()
        manager.associateWithCurrentProfile(url: url)
        manager.loadSubscriptions()
        return podcast
    }

    private func seedActionMap(_ entries: [String: EpisodeAction]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "episodeActionMap")
        }
        manager.loadActionMap()
    }

    /// A server report of a position past the completion threshold: 2167 of 2280 is 95.0%.
    private func actionPastThreshold(for episode: Episode, podcast: Podcast) -> EpisodeAction {
        EpisodeAction(
            podcast: podcast.url,
            episode: episode.audioUrl ?? "",
            guid: episode.guid,
            action: "play",
            timestamp: Int(Date().timeIntervalSince1970),
            position: 2167,
            started: 0,
            total: 2280,
            device: "yourpods-web-abcd1234"
        )
    }

    // MARK: - The contract violation

    /// The defect, stated once: on a Pro profile the position heuristic must not run at all.
    func test_proProfile_positionPastThreshold_doesNotMarkPlayed() {
        let podcast = insertPodcast(url: "https://example.com/feed-pro")
        let episode = podcast.episodes.first!
        episode.isPlayed = false
        try! context.save()
        manager.setSyncClient(makeProClient(), deviceId: "yourpods-iPhone-test")
        seedActionMap([episode.guid: actionPastThreshold(for: episode, podcast: podcast)])

        manager.applyEpisodeActions(strategy: .serverWins)

        XCTAssertFalse(
            episode.isPlayed,
            "the sync contract: the completed side-channel is authoritative for Pro. Re-deriving "
            + "completion from position gives the un-complete a second opponent that re-runs on "
            + "every apply — so it wins by repetition and the episode re-marks itself played"
        )
    }

    /// The other side of the rule. gPodder and Vault clients mark an episode played *solely*
    /// by reporting `position == total`; deleting the inference for them would delete the
    /// only completion signal those profiles have.
    func test_nonProProfile_positionPastThreshold_stillMarksPlayed() {
        let podcast = insertPodcast(url: "https://example.com/feed-gpodder")
        let episode = podcast.episodes.first!
        episode.isPlayed = false
        try! context.save()
        // No Pro client set — gPodder / Nextcloud / Vault.
        seedActionMap([episode.guid: actionPastThreshold(for: episode, podcast: podcast)])

        manager.applyEpisodeActions(strategy: .serverWins)

        XCTAssertTrue(episode.isPlayed,
                      "the position fallback is the whole completion signal for a gPodder profile")
    }

    /// Suppressing the heuristic must not suppress completion itself: the side-channel the
    /// contract names as authoritative has to keep marking episodes played on Pro.
    func test_proProfile_completedSideChannel_stillMarksPlayed() {
        let podcast = insertPodcast(url: "https://example.com/feed-pro-2")
        let episode = podcast.episodes.first!
        episode.isPlayed = false
        try! context.save()
        manager.setSyncClient(makeProClient(), deviceId: "yourpods-iPhone-test")

        manager.episodeActionSync.applyCompletedChanges([CompletedStateChange(guid: episode.guid)])

        XCTAssertTrue(episode.isPlayed,
                      "applyCompletedChanges IS the authority the contract points at — it must still fire")
    }

    /// The scenario end to end, in the order a real sync runs it: the server reports the
    /// position *and* the un-complete in the same pull, and the episode has to come out
    /// unplayed — then stay that way when the next apply sees the same position with no
    /// change attached, which is where it used to come back.
    func test_proProfile_unCompletedEpisode_staysUnplayedAcrossASecondApply() {
        let podcast = insertPodcast(url: "https://example.com/feed-relisten")
        let episode = podcast.episodes.first!
        episode.isPlayed = true
        episode.listenedSeconds = 2167
        try! context.save()
        manager.setSyncClient(makeProClient(), deviceId: "yourpods-iPhone-test")
        seedActionMap([episode.guid: actionPastThreshold(for: episode, podcast: podcast)])

        manager.applyEpisodeActions(strategy: .serverWins)
        manager.episodeActionSync.applyUncompletedChanges([UncompletedStateChange(guid: episode.guid)])

        XCTAssertFalse(episode.isPlayed, "the un-complete did not survive its own sync cycle")

        // The change is one-shot; the position is not. This second apply is the one that
        // used to undo it.
        manager.applyEpisodeActions(strategy: .serverWins)

        XCTAssertFalse(
            episode.isPlayed,
            "re-marked played by the position heuristic on the next apply — the un-complete "
            + "survives exactly one cycle and then reverts, with nothing on screen to explain it"
        )
    }

    // MARK: - The background write path

    /// `applyEpisodeActionsCore(cooperative:)` delegates the write loop to `SyncStore`,
    /// which carries its own copy of the heuristic. A guard on only the MainActor path
    /// would leave the one that actually runs during a sync untouched.
    func test_syncStore_serverAuthoritative_doesNotMarkPlayedFromPosition() async {
        let podcast = insertPodcast(url: "https://example.com/feed-store")
        let episode = podcast.episodes.first!
        episode.isPlayed = false
        try! context.save()
        let store = SyncStore(container: container)

        _ = await store.applyEpisodeActions(
            actionMap: [episode.guid: actionPastThreshold(for: episode, podcast: podcast)],
            strategy: .serverWins,
            deviceId: "yourpods-iPhone-test",
            completionIsServerAuthoritative: true
        )

        context.rollback()
        let refetched = try? context.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(refetched?.first(where: { $0.guid == "ep-guid-1" })?.isPlayed, false)
    }

    func test_syncStore_notServerAuthoritative_stillMarksPlayedFromPosition() async {
        let podcast = insertPodcast(url: "https://example.com/feed-store-2")
        let episode = podcast.episodes.first!
        episode.isPlayed = false
        try! context.save()
        let store = SyncStore(container: container)

        _ = await store.applyEpisodeActions(
            actionMap: [episode.guid: actionPastThreshold(for: episode, podcast: podcast)],
            strategy: .serverWins,
            deviceId: "yourpods-iPhone-test",
            completionIsServerAuthoritative: false
        )

        context.rollback()
        let refetched = try? context.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(refetched?.first(where: { $0.guid == "ep-guid-1" })?.isPlayed, true)
    }
}
