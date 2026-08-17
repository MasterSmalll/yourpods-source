import SwiftUI

/// Episode list for a specific podcast. Port of episode_list_screen.dart.
struct PodcastDetailView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext
    let podcast: Podcast
    
    @State private var showSettings = false
    @State private var isRefreshing = false
    @State private var episodeSheetItem: EpisodeSheetItem?
    @State private var showMarkAllConfirmation = false
    @State private var showHideOlderConfirmation = false
    @State private var episodeToDeleteDownload: Episode?
    @State private var isDescriptionExpanded = false
    @AppStorage("skipDeleteDownloadConfirmation") private var skipDeleteConfirmation = false
    @AppStorage("showHiddenEpisodes") private var showHidden = false
    
    private var allEpisodes: [Episode] {
        podcast.episodes
            .filter { !$0.isStale }
            .sorted(by: episodesByFeedOrder)
    }
    
    private var visibleEpisodes: [Episode] {
        var eps = allEpisodes
        if settingsManager.hidePlayedEpisodes {
            // When Hide Played is on, show unplayed episodes.
            // If Show Hidden is also on, additionally include hidden episodes.
            if showHidden {
                eps = eps.filter { !$0.isPlayed || podcastManager.episodeActionSync.isHidden(guid: $0.guid) }
            } else {
                eps = eps.filter { !$0.isPlayed }
            }
        } else if !showHidden {
            // When Hide Played is off, filter out hidden episodes (they appear played)
            // unless Show Hidden is on
            eps = eps.filter { !podcastManager.episodeActionSync.isHidden(guid: $0.guid) || !$0.isPlayed }
        }
        return eps
    }
    
    private var playedCount: Int {
        allEpisodes.filter { $0.isPlayed }.count
    }
    
    private var hiddenCount: Int {
        podcastManager.episodeActionSync.hiddenGuids(for: podcast).count
    }
    
    private var unplayedCount: Int {
        allEpisodes.count - playedCount
    }
    
    var body: some View {
        List {
            // Podcast header
            Section {
                HStack(spacing: 16) {
                    ZStack(alignment: .bottomTrailing) {
                        CachedAsyncImage(url: URL(string: podcast.logoUrl ?? "")) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        }
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        if podcast.requiresAuth {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.orange, in: Circle())
                                .offset(x: 4, y: 4)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(podcast.title)
                                .font(.headline)
                            if podcast.requiresAuth {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let author = podcast.author {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let publisher = podcast.publisher, publisher != podcast.author {
                            Text(String(localized: "podcast.byPublisher",
                                        defaultValue: "by \(publisher)",
                                        comment: "Attribution under a podcast title, as in 'by NPR'. Argument 1 is the publisher name and is never translated. German renders this as 'von NPR'."))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 6) {
                            Text("\(allEpisodes.count) episodes")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            if playedCount > 0 {
                                Text(verbatim: "·")
                                    .foregroundStyle(.tertiary)
                                Text("\(playedCount) played")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        
                        // Spec metadata badges
                        metadataBadges
                    }
                }
                
                // Podcast description (tap to expand)
                if let desc = podcast.podcastDescription, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(desc.strippingHTML())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isDescriptionExpanded ? nil : 4)
                            .animation(.easeInOut(duration: 0.2), value: isDescriptionExpanded)
                        
                        Button {
                            withAnimation { isDescriptionExpanded.toggle() }
                        } label: {
                            Text(isDescriptionExpanded ? "Show Less" : "Show More")
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // Podcast links section
                podcastLinksSection
                
                // V4V info card
                if podcast.supportsValue4Value {
                    Label {
                        Text("This show supports Value4Value (⚡ Lightning). Direct listener support via compatible apps.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.yellow)
                    }
                    .padding(10)
                    .background(Color.yellow.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                // Live badge
                if podcast.hasLiveItem {
                    liveItemBanner
                }
            }
            
            // Controls
            Section {
                Toggle(isOn: Bindable(settingsManager).hidePlayedEpisodes) {
                    Label("Hide Played", systemImage: "eye.slash")
                }
                
                if hiddenCount > 0 {
                    Toggle(isOn: $showHidden) {
                        Label("Show Hidden (\(hiddenCount))", systemImage: "eye")
                    }
                }
                
                if unplayedCount > 0 {
                    Button(role: .destructive) {
                        showHideOlderConfirmation = true
                    } label: {
                        Label("Hide Older Episodes (\(unplayedCount))", systemImage: "eye.slash.fill")
                    }
                }
                
                if unplayedCount > 0 {
                    Button(role: .destructive) {
                        showMarkAllConfirmation = true
                    } label: {
                        Label("Mark All as Played (\(allEpisodes.count))", systemImage: "checkmark.circle.fill")
                    }
                } else {
                    HStack {
                        Label("All Episodes Played", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                    }
                }
            }
            
            // Episodes
            Section("\(visibleEpisodes.count) episodes") {
                ForEach(visibleEpisodes) { episode in
                    let isHidden = podcastManager.episodeActionSync.isHidden(guid: episode.guid)
                    let isInQueue = playerManager.queuedEpisodeGuids.contains(episode.guid)
                    EpisodeRow(
                        episode: episode,
                        isPlaying: episode.guid == playerManager.currentEpisodeGuid,
                        isDownloaded: downloadManager.isDownloaded(episode.guid),
                        isDownloading: downloadManager.activeDownloads[episode.guid] != nil,
                        isHidden: isHidden,
                        isInQueue: isInQueue,
                        onDownloadTap: { downloadAction(episode) },
                        onMenuAction: { action in handleMenuAction(action, episode: episode) },
                        onTap: { episodeSheetItem = EpisodeSheetItem(episode: episode) },
                        swipeLeading: settingsManager.episodeSwipeLeading,
                        swipeTrailing: settingsManager.episodeSwipeTrailing
                    )
                    .opacity(isHidden && showHidden ? 0.5 : 1.0)
                    .contextMenu {
                        Button { handleMenuAction(.play, episode: episode) } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        Button { handleMenuAction(.playNext, episode: episode) } label: {
                            Label("Play Next", systemImage: "text.insert")
                        }
                        if isInQueue {
                            Button { handleMenuAction(.removeFromQueue, episode: episode) } label: {
                                Label("Remove from Queue", systemImage: "minus.circle")
                            }
                        } else {
                            Button { handleMenuAction(.addToQueue, episode: episode) } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }
                        }
                        Divider()
                        Button { handleMenuAction(.download, episode: episode) } label: {
                            Label(
                                EpisodeDownloadHelper.downloadLabel(isDownloaded: downloadManager.isDownloaded(episode.guid)),
                                systemImage: EpisodeDownloadHelper.downloadIcon(isDownloaded: downloadManager.isDownloaded(episode.guid))
                            )
                        }
                        Button { handleMenuAction(.markPlayed, episode: episode) } label: {
                            Label(
                                episode.isPlayed ? "Mark as Unplayed" : "Mark as Played",
                                systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
                            )
                        }
                        Divider()
                        Button { handleMenuAction(.hide, episode: episode) } label: {
                            Label(
                                isHidden ? "Unhide" : "Hide",
                                systemImage: isHidden ? "eye" : "eye.slash"
                            )
                        }
                        Divider()
                        Button { handleMenuAction(.details, episode: episode) } label: {
                            Label("Details", systemImage: "info.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle(podcast.title)
        #if os(iOS)
        .inlineNavigationBarTitle()
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
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
        .sheet(isPresented: $showSettings) {
            PodcastSettingsSheet(podcast: podcast)
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
        .confirmationDialog(
            "Mark All as Played",
            isPresented: $showMarkAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mark \(allEpisodes.count) Episodes as Played", role: .destructive) {
                podcastManager.markAllEpisodesAsPlayed(for: podcast)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will mark all \(allEpisodes.count) episodes as fully played and sync to the server. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete Download?",
            isPresented: Binding(
                get: { episodeToDeleteDownload != nil },
                set: { if !$0 { episodeToDeleteDownload = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ep = episodeToDeleteDownload {
                    downloadManager.deleteDownload(guid: ep.guid)
                    episodeToDeleteDownload = nil
                }
            }
            Button("Delete & Don't Ask Again", role: .destructive) {
                skipDeleteConfirmation = true
                if let ep = episodeToDeleteDownload {
                    downloadManager.deleteDownload(guid: ep.guid)
                    episodeToDeleteDownload = nil
                }
            }
            Button("Cancel", role: .cancel) { episodeToDeleteDownload = nil }
        } message: {
            Text("This will remove the downloaded episode from your device.")
        }
        .confirmationDialog(
            "Hide Older Episodes",
            isPresented: $showHideOlderConfirmation,
            titleVisibility: .visible
        ) {
            Button("Hide \(unplayedCount) Unplayed Episodes", role: .destructive) {
                let unplayed = allEpisodes.filter { !$0.isPlayed }
                podcastManager.hideEpisodes(unplayed)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will hide all \(unplayedCount) unplayed episodes from this podcast. They won't appear in your feed but can be shown again with the Show Hidden toggle.")
        }
    }
    
    private func downloadAction(_ episode: Episode) {
        if downloadManager.isDownloaded(episode.guid) {
            if skipDeleteConfirmation {
                downloadManager.deleteDownload(guid: episode.guid)
            } else {
                episodeToDeleteDownload = episode
            }
        } else if downloadManager.activeDownloads[episode.guid] == nil,
                  let audioUrl = episode.audioUrl {
            let authHeaders: [String: String]? = episode.podcast?.requiresAuth == true
                ? KeychainHelper.shared.buildBasicAuthHeader(forPodcastUrl: episode.podcast!.url)
                    .map { ["Authorization": $0] }
                : nil
            let privacyMode = episode.podcast?.effectiveSettings.privacyMode ?? settingsManager.p3Enabled
            downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl, authHeaders: authHeaders, privacyMode: privacyMode)
        }
    }
    
    private func handleMenuAction(_ action: EpisodeMenuAction, episode: Episode) {
        switch action {
        case .play:
            playerManager.playEpisode(episode)
        case .playNext:
            playerManager.addToQueue(episode, playNext: true)
        case .addToQueue:
            playerManager.addToQueue(episode)
        case .removeFromQueue:
            // Find the matching QueueItem by GUID and remove it
            if let item = playerManager.audioManager.queue.first(where: { $0.id == episode.guid }) {
                playerManager.removeFromQueue(item)
            } else if playerManager.audioManager.currentItem?.id == episode.guid {
                playerManager.removeCurrentEpisodeFromQueue()
            }
        case .download:
            downloadAction(episode)
        case .markPlayed:
            if let podcastUrl = episode.podcastUrl {
                if episode.isPlayed {
                    podcastManager.markEpisodeAsUnplayed(podcastUrl: podcastUrl, episodeGuid: episode.guid)
                } else if EpisodeDetailSheetHelper.shouldUsePlayerManager(
                    episodeGuid: episode.guid,
                    currentEpisodeGuid: playerManager.currentEpisodeGuid
                ) {
                    // Currently playing: mark played + advance the queue
                    playerManager.markCurrentEpisodeAsPlayed()
                } else {
                    podcastManager.markEpisodeAsPlayed(podcastUrl: podcastUrl, episodeGuid: episode.guid)
                }
            }
        case .hide:
            podcastManager.toggleHidden(episode: episode)
        case .details:
            episodeSheetItem = EpisodeSheetItem(episode: episode)
        }
    }
}

// MARK: - Podcast Metadata Badges

extension PodcastDetailView {
    @ViewBuilder
    private var metadataBadges: some View {
        let hasBadges = podcast.explicit != nil || !podcast.categories.isEmpty || podcast.isComplete || podcast.showType == "serial"
        if hasBadges {
            HStack(spacing: 6) {
                if podcast.explicit == true {
                    // U+1F174 NEGATIVE SQUARED LATIN CAPITAL LETTER E — the
                    // glyph is the badge, so it is verbatim, and VoiceOver
                    // reads the label rather than the character's Unicode name.
                    Text(verbatim: "🅴")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Explicit")
                }
                
                ForEach(podcast.categories, id: \.self) { cat in
                    Text(cat)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                
                if podcast.isComplete {
                    Label(String(localized: "podcast.badge.complete",
                                 defaultValue: "Complete",
                                 comment: "Badge on a podcast that has finished publishing and will get no further episodes. The ADJECTIVE describing a finished series, never a verb telling the user to complete something."),
                          systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                
                if podcast.showType == "serial" {
                    Label(String(localized: "podcast.badge.serial",
                                 defaultValue: "Serial",
                                 comment: "Badge on a podcast meant to be heard in order from episode 1, as opposed to episodic. Describes the show's format."),
                          systemImage: "list.number")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                }
            }
        }
    }
    
    @ViewBuilder
    private var liveItemBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.liveItemStatus?.uppercased() ?? "LIVE")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                if let start = podcast.liveItemStart {
                    Text("Scheduled: \(start.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if let linkStr = podcast.liveItemContentLink, let url = URL(string: linkStr) {
                Link(destination: url) {
                    Label(String(localized: "podcast.action.openWebsite",
                                 defaultValue: "Watch",
                                 comment: "Opens a video podcast's website in the browser. The VERB 'to watch' — never the noun meaning a wristwatch or Apple Watch."),
                          systemImage: "arrow.up.right")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    @ViewBuilder
    private var podcastLinksSection: some View {
        let hasLinks = podcast.website != nil || podcast.fundingUrl != nil || podcast.language != nil || podcast.copyright != nil
        if hasLinks {
            VStack(alignment: .leading, spacing: 8) {
                // Website
                if let websiteStr = podcast.website, let url = URL(string: websiteStr) {
                    Link(destination: url) {
                        Label {
                            Text(url.host ?? websiteStr)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "globe")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    }
                }
                
                // Funding link
                if let fundingUrlStr = podcast.fundingUrl, let url = URL(string: fundingUrlStr) {
                    Link(destination: url) {
                        Label(
                            podcast.fundingLabel ?? "Support This Show",
                            systemImage: "heart.fill"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.pink)
                    }
                }
                
                // RSS feed URL
                if let feedUrl = URL(string: podcast.url) {
                    Link(destination: feedUrl) {
                        Label("RSS Feed", systemImage: "dot.radiowaves.up.forward")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                
                // Language + Copyright row
                HStack(spacing: 12) {
                    if let lang = podcast.language {
                        Label(lang.uppercased(), systemImage: "globe.americas")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let copyright = podcast.copyright {
                        Label {
                            Text(copyright)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "c.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Episode Menu Action

enum EpisodeMenuAction {
    case play, playNext, addToQueue, removeFromQueue, download, markPlayed, hide, details
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: Episode
    let isPlaying: Bool
    let isDownloaded: Bool
    var isDownloading: Bool = false
    var isHidden: Bool = false
    var isInQueue: Bool = false
    var onDownloadTap: () -> Void = {}
    var onMenuAction: (EpisodeMenuAction) -> Void = { _ in }
    var onTap: () -> Void = {}
    /// Episode lens: show an always-visible add/remove-from-queue button.
    var showQueueButton: Bool = false
    /// Leading (swipe-from-left) action. nil = no leading swipe (preserves call sites that don't opt in).
    var swipeLeading: EpisodeSwipeAction? = nil
    /// Trailing (swipe-from-right) action. nil = no trailing swipe.
    var swipeTrailing: EpisodeSwipeAction? = nil

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                artwork

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.subheadline.bold())
                        .foregroundColor(titleColor)
                        .lineLimit(2)

                    metadataBadges

                    listenProgressBar
                }

                Spacer()

                downloadButton

                if showQueueButton {
                    queueButton
                }

                menuButton

                // Playing indicator
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.accentColor)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        // MARK: VoiceOver Accessibility
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EpisodeAccessibility.episodeLabel(
            title: episode.title,
            podcastTitle: episode.podcastTitle,
            pubDate: episode.pubDate,
            durationSeconds: episode.durationSeconds,
            listenedSeconds: episode.listenedSeconds,
            isPlayed: episode.isPlayed,
            isPlaying: isPlaying,
            isDownloaded: isDownloaded,
            isHidden: isHidden,
            isInQueue: isInQueue
        ))
        .accessibilityHint(EpisodeAccessibility.episodeHint())
        .accessibilityAddTraits(isPlaying ? [.isSelected, .startsMediaSession] : .startsMediaSession)
        .accessibilityAction(named: "Play") { onMenuAction(.play) }
        .accessibilityAction(named: "Play Next") { onMenuAction(.playNext) }
        .accessibilityAction(named: isInQueue ? "Remove from Queue" : "Add to Queue") {
            onMenuAction(isInQueue ? .removeFromQueue : .addToQueue)
        }
        .accessibilityAction(named: isDownloaded ? "Remove Download" : "Download") { onMenuAction(.download) }
        .accessibilityAction(named: episode.isPlayed ? "Mark as Unplayed" : "Mark as Played") { onMenuAction(.markPlayed) }
        .accessibilityAction(named: isHidden ? "Unhide" : "Hide") { onMenuAction(.hide) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let swipeLeading { swipeButton(swipeLeading) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let swipeTrailing { swipeButton(swipeTrailing) }
        }
    }

    // MARK: - Sub-views
    // EpisodeRow.body was a single large expression that Swift 6.4 (Xcode 27) could
    // not type-check in reasonable time. Splitting it into these sub-views keeps each
    // expression small enough to compile. No behavior change.

    private var titleColor: Color {
        if episode.isPlayed { return .secondary }
        return isPlaying ? .accentColor : .primary
    }

    @ViewBuilder
    private var artwork: some View {
        let imageUrl = episode.imageUrl ?? episode.podcast?.logoUrl
        ZStack(alignment: .bottomTrailing) {
            CachedAsyncImage(url: URL(string: imageUrl ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Played badge
            if episode.isPlayed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.green)
                    .background(Circle().fill(.white).padding(-1))
                    .offset(x: 4, y: 4)
            }
        }
    }

    @ViewBuilder
    private var metadataBadges: some View {
        HStack(spacing: 8) {
            // Season/Episode label
            if let seasonNum = episode.seasonNumber {
                let epNum = episode.episodeNumber.map { Int($0) }
                let label = episode.episodeDisplay
                    ?? (epNum != nil ? "S\(seasonNum)E\(epNum!)" : "S\(seasonNum)")
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.indigo)
            } else if let epNum = episode.episodeNumber {
                Text(episode.episodeDisplay ?? "Ep \(Int(epNum))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.indigo)
            }

            // Episode type badge
            if let type = episode.episodeType, type != "full" {
                Text(type.capitalized)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(type == "trailer" ? Color.orange.opacity(0.15) : Color.purple.opacity(0.15))
                    .foregroundStyle(type == "trailer" ? .orange : .purple)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // Explicit badge
            if episode.explicit == true {
                Text(String(localized: "badge.explicit.short",
                            defaultValue: "E",
                            comment: "One- or two-character badge marking explicit content, shown in a small red pill beside a title. Keep it as short as possible — the pill does not grow. English uses 'E'; use whatever short form your language's store convention uses."))
                    .font(.system(size: 8, weight: .black))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }

            // In Queue badge
            if isInQueue {
                HStack(spacing: 2) {
                    Image(systemName: "text.line.first.and.arrowforward")
                        .font(.system(size: 8))
                    Text("Queued")
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            if let pubDate = episode.pubDate {
                Text(pubDate, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            durationLabel
        }
    }

    @ViewBuilder
    private var durationLabel: some View {
        if let duration = episode.durationSeconds {
            if episode.listenedSeconds > 0 && !episode.isPlayed {
                // Show remaining time
                let remaining = max(0, duration - episode.listenedSeconds)
                Text(DurationFormatting.remaining(TimeInterval(remaining)))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text(PlayerManager.formatDuration(TimeInterval(duration)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var listenProgressBar: some View {
        // Listen progress bar for in-progress episodes
        if episode.listenedSeconds > 0 && !episode.isPlayed {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 3)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * episode.listenProgress), height: 3)
                }
            }
            .frame(height: 3)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        Button(action: onDownloadTap) {
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                let downloadIcon = isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle"
                let downloadColor: Color = isDownloaded ? .green : .secondary
                Image(systemName: downloadIcon)
                    .font(.body)
                    .foregroundColor(downloadColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDownloading)
    }

    @ViewBuilder
    private var queueButton: some View {
        Button {
            onMenuAction(isInQueue ? .removeFromQueue : .addToQueue)
        } label: {
            Image(systemName: isInQueue ? "checkmark.circle.fill" : "plus.circle")
                .font(.title3)
                .foregroundColor(isInQueue ? .green : .accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isInQueue ? "Remove from Queue" : "Add to Queue")
    }

    @ViewBuilder
    private func swipeButton(_ action: EpisodeSwipeAction) -> some View {
        // State-aware label/tint for toggles; static otherwise.
        // Computed via an immediately-invoked plain closure (not @ViewBuilder) so this
        // switch is ordinary control flow — inline inside the @ViewBuilder function body,
        // an assignment-only switch case gets misinterpreted as a view-building expression.
        let (title, icon): (String, String) = {
            switch action {
            case .markPlayed:
                return (episode.isPlayed ? "Unplayed" : "Played", episode.isPlayed ? "circle" : "checkmark.circle")
            case .hide:
                return (isHidden ? "Unhide" : "Hide", isHidden ? "eye" : "eye.slash")
            default:
                return (action.displayName, action.systemImage)
            }
        }()
        Button {
            onMenuAction(action.menuAction)
        } label: {
            Label(title, systemImage: icon)
        }
        .tint(swipeTint(action))
    }

    private func swipeTint(_ action: EpisodeSwipeAction) -> Color {
        switch action {
        case .addToQueue, .playNext, .playNow: return .accentColor
        case .markPlayed:                      return .green
        case .hide:                            return .gray
        }
    }

    @ViewBuilder
    private var menuButton: some View {
        Menu {
            Button { onMenuAction(.play) } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button { onMenuAction(.playNext) } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            if isInQueue {
                Button { onMenuAction(.removeFromQueue) } label: {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
            } else {
                Button { onMenuAction(.addToQueue) } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
            }
            Divider()
            Button { onMenuAction(.download) } label: {
                Label(
                    isDownloaded ? "Remove Download" : "Download",
                    systemImage: isDownloaded ? "trash" : "arrow.down.circle"
                )
            }
            Button { onMenuAction(.markPlayed) } label: {
                Label(
                    episode.isPlayed ? "Mark as Unplayed" : "Mark as Played",
                    systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
                )
            }
            Divider()
            Button { onMenuAction(.details) } label: {
                Label("Details", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
        }
    }
}
