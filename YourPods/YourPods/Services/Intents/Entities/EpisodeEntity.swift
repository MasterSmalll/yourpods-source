import AppIntents
import Foundation

struct EpisodeEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode")
    static var defaultQuery = EpisodeEntityQuery()

    /// Composite key: "<podcastFeedUrl>|<episodeGuid>" — both halves are the canonical
    /// keys used by PodcastManager.markEpisodeAsPlayed(podcastUrl:episodeGuid:).
    let id: String
    let guid: String
    let podcastUrl: String
    let artworkUrl: String?

    @Property(title: "Title") var title: String
    @Property(title: "Podcast") var podcastTitle: String
    @Property(title: "Duration (seconds)") var durationSeconds: Int
    @Property(title: "Position (seconds)") var positionSeconds: Int
    @Property(title: "Remaining (seconds)") var remainingSeconds: Int
    @Property(title: "Played") var isPlayed: Bool
    @Property(title: "Published") var publishDate: Date?
    @Property(title: "Link") var deepLink: String

    init(snapshot: EpisodeSnapshot) {
        self.id = "\(snapshot.podcastUrl)|\(snapshot.guid)"
        self.guid = snapshot.guid
        self.podcastUrl = snapshot.podcastUrl
        self.artworkUrl = snapshot.artworkUrl
        self.title = snapshot.title
        self.podcastTitle = snapshot.podcastTitle
        self.durationSeconds = snapshot.durationSeconds
        self.positionSeconds = snapshot.positionSeconds
        self.remainingSeconds = max(0, snapshot.durationSeconds - snapshot.positionSeconds)
        self.isPlayed = snapshot.isPlayed
        self.publishDate = snapshot.pubDate
        var link = URLComponents(string: "yourpods://episode")!
        link.queryItems = [URLQueryItem(name: "feed", value: snapshot.podcastUrl),
                           URLQueryItem(name: "guid", value: snapshot.guid)]
        self.deepLink = link.url?.absoluteString ?? "yourpods://episode"
    }

    var displayRepresentation: DisplayRepresentation {
        // Named keys rather than bare "\(title)": the latter extracts as `%@`,
        // a single catalog entry shared by every unrelated one-argument
        // interpolation in the app. Both values are feed content.
        DisplayRepresentation(
            title: LocalizedStringResource("entity.episode.title",
                                           defaultValue: "\(title)",
                                           comment: "An episode's title as Siri shows it. The argument is the title from the podcast feed — nothing to translate."),
            subtitle: LocalizedStringResource("entity.episode.podcast",
                                              defaultValue: "\(podcastTitle)",
                                              comment: "The show an episode belongs to, as Siri shows it. The argument is the show's name from its feed — nothing to translate."),
            image: artworkUrl.flatMap(URL.init(string:)).map { .init(url: $0) })
    }
}

struct EpisodeEntityQuery: EntityQuery {
    @MainActor
    private func queueEntities() async -> [EpisodeEntity] {
        let outcome = await SiriIntentBridge.shared.perform(.getQueue)
        guard case .episodes(let snaps, _) = outcome else { return [] }
        return snaps.map(EpisodeEntity.init(snapshot:))
    }

    func entities(for identifiers: [String]) async throws -> [EpisodeEntity] {
        let ids = Set(identifiers)
        var pool = await queueEntities()
        // The currently playing episode isn't in the queue array — include it.
        if case .episode(let snap, _) = await SiriIntentBridge.shared.perform(.getCurrentEpisode) {
            pool.append(EpisodeEntity(snapshot: snap))
        }
        return pool.filter { ids.contains($0.id) }
    }

    func suggestedEntities() async throws -> [EpisodeEntity] {
        await queueEntities()
    }
}
