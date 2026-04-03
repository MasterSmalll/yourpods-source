import SwiftUI

/// Persistent mini-player bar shown at the bottom of the screen.
/// Clean layout: artwork | title (+ chapter) | skip-back | play/pause | skip-fwd | ⋯ menu
/// Tapping artwork or title opens the episode detail view.
struct NowPlayingBar: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settings
    @Environment(SleepTimerManager.self) private var sleepTimer
    @State private var showFullPlayer = false
    @State private var selectedEpisodeForDetail: Episode?
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    @State private var showChapters = false

    @State private var isDraggingSeekBar = false
    @State private var dragProgress: Double = 0
    @State private var chapters: [Chapter] = []
    
    /// Resolve the current Episode model from the QueueItem GUID.
    private var currentEpisode: Episode? {
        guard let guid = playerManager.currentEpisodeGuid else { return nil }
        for podcast in podcastManager.subscriptions {
            if let ep = podcast.episodes.first(where: { $0.guid == guid }) {
                return ep
            }
        }
        return nil
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
                    let currentProgress = playerManager.currentDuration > 0
                        ? playerManager.currentPosition / playerManager.currentDuration
                        : 0
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
                    AsyncImage(url: URL(string: item.artworkUrl ?? "")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        if let ep = currentEpisode {
                            selectedEpisodeForDetail = ep
                        } else {
                            showFullPlayer = true
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
                            selectedEpisodeForDetail = ep
                        } else {
                            showFullPlayer = true
                        }
                    }
                    
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
                        
                        // Play/Pause
                        Button { playerManager.togglePlayPause() } label: {
                            if playerManager.isBuffering {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                            }
                        }
                        
                        // Skip forward
                        Button {
                            playerManager.seekRelative(seconds: Double(settings.skipForwardSeconds))
                        } label: {
                            Image(systemName: "goforward.\(settings.skipForwardSeconds)")
                                .font(.body)
                        }
                    }
                    .foregroundStyle(.primary)
                    
                    // Overflow menu (replaces secondary controls row)
                    overflowMenu
                }
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            // Episode detail sheet (mini player tap)
            .sheet(item: $selectedEpisodeForDetail) { episode in
                EpisodeDetailSheet(episode: episode)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showFullPlayer) {
                PlayerView()
            }
            #else
            .sheet(isPresented: $showFullPlayer) {
                PlayerView()
            }
            #endif
            .sheet(isPresented: $showSpeedPicker) {
                SpeedPickerSheet()
                    .presentationDetents([.height(200)])
            }
            .sheet(isPresented: $showSleepTimer) {
                SleepTimerSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showChapters) {
                ChapterListSheet(chapters: chapters, currentPosition: playerManager.currentPosition) { chapter in
                    playerManager.seek(to: chapter.startTime)
                    showChapters = false
                }
                .presentationDetents([.medium, .large])
            }

            .task(id: playerManager.currentEpisodeGuid) {
                await loadChapters()
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
                    Label("Sleep: End of Episode", systemImage: "moon.zzz.fill")
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
                    selectedEpisodeForDetail = ep
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
