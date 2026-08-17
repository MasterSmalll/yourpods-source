import AppIntents
import Foundation

/// Return-only entity: fixed id "stats"; the query re-materializes
/// current stats so Shortcuts can re-resolve a saved magic variable.
struct ListeningStatsEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Listening Stats")
    static var defaultQuery = ListeningStatsEntityQuery()

    let id: String
    @Property(title: "Minutes Today") var minutesToday: Int
    @Property(title: "Minutes This Week") var minutesThisWeek: Int
    @Property(title: "Episodes Completed") var episodesCompleted: Int
    @Property(title: "Current Streak (days)") var currentStreakDays: Int

    init(snapshot: ListeningStatsSnapshot) {
        self.id = "stats"
        self.minutesToday = snapshot.minutesToday
        self.minutesThisWeek = snapshot.minutesThisWeek
        self.episodesCompleted = snapshot.episodesCompleted
        self.currentStreakDays = snapshot.currentStreakDays
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Listening Stats",
                              subtitle: "\(minutesThisWeek) min this week")
    }
}

struct ListeningStatsEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ListeningStatsEntity] {
        guard identifiers.contains("stats") else { return [] }
        let outcome = await SiriIntentBridge.shared.perform(.getListeningStats)
        guard case .stats(let snap, _) = outcome else { return [] }
        return [ListeningStatsEntity(snapshot: snap)]
    }
}
