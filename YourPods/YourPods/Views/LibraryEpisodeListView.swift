import SwiftUI

/// The Library's Episode lens: a flat, filterable, capped episode list across all shows.
/// Filtering/sorting/capping is delegated to `LibraryEpisodeList`; sectioning to `EpisodeArranger`.
struct LibraryEpisodeListView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext

    let filter: LibraryView.LibraryFilter
    let searchText: String

    @State private var episodeSheetItem: EpisodeSheetItem?

    var body: some View {
        let result = LibraryEpisodeList.build(
            episodes: podcastManager.subscriptions.flatMap { $0.episodes },
            filter: filter,
            titleQuery: searchText,
            isDownloaded: downloadManager.isDownloaded,
            hasInProgressAction: { podcastManager.getLatestAction(for: $0) != nil },
            isHidden: { podcastManager.episodeActionSync.isHidden(guid: $0) }
        )
        let sections = EpisodeArranger.sections(
            episodes: result.episodes,
            arrangement: settingsManager.libraryEpisodeArrangement
        )
        return Group {
            if result.episodes.isEmpty {
                ContentUnavailableView(
                    "No Episodes",
                    systemImage: "list.bullet",
                    description: Text(String(localized: "library.empty.noEpisodesForFilter",
                                             defaultValue: "No episodes match the \(filter.displayName) filter.",
                                             comment: "Empty-state message when the chosen library filter matches nothing. Argument 1 is the filter's own name — All, Groups, Downloaded, Unplayed or In Progress — already localized, so translate this sentence around it."))
                )
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.episodes) { episode in
                                episodeRow(episode)
                            }
                        } header: {
                            if let title = section.title { Text(title) }
                        }
                    }

                    if result.overflowCount > 0 {
                        Text("Showing newest \(result.episodes.count) — \(result.overflowCount) older hidden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowSeparator(.hidden)
                            .accessibilityLabel("Showing the newest \(result.episodes.count) episodes. \(result.overflowCount) older episodes are hidden.")
                    }
                }
                .listStyle(.plain)
            }
        }
        .refreshable {
            let strategy = settingsManager.syncConflictStrategy
            let conflicts = await podcastManager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                strategy: strategy
            )
            playerManager.deliverConflicts(conflicts, strategy: strategy)
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

    @ViewBuilder
    private func episodeRow(_ episode: Episode) -> some View {
        EpisodeRow(
            episode: episode,
            isPlaying: episode.guid == playerManager.currentEpisodeGuid,
            isDownloaded: downloadManager.isDownloaded(episode.guid),
            isDownloading: downloadManager.activeDownloads[episode.guid] != nil,
            isHidden: podcastManager.episodeActionSync.isHidden(guid: episode.guid),
            isInQueue: playerManager.queuedEpisodeGuids.contains(episode.guid),
            onDownloadTap: { downloadAction(episode) },
            onMenuAction: { action in handleMenuAction(action, for: episode) },
            onTap: { episodeSheetItem = EpisodeSheetItem(episode: episode) },
            showQueueButton: true,
            swipeLeading: settingsManager.episodeSwipeLeading,
            swipeTrailing: settingsManager.episodeSwipeTrailing
        )
    }

    private func downloadAction(_ episode: Episode) {
        if downloadManager.isDownloaded(episode.guid) {
            downloadManager.deleteDownload(guid: episode.guid)
        } else if let audioUrl = episode.audioUrl {
            let authHeaders: [String: String]? = episode.podcast?.requiresAuth == true
                ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: episode.podcast!.url)
                    .map { ["Authorization": $0] }
                : nil
            let privacyMode = episode.podcast?.effectiveSettings.privacyMode ?? settingsManager.p3Enabled
            downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl,
                                            authHeaders: authHeaders, privacyMode: privacyMode)
        }
    }

    private func handleMenuAction(_ action: EpisodeMenuAction, for episode: Episode) {
        switch action {
        case .play:            playerManager.playEpisode(episode)
        case .playNext:        playerManager.addToQueue(episode, playNext: true)
        case .addToQueue:      playerManager.addToQueue(episode)
        case .removeFromQueue:
            // Find the matching QueueItem by GUID and remove it
            if let item = playerManager.audioManager.queue.first(where: { $0.id == episode.guid }) {
                playerManager.removeFromQueue(item)
            } else if playerManager.audioManager.currentItem?.id == episode.guid {
                playerManager.removeCurrentEpisodeFromQueue()
            }
        case .markPlayed:
            if let podcastUrl = episode.podcastUrl {
                if episode.isPlayed {
                    podcastManager.markEpisodeAsUnplayed(podcastUrl: podcastUrl, episodeGuid: episode.guid)
                } else {
                    podcastManager.markEpisodeAsPlayed(podcastUrl: podcastUrl, episodeGuid: episode.guid)
                }
            }
        case .hide:            podcastManager.toggleHidden(episode: episode)
        case .details:         episodeSheetItem = EpisodeSheetItem(episode: episode)
        case .download:        downloadAction(episode)
        }
    }
}
