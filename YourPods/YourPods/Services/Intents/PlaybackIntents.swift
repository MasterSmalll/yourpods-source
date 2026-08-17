import AppIntents
import Foundation

// MARK: - Shared result helper

extension IntentOutcome {
    /// Every intent speaks the outcome's dialog — success or honest failure.
    var dialogValue: IntentDialog { IntentDialog(stringLiteral: spokenDialog) }
}

// MARK: - Play / Resume (AudioPlaybackIntent: background audio-start grant)

struct PlayQueueIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play My Queue"
    static var description = IntentDescription("Resume playback or start playing your queue.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Play my queue") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.playQueue)
        return .result(dialog: outcome.dialogValue)
    }
}

struct ResumePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Playback"
    static var description = IntentDescription("Resume the currently paused episode.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Resume playback") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.playQueue)
        return .result(dialog: outcome.dialogValue)
    }
}

// MARK: - Pause / Stop

struct PausePodcastIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Playback"
    static var description = IntentDescription("Pause the currently playing episode.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Pause playback") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.pause)
        return .result(dialog: outcome.dialogValue)
    }
}

struct StopPlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Playback"
    static var description = IntentDescription("Stop playback and clear the current episode.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Stop playback") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.stop)
        return .result(dialog: outcome.dialogValue)
    }
}

// MARK: - Skip

struct SkipForwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var description = IntentDescription("Skip forward 30 seconds.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Skip forward") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.skipForward)
        return .result(dialog: outcome.dialogValue)
    }
}

struct SkipBackwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Backward"
    static var description = IntentDescription("Skip backward 15 seconds.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Skip backward") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.skipBackward)
        return .result(dialog: outcome.dialogValue)
    }
}

struct SkipToNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Next Episode"
    static var description = IntentDescription("Skip to the next episode in the queue.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Skip to the next episode") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.nextEpisode)
        return .result(dialog: outcome.dialogValue)
    }
}

// MARK: - What's Playing

struct WhatsPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Playing"
    static var description = IntentDescription("Find out what episode is currently playing.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Get what's playing") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.getCurrentEpisode)
        return .result(dialog: outcome.dialogValue)
    }
}

// MARK: - Sleep timer

struct CancelSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Sleep Timer"
    static var description = IntentDescription("Cancel the active sleep timer.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Cancel the sleep timer") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.cancelSleepTimer)
        return .result(dialog: outcome.dialogValue)
    }
}

// MARK: - Parameterized intents

struct PlayPodcastIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Podcast"
    static var description = IntentDescription("Play the latest episode of a podcast from your library.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary {
        Summary("Play the latest episode of \(\.$podcast)")
    }

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.playPodcast(feedUrl: podcast.id))
        return .result(dialog: outcome.dialogValue)
    }
}

/// Kept for saved-shortcut continuity; identical behavior to PlayPodcastIntent.
struct PlayLatestIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Latest Episode"
    static var description = IntentDescription("Play the latest episode of a podcast from your library.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary {
        Summary("Play the latest episode of \(\.$podcast)")
    }

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.playPodcast(feedUrl: podcast.id))
        return .result(dialog: outcome.dialogValue)
    }
}

struct SetPlaybackSpeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Playback Speed"
    static var description = IntentDescription("Change the playback speed.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary {
        Summary("Set playback speed to \(\.$speed)")
    }

    @Parameter(title: "Speed", description: "Playback speed multiplier (0.5–3.0)")
    var speed: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.setSpeed(Float(speed)))
        return .result(dialog: outcome.dialogValue)
    }
}

struct SetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Sleep Timer"
    static var description = IntentDescription("Pause playback after a number of minutes.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary {
        Summary("Set a sleep timer for \(\.$minutes) minutes")
    }

    @Parameter(title: "Minutes", description: "Minutes until playback pauses (1–480)")
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.setSleepTimer(minutes: minutes))
        return .result(dialog: outcome.dialogValue)
    }
}

// MARK: - Chapter, restart, and sleep-timer verbs

struct RestartEpisodeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Restart Episode"
    static var description = IntentDescription("Start the current episode over from the beginning.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Restart the current episode") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.restartEpisode)
        return .result(dialog: outcome.dialogValue)
    }
}

struct NextChapterIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Chapter"
    static var description = IntentDescription("Skip to the next chapter of the current episode.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Skip to the next chapter") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.nextChapter)
        return .result(dialog: outcome.dialogValue)
    }
}

struct PreviousChapterIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Chapter"
    static var description = IntentDescription("Go back to the previous chapter of the current episode.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Go to the previous chapter") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.previousChapter)
        return .result(dialog: outcome.dialogValue)
    }
}

struct ExtendSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Extend Sleep Timer"
    static var description = IntentDescription("Add time to the running sleep timer.")
    static var openAppWhenRun: Bool = false
    static var parameterSummary: some ParameterSummary {
        Summary("Extend the sleep timer by \(\.$minutes) minutes")
    }

    @Parameter(title: "Minutes", description: "Minutes to add (1–480)", default: 10)
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SiriIntentBridge.shared.perform(.extendSleepTimer(minutes: minutes))
        return .result(dialog: outcome.dialogValue)
    }
}
