import SwiftUI

/// Detail sheet shown when tapping an episode. Displays artwork, description, and action buttons.
struct EpisodeDetailSheet: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    
    let episode: Episode
    
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var showChapters = false
    @State private var showTranscript = false
    @State private var chapters: [Chapter]
    @State private var transcript: Transcript?
    
    init(episode: Episode) {
        self.episode = episode
        // Pre-populate chapters synchronously from description if no chapters URL
        if let desc = episode.episodeDescription, (episode.chaptersUrl ?? "").isEmpty {
            _chapters = State(initialValue: ChapterService.parseChaptersFromDescription(desc))
        } else {
            _chapters = State(initialValue: [])
        }
    }
    
    private var isCurrentlyPlaying: Bool {
        episode.guid == playerManager.currentEpisodeGuid
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Episode Artwork
                    artworkSection
                    
                    // Title & metadata
                    metadataSection
                    
                    // Playback scrubber (if this is the playing episode)
                    if isCurrentlyPlaying {
                        playbackSection
                    } else if episode.listenedSeconds > 0 {
                        // Static progress for non-playing episode
                        staticProgressSection
                    }
                    
                    Divider()
                    
                    // Action buttons
                    actionButtonsSection
                    
                    // Chapters & Transcript buttons (appears when data is loaded by .task)
                    chaptersTranscriptSection
                    
                    Divider()
                    
                    // Episode description
                    descriptionSection
                }
                .padding()
            }
            .task {
                // Fetch URL-based chapters (overrides description-parsed ones if available)
                if let chaptersUrl = episode.chaptersUrl, !chaptersUrl.isEmpty {
                    let fetched = await ChapterService.shared.fetchChapters(url: chaptersUrl)
                    if !fetched.isEmpty {
                        chapters = fetched
                    }
                }
                if let transcriptUrl = episode.transcriptUrl, !transcriptUrl.isEmpty {
                    transcript = await TranscriptService.shared.fetchTranscript(url: transcriptUrl)
                }
            }
            .navigationTitle("Episode Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showChapters) {
                ChapterListSheet(
                    chapters: chapters,
                    currentPosition: isCurrentlyPlaying ? playerManager.currentPosition : TimeInterval(episode.listenedSeconds)
                ) { chapter in
                    if isCurrentlyPlaying {
                        playerManager.seek(to: chapter.startTime)
                    }
                }
            }
            .sheet(isPresented: $showTranscript) {
                if let transcript {
                    TranscriptListSheet(
                        transcript: transcript,
                        currentPosition: isCurrentlyPlaying ? playerManager.currentPosition : TimeInterval(episode.listenedSeconds)
                    ) { item in
                        if isCurrentlyPlaying {
                            playerManager.seek(to: item.start)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Playback Section (live seek bar)
    
    private var playbackSection: some View {
        VStack(spacing: 8) {
            // Seek slider
            Slider(
                value: Binding(
                    get: {
                        if isDragging { return dragValue }
                        guard playerManager.currentDuration > 0 else { return 0 }
                        return playerManager.currentPosition / playerManager.currentDuration
                    },
                    set: { newValue in
                        isDragging = true
                        dragValue = newValue
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing {
                        // Drag ended — seek to position
                        let seekTime = dragValue * playerManager.currentDuration
                        playerManager.seek(to: seekTime)
                        isDragging = false
                    }
                }
            )
            .tint(.accentColor)
            
            // Time labels
            HStack {
                let displayPosition = isDragging
                    ? dragValue * playerManager.currentDuration
                    : playerManager.currentPosition
                let remaining = playerManager.currentDuration - displayPosition
                
                Text(PlayerManager.formatDuration(displayPosition))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("-\(PlayerManager.formatDuration(max(0, remaining)))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            // Playback controls
            HStack(spacing: 32) {
                Button {
                    playerManager.seekRelative(seconds: -Double(settings.skipBackwardSeconds))
                } label: {
                    Image(systemName: "gobackward.\(settings.skipBackwardSeconds)")
                        .font(.title2)
                }
                
                Button { playerManager.togglePlayPause() } label: {
                    Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                }
                
                Button {
                    playerManager.seekRelative(seconds: Double(settings.skipForwardSeconds))
                } label: {
                    Image(systemName: "goforward.\(settings.skipForwardSeconds)")
                        .font(.title2)
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
    }
    
    // MARK: - Static Progress (for non-playing but partially listened)
    
    private var staticProgressSection: some View {
        VStack(spacing: 4) {
            ProgressView(value: episode.listenProgress)
                .tint(.accentColor)
            
            HStack {
                Text(PlayerManager.formatDuration(TimeInterval(episode.listenedSeconds)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let total = episode.durationSeconds {
                    let remaining = max(0, total - episode.listenedSeconds)
                    Text("-\(PlayerManager.formatDuration(TimeInterval(remaining)))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
    }
    
    // MARK: - Artwork
    
    private var artworkSection: some View {
        let imageUrl = episode.imageUrl ?? episode.podcast?.logoUrl
        return AsyncImage(url: URL(string: imageUrl ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fit)
            default:
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(maxWidth: 280, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 12)
    }
    
    // MARK: - Metadata
    
    private var metadataSection: some View {
        VStack(spacing: 8) {
            Text(episode.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            
            if let podcastTitle = episode.podcastTitle {
                Text(podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 16) {
                if let pubDate = episode.pubDate {
                    Label(pubDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let duration = episode.durationSeconds {
                    Label(PlayerManager.formatDuration(TimeInterval(duration)), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Action Buttons
    
    private var actionButtonsSection: some View {
        let isCurrentlyPlaying = episode.guid == playerManager.currentEpisodeGuid
        let isDownloaded = downloadManager.isDownloaded(episode.guid)
        
        return VStack(spacing: 12) {
            // Primary play button
            if episode.isPlayed {
                // Replay: reset progress and play from start
                Button {
                    if let podcastUrl = episode.podcastUrl {
                        podcastManager.markEpisodeAsUnplayed(podcastUrl: podcastUrl, episodeGuid: episode.guid)
                    }
                    playerManager.playEpisode(episode, position: 0)
                    dismiss()
                } label: {
                    Label("Replay Episode", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Button {
                    playerManager.playEpisode(episode)
                    dismiss()
                } label: {
                    Label(
                        isCurrentlyPlaying ? "Now Playing" : "Play Episode",
                        systemImage: isCurrentlyPlaying ? "speaker.wave.2.fill" : "play.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isCurrentlyPlaying)
            }
            
            // Secondary actions row
            HStack(spacing: 12) {
                ActionButton(title: "Play Next", icon: "text.insert") {
                    playerManager.addToQueue(episode, playNext: true)
                    dismiss()
                }
                
                ActionButton(title: "Queue", icon: "text.append") {
                    playerManager.addToQueue(episode)
                    dismiss()
                }
                
                ActionButton(
                    title: isDownloaded ? "Downloaded" : "Download",
                    icon: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle"
                ) {
                    if isDownloaded {
                        downloadManager.deleteDownload(guid: episode.guid)
                    } else if let audioUrl = episode.audioUrl {
                        Task {
                            try? await downloadManager.downloadEpisode(guid: episode.guid, audioUrl: audioUrl)
                        }
                    }
                }
                
                ActionButton(title: "Played", icon: "checkmark") {
                    if let podcastUrl = episode.podcastUrl {
                        podcastManager.markEpisodeAsPlayed(podcastUrl: podcastUrl, episodeGuid: episode.guid)
                    }
                    dismiss()
                }
            }
        }
    }
    
    // MARK: - Chapters & Transcript
    
    private var chaptersTranscriptSection: some View {
        HStack(spacing: 12) {
            if !chapters.isEmpty {
                ActionButton(title: "Chapters", icon: "book.pages") {
                    showChapters = true
                }
            }
            if let transcript, !transcript.items.isEmpty {
                ActionButton(title: "Transcript", icon: "text.quote") {
                    showTranscript = true
                }
            }
        }
    }
    
    // MARK: - Description
    
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About This Episode")
                .font(.headline)
            
            if let description = episode.episodeDescription {
                Text(description.htmlAttributedString())
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("No description available.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reusable Action Button

private struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .foregroundStyle(.primary)
    }
}
