import SwiftUI

/// Listening history / stats view.
struct HistoryView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @State private var stats: ListeningStats = .empty
    @State private var isComputing = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Summary Cards
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    StatCard(title: "Total Listening", value: formatDuration(stats.totalListeningDuration), icon: "headphones")
                    StatCard(title: "Episodes", value: "\(stats.episodesCompleted)", icon: "checkmark.circle")
                    StatCard(title: "Current Streak", value: "\(stats.currentStreak) days", icon: "flame")
                    StatCard(title: "Longest Streak", value: "\(stats.longestStreak) days", icon: "trophy")
                }
                .padding(.horizontal)
                
                // Top Podcasts
                if !stats.topPodcasts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Top Podcasts")
                            .font(.title3.bold())
                            .padding(.horizontal)
                        
                        ForEach(stats.topPodcasts) { podStats in
                            HStack(spacing: 12) {
                                CachedAsyncImage(url: URL(string: podStats.logoUrl ?? "")) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                                }
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(podStats.podcastTitle)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                    Text("\(podStats.episodeCount) ep · \(formatDuration(TimeInterval(podStats.totalTimeSeconds)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Listening Stats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await computeStats() }
                } label: {
                    if isComputing { ProgressView() }
                    else { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .task { await loadOrCompute() }
    }
    
    private func loadOrCompute() async {
        if let cached = ListeningStatsService.loadFromCache() {
            stats = cached
        } else {
            await computeStats()
        }
    }
    
    private func computeStats() async {
        isComputing = true
        let actions = Array(podcastManager.actionMap.values)
        stats = ListeningStatsService.computeStats(
            actions: actions,
            subscriptions: podcastManager.subscriptions
        )
        ListeningStatsService.saveToCache(stats)
        isComputing = false
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            
            Text(value)
                .font(.title3.bold())
            
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
