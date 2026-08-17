import SwiftUI

/// Home screen showing recently updated episodes, quick actions, and now playing.
struct HomeView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext
    
    @State private var episodeSheetItem: EpisodeSheetItem?
    
    /// Collect the newest unplayed, non-interacted episodes across all subscriptions.
    /// Limited to episodes from the last 3 months with per-podcast diversity guarantees.
    private var recentFilterResult: RecentlyUpdatedFilter.FilterResult {
        RecentlyUpdatedFilter.filter(
            episodes: podcastManager.subscriptions.flatMap { $0.episodes },
            limit: settingsManager.recentlyUpdatedLimit
        )
    }
    
    private var recentEpisodes: [Episode] { recentFilterResult.episodes }
    private var overflowCount: Int { recentFilterResult.overflowCount }
    
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
                            playerManager.deliverConflicts(conflicts, strategy: strategy)
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
                        HStack {
                            Text("Recently Updated")
                                .font(.title2.bold())
                            Spacer()
                            // Persistent entry to the full new-episodes list. Shows
                            // "+N more" when the settings limit hides some, else
                            // "See All" so the full list is always reachable.
                            if !recentEpisodes.isEmpty {
                                NavigationLink {
                                    AllRecentEpisodesView()
                                } label: {
                                    Group {
                                        if overflowCount > 0 {
                                            Text("+\(overflowCount) more")
                                        } else {
                                            Text("See All")
                                        }
                                    }
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
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
                                    plm.deliverConflicts(conflicts, strategy: strategy)
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
    
    /// Dynamically chooses centered grid or horizontal scroll based on available width.
    @ViewBuilder
    private func recentEpisodesGrid(episodes: [Episode]) -> some View {
        GeometryReader { geo in
            let containerWidth = geo.size.width
            let columnsPerRow = RecentGridLayout.columnsPerRow(availableWidth: containerWidth)
            
            if RecentGridLayout.fitsOnScreen(episodeCount: episodes.count, availableWidth: containerWidth) {
                // All episodes fit in ≤2 rows — centered grid
                let columns = Array(repeating: GridItem(.flexible(), spacing: RecentGridLayout.cardSpacing), count: columnsPerRow)
                LazyVGrid(columns: columns, spacing: RecentGridLayout.rowSpacing) {
                    ForEach(episodes) { episode in
                        recentEpisodeButton(for: episode)
                    }
                }
                .padding(.horizontal)
            } else {
                // More episodes than fit — horizontally scrollable 2-row grid
                ScrollView(.horizontal, showsIndicators: false) {
                    let rows = Array(repeating: GridItem(.fixed(RecentGridLayout.rowHeight), spacing: RecentGridLayout.cardSpacing), count: 2)
                    LazyHGrid(rows: rows, spacing: RecentGridLayout.cardSpacing) {
                        ForEach(episodes) { episode in
                            recentEpisodeButton(for: episode)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(height: RecentGridLayout.gridHeight(episodeCount: episodes.count, availableWidth: RecentGridLayout.screenWidth))
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
                markEpisodePlayed(episode)
            } label: {
                Label("Mark as Played", systemImage: "checkmark.circle")
            }
            Button {
                podcastManager.toggleHidden(episode: episode)
            } label: {
                let isHidden = podcastManager.episodeActionSync.isHidden(guid: episode.guid)
                Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
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
            markEpisodePlayed(episode)
        }
        .accessibilityAction(named: podcastManager.episodeActionSync.isHidden(guid: episode.guid) ? "Unhide" : "Hide") {
            podcastManager.toggleHidden(episode: episode)
        }
        .accessibilityAction(named: "Details") {
            episodeSheetItem = EpisodeSheetItem(episode: episode)
        }
    }
    
    /// Mark an episode played. If it is the one currently playing, route through
    /// PlayerManager so playback advances to the next queued episode (or stops when
    /// Up Next is empty) instead of leaving a played episode playing — the same
    /// gate EpisodeDetailSheet uses.
    private func markEpisodePlayed(_ episode: Episode) {
        if EpisodeDetailSheetHelper.shouldUsePlayerManager(
            episodeGuid: episode.guid,
            currentEpisodeGuid: playerManager.currentEpisodeGuid
        ) {
            playerManager.markCurrentEpisodeAsPlayed()
        } else {
            podcastManager.markEpisodeAsPlayed(
                podcastUrl: episode.podcastUrl ?? "",
                episodeGuid: episode.guid
            )
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
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                
                // NEW badge
                if isNew {
                    Text(String(localized: "episode.badge.new",
                                defaultValue: "NEW",
                                comment: "Small badge on an episode the user has not seen yet. English styles it all-caps; use your language's normal badge convention rather than copying the capitalisation."))
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
        .accessibilityLabel(EpisodeAccessibility.cardLabel(
            title: episode.title,
            podcastTitle: episode.podcastTitle,
            isNew: isNew
        ))
    }
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    /// `LocalizedStringResource`, not `String`: as a `String` the literals at
    /// the call sites bound the non-localizing overload and shipped in English
    /// everywhere — verified under the double-length pseudolanguage, where
    /// every label on the Home screen doubled except these two.
    let title: LocalizedStringResource
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
            .yourPodsGlass(role: .card, cornerRadius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isLoading)
        .accessibilityLabel(Self.actionCardLabel(title: title, isLoading: isLoading))
    }

    /// The card's title, with "loading" appended while its action runs.
    ///
    /// Written as a ternary between an interpolated literal and a bare
    /// `String`, this bound the non-localizing overload: neither branch
    /// extracted, so VoiceOver said "loading" in every language.
    private static func actionCardLabel(title: LocalizedStringResource, isLoading: Bool) -> String {
        guard isLoading else { return String(localized: title) }
        return String(localized: "a11y.card.loading",
                      defaultValue: "\(String(localized: title)), loading",
                      comment: "VoiceOver label for an action card whose work is still running. The argument is the card's title.")
    }
}

// MARK: - Now Playing Card

private struct NowPlayingCard: View {
    let item: QueueItem
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(ChapterCoordinator.self) private var chapterCoordinator
    @State private var showChapters = false

    /// Chapters for the currently-playing item, owned by `ChapterCoordinator`
    /// — the same resolved (embedded-first) list the mini player and CarPlay
    /// show. This card is the now-playing card (it renders the current
    /// `item`), so it's a currently-playing surface per the chapter-images
    /// plan and reads the coordinator directly rather than running its own
    /// feed-only `ChapterService.fetchAllChapters`, which showed nothing for
    /// episodes whose chapters are embedded in the audio file.
    private var chapters: [Chapter] { chapterCoordinator.visibleChapters }

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
                .clipped()
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
                                Text(verbatim: "·")
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
            .yourPodsGlass(role: .card, cornerRadius: 12)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EpisodeAccessibility.nowPlayingLabel(
            title: item.title,
            podcastTitle: item.podcastTitle,
            isPlaying: playerManager.isPlaying
        ))
        .accessibilityHint(playerManager.isPlaying ? "Double tap to pause" : "Double tap to play")
    }
}
