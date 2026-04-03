import AppIntents
import Foundation

// MARK: - Notification Names for Siri → App Communication

extension Notification.Name {
    static let siriPlayQueue = Notification.Name("com.yourpods.siri.playQueue")
    static let siriResumePlayback = Notification.Name("com.yourpods.siri.resumePlayback")
    static let siriPause = Notification.Name("com.yourpods.siri.pause")
    static let siriStop = Notification.Name("com.yourpods.siri.stop")
    static let siriSkipForward = Notification.Name("com.yourpods.siri.skipForward")
    static let siriSkipBackward = Notification.Name("com.yourpods.siri.skipBackward")
    static let siriSkipToNext = Notification.Name("com.yourpods.siri.skipToNext")
    static let siriPlayLatest = Notification.Name("com.yourpods.siri.playLatest")
    static let siriSetSpeed = Notification.Name("com.yourpods.siri.setSpeed")
    static let siriPlayPodcast = Notification.Name("com.yourpods.siri.playPodcast")
    static let siriSetSleepTimer = Notification.Name("com.yourpods.siri.setSleepTimer")
    static let siriCancelSleepTimer = Notification.Name("com.yourpods.siri.cancelSleepTimer")
    static let siriWhatsPlaying = Notification.Name("com.yourpods.siri.whatsPlaying")
}

// MARK: - Play / Resume Intent

@available(iOS 16.0, *)
struct PlayQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Play My Queue"
    static var description = IntentDescription("Resume playback or start playing your queue.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .siriResumePlayback, object: nil)
        return .result(dialog: "Playing YourPods")
    }
}

// MARK: - Resume Playback Intent

@available(iOS 16.0, *)
struct ResumePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Playback"
    static var description = IntentDescription("Resume the currently paused episode.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .siriResumePlayback, object: nil)
        return .result(dialog: "Resuming playback")
    }
}

// MARK: - Play Latest Episode Intent

@available(iOS 16.0, *)
struct PlayLatestIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Latest Episode"
    static var description = IntentDescription("Play the latest episode from a specific podcast.")
    static var openAppWhenRun: Bool = false
    
    @Parameter(title: "Podcast Name")
    var podcastName: String
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(
            name: .siriPlayLatest,
            object: nil,
            userInfo: ["podcastName": podcastName]
        )
        return .result(dialog: "Playing latest from \(podcastName)")
    }
}

// MARK: - Play Specific Podcast Intent

@available(iOS 16.0, *)
struct PlayPodcastIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Podcast"
    static var description = IntentDescription("Play the latest episode from a podcast by name.")
    static var openAppWhenRun: Bool = false
    
    @Parameter(title: "Podcast Name")
    var podcastName: String
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(
            name: .siriPlayPodcast,
            object: nil,
            userInfo: ["podcastName": podcastName]
        )
        return .result(dialog: "Playing \(podcastName)")
    }
}

// MARK: - Pause Intent

@available(iOS 16.0, *)
struct PausePodcastIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Playback"
    static var description = IntentDescription("Pause the currently playing episode.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .siriPause, object: nil)
        return .result(dialog: "Paused")
    }
}

// MARK: - Stop Intent

@available(iOS 16.0, *)
struct StopPlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Playback"
    static var description = IntentDescription("Stop playback and clear the current episode.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .siriStop, object: nil)
        return .result(dialog: "Stopped")
    }
}

// MARK: - Skip Forward Intent

@available(iOS 16.0, *)
struct SkipForwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var description = IntentDescription("Skip forward 30 seconds.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .siriSkipForward, object: nil)
        return .result(dialog: "Skipping forward")
    }
}

// MARK: - Skip Backward Intent

@available(iOS 16.0, *)
struct SkipBackwardIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Backward"
    static var description = IntentDescription("Skip backward 15 seconds.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .siriSkipBackward, object: nil)
        return .result(dialog: "Skipping backward")
    }
}

// MARK: - Skip to Next Intent

@available(iOS 16.0, *)
struct SkipToNextIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Next Episode"
    static var description = IntentDescription("Skip to the next episode in the queue.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .siriSkipToNext, object: nil)
        return .result(dialog: "Playing next episode")
    }
}

// MARK: - Set Playback Speed Intent

@available(iOS 16.0, *)
struct SetPlaybackSpeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Playback Speed"
    static var description = IntentDescription("Change the playback speed.")
    static var openAppWhenRun: Bool = false
    
    @Parameter(title: "Speed", description: "Playback speed multiplier (e.g. 1.0, 1.5, 2.0)")
    var speed: Double
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clampedSpeed = Float(min(max(speed, 0.5), 3.0))
        NotificationCenter.default.post(
            name: .siriSetSpeed,
            object: nil,
            userInfo: ["speed": clampedSpeed]
        )
        let formatted = String(format: "%.1f", clampedSpeed)
        return .result(dialog: "Speed set to \(formatted)x")
    }
}

// MARK: - Set Sleep Timer Intent

@available(iOS 16.0, *)
struct SetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Sleep Timer"
    static var description = IntentDescription("Set a sleep timer to pause playback after a duration.")
    static var openAppWhenRun: Bool = false
    
    @Parameter(title: "Minutes", description: "Number of minutes until playback pauses (e.g. 15, 30, 60)")
    var minutes: Int
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clampedMinutes = min(max(minutes, 1), 480)
        NotificationCenter.default.post(
            name: .siriSetSleepTimer,
            object: nil,
            userInfo: ["minutes": clampedMinutes]
        )
        return .result(dialog: "Sleep timer set for \(clampedMinutes) minutes")
    }
}

// MARK: - Cancel Sleep Timer Intent

@available(iOS 16.0, *)
struct CancelSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Sleep Timer"
    static var description = IntentDescription("Cancel the active sleep timer.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .siriCancelSleepTimer, object: nil)
        return .result(dialog: "Sleep timer cancelled")
    }
}

// MARK: - What's Playing Intent

@available(iOS 16.0, *)
struct WhatsPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Playing"
    static var description = IntentDescription("Find out what episode is currently playing.")
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Post notification and return a generic response.
        // The actual title comes from MPNowPlayingInfoCenter which Siri can read,
        // but we provide a dialog fallback.
        NotificationCenter.default.post(name: .siriWhatsPlaying, object: nil)
        return .result(dialog: "Check YourPods for the currently playing episode.")
    }
}

// MARK: - App Shortcuts Provider

@available(iOS 16.0, *)
struct YourPodsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayQueueIntent(),
            phrases: [
                "Play my queue in \(.applicationName)",
                "Resume playback in \(.applicationName)",
                "Play \(.applicationName)",
                "Start \(.applicationName)",
                "Resume \(.applicationName)",
                "Continue playing in \(.applicationName)",
                "Unpause \(.applicationName)",
            ],
            shortTitle: "Play Queue",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PausePodcastIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause playback in \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.circle.fill"
        )
        AppShortcut(
            intent: StopPlaybackIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "Stop playing in \(.applicationName)",
            ],
            shortTitle: "Stop",
            systemImageName: "stop.circle.fill"
        )
        AppShortcut(
            intent: PlayLatestIntent(),
            phrases: [
                "Play latest episode in \(.applicationName)",
                "Play newest episode in \(.applicationName)",
            ],
            shortTitle: "Play Latest",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: SkipForwardIntent(),
            phrases: [
                "Skip forward in \(.applicationName)",
                "Fast forward in \(.applicationName)",
            ],
            shortTitle: "Skip Forward",
            systemImageName: "goforward.30"
        )
        AppShortcut(
            intent: SkipToNextIntent(),
            phrases: [
                "Skip to next in \(.applicationName)",
                "Next episode in \(.applicationName)",
            ],
            shortTitle: "Next Episode",
            systemImageName: "forward.end.fill"
        )
        AppShortcut(
            intent: SetPlaybackSpeedIntent(),
            phrases: [
                "Set playback speed in \(.applicationName)",
                "Change speed in \(.applicationName)",
            ],
            shortTitle: "Set Speed",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Set sleep timer in \(.applicationName)",
                "Sleep timer for \(.applicationName)",
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: CancelSleepTimerIntent(),
            phrases: [
                "Cancel sleep timer in \(.applicationName)",
                "Turn off sleep timer in \(.applicationName)",
            ],
            shortTitle: "Cancel Timer",
            systemImageName: "moon.fill"
        )
        AppShortcut(
            intent: WhatsPlayingIntent(),
            phrases: [
                "What's playing in \(.applicationName)",
                "What am I listening to in \(.applicationName)",
            ],
            shortTitle: "What's Playing",
            systemImageName: "info.circle.fill"
        )
    }
}
