import XCTest
@testable import YourPods

@MainActor
final class IntentEntityTests: XCTestCase {

    override func tearDown() {
        SiriIntentBridge.shared.handler = nil
        super.tearDown()
    }

    private func stubPodcasts(_ snaps: [PodcastSnapshot]) {
        SiriIntentBridge.shared.handler = { command in
            command == .getPodcasts ? .podcasts(snaps, dialog: "") : .failure(message: "unexpected \(command)")
        }
    }

    private let pods = [
        PodcastSnapshot(feedUrl: "https://feed/atp", title: "Accidental Tech Podcast",
                        author: "ATP", artworkUrl: nil),
        PodcastSnapshot(feedUrl: "https://feed/talk", title: "The Talk Show",
                        author: nil, artworkUrl: nil),
    ]

    // MARK: - PodcastEntityQuery

    func test_suggestedEntities_returnsAllSubscriptions() async throws {
        stubPodcasts(pods)
        let result = try await PodcastEntityQuery().suggestedEntities()
        XCTAssertEqual(result.map(\.id), ["https://feed/atp", "https://feed/talk"])
    }

    func test_entitiesForIdentifiers_filtersById() async throws {
        stubPodcasts(pods)
        let result = try await PodcastEntityQuery().entities(for: ["https://feed/talk"])
        XCTAssertEqual(result.map(\.title), ["The Talk Show"])
    }

    func test_entitiesMatchingString_matchesTitleCaseInsensitive() async throws {
        stubPodcasts(pods)
        let result = try await PodcastEntityQuery().entities(matching: "tech")
        XCTAssertEqual(result.map(\.title), ["Accidental Tech Podcast"])
    }

    func test_suggestedEntities_returnsEmpty_whenBridgeFails() async throws {
        SiriIntentBridge.shared.handler = nil
        let result = try await PodcastEntityQuery().suggestedEntities()
        XCTAssertTrue(result.isEmpty)   // log-and-continue: never throw at Siri
    }

    // MARK: - EpisodeEntity

    func test_episodeEntity_compositeIdAndDerivedProperties() {
        let snap = EpisodeSnapshot(guid: "g1", podcastUrl: "https://feed/atp",
                                   title: "Ep", podcastTitle: "ATP",
                                   audioUrl: "https://a/1.mp3", artworkUrl: nil,
                                   durationSeconds: 600, positionSeconds: 90,
                                   isPlayed: false, pubDate: nil)
        let entity = EpisodeEntity(snapshot: snap)
        XCTAssertEqual(entity.id, "https://feed/atp|g1")
        XCTAssertEqual(entity.remainingSeconds, 510)
        XCTAssertTrue(entity.deepLink.hasPrefix("yourpods://episode?"))
        XCTAssertTrue(entity.deepLink.contains("guid=g1"))
    }

    func test_episodeEntityQuery_suggestedEntities_returnsQueue() async throws {
        let snap = EpisodeSnapshot(guid: "g1", podcastUrl: "f", title: "Ep",
                                   podcastTitle: "P", audioUrl: "a", artworkUrl: nil,
                                   durationSeconds: 0, positionSeconds: 0,
                                   isPlayed: false, pubDate: nil)
        SiriIntentBridge.shared.handler = { command in
            command == .getQueue ? .episodes([snap], dialog: "") : .failure(message: "unexpected")
        }
        let result = try await EpisodeEntityQuery().suggestedEntities()
        XCTAssertEqual(result.map(\.id), ["f|g1"])
    }
}
