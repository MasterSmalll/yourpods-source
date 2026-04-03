import SwiftUI

/// Episode list for a specific podcast. Port of episode_list_screen.dart.
struct PodcastDetailView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settingsManager
    let podcast: Podcast
    
    @State private var showSettings = false
    @State private var isRefreshing = false
    @State private var selectedEpisode: Episode?
    @State private var showMarkAllConfirmation = false
    @State private var episodeToDeleteDownload: Episode?
    @State private var isDescriptionExpanded = false
    @AppStorage("skipDeleteDownloadConfirmation") private var skipDeleteConfirmation = false
    
    private var allEpisodes: [Episode] {
        podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }
    
    private var visibleEpisodes: [Episode] {
        if settingsManager.hidePlayedEpisodes {
            return allEpisodes.filter { !$0.isPlayed }
        }
        return allEpisodes
    }
    
    private var playedCount: Int {
        allEpisodes.filter { $0.isPlayed }.count
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
                        AsyncImage(url: URL(string: podcast.logoUrl ?? "")) { image in
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
                            Text("by \(publisher)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 6) {
                            Text("\(allEpisodes.count) episodes")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            if playedCount > 0 {
                                Text("·")
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
            Section("\(visibleEpisodes.count) Episodes") {
                ForEach(visibleEpisodes) { episode in
                    EpisodeRow(
                        episode: episode,
                        isPlaying: episode.guid == playerManager.currentEpisodeGuid,
                        isDownloaded: downloadManager.isDownloaded(episode.guid),
                        isDownloading: downloadManager.activeDownloads[episode.guid] != nil,
                        onDownloadTap: { downloadAction(episode) },
                        onMenuAction: { action in handleMenuAction(action, episode: episode) },
                        onTap: { selectedEpisode = episode }
                    )
                    .contextMenu {
                        Button { handleMenuAction(.play, episode: episode) } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        Button { handleMenuAction(.playNext, episode: episode) } label: {
                            Label("Play Next", systemImage: "text.insert")
                        }
                        Button { handleMenuAction(.addToQueue, episode: episode) } label: {
                            Label("Add to Queue", systemImage: "text.append")
                        }
                        Divider()
                        Button { handleMenuAction(.download, episode: episode) } label: {
                            Label(
                                downloadManager.isDownloaded(episode.guid) ? "Remove Download" : "Download",
                                systemImage: downloadManager.isDownloaded(episode.guid) ? "trash" : "arrow.down.circle"
                            )
                        }
                        Button { handleMenuAction(.markPlayed, episode: episode) } label: {
                            Label(
                                episode.isPlayed ? "Mark as Unplayed" : "Mark as Played",
                                systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
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
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .refreshable {
            _ = try? await podcastManager.refreshFeed(for: podcast)
        }
        .sheet(isPresented: $showSettings) {
            PodcastSettingsSheet(podcast: podcast)
        }
        .sheet(item: $selectedEpisode) { episode in
            EpisodeDetailSheet(episode: episode)
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
            downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl, authHeaders: authHeaders)
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
        case .download:
            downloadAction(episode)
        case .markPlayed:
            if let podcastUrl = episode.podcastUrl {
                if episode.isPlayed {
                    podcastManager.markEpisodeAsUnplayed(podcastUrl: podcastUrl, episodeGuid: episode.guid)
                } else {
                    podcastManager.markEpisodeAsPlayed(podcastUrl: podcastUrl, episodeGuid: episode.guid)
                }
            }
        case .details:
            selectedEpisode = episode
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
                    Text("🅴")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
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
                    Label("Complete", systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                
                if podcast.showType == "serial" {
                    Label("Serial", systemImage: "list.number")
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
                    Label("Watch", systemImage: "arrow.up.right")
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
    case play, playNext, addToQueue, download, markPlayed, details
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: Episode
    let isPlaying: Bool
    let isDownloaded: Bool
    var isDownloading: Bool = false
    var onDownloadTap: () -> Void = {}
    var onMenuAction: (EpisodeMenuAction) -> Void = { _ in }
    var onTap: () -> Void = {}
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Episode-specific artwork
                let imageUrl = episode.imageUrl ?? episode.podcast?.logoUrl
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: URL(string: imageUrl ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                                .overlay {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
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
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.subheadline.bold())
                        .foregroundColor(episode.isPlayed ? .secondary : (isPlaying ? .accentColor : .primary))
                        .lineLimit(2)
                    
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
                            Text("E")
                                .font(.system(size: 8, weight: .black))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.12))
                                .foregroundStyle(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        
                        if let pubDate = episode.pubDate {
                            Text(pubDate, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        if let duration = episode.durationSeconds {
                            if episode.listenedSeconds > 0 && !episode.isPlayed {
                                // Show remaining time
                                let remaining = max(0, duration - episode.listenedSeconds)
                                Text("\(PlayerManager.formatDuration(TimeInterval(remaining))) left")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text(PlayerManager.formatDuration(TimeInterval(duration)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
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
                
                Spacer()
                
                // Download button
                Button(action: onDownloadTap) {
                    if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isDownloaded
                            ? "arrow.down.circle.fill"
                            : "arrow.down.circle"
                        )
                        .font(.body)
                        .foregroundColor(isDownloaded ? .green : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
                
                // Menu button
                Menu {
                    Button { onMenuAction(.play) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { onMenuAction(.playNext) } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    Button { onMenuAction(.addToQueue) } label: {
                        Label("Add to Queue", systemImage: "text.append")
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
    }
}
