import SwiftUI
import AppIntents

/// Settings › Siri & Shortcuts: discoverability for the App Shortcuts catalog.
struct SiriShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("YourPods adds actions to the Shortcuts app — playback controls, downloads, bookmarks, and building blocks like Get Current Episode that return values you can use in your own automations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                ShortcutsLink()
                    .shortcutsLinkStyle(.automatic)
                    .accessibilityLabel("Open YourPods shortcuts in the Shortcuts app")
                #endif
            } header: {
                Label("Shortcuts App", systemImage: "square.2.layers.3d")
            } footer: {
                Text("Ideas: play your queue when your car connects, set a sleep timer with your bedtime Focus, or bookmark a moment with a Back Tap.")
            }

            #if os(iOS)
            Section {
                SiriTipView(intent: BookmarkMomentIntent())
                SiriTipView(intent: PlayQueueIntent())
                SiriTipView(intent: CheckForNewEpisodesIntent())
            } header: {
                Label("Try Saying", systemImage: "mic.circle")
            }
            .accessibilityElement(children: .contain)
            #endif

            Section {
                voiceCommandRows
            } header: {
                Label("All Voice Commands", systemImage: "waveform")
            } footer: {
                Text("Say \"Hey Siri\" followed by any phrase. Every action above is also available in the Shortcuts app.")
            }
        }
        .navigationTitle("Siri & Shortcuts")
    }

    @ViewBuilder
    private var voiceCommandRows: some View {
        // Playback
        SiriCommandRow(
            icon: "play.circle.fill",
            title: "Play / Resume",
            phrases: ["\"Play YourPods\"", "\"Resume YourPods\""]
        )
        SiriCommandRow(
            icon: "pause.circle.fill",
            title: "Pause",
            phrases: ["\"Pause YourPods\""]
        )
        SiriCommandRow(
            icon: "stop.circle.fill",
            title: "Stop",
            phrases: ["\"Stop YourPods\""]
        )

        // Navigation
        SiriCommandRow(
            icon: "goforward.30",
            title: "Skip Forward",
            phrases: ["\"Skip forward in YourPods\""]
        )
        SiriCommandRow(
            icon: "gobackward.15",
            title: "Skip Backward",
            phrases: ["\"Rewind in YourPods\""]
        )
        SiriCommandRow(
            icon: "forward.end.fill",
            title: "Next Episode",
            phrases: ["\"Next episode in YourPods\""]
        )
        SiriCommandRow(
            icon: "sparkles",
            title: "Play Latest Episode",
            phrases: ["\"Play latest episode in YourPods\""]
        )

        // Speed
        SiriCommandRow(
            icon: "gauge.with.dots.needle.67percent",
            title: "Set Playback Speed",
            phrases: ["\"Set playback speed to 1.5 in YourPods\""]
        )

        // Timer
        SiriCommandRow(
            icon: "moon.zzz.fill",
            title: "Set Sleep Timer",
            phrases: ["\"Set sleep timer to 30 minutes in YourPods\""]
        )
        SiriCommandRow(
            icon: "moon.fill",
            title: "Cancel Sleep Timer",
            phrases: ["\"Cancel sleep timer in YourPods\""]
        )

        // Info
        SiriCommandRow(
            icon: "info.circle.fill",
            title: "What's Playing",
            phrases: ["\"What's playing in YourPods?\""]
        )
    }
}

// MARK: - Siri Command Row

/// A row displaying a Siri command with its icon, title, and example phrases.
private struct SiriCommandRow: View {
    let icon: String
    let title: String
    let phrases: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))

                Text(phrases.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
