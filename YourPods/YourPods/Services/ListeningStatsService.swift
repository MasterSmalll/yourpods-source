import Foundation
import os

/// Per-podcast listening stats breakdown
struct PodcastStats: Codable, Identifiable {
    var id: String { podcastUrl }
    let podcastUrl: String
    let podcastTitle: String
    let logoUrl: String?
    var totalTimeSeconds: Int
    var episodeCount: Int
}

/// Aggregate listening statistics computed from episode actions.
///
struct ListeningStats: Codable {
    let totalListeningSeconds: Int
    let episodesCompleted: Int
    let currentStreak: Int
    let longestStreak: Int
    let podcastBreakdowns: [String: PodcastStats]
    let dailyListening: [String: Int]  // ISO date → seconds
    let topPodcasts: [PodcastStats]
    let lastUpdated: Date
    
    var totalListeningDuration: TimeInterval { TimeInterval(totalListeningSeconds) }
    
    static let empty = ListeningStats(
        totalListeningSeconds: 0, episodesCompleted: 0,
        currentStreak: 0, longestStreak: 0,
        podcastBreakdowns: [:], dailyListening: [:],
        topPodcasts: [], lastUpdated: Date()
    )
}

/// Service that computes and caches listening statistics.
struct ListeningStatsService {
    private static let logger = Logger(subsystem: "com.yourpods", category: "ListeningStats")
    private static let cacheKey = "listening_stats_cache"
    
    // MARK: - Cache
    
    static func loadFromCache() -> ListeningStats? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(ListeningStats.self, from: data)
    }
    
    static func saveToCache(_ stats: ListeningStats) {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
    
    static func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }
    
    // MARK: - Compute
    
    static func computeStats(actions: [EpisodeAction], subscriptions: [Podcast]) -> ListeningStats {
        guard !actions.isEmpty else { return .empty }
        
        let sorted = actions.sorted { $0.timestamp < $1.timestamp }
        
        var totalSeconds = 0
        var completedCount = 0
        var breakdowns: [String: PodcastStats] = [:]
        var dailySeconds: [String: Int] = [:]
        
        // Group by episode
        var episodeActions: [String: [EpisodeAction]] = [:]
        for action in sorted {
            let key = action.guid ?? action.episode
            episodeActions[key, default: []].append(action)
        }
        
        for (_, epActions) in episodeActions {
            let first = epActions[0]
            let podUrl = first.podcast
            
            let podcast = subscriptions.first { $0.url == podUrl }
            
            // Skip actions from podcasts the user is not subscribed to.
            // gPodder sync stores actions for ALL podcasts (including those
            // unsubscribed or from other devices). Without this guard, they
            // appear as "Unknown Podcast" in the stats view.
            if podcast == nil && !subscriptions.isEmpty {
                continue
            }
            
            let title = podcast?.title ?? "Unknown Podcast"
            let logo = podcast?.logoUrl
            
            if breakdowns[podUrl] == nil {
                breakdowns[podUrl] = PodcastStats(
                    podcastUrl: podUrl, podcastTitle: title,
                    logoUrl: logo, totalTimeSeconds: 0, episodeCount: 0
                )
            }
            
            var epSeconds = 0
            for action in epActions {
                if let started = action.started, let pos = action.position, pos > started {
                    let segment = pos - started
                    epSeconds += segment
                    
                    let date = Date(timeIntervalSince1970: TimeInterval(action.timestamp))
                    let dayKey = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: date))
                    dailySeconds[dayKey, default: 0] += segment
                }
            }
            
            // Fallback: max position
            if epSeconds == 0 {
                let maxPos = epActions.compactMap(\.position).max() ?? 0
                epSeconds = maxPos
                if let lastTs = epActions.last?.timestamp {
                    let date = Date(timeIntervalSince1970: TimeInterval(lastTs))
                    let dayKey = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: date))
                    dailySeconds[dayKey, default: 0] += maxPos
                }
            }
            
            totalSeconds += epSeconds
            breakdowns[podUrl]?.totalTimeSeconds += epSeconds
            breakdowns[podUrl]?.episodeCount += 1
            
            // Completion check
            if let last = epActions.last, let total = last.total, let pos = last.position,
               total > 0, pos >= Int(Double(total) * 0.95) {
                completedCount += 1
            }
        }
        
        // Streaks
        let sortedDays = dailySeconds.keys.sorted()
        let formatter = ISO8601DateFormatter()
        let dayDates = sortedDays.compactMap { formatter.date(from: $0) }
        
        var currentStreak = 0
        var longestStreak = 0
        
        if !dayDates.isEmpty {
            var temp = 1
            for i in 0..<(dayDates.count - 1) {
                let diff = Calendar.current.dateComponents([.day], from: dayDates[i], to: dayDates[i+1]).day ?? 0
                if diff == 1 { temp += 1 } else { longestStreak = max(longestStreak, temp); temp = 1 }
            }
            longestStreak = max(longestStreak, temp)
            
            let today = Calendar.current.startOfDay(for: Date())
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            if let last = dayDates.last, last >= yesterday {
                currentStreak = 1
                for i in stride(from: dayDates.count - 1, through: 1, by: -1) {
                    let diff = Calendar.current.dateComponents([.day], from: dayDates[i-1], to: dayDates[i]).day ?? 0
                    if diff == 1 { currentStreak += 1 } else { break }
                }
            }
        }
        
        let topPods = breakdowns.values.sorted { $0.totalTimeSeconds > $1.totalTimeSeconds }
        
        return ListeningStats(
            totalListeningSeconds: totalSeconds,
            episodesCompleted: completedCount,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            podcastBreakdowns: breakdowns,
            dailyListening: dailySeconds,
            topPodcasts: Array(topPods.prefix(5)),
            lastUpdated: Date()
        )
    }
}
