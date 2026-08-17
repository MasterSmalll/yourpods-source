import AppIntents
import Foundation

struct BookmarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Bookmark This Moment"
    static var description = IntentDescription("Save a timestamped note on the episode you're listening to — hands-free.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary {
        Summary("Bookmark the current moment") {
            \.$note
        }
    }

    @Parameter(title: "Note", description: "Optional note text", default: nil)
    var note: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.bookmarkCurrentMoment(note: note))
        return .result(dialog: outcome.dialogValue)
    }
}

struct GetShareLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Share Link"
    static var description = IntentDescription("Returns a share link to the current episode at the current timestamp.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Get a share link for the current moment") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.getShareLink)
        guard case .url(let url, let dialog) = outcome else {
            throw SiriIntentError(message: outcome.spokenDialog)
        }
        return .result(value: url, dialog: IntentDialog(stringLiteral: dialog))
    }
}

/// Convenience composition: same as GetShareLinkIntent but titled for the
/// gallery's "share what I'm listening to" mental model.
struct ShareCurrentEpisodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Share What I'm Listening To"
    static var description = IntentDescription("Returns a timestamped link to the current episode, ready to send.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Share the current episode") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.getShareLink)
        guard case .url(let url, let dialog) = outcome else {
            throw SiriIntentError(message: outcome.spokenDialog)
        }
        return .result(value: url, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct OpenPodcastIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Podcast"
    static var description = IntentDescription("Open a podcast's page in YourPods.")
    static var openAppWhenRun: Bool = true
    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$podcast) in YourPods")
    }

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await SiriIntentBridge.shared.perform(.openPodcast(feedUrl: podcast.id))
        return .result()
    }
}

struct OpenQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Open My Queue"
    static var description = IntentDescription("Open the Up Next queue in YourPods.")
    static var openAppWhenRun: Bool = true
    static var parameterSummary: some ParameterSummary { Summary("Open my queue in YourPods") }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await SiriIntentBridge.shared.perform(.openQueue)
        return .result()
    }
}
