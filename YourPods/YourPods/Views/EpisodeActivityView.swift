import SwiftUI

// ─── EpisodeActivityView ──────────────────────────────────────────────────
// Router: YourPods Sync accounts see ProStatsView; gPodder accounts see GpodderActivityView.
// ─────────────────────────────────────────────────────────────────────────

/// Entry point for the "Episode Activity" settings row.
///
/// Routes to the appropriate stats view based on the active profile type:
/// - `.yourpodsPro` → `ProStatsView` (tiered stats: basic for Sync, full for Pro)
/// - `.gpodder` / local → `GpodderActivityView` (raw episode action list)
struct EpisodeActivityView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        if settings.activeProfile?.profileType == .yourpodsPro {
            ProStatsView()
        } else {
            GpodderActivityView()
        }
    }
}

// MARK: - GpodderActivityView

/// Shows synced episode listening progress from the gPodder server.
/// Formerly the body of `EpisodeActivityView` — extracted so `EpisodeActivityView`
/// can route to `ProStatsView` for YourPods Sync accounts.
struct GpodderActivityView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settings
    // Needed to reach refreshAndSync — see refreshActions().
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager

    @State private var isRefreshing = false
    @State private var sortOrder: SortOrder = .recent

    enum SortOrder: String, CaseIterable {
        case recent = "Recent"
        case podcast = "By Podcast"
    }

    private var actions: [EpisodeAction] {
        let all = Array(podcastManager.actionMap.values)
        switch sortOrder {
        case .recent:
            return all.sorted { $0.timestamp > $1.timestamp }
        case .podcast:
            return all.sorted { ($0.podcast, $0.timestamp) < ($1.podcast, $1.timestamp) }
        }
    }

    var body: some View {
        List {
            // Header
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(actions.count) synced actions")
                            .font(.headline)
                        if let lastSync = UserDefaults.standard.object(forKey: "lastEpisodeActionSync") as? Int, lastSync > 0 {
                            let date = Date(timeIntervalSince1970: TimeInterval(lastSync))
                            Text("sync.lastSynced \(DurationFormatting.relative(date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        refreshActions()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel(isRefreshing ? "Syncing episode activity" : "Refresh episode activity")
                }
            }

            // Sort picker
            Section {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Actions list
            if actions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Episode Activity",
                        systemImage: "waveform",
                        description: Text("Episode listening progress from your gPodder server will appear here after syncing.")
                    )
                }
            } else {
                Section("Activity") {
                    ForEach(actions) { action in
                        EpisodeActionRow(action: action, podcastManager: podcastManager)
                    }
                }
            }
        }
        .navigationTitle("Episode Activity")
    }

    private func refreshActions() {
        isRefreshing = true
        Task {
            // Through refreshAndSync rather than the episode-action step alone: pulling
            // actions in isolation advances the delta cursor for a window whose playback
            // and queue changes were never applied, so the rest of that window is not
            // re-offered on the next sync.
            _ = await podcastManager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settings,
                strategy: settings.syncConflictStrategy
            )
            isRefreshing = false
        }
    }
}

// MARK: - Episode Action Row

struct EpisodeActionRow: View {
    let action: EpisodeAction
    let podcastManager: PodcastManager

    /// Try to find the podcast name from subscriptions
    private var podcastTitle: String {
        podcastManager.subscriptions.first(where: { $0.url == action.podcast })?.title ?? action.podcast
    }

    /// Try to find the episode title from the podcast's episodes
    private var episodeTitle: String? {
        let podcast = podcastManager.subscriptions.first(where: { $0.url == action.podcast })
        let guid = action.guid ?? action.episode
        return podcast?.episodes.first(where: { $0.guid == guid })?.title
    }

    private var actionIcon: String {
        switch action.action {
        case "play": return "play.circle.fill"
        case "new": return "sparkles"
        case "download": return "arrow.down.circle.fill"
        case "delete": return "trash.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private var actionColor: Color {
        switch action.action {
        case "play": return .blue
        case "new": return .green
        case "download": return .purple
        case "delete": return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: actionIcon)
                .foregroundColor(actionColor)
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(episodeTitle ?? action.episode)
                    .font(.subheadline.bold())
                    .lineLimit(2)

                Text(podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    // Action type
                    Text(action.action.capitalized)
                        .font(.caption2.bold())
                        .foregroundColor(actionColor)

                    // Position / Progress
                    if let position = action.position, let total = action.total, total > 0 {
                        // `.percent` rather than a literal '%': French writes
                        // "45 %" with a non-breaking space, and the separator
                        // is not ours to hardcode.
                        let share = min(1, Double(position) / Double(total))
                        let percent = share.formatted(.percent.precision(.fractionLength(0)))
                        Text(String(localized: "activity.positionOfTotal",
                                    defaultValue: "\(percent) · \(formatTime(position)) / \(formatTime(total))",
                                    comment: "How far into an episode a synced action happened. Argument 1 is the share already played, 2 the position, 3 the episode's length — e.g. '45% · 12:00 / 30:00'."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if let position = action.position {
                        Text(String(localized: "activity.playedAt",
                                    defaultValue: "at \(formatTime(position))",
                                    comment: "Where in an episode an action happened, as in 'at 12:04'. Argument 1 is a timestamp already formatted as h:mm:ss."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Timestamp
                    let date = Date(timeIntervalSince1970: TimeInterval(action.timestamp))
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Device
                if let device = action.device {
                    Text(String(localized: "activity.onDevice",
                                defaultValue: "Device: \(device)",
                                comment: "Which device an action came from. Argument 1 is a user-chosen device name and is never translated."))
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    /// Composes a natural-language VoiceOver description for the entire row.
    /// Example: "Played, The Daily, from The New York Times, 85 percent, 5 minutes ago"
    private var rowAccessibilityLabel: String {
        var parts: [String] = []

        // Action verb. The default arm capitalizes a raw server string — it is
        // an unknown action type, not interface copy, so it stays unlocalized.
        let actionWord: String
        switch action.action {
        case "play":
            actionWord = String(localized: "a11y.activity.action.played",
                                defaultValue: "Played",
                                comment: "VoiceOver: a sync record for playing an episode.")
        case "new":
            actionWord = String(localized: "a11y.activity.action.new",
                                defaultValue: "New episode",
                                comment: "VoiceOver: a sync record for an episode arriving in a feed.")
        case "download":
            actionWord = String(localized: "a11y.activity.action.downloaded",
                                defaultValue: "Downloaded",
                                comment: "VoiceOver: a sync record for downloading an episode.")
        case "delete":
            actionWord = String(localized: "a11y.activity.action.deleted",
                                defaultValue: "Deleted",
                                comment: "VoiceOver: a sync record for deleting an episode.")
        default:
            actionWord = action.action.capitalized
        }
        parts.append(actionWord)

        // Episode + podcast
        parts.append(episodeTitle ?? action.episode)
        parts.append(String(localized: "a11y.activity.fromPodcast",
                            defaultValue: "from \(podcastTitle)",
                            comment: "VoiceOver: names the show an episode belongs to. The argument is the podcast title."))

        // Progress
        if let position = action.position, let total = action.total, total > 0 {
            let pct = min(100, Int(Double(position) / Double(total) * 100))
            parts.append(String(localized: "a11y.activity.percent",
                                defaultValue: "\(pct) percent",
                                comment: "VoiceOver: how far through an episode a sync record was made."))
        } else if let position = action.position {
            parts.append(String(localized: "a11y.activity.atPosition",
                                defaultValue: "at \(formatTime(position))",
                                comment: "VoiceOver: the playback position of a sync record. The argument is a clock timestamp such as '23:14'."))
        }

        // Relative time
        let date = Date(timeIntervalSince1970: TimeInterval(action.timestamp))
        parts.append(DurationFormatting.relative(date))

        // Device (optional)
        if let device = action.device {
            parts.append(String(localized: "a11y.activity.onDevice",
                                defaultValue: "on \(device)",
                                comment: "VoiceOver: which device produced a sync record. The argument is a user-chosen device name."))
        }

        return parts.joined(separator: EpisodeAccessibility.listSeparator)
    }

    private func formatTime(_ seconds: Int) -> String {
        DurationFormatting.timestamp(TimeInterval(seconds))
    }
}
