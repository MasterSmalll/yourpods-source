// YourPods/YourPods/Services/WatchWireFormat.swift
import Foundation

/// Single source of truth for every phone↔watch dictionary payload.
/// Compiled into BOTH the iOS app target and the watch app target so the
/// producer and parser can never drift (the guid/imageUrl mismatch of 2026-07
/// made watch library browsing silently return zero episodes).
enum WatchWireFormat {

    // MARK: - Queue items (applicationContext "queue" array + refresh_queue replies)

    struct QueueItemPayload {
        let id: String
        let title: String
        let album: String
        let artist: String
        let duration: Int
        let position: Int
        let url: String?
        let artUri: String?
        let autoDownload: Bool
        let isAvailableOnPhone: Bool
        let chapters: [[String: Any]]?
    }

    static func encodeQueueItem(_ item: QueueItemPayload) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.id,
            "title": item.title,
            "album": item.album,
            "artist": item.artist,
            "duration": item.duration,
            "position": item.position,
            "url": item.url ?? "",
            "artUri": item.artUri ?? "",
            "autoDownload": item.autoDownload,
            "isAvailableOnPhone": item.isAvailableOnPhone,
        ]
        if let chapters = item.chapters { dict["chapters"] = chapters }
        return dict
    }

    static func decodeQueueItem(_ dict: [String: Any]) -> QueueItemPayload? {
        guard let id = dict["id"] as? String else { return nil }
        return QueueItemPayload(
            id: id,
            title: dict["title"] as? String ?? WireString.unknownTitle,
            album: dict["album"] as? String ?? "",
            artist: dict["artist"] as? String ?? "",
            duration: dict["duration"] as? Int ?? 0,
            position: dict["position"] as? Int ?? 0,
            url: dict["url"] as? String,
            artUri: dict["artUri"] as? String,
            autoDownload: dict["autoDownload"] as? Bool ?? false,
            isAvailableOnPhone: dict["isAvailableOnPhone"] as? Bool ?? false,
            chapters: dict["chapters"] as? [[String: Any]]
        )
    }

    // MARK: - Episode list items (episodes_for_feed / recent_episodes)

    struct EpisodeListItem {
        let guid: String
        let title: String
        let duration: Int
        let audioUrl: String?
        let imageUrl: String?
    }

    static func encodeEpisodeListItem(_ item: EpisodeListItem) -> [String: Any] {
        [
            "guid": item.guid,
            "title": item.title,
            "duration": item.duration,
            "audioUrl": item.audioUrl ?? "",
            "imageUrl": item.imageUrl ?? "",
        ]
    }

    static func decodeEpisodeListItem(_ dict: [String: Any]) -> EpisodeListItem? {
        // Legacy fallbacks: pre-fix iOS builds sent "id" and "artUri".
        guard let guid = (dict["guid"] as? String) ?? (dict["id"] as? String) else { return nil }
        return EpisodeListItem(
            guid: guid,
            title: dict["title"] as? String ?? WireString.unknownTitle,
            duration: dict["duration"] as? Int ?? 0,
            audioUrl: dict["audioUrl"] as? String,
            imageUrl: (dict["imageUrl"] as? String) ?? (dict["artUri"] as? String)
        )
    }

    // MARK: - Watch→phone actions

    enum Action: String {
        case markAsPlayed = "mark_as_played"
        case removeFromQueue = "remove_from_queue"
        case updateProgress = "update_progress"
    }

    struct DecodedAction {
        let action: Action
        let episodeId: String
        let position: Int?
        let sentAt: TimeInterval?
    }

    static func encodeAction(_ action: Action, episodeId: String,
                             position: Int?, sentAt: TimeInterval) -> [String: Any] {
        var dict: [String: Any] = [
            "command": action.rawValue,
            "episodeId": episodeId,
            "sentAt": sentAt,
        ]
        if let position { dict["position"] = position }
        return dict
    }

    static func decodeAction(_ dict: [String: Any]) -> DecodedAction? {
        guard let raw = dict["command"] as? String,
              let action = Action(rawValue: raw),
              let episodeId = dict["episodeId"] as? String else { return nil }
        return DecodedAction(
            action: action,
            episodeId: episodeId,
            position: dict["position"] as? Int,
            sentAt: dict["sentAt"] as? TimeInterval
        )
    }
}
