import AppIntents
import Foundation

struct PodcastEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast")
    static var defaultQuery = PodcastEntityQuery()

    /// Feed URL — the canonical podcast key across the app and sync layer.
    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Author") var author: String?
    let artworkUrl: String?

    init(snapshot: PodcastSnapshot) {
        self.id = snapshot.feedUrl
        self.artworkUrl = snapshot.artworkUrl
        self.title = snapshot.title
        self.author = snapshot.author
    }

    var displayRepresentation: DisplayRepresentation {
        // See EpisodeEntity: a bare "\(title)" extracts as the shared key `%@`.
        DisplayRepresentation(
            title: LocalizedStringResource("entity.podcast.title",
                                           defaultValue: "\(title)",
                                           comment: "A show's title as Siri shows it. The argument is the title from its feed — nothing to translate."),
            subtitle: author.map {
                LocalizedStringResource("entity.podcast.author",
                                        defaultValue: "\($0)",
                                        comment: "A show's author as Siri shows it. The argument is the author from its feed — nothing to translate.")
            },
            image: artworkUrl.flatMap(URL.init(string:)).map { .init(url: $0) })
    }
}

struct PodcastEntityQuery: EntityStringQuery {
    @MainActor
    private func allPodcasts() async -> [PodcastEntity] {
        // Reuses the single bridge wiring path; on failure return [] (log-and-continue —
        // an empty picker beats a Siri error).
        let outcome = await SiriIntentBridge.shared.perform(.getPodcasts)
        guard case .podcasts(let snaps, _) = outcome else { return [] }
        return snaps.map(PodcastEntity.init(snapshot:))
    }

    func entities(for identifiers: [String]) async throws -> [PodcastEntity] {
        let ids = Set(identifiers)
        return await allPodcasts().filter { ids.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PodcastEntity] {
        await allPodcasts()
    }

    func entities(matching string: String) async throws -> [PodcastEntity] {
        await allPodcasts().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
}
