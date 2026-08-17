import SwiftData
import Foundation

/// Local annotation (note) attached to a podcast episode.
///
/// Available to ALL users locally. Cloud sync via `POST /annotations/sync`
/// is gated behind YourPods Pro. This matches the Podcast Groups pattern —
/// local feature for everyone, sync for Pro.
@Model
final class Annotation {
    /// Client-generated UUID (matches server `id` field).
    /// Named `annotationId` to avoid colliding with SwiftData's synthesized
    /// `PersistentModel.id` property (which is a `PersistentIdentifier`).
    @Attribute(.unique) var annotationId: String
    /// RSS `<enclosure url>` — primary key for episode identity across devices.
    var episodeUrl: String
    /// RSS feed URL — identifies the podcast.
    var podcastUrl: String
    /// RSS `<guid>` if available.
    var episodeGuid: String?
    /// Playback position in seconds where the note was created.
    var timestampSec: Double
    /// Note body text (required).
    var noteText: String
    /// Chapter title at the time of note creation.
    var chapterTitle: String?
    /// Chapter start time in seconds.
    var chapterStartSec: Double?
    /// Highlighted transcript text.
    var transcriptText: String?
    /// Transcript segment start time in seconds.
    var transcriptStartSec: Double?
    /// Transcript segment end time in seconds.
    var transcriptEndSec: Double?
    /// Semantic color name: "blue", "green", "purple", "yellow", "red", or nil (default).
    var color: String?
    /// Normalized tag array (lowercase, hyphenated).
    var tags: [String]
    /// Soft-delete flag for tombstone propagation.
    var deleted: Bool
    /// True when local changes haven't been synced to the server yet.
    var isDirty: Bool
    /// When this annotation was created locally.
    var createdAt: Date
    /// Last local modification time.
    var updatedAt: Date
    /// Last successful sync time (nil = never synced).
    var syncedAt: Date?

    // MARK: - Episode Snapshot (denormalized for offline browsing)

    var podcastTitle: String?
    var episodeTitle: String?
    var artUrl: String?
    var episodeDescription: String?
    var durationSec: Double?
    /// VTT/SRT URL — required in snapshot for web transcript viewer linking.
    var transcriptUrl: String?

    init(
        annotationId: String = UUID().uuidString,
        episodeUrl: String,
        podcastUrl: String,
        episodeGuid: String? = nil,
        timestampSec: Double,
        noteText: String,
        chapterTitle: String? = nil,
        chapterStartSec: Double? = nil,
        transcriptText: String? = nil,
        transcriptStartSec: Double? = nil,
        transcriptEndSec: Double? = nil,
        color: String? = nil,
        tags: [String] = [],
        deleted: Bool = false,
        isDirty: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        syncedAt: Date? = nil,
        podcastTitle: String? = nil,
        episodeTitle: String? = nil,
        artUrl: String? = nil,
        episodeDescription: String? = nil,
        durationSec: Double? = nil,
        transcriptUrl: String? = nil
    ) {
        self.annotationId = annotationId
        self.episodeUrl = episodeUrl
        self.podcastUrl = podcastUrl
        self.episodeGuid = episodeGuid
        self.timestampSec = timestampSec
        self.noteText = noteText
        self.chapterTitle = chapterTitle
        self.chapterStartSec = chapterStartSec
        self.transcriptText = transcriptText
        self.transcriptStartSec = transcriptStartSec
        self.transcriptEndSec = transcriptEndSec
        self.color = color
        self.tags = tags
        self.deleted = deleted
        self.isDirty = isDirty
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncedAt = syncedAt
        self.podcastTitle = podcastTitle
        self.episodeTitle = episodeTitle
        self.artUrl = artUrl
        self.episodeDescription = episodeDescription
        self.durationSec = durationSec
        self.transcriptUrl = transcriptUrl
    }
}
