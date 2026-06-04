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
    @Environment(\.modelContext) private var modelContext
    
    @State private var episodeSheetItem: EpisodeSheetItem?
    
    /// Collect the newest unplayed, non-interacted episodes across all subscriptions.
    /// Limited to episodes from the last 2 months to ensure podcast diversity.
    private var recentEpisodes: [Episode] {
        RecentlyUpdatedFilter.filter(
            episodes: podcastManager.subscriptions.flatMap { $0.episodes },
            limit: Self.recentEpisodesLimit
        )
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Connectivity banner
                    OfflineBanner {
                        Task {
                            let strategy = settingsManager.syncConflictStrategy
                            let conflicts = await podcastManager.refreshAndSync(
                                playerManager: playerManager,
                                downloadManager: downloadManager,
                                settingsManager: settingsManager,
                                strategy: strategy
                            )
                            if !conflicts.isEmpty && strategy == .ask {
                                playerManager.pendingConflicts = conflicts
                            }
                        }
                    }
                    
                    // Pro sync auth-error banner (403 / 401)
                    if let syncError = podcastManager.lastSyncError {
                        SyncErrorBanner(message: syncError) {
                            podcastManager.lastSyncError = nil
                        }
                    }
                    
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
                    
                    // Quick Actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick Actions")
                            .font(.title2.bold())
                            .padding(.horizontal)
                        
                        HStack(spacing: 16) {
                            QuickActionButton(
                                title: "Refresh & Sync",
                                icon: "arrow.triangle.2.circlepath",
                                isLoading: podcastManager.isRefreshing || podcastManager.isSyncing
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
                }
                .padding(.top)
                .padding(.bottom, playerManager.currentEpisodeGuid != nil ? 100 : 16)
            }
            .navigationTitle("YourPods")
            .inlineNavigationBarTitle()
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
    }
    
    /// Determines if an episode is "new" based on the podcast's markedPlayedBefore date.
    private func isNewEpisode(_ episode: Episode) -> Bool {
        guard let podcast = episode.podcast else { return false }
        // Guard: podcast may be mid-deletion (deleted from context but SwiftUI hasn't
        // refreshed its @Query yet). effectiveSettings is safe to call here now.
        guard !podcast.isDeleted else { return false }
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
            episodeSheetItem = EpisodeSheetItem(episode: episode)
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
                downloadAction(episode)
            } label: {
                Label(
                    EpisodeDownloadHelper.downloadLabel(isDownloaded: downloadManager.isDownloaded(episode.guid)),
                    systemImage: EpisodeDownloadHelper.downloadIcon(isDownloaded: downloadManager.isDownloaded(episode.guid))
                )
            }
            Button {
                podcastManager.markEpisodeAsPlayed(
                    podcastUrl: episode.podcastUrl ?? "",
                    episodeGuid: episode.guid
                )
            } label: {
                Label("Mark as Played", systemImage: "checkmark.circle")
            }
            Divider()
            Button {
                episodeSheetItem = EpisodeSheetItem(episode: episode)
            } label: {
                Label("Details", systemImage: "info.circle")
            }
        }
        // MARK: VoiceOver - Recent Episodes
        .accessibilityAction(named: "Play") {
            playerManager.playEpisode(episode)
        }
        .accessibilityAction(named: "Play Next") {
            playerManager.addToQueue(episode, playNext: true)
        }
        .accessibilityAction(named: "Add to Queue") {
            playerManager.addToQueue(episode)
        }
        .accessibilityAction(named: EpisodeDownloadHelper.accessibilityActionName(isDownloaded: downloadManager.isDownloaded(episode.guid))) {
            downloadAction(episode)
        }
        .accessibilityAction(named: "Mark as Played") {
            podcastManager.markEpisodeAsPlayed(
                podcastUrl: episode.podcastUrl ?? "",
                episodeGuid: episode.guid
            )
        }
        .accessibilityAction(named: "Details") {
            episodeSheetItem = EpisodeSheetItem(episode: episode)
        }
    }
    
    // MARK: - Download Action
    
    /// Toggle download state for an episode from context menu.
    private func downloadAction(_ episode: Episode) {
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
    }
}

// MARK: - Sync Error Banner

/// Shown when any sync backend (Pro or gPodder) returns an error.
private struct SyncErrorBanner: View {
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .font(.body.weight(.semibold))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Error")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
            
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(6)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Dismiss sync error")
        }
        .padding()
        .background(Color.red.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: message)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sync error: \(message)")
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
                CachedAsyncImage(url: URL(string: imageUrl ?? "")) { image in
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
        // MARK: VoiceOver
        .accessibilityElement(children: .ignore)
        .accessibilityLabel({
            var label = episode.title
            if let podcastTitle = episode.podcastTitle {
                label += ", \(podcastTitle)"
            }
            if isNew { label += ", New episode" }
            return label
        }())
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
        .accessibilityLabel(isLoading ? "\(title), loading" : title)
    }
}

// MARK: - Now Playing Card

private struct NowPlayingCard: View {
    let item: QueueItem
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @State private var chapters: [Chapter] = []
    @State private var showChapters = false
    
    /// Artwork size — 15% smaller than the original 60pt.
    private static let artworkSize: CGFloat = 51
    
    /// Current chapter based on playback position.
    private var currentChapter: Chapter? {
        guard !chapters.isEmpty else { return nil }
        let pos = playerManager.currentPosition
        return chapters.last(where: { $0.startTime <= pos })
    }
    
    var body: some View {
        Button {
            playerManager.togglePlayPause()
        } label: {
            VStack(spacing: 0) {
                // Album art
                CachedAsyncImage(url: URL(string: item.artworkUrl ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                }
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 10)
                .padding(.bottom, 6)
                
                // Thin info strip below artwork
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Title
                        Text(item.title)
                            .font(.caption.bold())
                            .lineLimit(1)
                        
                        // Condensed metadata: podcast · date · duration/progress
                        HStack(spacing: 4) {
                            Text(item.podcastTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            
                            let meta = NowPlayingCardHelper.condensedMetadata(
                                pubDate: item.pubDate,
                                durationSeconds: item.durationSeconds,
                                position: playerManager.currentPosition,
                                totalDuration: playerManager.currentDuration
                            )
                            if !meta.isEmpty {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(meta)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        
                        // Chapter indicator
                        if let chapter = currentChapter {
                            Text(chapter.title)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer(minLength: 4)
                    
                    Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showChapters) {
            ChapterListSheet(chapters: chapters, currentPosition: playerManager.currentPosition) { chapter in
                playerManager.seek(to: chapter.startTime)
                showChapters = false
            }
            .presentationDetents([.medium, .large])
        }
        .simultaneousGesture(
            // Long-press opens chapters if available
            LongPressGesture().onEnded { _ in
                if !chapters.isEmpty {
                    showChapters = true
                }
            }
        )
        .task(id: playerManager.currentEpisodeGuid) {
            chapters = []
            chapters = await ChapterService.shared.fetchAllChapters(
                chaptersUrl: item.chaptersUrl,
                chaptersJSON: item.chaptersJSON,
                description: item.episodeDescription
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EpisodeAccessibility.nowPlayingLabel(
            title: item.title,
            podcastTitle: item.podcastTitle,
            isPlaying: playerManager.isPlaying
        ))
        .accessibilityHint(playerManager.isPlaying ? "Double tap to pause" : "Double tap to play")
    }
}
