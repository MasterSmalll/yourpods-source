import Foundation

/// A shared episode resolved from a deep link (transient — not persisted).
/// `id` is a fresh token so `.sheet(item:)` rebuilds on re-open (mirrors EpisodeSheetItem).
struct SharedEpisode: Identifiable, Equatable, Sendable {
    let id: String
    let guid: String
    let title: String
    let podcastTitle: String
    let podcastAuthor: String?
    let audioUrl: String
    let feedUrl: String
    let artworkUrl: String?
    let durationSeconds: Int?
    let episodeDescription: String?
    let startSec: Int?
    let pubDate: Date?

    init(guid: String, title: String, podcastTitle: String, podcastAuthor: String?,
         audioUrl: String, feedUrl: String, artworkUrl: String?, durationSeconds: Int?,
         episodeDescription: String?, startSec: Int?, pubDate: Date?) {
        self.id = UUID().uuidString
        self.guid = guid
        self.title = title
        self.podcastTitle = podcastTitle
        self.podcastAuthor = podcastAuthor
        self.audioUrl = audioUrl
        self.feedUrl = feedUrl
        self.artworkUrl = artworkUrl
        self.durationSeconds = durationSeconds
        self.episodeDescription = episodeDescription
        self.startSec = startSec
        self.pubDate = pubDate
    }

    func toQueueItem(positionSeconds: Int = 0) -> QueueItem {
        QueueItem(
            id: guid, title: title, podcastTitle: podcastTitle, audioUrl: audioUrl,
            artworkUrl: artworkUrl, durationSeconds: durationSeconds,
            positionSeconds: positionSeconds, podcastUrl: feedUrl, pubDate: pubDate,
            podcastAuthor: podcastAuthor, episodeDescription: episodeDescription)
    }
}

/// A shared podcast resolved from a deep link (transient).
struct SharedPodcast: Identifiable, Equatable, Sendable {
    let id: String
    let feedUrl: String
    let title: String
    let author: String?
    let artworkUrl: String?
    let podcastDescription: String?

    init(feedUrl: String, title: String, author: String?, artworkUrl: String?, podcastDescription: String?) {
        self.id = UUID().uuidString
        self.feedUrl = feedUrl
        self.title = title
        self.author = author
        self.artworkUrl = artworkUrl
        self.podcastDescription = podcastDescription
    }
}
