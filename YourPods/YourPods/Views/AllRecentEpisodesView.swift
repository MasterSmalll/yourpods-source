import SwiftUI

/// Full-screen list of all recently updated episodes (unfiltered by the home limit).
/// Navigated to from the "+N others" overflow card on the Home screen.
struct AllRecentEpisodesView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext
    
    @State private var episodeSheetItem: EpisodeSheetItem?
    
    /// All recent episodes with no cap — uses a large limit to show everything from the 3-month window.
    private var allRecentEpisodes: [Episode] {
        RecentlyUpdatedFilter.filter(
            episodes: podcastManager.subscriptions.flatMap { $0.episodes },
            limit: 500
        ).episodes
    }
    
    var body: some View {
        List {
            ForEach(allRecentEpisodes) { episode in
                EpisodeRow(
                    episode: episode,
                    isPlaying: playerManager.audioManager.currentItem?.id == episode.guid,
                    isDownloaded: downloadManager.isDownloaded(episode.guid),
                    isHidden: podcastManager.episodeActionSync.isHidden(guid: episode.guid),
                    isInQueue: playerManager.queuedEpisodeGuids.contains(episode.guid),
                    onDownloadTap: {
                        if downloadManager.isDownloaded(episode.guid) {
                            downloadManager.deleteDownload(guid: episode.guid)
                        } else if let audioUrl = episode.audioUrl {
                            let authHeaders: [String: String]? = episode.podcast?.requiresAuth == true
                                ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: episode.podcast!.url)
                                    .map { ["Authorization": $0] }
                                : nil
                            let privacyMode = episode.podcast?.effectiveSettings.privacyMode ?? settingsManager.p3Enabled
                            downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl, authHeaders: authHeaders, privacyMode: privacyMode)
                        }
                    },
                    onMenuAction: { action in
                        handleMenuAction(action, for: episode)
                    },
                    onTap: {
                        episodeSheetItem = EpisodeSheetItem(episode: episode)
                    },
                    swipeLeading: settingsManager.episodeSwipeLeading,
                    swipeTrailing: settingsManager.episodeSwipeTrailing
                )
            }
        }
        .listStyle(.plain)
        .navigationTitle("All Recent Episodes")
        .refreshable {
            await podcastManager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                strategy: settingsManager.syncConflictStrategy
            )
        }
        .sheet(item: $episodeSheetItem) { item in
            EpisodeDetailSheet(episode: item.episode)
                .environment(playerManager)
                .environment(podcastManager)
                .environment(downloadManager)
                .environment(settingsManager)
                .environment(navigationState)
                .modelContext(modelContext)
        }
    }
    
    private func handleMenuAction(_ action: EpisodeMenuAction, for episode: Episode) {
        switch action {
        case .play:
            playerManager.playEpisode(episode)
        case .playNext:
            playerManager.addToQueue(episode, playNext: true)
        case .addToQueue:
            playerManager.addToQueue(episode)
        case .markPlayed:
            if episode.isPlayed {
                podcastManager.markEpisodeAsUnplayed(podcastUrl: episode.podcastUrl ?? "", episodeGuid: episode.guid)
            } else if EpisodeDetailSheetHelper.shouldUsePlayerManager(
                episodeGuid: episode.guid,
                currentEpisodeGuid: playerManager.currentEpisodeGuid
            ) {
                // Currently playing: mark played + advance the queue
                playerManager.markCurrentEpisodeAsPlayed()
            } else {
                podcastManager.markEpisodeAsPlayed(podcastUrl: episode.podcastUrl ?? "", episodeGuid: episode.guid)
            }
        case .hide:
            podcastManager.toggleHidden(episode: episode)
        case .details:
            episodeSheetItem = EpisodeSheetItem(episode: episode)
        case .download:
            break // handled by onDownloadTap
        case .removeFromQueue:
            // Find the matching QueueItem by GUID and remove it
            if let item = playerManager.audioManager.queue.first(where: { $0.id == episode.guid }) {
                playerManager.removeFromQueue(item)
            } else if playerManager.audioManager.currentItem?.id == episode.guid {
                playerManager.removeCurrentEpisodeFromQueue()
            }
        }
    }
}
