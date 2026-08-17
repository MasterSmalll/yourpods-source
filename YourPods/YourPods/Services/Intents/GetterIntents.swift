import AppIntents
import Foundation

/// Honest, user-facing error for getter intents that have no value to return.
struct SiriIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    /// A bare `"\(message)"` extracts as the catalog key `%@` — one entry, no
    /// comment, shared with every other place in the app that interpolates a
    /// lone string. The key names what this is; the message itself arrives
    /// already composed and is not translated here.
    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource("intent.error.message",
                                defaultValue: "\(message)",
                                comment: "Carries an already-composed Siri error sentence. The argument is the whole message — there is nothing around it to translate.")
    }
}

struct GetCurrentEpisodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Episode"
    static var description = IntentDescription("Returns the episode that's currently playing, with its position, duration, and link.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Get the current episode") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EpisodeEntity> & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.getCurrentEpisode)
        guard case .episode(let snap, let dialog) = outcome else {
            throw SiriIntentError(message: outcome.spokenDialog)
        }
        return .result(value: EpisodeEntity(snapshot: snap),
                       dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct GetQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Queue"
    static var description = IntentDescription("Returns the episodes in your Up Next queue.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Get my queue") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[EpisodeEntity]> & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.getQueue)
        guard case .episodes(let snaps, let dialog) = outcome else {
            throw SiriIntentError(message: outcome.spokenDialog)
        }
        return .result(value: snaps.map(EpisodeEntity.init(snapshot:)),
                       dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct GetPodcastsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Podcasts"
    static var description = IntentDescription("Returns the podcasts you follow.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Get my podcasts") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[PodcastEntity]> & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.getPodcasts)
        guard case .podcasts(let snaps, let dialog) = outcome else {
            throw SiriIntentError(message: outcome.spokenDialog)
        }
        return .result(value: snaps.map(PodcastEntity.init(snapshot:)),
                       dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct WhatsNextIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Next in Queue"
    static var description = IntentDescription("Tells you the next episode in your queue and returns it.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Get what's next in my queue") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EpisodeEntity> & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.whatsNext)
        guard case .episode(let snap, let dialog) = outcome else {
            throw SiriIntentError(message: outcome.spokenDialog)
        }
        return .result(value: EpisodeEntity(snapshot: snap),
                       dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct GetListeningStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Listening Stats"
    static var description = IntentDescription("Returns your listening time and streaks as numbers you can use in shortcuts.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Get my listening stats") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ListeningStatsEntity> & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.getListeningStats)
        guard case .stats(let snap, let dialog) = outcome else {
            throw SiriIntentError(message: outcome.spokenDialog)
        }
        return .result(value: ListeningStatsEntity(snapshot: snap),
                       dialog: IntentDialog(stringLiteral: dialog))
    }
}
