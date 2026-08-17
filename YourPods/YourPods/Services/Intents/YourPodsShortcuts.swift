import AppIntents
import Foundation

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
