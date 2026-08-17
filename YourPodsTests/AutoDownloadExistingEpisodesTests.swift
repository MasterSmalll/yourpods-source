import XCTest
import SwiftData
@testable import YourPods

/// Integration tests for auto-download of already-present episodes.
///
/// Mirrors `AutoQueueIntegrationTests`: auto-queue has always backfilled the
/// latest existing unplayed episode (`autoQueueExistingEpisodes`), but
/// auto-download historically only fired for episodes a feed refresh discovered
/// as brand-new (`processNewEpisodes` → `newOnly`). That meant enabling
/// "Download New Episodes" for a podcast that already had unplayed episodes —
/// or subscribing — downloaded nothing until the next brand-new episode
/// published. These tests pin the backfill path: `autoDownloadExistingEpisodes`
/// downloads the most-recent unplayed episodes up to the per-podcast limit, and
/// it must actually be wired into `processNewEpisodes`.
@MainActor
final class AutoDownloadExistingEpisodesTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var podcastManager: PodcastManager!
    private var audioManager: AudioManager!
    private var playerManager: PlayerManager!
    private var downloadManager: DownloadManager!
    private var settingsManager: SettingsManager!

    private let testProfileId = "test-profile-autodownload-existing"

    override func setUp() {
        super.setUp()
        clearTestDefaults()

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        UserDefaults.standard.set(testProfileId, forKey: "activeProfileId")

        podcastManager = PodcastManager(modelContext: context)
        audioManager = AudioManager()
        playerManager = PlayerManager(audioManager: audioManager)
        playerManager.podcastManager = podcastManager
        downloadManager = DownloadManager()
        settingsManager = SettingsManager()
    }

    override func tearDown() {
        clearTestDefaults()
        podcastManager = nil
        audioManager = nil
        playerManager = nil
        downloadManager = nil
        settingsManager = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func clearTestDefaults() {
        let keys = [
            "activeProfileId",
            "subscriptionUrls_\(testProfileId)",
            "defaultAutoDownload",
            "defaultAutoQueueMode",
            "autoDownloadNetworkPolicy",
            "savedQueue",
            "savedCurrentItem",
            "savedCurrentPosition"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Inserts a podcast with `episodeCount` episodes (ep-1 newest … ep-N oldest)
    /// and auto-download configured per-podcast. Returns episodes sorted newest-first.
    @discardableResult
    private func insertPodcast(
        url: String,
        title: String = "Test Podcast",
        episodeCount: Int,
        autoDownload: Bool? = true,
        episodeLimit: Int? = nil
    ) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        var settings = PodcastSettings()
        settings.autoDownloadNewEpisodes = autoDownload
        settings.autoDownloadEpisodeLimit = episodeLimit
        podcast.settings = settings
        context.insert(podcast)

        for i in 1...episodeCount {
            let ep = Episode(
                guid: "ep-\(i)-\(url.hashValue)",
                title: "Episode \(i)",
                audioUrl: "https://example.com/ep\(i).mp3",
                pubDate: Date().addingTimeInterval(Double(-i * 86400)),
                durationSeconds: 3600,
                podcast: podcast
            )
            context.insert(ep)
        }

        try! context.save()
        podcastManager.associateWithCurrentProfile(url: url)
        podcastManager.loadSubscriptions()

        return podcast
    }

    private func sortedNewestFirst(_ podcast: Podcast) -> [Episode] {
        podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    private var activeGuids: Set<String> {
        Set(downloadManager.activeDownloads.keys)
    }

    // MARK: - Limit behavior

    /// Default limit (3 when unset) downloads only the 3 most-recent unplayed episodes.
    func test_autoDownloadExistingEpisodes_downloadsThreeMostRecent_whenLimitUnset() {
        let podcast = insertPodcast(url: "https://example.com/unset-limit", episodeCount: 5)
        let sorted = sortedNewestFirst(podcast)

        podcastManager.autoDownloadExistingEpisodes(downloadManager: downloadManager, settingsManager: settingsManager)

        XCTAssertEqual(activeGuids, Set(sorted.prefix(3).map(\.guid)),
                       "Unset per-podcast limit should download the 3 most-recent unplayed episodes")
    }

    /// Per-podcast limit caps how many existing episodes download.
    func test_autoDownloadExistingEpisodes_respectsPerPodcastLimit() {
        let podcast = insertPodcast(url: "https://example.com/limit-2", episodeCount: 5, episodeLimit: 2)
        let sorted = sortedNewestFirst(podcast)

        podcastManager.autoDownloadExistingEpisodes(downloadManager: downloadManager, settingsManager: settingsManager)

        XCTAssertEqual(activeGuids, Set(sorted.prefix(2).map(\.guid)),
                       "Per-podcast autoDownloadEpisodeLimit should cap the number of backfilled downloads")
    }

    // MARK: - Enable/disable gating

    /// Disabled per-podcast with global default off → nothing downloads.
    func test_autoDownloadExistingEpisodes_downloadsNothing_whenDisabled() {
        insertPodcast(url: "https://example.com/disabled", episodeCount: 3, autoDownload: false)
        settingsManager.defaultAutoDownload = false

        podcastManager.autoDownloadExistingEpisodes(downloadManager: downloadManager, settingsManager: settingsManager)

        XCTAssertTrue(activeGuids.isEmpty, "Auto-download off should download nothing")
    }

    /// Per-podcast nil falls back to the global default (on) and downloads.
    func test_autoDownloadExistingEpisodes_usesGlobalDefault_whenPerPodcastNil() {
        let podcast = insertPodcast(url: "https://example.com/global-on", episodeCount: 2, autoDownload: nil)
        settingsManager.defaultAutoDownload = true
        let sorted = sortedNewestFirst(podcast)

        podcastManager.autoDownloadExistingEpisodes(downloadManager: downloadManager, settingsManager: settingsManager)

        XCTAssertEqual(activeGuids, Set(sorted.map(\.guid)),
                       "nil per-podcast setting should adopt the global defaultAutoDownload")
    }

    // MARK: - Filtering

    /// Played episodes are skipped; the limit applies to remaining unplayed ones.
    func test_autoDownloadExistingEpisodes_skipsPlayedEpisodes() {
        let podcast = insertPodcast(url: "https://example.com/played", episodeCount: 3, episodeLimit: 3)
        let sorted = sortedNewestFirst(podcast)
        sorted[0].isPlayed = true   // newest already played
        try! context.save()

        podcastManager.autoDownloadExistingEpisodes(downloadManager: downloadManager, settingsManager: settingsManager)

        XCTAssertEqual(activeGuids, Set([sorted[1].guid, sorted[2].guid]),
                       "Played episodes must never be auto-downloaded")
    }

    /// Already-downloaded episodes are not re-downloaded; the next unplayed one is.
    func test_autoDownloadExistingEpisodes_skipsAlreadyDownloaded() {
        let podcast = insertPodcast(url: "https://example.com/already-dl", episodeCount: 3, episodeLimit: 1)
        let sorted = sortedNewestFirst(podcast)
        // Mark the newest as already downloaded on disk.
        downloadManager.downloadedFiles[sorted[0].guid] = URL(fileURLWithPath: "/tmp/already.mp3")

        podcastManager.autoDownloadExistingEpisodes(downloadManager: downloadManager, settingsManager: settingsManager)

        XCTAssertFalse(activeGuids.contains(sorted[0].guid),
                       "An already-downloaded episode must not start a new download")
    }

    // MARK: - Wiring

    /// Regression guard (see AutoQueueIntegrationTests header): the backfill must
    /// actually be invoked by processNewEpisodes, not just exist in isolation.
    func test_processNewEpisodes_triggersExistingEpisodeAutoDownload() async {
        let podcast = insertPodcast(url: "https://example.com/wiring", episodeCount: 2)
        let sorted = sortedNewestFirst(podcast)

        // No brand-new episodes this refresh — only the existing-episode backfill should fire.
        await podcastManager.processNewEpisodes(
            [],
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )

        XCTAssertEqual(activeGuids, Set(sorted.map(\.guid)),
                       "processNewEpisodes must invoke autoDownloadExistingEpisodes so enabling auto-download backfills existing episodes")
    }

    /// Regression: auto-queue marks the episode it queues as interacted, and the
    /// download candidate filter excludes interacted episodes. The download
    /// back-fill must therefore run before auto-queue, so the newest (most wanted)
    /// episode is downloaded rather than skipped in favor of an older one.
    func test_processNewEpisodes_downloadsNewest_evenWhenAlsoAutoQueued() async {
        let podcast = insertPodcast(url: "https://example.com/queue-and-download", episodeCount: 3, episodeLimit: 1)
        podcast.effectiveSettings.autoQueueMode = .normal
        try! context.save()
        settingsManager.defaultAutoQueueMode = .normal
        let sorted = sortedNewestFirst(podcast)

        await podcastManager.processNewEpisodes(
            [],
            playerManager: playerManager,
            downloadManager: downloadManager,
            settingsManager: settingsManager
        )

        XCTAssertTrue(activeGuids.contains(sorted[0].guid),
                      "Newest episode must download even though auto-queue also queued (and interacted-marked) it")
    }
}
