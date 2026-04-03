import SwiftUI

/// Home screen showing recently updated episodes, quick actions, and now playing.
struct HomeView: View {
    /// Maximum number of episodes shown in the "Recently Updated" section.
    /// Two rows × ~6 visible columns for horizontal scroll.
    static let recentEpisodesLimit = 12
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    
    @State private var selectedEpisode: Episode?
    
    /// Collect the newest unplayed, non-interacted episodes across all subscriptions.
    private var recentEpisodes: [Episode] {
        podcastManager.subscriptions
            .flatMap { $0.episodes }
            .filter { !$0.isPlayed && !$0.isInteracted }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            .prefix(Self.recentEpisodesLimit)
            .map { $0 }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Recently Updated Episodes
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recently Updated")
                            .font(.title2.bold())
                            .padding(.horizontal)
                        
                        if recentEpisodes.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(.green)
                                    Text("You're all caught up!")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 24)
                                Spacer()
                            }
                        } else {
                            recentEpisodesGrid(episodes: recentEpisodes)
                        }
                    }
                    
                    // Quick Actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick Actions")
                            .font(.title2.bold())
                            .padding(.horizontal)
                        
                        HStack(spacing: 16) {
                            QuickActionButton(
                                title: "Refresh & Sync",
                                icon: "arrow.triangle.2.circlepath",
                                isLoading: podcastManager.isRefreshing
                            ) {
                                let pm = podcastManager
                                let plm = playerManager
                                let dm = downloadManager
                                let sm = settingsManager
                                Task { @MainActor in
                                    let strategy = sm.syncConflictStrategy
                                    let conflicts = await pm.refreshAndSync(
                                        playerManager: plm,
                                        downloadManager: dm,
                                        settingsManager: sm,
                                        strategy: strategy
                                    )
                                    if !conflicts.isEmpty && strategy == .ask {
                                        plm.pendingConflicts = conflicts
                                    }
                                }
                            }
                            
                            QuickActionButton(
                                title: "Add Podcast",
                                icon: "plus.circle"
                            ) {
                                navigationState.switchToAddPodcasts()
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    // Now Playing (if active)
                    if let item = playerManager.audioManager.currentItem {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Now Playing")
                                .font(.title2.bold())
                                .padding(.horizontal)
                            
                            NowPlayingCard(item: item)
                                .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("YourPods")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("YourPods")
                            .font(.headline)
                        Image("YourPodsLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .navigationDestination(for: Podcast.self) { podcast in
                PodcastDetailView(podcast: podcast)
            }
            .sheet(item: $selectedEpisode) { episode in
                EpisodeDetailSheet(episode: episode)
            }
        }
    }
    
    /// Determines if an episode is "new" based on the podcast's markedPlayedBefore date.
    private func isNewEpisode(_ episode: Episode) -> Bool {
        guard let podcast = episode.podcast else { return false }
        guard let markedBefore = podcast.effectiveSettings.markedPlayedBefore else { return true }
        guard let pubDate = episode.pubDate else { return false }
        return pubDate > markedBefore
    }
    
    // MARK: - Recently Updated Layout
    
    /// Card width constant shared between grid and horizontal scroll layouts.
    private static let cardWidth: CGFloat = 110
    /// Spacing between cards.
    private static let cardSpacing: CGFloat = 12
    /// Horizontal padding on each side.
    private static let horizontalPadding: CGFloat = 16
    
    /// Dynamically chooses centered grid or horizontal scroll based on available width.
    @ViewBuilder
    private func recentEpisodesGrid(episodes: [Episode]) -> some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width - (Self.horizontalPadding * 2)
            let columnsPerRow = max(1, Int(availableWidth / (Self.cardWidth + Self.cardSpacing)))
            let fitsOnScreen = episodes.count <= columnsPerRow * 2
            
            if fitsOnScreen {
                // All episodes fit in ≤2 rows — centered grid
                let columns = Array(repeating: GridItem(.flexible(), spacing: Self.cardSpacing), count: columnsPerRow)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(episodes) { episode in
                        recentEpisodeButton(for: episode)
                    }
                }
                .padding(.horizontal)
            } else {
                // More episodes than fit — horizontally scrollable 2-row grid
                ScrollView(.horizontal, showsIndicators: false) {
                    let rows = Array(repeating: GridItem(.fixed(170), spacing: Self.cardSpacing), count: 2)
                    LazyHGrid(rows: rows, spacing: Self.cardSpacing) {
                        ForEach(episodes) { episode in
                            recentEpisodeButton(for: episode)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(height: recentEpisodesGridHeight(count: episodes.count))
    }
    
    /// Calculates the height needed for the recent episodes section.
    private func recentEpisodesGridHeight(count: Int) -> CGFloat {
        let rowHeight: CGFloat = 170
        let rows: CGFloat = count <= 3 ? 1 : 2
        return (rowHeight * rows) + (rows > 1 ? 14 : 0)
    }
    
    /// Shared episode card button with context menu — used by both grid and scroll layouts.
    @ViewBuilder
    private func recentEpisodeButton(for episode: Episode) -> some View {
        Button {
            selectedEpisode = episode
        } label: {
            RecentEpisodeCard(
                episode: episode,
                isNew: isNewEpisode(episode),
                podcastArtworkUrl: episode.podcast?.logoUrl
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                playerManager.playEpisode(episode)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button {
                playerManager.addToQueue(episode, playNext: true)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button {
                playerManager.addToQueue(episode)
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            Divider()
            Button {
                podcastManager.markEpisodeAsPlayed(
                    podcastUrl: episode.podcastUrl ?? "",
                    episodeGuid: episode.guid
                )
            } label: {
                Label("Mark as Played", systemImage: "checkmark.circle")
            }
        }
    }
}

// MARK: - Recent Episode Card

private struct RecentEpisodeCard: View {
    let episode: Episode
    let isNew: Bool
    var podcastArtworkUrl: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Episode art, fallback to podcast art
                let imageUrl = episode.imageUrl ?? podcastArtworkUrl ?? episode.podcast?.logoUrl
                AsyncImage(url: URL(string: imageUrl ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "waveform")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                
                // NEW badge
                if isNew {
                    Text("NEW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                        .padding(4)
                }
            }
            
            Text(episode.title)
                .font(.caption.bold())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: 110, alignment: .leading)
            
            if let podcastTitle = episode.podcastTitle {
                Text(podcastTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
            }
        }
        .frame(width: 110)
    }
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    let title: String
    let icon: String
    var isLoading: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isLoading)
    }
}

// MARK: - Now Playing Card

private struct NowPlayingCard: View {
    let item: QueueItem
    @Environment(PlayerManager.self) private var playerManager
    @State private var selectedEpisode: Episode?
    
    var body: some View {
        Button {
            playerManager.togglePlayPause()
        } label: {
            HStack(spacing: 16) {
                AsyncImage(url: URL(string: item.artworkUrl ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.bold())
                        .lineLimit(2)
                    Text(item.podcastTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
