import XCTest
import SwiftData
@testable import YourPods

/// The completed / uncompleted / hidden side-channels must find the episode they name.
///
/// `parseRecentResponse` keys every one of them as `episodeGuid ?? episodeUrl` — the URL
/// is the documented fallback for a row the server holds without a GUID, which is what web
/// and the gPodder bridge write. All three appliers then matched strictly on
/// `episode.guid == key`.
///
/// So for those rows the key is an **audio URL** being compared against local **GUIDs**,
/// which never matches. Not "sometimes": a NULL-guid completion is dropped **100%** of the
/// time, silently, and the server considers it delivered.
///
/// The repo already knows how to match these — `lookupDevicePosition` tries guid, then
/// lower-cased guid, then audio URL, and the case-insensitive step exists because
/// UUID-style GUIDs come back from some servers in a different case than the feed wrote
/// them (RFC 4122 says they are case-insensitive). The side-channels never got the same
/// treatment.
@MainActor
final class SideChannelMatchingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: EpisodeActionSyncService!

    private var podcast: Podcast!

    private let guidEpisodeGuid = "4C2C0FCE-1E3D-4F6B-9A11-B0D2E3F4A5B6"
    private let guidEpisodeUrl = "https://cdn.example.com/guid-ep.mp3"
    private let urlOnlyGuid = "url-only-ep-guid"
    private let urlOnlyUrl = "https://cdn.example.com/url-only-ep.mp3"

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = container.mainContext

        podcast = Podcast(url: "https://feeds.example.com/show.xml", title: "Show")
        context.insert(podcast)
        for (guid, url) in [(guidEpisodeGuid, guidEpisodeUrl), (urlOnlyGuid, urlOnlyUrl)] {
            let ep = Episode(guid: guid, title: "Episode", audioUrl: url,
                             pubDate: Date(), durationSeconds: 1800, podcast: podcast)
            ep.isPlayed = false
            context.insert(ep)
        }
        try! context.save()

        let pod = podcast!
        service = EpisodeActionSyncService(
            modelContext: context,
            subscriptionsProvider: { [pod] },
            syncClientProvider: { nil },
            profileIdProvider: { "test-side-channel" },
            deviceIdProvider: { "yourpods-iPhone-side" }
        )
    }

    override func tearDown() {
        service = nil
        podcast = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func episode(guid: String) -> Episode? {
        podcast.episodes.first { $0.guid == guid }
    }

    // MARK: - The 100% case

    /// A completion the server holds without a GUID. The key is an audio URL, and matching
    /// it against local GUIDs cannot ever succeed.
    func test_completed_matchesByAudioUrl_whenTheServerHasNoGuid() {
        service.applyCompletedChanges([CompletedStateChange(guid: urlOnlyUrl)])

        XCTAssertEqual(
            episode(guid: urlOnlyGuid)?.isPlayed, true,
            "a NULL-guid completion is keyed by episodeUrl and was matched against local "
            + "GUIDs — dropped 100% of the time, silently, while the server counts it delivered"
        )
    }

    func test_uncompleted_matchesByAudioUrl_whenTheServerHasNoGuid() {
        episode(guid: urlOnlyGuid)?.isPlayed = true
        try! context.save()

        service.applyUncompletedChanges([UncompletedStateChange(guid: urlOnlyUrl)])

        XCTAssertEqual(episode(guid: urlOnlyGuid)?.isPlayed, false)
    }

    func test_hidden_matchesByAudioUrl_whenTheServerHasNoGuid() {
        service.applyHiddenChanges([HiddenStateChange(guid: urlOnlyUrl, hidden: true)])

        XCTAssertEqual(episode(guid: urlOnlyGuid)?.isPlayed, true,
                       "hiding marks played locally, so a missed match leaves the episode visible")
    }

    // MARK: - Case-insensitive GUIDs

    /// RFC 4122 UUIDs are case-insensitive, and some servers hand them back in a different
    /// case than the feed wrote them. `lookupEpisodeMetadata` already compensates; the
    /// side-channels did not, so a completion for a UUID-guid episode could vanish on the
    /// same account that resolves its conflicts correctly.
    func test_completed_matchesGuid_caseInsensitively() {
        service.applyCompletedChanges([CompletedStateChange(guid: guidEpisodeGuid.lowercased())])

        XCTAssertEqual(episode(guid: guidEpisodeGuid)?.isPlayed, true)
    }

    // MARK: - Exact matches still win

    func test_completed_stillMatchesAnExactGuid() {
        service.applyCompletedChanges([CompletedStateChange(guid: guidEpisodeGuid)])

        XCTAssertEqual(episode(guid: guidEpisodeGuid)?.isPlayed, true)
    }

    /// A key that names nothing must change nothing — the fallback widens matching, it does
    /// not make it guess.
    func test_completed_unknownKey_touchesNoEpisode() {
        service.applyCompletedChanges([CompletedStateChange(guid: "https://cdn.example.com/not-mine.mp3")])

        XCTAssertEqual(episode(guid: guidEpisodeGuid)?.isPlayed, false)
        XCTAssertEqual(episode(guid: urlOnlyGuid)?.isPlayed, false)
    }

    /// The URL fallback must not reach across episodes: matching is guid, then case-folded
    /// guid, then audio URL — never a partial or prefix match.
    func test_completed_urlOfOneEpisode_doesNotCompleteAnother() {
        service.applyCompletedChanges([CompletedStateChange(guid: urlOnlyUrl)])

        XCTAssertEqual(episode(guid: guidEpisodeGuid)?.isPlayed, false,
                       "the other episode was completed by a URL that is not its own")
    }
}
