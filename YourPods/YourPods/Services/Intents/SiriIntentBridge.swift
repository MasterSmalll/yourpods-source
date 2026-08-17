import Foundation
import OSLog

// MARK: - Snapshots (Sendable value types — never live SwiftData models)

struct EpisodeSnapshot: Sendable, Equatable {
    let guid: String
    let podcastUrl: String
    let title: String
    let podcastTitle: String
    let audioUrl: String
    let artworkUrl: String?
    let durationSeconds: Int
    let positionSeconds: Int
    let isPlayed: Bool
    let pubDate: Date?
}

extension EpisodeSnapshot {
    init(item: QueueItem, livePositionSeconds: Int? = nil) {
        self.init(
            guid: item.id,
            podcastUrl: item.podcastUrl,
            title: item.title,
            podcastTitle: item.podcastTitle,
            audioUrl: item.audioUrl,
            artworkUrl: item.artworkUrl,
            durationSeconds: item.durationSeconds ?? 0,
            positionSeconds: livePositionSeconds ?? item.positionSeconds,
            isPlayed: item.isPlayed,
            pubDate: item.pubDate)
    }
}

struct PodcastSnapshot: Sendable, Equatable {
    let feedUrl: String
    let title: String
    let author: String?
    let artworkUrl: String?
}

struct ListeningStatsSnapshot: Sendable, Equatable {
    let minutesToday: Int
    let minutesThisWeek: Int
    let episodesCompleted: Int
    let currentStreakDays: Int
}

// MARK: - Commands

enum SiriIntentCommand: Sendable, Equatable {
    // Playback
    case playQueue
    case pause
    case stop
    case skipForward
    case skipBackward
    case nextEpisode
    case restartEpisode
    case setSpeed(Float)
    case playPodcast(feedUrl: String)
    case nextChapter
    case previousChapter
    // Sleep timer
    case setSleepTimer(minutes: Int)
    case cancelSleepTimer
    case extendSleepTimer(minutes: Int)
    // Queue & library
    case checkForNewEpisodes
    case downloadQueue
    case downloadLatest(feedUrl: String)
    case markPlayedAndPlayNext
    case clearQueue
    // Getters
    case getCurrentEpisode
    case getQueue
    case getPodcasts
    case getListeningStats
    case getShareLink
    case whatsNext
    // Differentiators & open
    case bookmarkCurrentMoment(note: String?)
    case openPodcast(feedUrl: String)
    case openQueue

    /// Case name WITHOUT associated values — safe for privacy-.public os_log
    /// markers. Associated values can carry user data (note text, feed URLs)
    /// and must never reach public log output.
    var caseName: String {
        String(describing: self).split(separator: "(").first.map(String.init) ?? String(describing: self)
    }
}

// MARK: - Outcomes

enum IntentOutcome: Sendable {
    case success(dialog: String)
    case failure(message: String)
    case episode(EpisodeSnapshot, dialog: String)
    case episodes([EpisodeSnapshot], dialog: String)
    case podcasts([PodcastSnapshot], dialog: String)
    case stats(ListeningStatsSnapshot, dialog: String)
    case url(URL, dialog: String)

    var spokenDialog: String {
        switch self {
        case .success(let d), .episode(_, let d), .episodes(_, let d),
             .podcasts(_, let d), .stats(_, let d), .url(_, let d):
            return d
        case .failure(let m):
            return m
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

// MARK: - Bridge
//
// Mirrors WidgetPlaybackBridge (YourPodsWidgets/WidgetPlaybackBridge.swift): a pure
// in-process singleton whose handler YourPodsApp installs at launch. The await is
// load-bearing — perform() must not return until the action completed, so a
// background-launched intent process establishes real state before returning.

@MainActor
final class SiriIntentBridge {
    static let shared = SiriIntentBridge()
    private init() {}

    var handler: (@MainActor (SiriIntentCommand) async -> IntentOutcome)?

    func perform(_ command: SiriIntentCommand) async -> IntentOutcome {
        guard let handler else {
            Logger(subsystem: "com.yourpods", category: "audio")
                .error("⟦siri-bridge⟧ no handler wired for \(command.caseName, privacy: .public)")
            return .failure(message: "YourPods isn't ready yet. Try again in a moment.")
        }
        return await handler(command)
    }
}
