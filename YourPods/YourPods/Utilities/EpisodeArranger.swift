import Foundation

/// Groups an already-newest-first episode list into display sections per `EpisodeArrangement`.
enum EpisodeArranger {

    struct Section: Identifiable {
        let id: String
        let title: String?      // nil = untitled (single flat section)
        let episodes: [Episode]
    }

    static func sections(
        episodes: [Episode],
        arrangement: EpisodeArrangement,
        now: Date = Date()
    ) -> [Section] {
        switch arrangement {
        case .newest:
            return [Section(id: "all", title: nil, episodes: episodes)]

        case .byDate:
            let cal = Calendar.current
            let startOfToday = cal.startOfDay(for: now)
            let weekAgo = cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
            var today: [Episode] = [], week: [Episode] = [], earlier: [Episode] = []
            for ep in episodes {
                guard let d = ep.pubDate else { earlier.append(ep); continue }
                if d >= startOfToday { today.append(ep) }
                else if d >= weekAgo { week.append(ep) }
                else { earlier.append(ep) }
            }
            var out: [Section] = []
            if !today.isEmpty   { out.append(Section(id: "today",   title: "Today",     episodes: today)) }
            if !week.isEmpty    { out.append(Section(id: "week",    title: "This Week", episodes: week)) }
            if !earlier.isEmpty { out.append(Section(id: "earlier", title: "Earlier",   episodes: earlier)) }
            return out

        case .byShow:
            var order: [String] = []
            var groups: [String: [Episode]] = [:]
            for ep in episodes {
                let key = ep.podcastTitle ?? "Unknown"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(ep)
            }
            return order.map { Section(id: $0, title: $0, episodes: groups[$0] ?? []) }
        }
    }
}
