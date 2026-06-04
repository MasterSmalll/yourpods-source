import SwiftUI

/// Persistent mini-player bar shown at the bottom of the screen.
/// Clean layout: artwork | title (+ chapter) | skip-back | play/pause | skip-fwd | ⋯ menu
/// Tapping artwork or title opens the episode detail view.
struct NowPlayingBar: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settings
    @Environment(SleepTimerManager.self) private var sleepTimer
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext
    @State private var showFullPlayer = false
    @State private var episodeSheetItem: EpisodeSheetItem?
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    @State private var showChapters = false
    @State private var showTranscript = false

    @State private var isDraggingSeekBar = false
    @State private var dragProgress: Double = 0
    @State private var chapters: [Chapter] = []
    @State private var transcript: Transcript?
    
    /// Resolve the current Episode model from the QueueItem GUID.
    /// Searches subscriptions first, then falls back to creating a transient
    /// Episode from the QueueItem's data so the full detail sheet can be shown
    /// even for episodes added from search without subscribing to the podcast.
    private var currentEpisode: Episode? {
        guard let guid = playerManager.currentEpisodeGuid else { return nil }
        return EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: guid,
            subscriptions: podcastManager.subscriptions,
            fallbackQueueItem: playerManager.audioManager.currentItem
        )
    }
    
    /// Current chapter based on playback position.
    private var currentChapter: Chapter? {
        guard !chapters.isEmpty else { return nil }
        let pos = playerManager.currentPosition
        return chapters.last(where: { $0.startTime <= pos })
    }
    
    var body: some View {
        if let item = playerManager.audioManager.currentItem {
            VStack(spacing: 0) {
                // Interactive seek bar
                GeometryReader { geo in
                    let currentProgress = PlayerManager.playbackProgress(
                        position: playerManager.currentPosition,
                        duration: playerManager.currentDuration
                    )
                    let displayProgress = isDraggingSeekBar ? dragProgress : currentProgress
                    
                    ZStack(alignment: .leading) {
                        // Track
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                        // Fill
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * displayProgress)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingSeekBar = true
                                dragProgress = min(1, max(0, value.location.x / geo.size.width))
                            }
                            .onEnded { value in
                                let pct = min(1, max(0, value.location.x / geo.size.width))
                                let seekTime = pct * playerManager.currentDuration
                                playerManager.seek(to: seekTime)
                                isDraggingSeekBar = false
                            }
                    )
                }
                .frame(height: isDraggingSeekBar ? 6 : 3)
                .animation(.easeInOut(duration: 0.15), value: isDraggingSeekBar)
                .accessibilityElement()
                .accessibilityLabel("Playback progress")
                .accessibilityValue({
                    let pos = Int(playerManager.currentPosition)
                    let dur = Int(playerManager.currentDuration)
                    guard dur > 0 else { return "" }
                    return "\(EpisodeAccessibility.spokenDuration(pos)) of \(EpisodeAccessibility.spokenDuration(dur))"
                }())
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        playerManager.seekRelative(seconds: 15)
                    case .decrement:
                        playerManager.seekRelative(seconds: -15)
                    @unknown default:
                        break
                    }
                }
                
                // Time labels (always visible)
                HStack {
                    if isDraggingSeekBar {
                        Text(PlayerManager.formatTimestamp(dragProgress * playerManager.currentDuration))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(PlayerManager.formatTimestamp(playerManager.currentPosition))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDraggingSeekBar {
                        Text("-\(PlayerManager.formatTimestamp((1 - dragProgress) * playerManager.currentDuration))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("-\(PlayerManager.formatTimestamp(max(0, playerManager.currentDuration - playerManager.currentPosition)))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 1)
                
                // Main row: artwork + title + controls + overflow menu
                HStack(spacing: 10) {
                    // Artwork (tapping opens episode details)
                    CachedAsyncImage(url: URL(string: item.artworkUrl ?? "")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        if let ep = currentEpisode {
                            episodeSheetItem = EpisodeSheetItem(episode: ep)
                        } else {
                            showFullPlayer = true
                        }
                    }
                    .contextMenu {
                        if let ep = currentEpisode {
                            Button {
                                episodeSheetItem = EpisodeSheetItem(episode: ep)
                            } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                        }
                    }
                    
                    // Title + podcast + chapter (tapping opens episode details)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(item.podcastTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // Chapter indicator
                        if let chapter = currentChapter {
                            Button {
                                if !chapters.isEmpty {
                                    showChapters = true
                                }
                            } label: {
                                Text(chapter.title)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onTapGesture {
                        if let ep = currentEpisode {
                            episodeSheetItem = EpisodeSheetItem(episode: ep)
                        } else {
                            showFullPlayer = true
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(EpisodeAccessibility.nowPlayingLabel(
                        title: item.title,
                        podcastTitle: item.podcastTitle,
                        isPlaying: playerManager.isPlaying
                    ))
                    .accessibilityHint("Double tap, to show episode details")
                    
                    Spacer()
                    
                    // Playback controls — increased sizes
                    HStack(spacing: 18) {
                        // Skip back
                        Button {
                            playerManager.seekRelative(seconds: -Double(settings.skipBackwardSeconds))
                        } label: {
                            Image(systemName: "gobackward.\(settings.skipBackwardSeconds)")
                                .font(.body)
                        }
                        .accessibilityLabel("Skip back \(settings.skipBackwardSeconds) seconds")
                        
                        // Play/Pause (or Retry on error)
                        if let errorMsg = playerManager.errorMessage, !errorMsg.isEmpty {
                            Button {
                                // Retry: re-run playEpisode from scratch with fresh URL
                                if let item = playerManager.audioManager.currentItem {
                                    Task {
                                        await playerManager.audioManager.playEpisode(
                                            item,
                                            initialPosition: playerManager.currentPosition > 0 ? playerManager.currentPosition : nil
                                        )
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.orange)
                                    .symbolEffect(.pulse)
                            }
                            .accessibilityLabel("Retry playback")
                        } else {
                            Button { playerManager.togglePlayPause() } label: {
                                if playerManager.isBuffering {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.title2)
                                }
                            }
                            .accessibilityLabel(playerManager.isBuffering ? "Loading" : (playerManager.isPlaying ? "Pause" : "Play"))
                        }
                        
                        // Skip forward
                        Button {
                            playerManager.seekRelative(seconds: Double(settings.skipForwardSeconds))
                        } label: {
                            Image(systemName: "goforward.\(settings.skipForwardSeconds)")
                                .font(.body)
                        }
                        .accessibilityLabel("Skip forward \(settings.skipForwardSeconds) seconds")
                    }
                    .foregroundStyle(.primary)
                    
                    // Overflow menu (replaces secondary controls row)
                    overflowMenu
                }
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .padding(.top, 8)
                .padding(.bottom, (!chapters.isEmpty || hasTranscript) ? 4 : 8)
                
                // Chapters & Transcript quick-access row
                if !chapters.isEmpty || hasTranscript {
                    HStack(spacing: 8) {
                        if !chapters.isEmpty {
                            Button {
                                showChapters = true
                            } label: {
                                Label("Chapters (\(chapters.count))", systemImage: "list.bullet.indent")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                        
                        if hasTranscript {
                            Button {
                                showTranscript = true
                            } label: {
                                Label("Transcript", systemImage: "text.quote")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            }
            .background(.ultraThinMaterial)
            // Episode detail sheet (mini player tap)
            .sheet(item: $episodeSheetItem) { item in
                EpisodeDetailSheet(episode: item.episode)
                    .environment(playerManager)
                    .environment(podcastManager)
                    .environment(downloadManager)
                    .environment(settings)
                    .environment(navigationState)
                    .modelContext(modelContext)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showFullPlayer) {
                PlayerView()
                    .environment(playerManager)
                    .environment(settings)
            }
            #else
            .sheet(isPresented: $showFullPlayer) {
                PlayerView()
                    .environment(playerManager)
                    .environment(settings)
            }
            #endif
            .sheet(isPresented: $showSpeedPicker) {
                SpeedPickerSheet()
                    .environment(settings)
                    .environment(playerManager)
                    .presentationDetents([.height(200)])
            }
            .sheet(isPresented: $showSleepTimer) {
                SleepTimerSheet()
                    .environment(sleepTimer)
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showChapters) {
                ChapterListSheet(chapters: chapters, currentPosition: playerManager.currentPosition) { chapter in
                    playerManager.seek(to: chapter.startTime)
                    showChapters = false
                }
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
            }
            .sheet(isPresented: $showTranscript) {
                if let transcript {
                    TranscriptListSheet(
                        transcript: transcript,
                        currentPosition: playerManager.currentPosition
                    ) { item in
                        playerManager.seek(to: item.start)
                        showTranscript = false
                    }
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
                }
            }
            .task(id: playerManager.currentEpisodeGuid) {
                await loadChapters()
                await loadTranscript()
            }
        }
    }
    
    // MARK: - Overflow Menu
    
    private var overflowMenu: some View {
        Menu {
            // Speed
            Button {
                showSpeedPicker = true
            } label: {
                Label("Speed: \(settings.playbackSpeed, specifier: "%.1f")×", systemImage: "gauge.with.needle")
            }
            
            // Trim Silence
            Button {
                playerManager.audioManager.skipSilenceEnabled.toggle()
            } label: {
                if playerManager.audioManager.skipSilenceEnabled {
                    Label("Trim Silence: On", systemImage: "waveform.path")
                } else {
                    Label("Trim Silence: Off", systemImage: "waveform.path")
                }
            }
            
            // Sleep Timer
            Button {
                showSleepTimer = true
            } label: {
                if sleepTimer.stopAfterCurrentEpisode {
                    Label("Sleep: DriftOff Mode", systemImage: "moon.zzz.fill")
                } else if sleepTimer.isActive {
                    Label("Sleep: \(sleepTimer.formattedRemaining)", systemImage: "moon.zzz.fill")
                } else {
                    Label("Sleep Timer", systemImage: "moon.zzz")
                }
            }
            
            Divider()
            
            // Chapters (if available)
            if !chapters.isEmpty {
                Button {
                    showChapters = true
                } label: {
                    Label("Chapters (\(chapters.count))", systemImage: "list.bullet.indent")
                }
            }
            
            // Episode Details
            if let ep = currentEpisode {
                Button {
                    episodeSheetItem = EpisodeSheetItem(episode: ep)
                } label: {
                    Label("Episode Details", systemImage: "info.circle")
                }
            }
            
            // Mark as Played
            Button(role: .destructive) {
                playerManager.markCurrentEpisodeAsPlayed()
            } label: {
                Label("Mark as Played", systemImage: "checkmark.circle")
            }
            
            Divider()
            
            // Share sub-menu
            if let item = playerManager.audioManager.currentItem {
                Menu {
                    Button {
                        SharePresenter.present(items: ShareService.shareEpisode(
                            title: item.title,
                            podcastTitle: item.podcastTitle,
                            link: currentEpisode?.link,
                            audioUrl: item.audioUrl
                        ))
                    } label: {
                        Label("Share Episode", systemImage: "waveform")
                    }
                    
                    Button {
                        SharePresenter.present(items: ShareService.sharePodcast(
                            title: item.podcastTitle,
                            website: currentEpisode?.podcast?.website,
                            feedUrl: item.podcastUrl
                        ))
                    } label: {
                        Label("Share Podcast", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    
                    Button {
                        SharePresenter.present(items: ShareService.sharePosition(
                            episodeTitle: item.title,
                            podcastTitle: item.podcastTitle,
                            position: playerManager.currentPosition,
                            link: currentEpisode?.link,
                            audioUrl: item.audioUrl
                        ))
                    } label: {
                        Label("Share Position", systemImage: "clock")
                    }
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.bold())
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
    }
    
    /// Whether the current episode has a transcript available.
    private var hasTranscript: Bool {
        transcript != nil && !(transcript?.items.isEmpty ?? true)
    }
    
    // MARK: - Chapter Loading
    
    private func loadChapters() async {
        chapters = []
        guard let item = playerManager.audioManager.currentItem else { return }
        chapters = await ChapterService.shared.fetchAllChapters(
            chaptersUrl: item.chaptersUrl,
            chaptersJSON: item.chaptersJSON,
            description: item.episodeDescription
        )
    }
    
    // MARK: - Transcript Loading
    
    private func loadTranscript() async {
        transcript = nil
        guard let item = playerManager.audioManager.currentItem,
              let transcriptUrl = item.transcriptUrl,
              !transcriptUrl.isEmpty else { return }
        transcript = await TranscriptService.shared.fetchTranscript(url: transcriptUrl)
    }
}

// MARK: - Speed Picker (Mini Player version)

private struct SpeedPickerSheet: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerManager.self) private var playerManager
    
    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    
    var body: some View {
        VStack {
            Text("Playback Speed")
                .font(.headline)
                .padding(.top)
            
            let columns = Array(repeating: GridItem(.flexible()), count: 4)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(speeds, id: \.self) { speed in
                    let isSelected = settings.playbackSpeed == speed
                    Button {
                        playerManager.setPlaybackRate(Float(speed))
                    } label: {
                        Text("\(speed, specifier: "%.2g")×")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
                            .foregroundColor(isSelected ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding()
        }
    }
}
