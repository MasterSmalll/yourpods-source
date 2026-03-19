import SwiftUI

/// Shows synced episode listening progress from the gPodder server.
/// Accessible from Settings → "Episode Activity".
struct EpisodeActivityView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settings
    
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
                            Text("Last synced: \(date, style: .relative) ago")
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
            _ = try? await podcastManager.syncEpisodeActions()
            isRefreshing = false
        }
    }
}

// MARK: - Episode Action Row

private struct EpisodeActionRow: View {
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
                        let pct = min(100, Int(Double(position) / Double(total) * 100))
                        Text("\(pct)% · \(formatTime(position)) / \(formatTime(total))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if let position = action.position {
                        Text("at \(formatTime(position))")
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
                    Text("Device: \(device)")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
