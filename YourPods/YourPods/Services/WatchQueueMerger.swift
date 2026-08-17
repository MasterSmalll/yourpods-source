import Foundation
import os

// MARK: - Shared watch queue data types
//
// Moved here (from YourPodsWatch/WatchSessionManager.swift, watch-target-only)
// so `WatchQueueMerger` below — which needs to be compiled into BOTH the main
// iOS target (for YourPodsTests) and the watch target (for production use) —
// can reference them. No behavior change: verbatim relocation.

struct WatchChapter: Identifiable, Codable {
    var id: Double { startTime }
    let startTime: Double // seconds
    let title: String
    let img: String?
    let url: String?
}

struct WatchEpisode: Identifiable, Codable {
    let id: String
    let title: String
    let album: String
    let artist: String
    let duration: Int
    let localPath: String? // Path relative to Documents directory
    let streamUrl: String? // Remote URL for streaming
    let artUri: String? // Cover art URL
    let isAvailableOnPhone: Bool // If true, can be manually downloaded
    let chapters: [WatchChapter]? // Episode chapters (if available)
    var position: Int // Playback position in seconds (synced from iOS)
    let pubDate: Date? // Episode publish date (for Recently Updated sorting)
    let podcastTitle: String? // Podcast name (for cross-podcast display)
    let podcastArtUri: String? // Podcast artwork URL (for Recently Updated)

    /// Backward-compatible decoder — new optional fields default to nil
    /// when decoding payloads from older iOS app versions or persisted data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        album = try container.decode(String.self, forKey: .album)
        artist = try container.decode(String.self, forKey: .artist)
        duration = try container.decode(Int.self, forKey: .duration)
        localPath = try container.decodeIfPresent(String.self, forKey: .localPath)
        streamUrl = try container.decodeIfPresent(String.self, forKey: .streamUrl)
        artUri = try container.decodeIfPresent(String.self, forKey: .artUri)
        isAvailableOnPhone = try container.decode(Bool.self, forKey: .isAvailableOnPhone)
        chapters = try container.decodeIfPresent([WatchChapter].self, forKey: .chapters)
        position = try container.decode(Int.self, forKey: .position)
        pubDate = try container.decodeIfPresent(Date.self, forKey: .pubDate)
        podcastTitle = try container.decodeIfPresent(String.self, forKey: .podcastTitle)
        podcastArtUri = try container.decodeIfPresent(String.self, forKey: .podcastArtUri)
    }

    init(id: String, title: String, album: String, artist: String, duration: Int,
         localPath: String?, streamUrl: String?, artUri: String?,
         isAvailableOnPhone: Bool, chapters: [WatchChapter]?, position: Int,
         pubDate: Date? = nil, podcastTitle: String? = nil, podcastArtUri: String? = nil) {
        self.id = id
        self.title = title
        self.album = album
        self.artist = artist
        self.duration = duration
        self.localPath = localPath
        self.streamUrl = streamUrl
        self.artUri = artUri
        self.isAvailableOnPhone = isAvailableOnPhone
        self.chapters = chapters
        self.position = position
        self.pubDate = pubDate
        self.podcastTitle = podcastTitle
        self.podcastArtUri = podcastArtUri
    }

    /// Copy with a different localPath, preserving every other field.
    func with(localPath newLocalPath: String?) -> WatchEpisode {
        WatchEpisode(id: id, title: title, album: album, artist: artist,
                     duration: duration, localPath: newLocalPath, streamUrl: streamUrl,
                     artUri: artUri, isAvailableOnPhone: isAvailableOnPhone,
                     chapters: chapters, position: position, pubDate: pubDate,
                     podcastTitle: podcastTitle, podcastArtUri: podcastArtUri)
    }
}

// MARK: - WatchQueueMerger

/// Pure parse+merge for incoming queue context. Decodes via WatchWireFormat
/// (single source of truth) and preserves watch-local state (localPath) from
/// the existing episode list. Mirrors the historical inline logic in
/// WatchSessionManager.handleQueueUpdate so it can be tested from YourPodsTests.
///
/// `WatchWireFormat.decodeQueueItem` exists as the single source of
/// truth for the queue wire format specifically because a hand-rolled parser
/// on one side and a hand-rolled encoder on the other can silently drift.
/// `handleQueueUpdate` still hand-parsed the raw context dicts instead of
/// using that decoder — this extraction closes that gap.
enum WatchQueueMerger {
    private static let logger = Logger(subsystem: "com.yourpods", category: "WatchQueueMerger")

    /// - Parameters:
    ///   - rawQueue: the raw `"queue"` array from applicationContext / a
    ///     `refresh_queue` reply / a background refresh.
    ///   - existing: the current in-memory episode list, consulted to preserve
    ///     watch-local state (localPath, and chapters/artUri when the payload
    ///     omits them) for items that were already present.
    /// - Returns: the merged episode list, in payload order. Items with no
    ///   `"id"` are dropped (never crash).
    static func merge(rawQueue: [[String: Any]], existing: [WatchEpisode]) -> [WatchEpisode] {
        var merged: [WatchEpisode] = []
        merged.reserveCapacity(rawQueue.count)
        var droppedCount = 0

        for item in rawQueue {
            guard let payload = WatchWireFormat.decodeQueueItem(item) else {
                droppedCount += 1
                continue
            }

            let existingEpisode = existing.first(where: { $0.id == payload.id })

            // Parse chapters if present (decodeQueueItem passes the raw dicts
            // through — WatchWireFormat has no chapter type of its own).
            var parsedChapters: [WatchChapter]? = nil
            if let chaptersData = payload.chapters {
                parsedChapters = chaptersData.compactMap { chData -> WatchChapter? in
                    guard let startTime = chData["startTime"] as? Double,
                          let title = chData["title"] as? String else { return nil }
                    return WatchChapter(
                        startTime: startTime,
                        title: title,
                        img: chData["img"] as? String,
                        url: chData["url"] as? String
                    )
                }
                if parsedChapters?.isEmpty == true { parsedChapters = nil }
            }

            // Use the server position, but preserve local position if it's
            // ahead (e.g., watch was actively playing this episode).
            let localPosition = existingEpisode?.position ?? 0
            let effectivePosition = max(payload.position, localPosition)

            merged.append(WatchEpisode(
                id: payload.id,
                title: payload.title,
                album: payload.album,
                artist: payload.artist,
                duration: payload.duration,
                localPath: existingEpisode?.localPath, // Keep path if we had it, otherwise nil
                streamUrl: payload.url,
                artUri: payload.artUri ?? existingEpisode?.artUri,
                isAvailableOnPhone: payload.isAvailableOnPhone,
                chapters: parsedChapters ?? existingEpisode?.chapters,
                position: effectivePosition
            ))
        }

        if droppedCount > 0 {
            logger.debug("Dropped \(droppedCount) queue item(s) with no id")
        }

        return merged
    }
}
