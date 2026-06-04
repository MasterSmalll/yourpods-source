import SwiftUI
import Charts

// ─── YourPods Sync ───────────────────────────────────────────────────────
// ProStatsView — tiered listening stats from GET /api/yourpods/stats
//
// Sync tier: basic stat cards (listen time, episodes, podcasts, streak)
// Pro tier:  full dashboard (+ period selector, skip breakdown, daily trend chart, top podcasts)
// ─────────────────────────────────────────────────────────────────────────

/// Shows aggregated listening stats from the YourPods server.
/// Available to all YourPods Sync and Pro users.
struct ProStatsView: View {
    /// Whether the view shows an "Upgrade to Pro" upsell section.
    /// Pro is not public yet — this must remain `false` until launch.
    static let showsUpgradePrompt = false

    /// Whether the view shows an episode activity list below the stat cards.
    static let showsActivityList = true

    /// The navigation title for this view.
    static let navigationTitleText = "Episode Activity"

    /// Sort order for the episode activity list.
    enum ActivitySortOrder: String, CaseIterable {
        case recent = "Recent"
        case byPodcast = "By Podcast"
    }

    /// Sort episode actions by the given order.
    /// Extracted as a static method for testability.
    static func sortActions(_ actions: [EpisodeAction], by order: ActivitySortOrder) -> [EpisodeAction] {
        switch order {
        case .recent:
            return actions.sorted { $0.timestamp > $1.timestamp }
        case .byPodcast:
            return actions.sorted { ($0.podcast, $0.timestamp) < ($1.podcast, $1.timestamp) }
        }
    }


    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settings

    @State private var response: ProStatsResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedPeriod: StatsPeriod = .allTime
    @State private var activitySortOrder: ActivitySortOrder = .recent

    var body: some View {
        List {
            if isLoading && response == nil {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading stats…")
                        Spacer()
                    }
                    .padding()
                    .accessibilityLabel("Loading listening stats")
                }
            } else if let error = errorMessage, response == nil {
                Section {
                    ContentUnavailableView(
                        "Couldn't Load Stats",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                }
            } else if let resp = response {
                // ── Period Selector (Pro only) ─────────────────────────────
                if resp.tier == "pro" {
                    Section {
                        Picker("Period", selection: $selectedPeriod) {
                            ForEach(StatsPeriod.allCases) { period in
                                Text(period.label).tag(period)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityHint("Filter stats by time period")
                    }
                }

                // ── Basic Stat Cards (all tiers) ──────────────────────────
                Section {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ], spacing: 12) {
                        StatCard(
                            icon: "headphones",
                            iconColor: .blue,
                            title: "Listen Time",
                            value: formatHours(resp.stats.totalListenTimeSec)
                        )
                        StatCard(
                            icon: "waveform",
                            iconColor: .purple,
                            title: "Episodes",
                            value: "\(resp.stats.uniqueEpisodes)"
                        )
                        StatCard(
                            icon: "antenna.radiowaves.left.and.right",
                            iconColor: .orange,
                            title: "Podcasts",
                            value: "\(resp.stats.uniquePodcasts)"
                        )
                        StatCard(
                            icon: "flame.fill",
                            iconColor: .red,
                            title: "Streak",
                            value: "\(resp.streak ?? 0) days"
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                // ── Skip Breakdown (Pro only) ─────────────────────────────
                if resp.tier == "pro" {
                    Section("Time Saved") {
                        StatRow(label: "Total Skipped", value: formatMins(resp.stats.totalSkippedSec ?? 0))
                        StatRow(label: "Manual Skips", value: "\(resp.stats.manualSkipCount ?? 0) (\(formatMins(resp.stats.manualSkipsSec ?? 0)))")
                        StatRow(label: "Auto-Skips", value: "\(resp.stats.autoSkipCount ?? 0) (\(formatMins(resp.stats.autoSkipsSec ?? 0)))")
                        StatRow(label: "Chapter Skips", value: "\(resp.stats.chapterSkipCount ?? 0) (\(formatMins(resp.stats.chapterSkipsSec ?? 0)))")
                    }
                }

                // ── Daily Trend Chart (Pro only) ──────────────────────────
                if resp.tier == "pro", let trend = resp.dailyTrend, !trend.isEmpty {
                    Section("Daily Listening") {
                        Chart(trend) { entry in
                            BarMark(
                                x: .value("Date", entry.date),
                                y: .value("Minutes", entry.listenTimeSec / 60.0)
                            )
                            .foregroundStyle(.blue.gradient)
                            .cornerRadius(4)
                        }
                        .chartYAxisLabel("Minutes")
                        .chartXAxis {
                            AxisMarks(values: .stride(by: 7)) { value in
                                AxisValueLabel()
                            }
                        }
                        .frame(height: 200)
                        .accessibilityLabel(dailyTrendAccessibilityLabel(trend))
                    }
                }

                // ── Top Podcasts (Pro only) ────────────────────────────────
                if resp.tier == "pro", let topPodcasts = resp.topPodcasts, !topPodcasts.isEmpty {
                    Section("Top Podcasts") {
                        let maxTime = topPodcasts.first?.listenTimeSec ?? 1
                        ForEach(topPodcasts, id: \.podcastUrl) { entry in
                            let title = podcastManager.subscriptions
                                .first(where: { $0.url == entry.podcastUrl })?.title
                                ?? entry.podcastUrl
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                    Text("\(entry.episodeCount) episodes · \(formatHours(entry.listenTimeSec))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                // Listen time bar
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.blue.opacity(0.3))
                                        .frame(width: max(4, geo.size.width * CGFloat(entry.listenTimeSec / maxTime)))
                                }
                                .frame(width: 60, height: 8)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(title), \(entry.episodeCount) episodes, \(formatHours(entry.listenTimeSec))")
                        }
                    }
                }

            } else {
                Section {
                    ContentUnavailableView(
                        "No Stats Yet",
                        systemImage: "chart.bar",
                        description: Text("Your listening stats will appear here once you've synced with YourPods Sync.")
                    )
                }
            }

            // ── Episode Activity List (all tiers) ─────────────────────
            if Self.showsActivityList {
                let allActions = Array(podcastManager.actionMap.values)
                let sortedActions = Self.sortActions(allActions, by: activitySortOrder)

                Section {
                    Picker("Sort", selection: $activitySortOrder) {
                        ForEach(ActivitySortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Sort episode activity")
                }

                if sortedActions.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Episode Activity",
                            systemImage: "waveform",
                            description: Text("Your played episodes will appear here after syncing.")
                        )
                    }
                } else {
                    Section("Activity") {
                        ForEach(sortedActions) { action in
                            EpisodeActionRow(action: action, podcastManager: podcastManager)
                        }
                    }
                }
            }
        }
        .navigationTitle(Self.navigationTitleText)
        .task { await loadStats() }
        .refreshable { await loadStats() }
        .onChange(of: selectedPeriod) { _, _ in
            Task { await loadStats() }
        }
    }

    // MARK: - Data Loading

    private func loadStats() async {
        guard let proClient = podcastManager.currentSyncClient as? YourPodsProClient else {
            errorMessage = "Listening stats require a YourPods Sync account."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            response = try await proClient.getStats(since: selectedPeriod.sinceDate)
        } catch {
            if response == nil {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    // MARK: - Formatting

    private func formatHours(_ secs: Double) -> String {
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatMins(_ secs: Double) -> String {
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return "\(m)m \(s)s"
    }

    // MARK: - Accessibility

    private func dailyTrendAccessibilityLabel(_ trend: [DailyTrendEntry]) -> String {
        let totalMins = Int(trend.reduce(0) { $0 + $1.listenTimeSec } / 60)
        let days = trend.count
        return "Daily listening chart, \(days) days, \(totalMins) total minutes"
    }
}

// MARK: - Stats Period

/// Time period selector for Pro-tier stats filtering.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case week = "week"
    case month = "month"
    case year = "year"
    case allTime = "allTime"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: "This Week"
        case .month: "This Month"
        case .year: "This Year"
        case .allTime: "All Time"
        }
    }

    /// Returns the `since` date for this period, or nil for all-time.
    var sinceDate: Date? {
        let cal = Calendar.current
        switch self {
        case .week:    return cal.date(byAdding: .day, value: -7, to: .now)
        case .month:   return cal.date(byAdding: .month, value: -1, to: .now)
        case .year:    return cal.date(byAdding: .year, value: -1, to: .now)
        case .allTime: return nil
        }
    }
}

// MARK: - Stat Card

/// A single stat card in the 2×2 grid (listen time, episodes, podcasts, streak).
private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}

// MARK: - Stat Row

/// A label-value row for skip breakdown sections.
private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.subheadline.monospacedDigit())
        }
        // Combine label + value into one VoiceOver element: "Total Listen Time, 2h 30m"
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}
