import SwiftUI

/// Home screen showing recently updated episodes, quick actions, and now playing.
struct HomeView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    
    @State private var selectedEpisode: Episode?
    
    /// Collect the newest unplayed, non-interacted episodes across all subscriptions (up to 6).
    private var recentEpisodes: [Episode] {
        podcastManager.subscriptions
            .flatMap { $0.episodes }
            .filter { !$0.isPlayed && !$0.isInteracted }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            .prefix(6)
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
                            let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(recentEpisodes) { episode in
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
                            .padding(.horizontal)
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
                                    await pm.refreshAndSync(
                                        playerManager: plm,
                                        downloadManager: dm,
                                        settingsManager: sm
                                    )
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
}

// MARK: - Recent Episode Card

private struct RecentEpisodeCard: View {
    let episode: Episode
    let isNew: Bool
    var podcastArtworkUrl: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Episode art, fallback to podcast art
                let imageUrl = episode.imageUrl ?? podcastArtworkUrl ?? episode.podcast?.logoUrl
                AsyncImage(url: URL(string: imageUrl ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "waveform")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // NEW badge
                if isNew {
                    Text("NEW")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
            
            Text(episode.title)
                .font(.caption.bold())
                .foregroundStyle(.primary)
                .lineLimit(2)
            
            if let podcastTitle = episode.podcastTitle {
                Text(podcastTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
