import AppIntents
import Foundation

// MARK: - Queue & library verbs

struct CheckForNewEpisodesIntent: AppIntent {
    static var title: LocalizedStringResource = "Check for New Episodes"
    static var description = IntentDescription("Refresh your podcasts and sync, then report how many new episodes arrived.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Check for new episodes") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.checkForNewEpisodes)
        return .result(dialog: outcome.dialogValue)
    }
}

struct DownloadQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Download My Queue"
    static var description = IntentDescription("Download every episode currently in your queue.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Download all episodes in my queue") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.downloadQueue)
        return .result(dialog: outcome.dialogValue)
    }
}

struct DownloadLatestIntent: AppIntent {
    static var title: LocalizedStringResource = "Download Latest Episode"
    static var description = IntentDescription("Download the latest episode of a podcast from your library.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary {
        Summary("Download the latest episode of \(\.$podcast)")
    }

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.downloadLatest(feedUrl: podcast.id))
        return .result(dialog: outcome.dialogValue)
    }
}

struct MarkPlayedAndPlayNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Mark Played and Play Next"
    static var description = IntentDescription("Mark the current episode played and play the next one in your queue.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Mark the current episode played and play the next") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.markPlayedAndPlayNext)
        return .result(dialog: outcome.dialogValue)
    }
}

struct ClearQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Clear Queue"
    static var description = IntentDescription("Remove every episode from your Up Next queue.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Clear my queue") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            dialog: "This removes every episode from your queue. Continue?")
        let outcome = await SiriIntentBridge.shared.perform(.clearQueue)
        return .result(dialog: outcome.dialogValue)
    }
}
