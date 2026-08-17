import SwiftUI

/// Full-screen Now Playing view with artwork, progress, and controls.
/// Port of player_screen.dart.
struct PlayerView: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settings
    @Environment(ChapterCoordinator.self) private var chapterCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var showSpeedPicker = false
    @State private var showChapters = false
    @State private var showTranscript = false
    @State private var transcript: Transcript?
    @State private var showAddNote = false
    
    var item: QueueItem? { playerManager.audioManager.currentItem }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let item {
                    mainArtwork

                    Spacer()
                    
                    // Title & Podcast
                    VStack(spacing: 8) {
                        Text(item.title)
                            .font(.title3.bold())
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        
                        HStack(spacing: 6) {
                            Text(item.podcastTitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            if item.privacyMode {
                                Image(systemName: "shield.checkered")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("P3 Privacy Preserving Playback is active")
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    Spacer()
                    
                    // Progress bar
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { isSeeking ? seekPosition : playerManager.currentPosition },
                                set: { newValue in
                                    isSeeking = true
                                    seekPosition = newValue
                                }
                            ),
                            in: 0...max(playerManager.currentDuration, 1),
                            onEditingChanged: { editing in
                                if !editing {
                                    playerManager.seek(to: seekPosition)
                                    isSeeking = false
                                }
                            }
                        )
                        .tint(.accentColor)
                        .accessibilityLabel("Seek position")
                        .accessibilityValue(EpisodeAccessibility.progressValue(
                            position: Int(isSeeking ? seekPosition : playerManager.currentPosition),
                            duration: Int(playerManager.currentDuration)
                        ))
                        
                        HStack {
                            Text(formatTime(isSeeking ? seekPosition : playerManager.currentPosition))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            Text(DurationFormatting.remainingTimestamp(max(0, playerManager.currentDuration - (isSeeking ? seekPosition : playerManager.currentPosition))))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    // Playback error banner
                    PlaybackErrorBanner(errorMessage: playerManager.errorMessage) {
                        if let item = playerManager.audioManager.currentItem {
                            Task {
                                await playerManager.audioManager.playEpisode(
                                    item,
                                    initialPosition: playerManager.currentPosition > 0 ? playerManager.currentPosition : nil
                                )
                            }
                        }
                    }
                    
                    // Controls
                    HStack(spacing: 40) {
                        Button { playerManager.skipToPrevious() } label: {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                        }
                        .accessibilityLabel("Restart Episode")
                        
                        Button { playerManager.seekRelative(seconds: -Double(settings.skipBackwardSeconds)) } label: {
                            Image(systemName: "gobackward.\(settings.skipBackwardSeconds)")
                                .font(.title2)
                        }
                        .accessibilityLabel("Skip back \(settings.skipBackwardSeconds) seconds")
                        
                        // Play/Pause (or Retry on error)
                        if let errorMsg = playerManager.errorMessage, !errorMsg.isEmpty {
                            Button {
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
                                    .font(.system(size: 60))
                                    .foregroundStyle(.orange)
                                    .symbolEffect(.pulse)
                            }
                            .accessibilityLabel("Retry playback")
                        } else {
                            Button { playerManager.togglePlayPause() } label: {
                                if playerManager.isBuffering {
                                    ProgressView()
                                        .frame(width: 60, height: 60)
                                } else {
                                    Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 60))
                                }
                            }
                            .accessibilityLabel(playerManager.isBuffering ? "Loading" : (playerManager.isPlaying ? "Pause" : "Play"))
                        }
                        
                        Button { playerManager.seekRelative(seconds: Double(settings.skipForwardSeconds)) } label: {
                            Image(systemName: "goforward.\(settings.skipForwardSeconds)")
                                .font(.title2)
                        }
                        .accessibilityLabel("Skip forward \(settings.skipForwardSeconds) seconds")
                        
                        Button { playerManager.skipToNext() } label: {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                        }
                        .accessibilityLabel("Next Episode")
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 20)
                    
                    // Bottom actions
                    HStack(spacing: 32) {
                        Button { showSpeedPicker.toggle() } label: {
                            Text(DurationFormatting.speed(settings.playbackSpeed))
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .yourPodsGlass(role: .control, cornerRadius: 20)
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel(String(localized: "a11y.player.playbackSpeed",
                                                   defaultValue: "Playback speed, \(DurationFormatting.spokenSpeed(settings.playbackSpeed))",
                                                   comment: "VoiceOver label for the speed button in the player. The argument is the spoken rate, e.g. '1.5 times'."))
                        
                        Spacer()
                        
                        if !chapterCoordinator.visibleChapters.isEmpty {
                            Button { showChapters = true } label: {
                                Image(systemName: "book.pages")
                                    .font(.title3)
                            }
                            .accessibilityLabel("Chapters")
                        }
                        
                        if transcript != nil, !(transcript?.items.isEmpty ?? true) {
                            Button { showTranscript = true } label: {
                                Image(systemName: "text.quote")
                                    .font(.title3)
                            }
                            .accessibilityLabel("Transcript")
                        }
                        
                        Button { showAddNote = true } label: {
                            Image(systemName: "note.text.badge.plus")
                                .font(.title3)
                        }
                        .accessibilityLabel("Add Note")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    
                } else {
                    ContentUnavailableView(
                        "Nothing Playing",
                        systemImage: "play.circle",
                        description: Text("Select an episode to start listening.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                    }
                }
            }
            .sheet(isPresented: $showSpeedPicker) {
                SpeedPickerView()
                    .environment(settings)
                    .environment(playerManager)
                    .presentationDetents([.height(200)])
            }
            .sheet(isPresented: $showChapters) {
                ChapterListSheet(
                    chapters: chapterCoordinator.visibleChapters,
                    currentPosition: playerManager.currentPosition
                ) { chapter in
                    playerManager.seek(to: chapter.startTime)
                }
            }
            .sheet(isPresented: $showTranscript) {
                if let transcript {
                    TranscriptListSheet(
                        transcript: transcript,
                        currentPosition: playerManager.currentPosition
                    ) { item in
                        playerManager.seek(to: item.start)
                    }
                }
            }
            .sheet(isPresented: $showAddNote) {
                if let item {
                    AddEditNoteSheet(
                        episodeUrl: item.audioUrl,
                        podcastUrl: item.podcastUrl,
                        episodeGuid: item.id,
                        timestampSec: playerManager.currentPosition,
                        podcastTitle: item.podcastTitle,
                        episodeTitle: item.title,
                        artUrl: item.artworkUrl,
                        durationSec: playerManager.currentDuration > 0 ? playerManager.currentDuration : nil,
                        transcriptUrl: item.transcriptUrl
                    )
                    .environment(podcastManager)
                    .presentationDetents([.medium, .large])
                }
            }
            .task(id: playerManager.currentEpisodeGuid) {
                transcript = nil
                guard let item = playerManager.audioManager.currentItem else { return }

                // Fetch transcript. Prefer the live episode over the QueueItem's snapshot,
                // which was frozen at enqueue time and misses transcripts the feed
                // published after the episode was queued.
                let live = podcastManager.episodes(withGuids: [item.id]).first
                if let source = TranscriptService.resolveSource(
                    snapshotUrl: item.transcriptUrl, snapshotType: item.transcriptType,
                    liveUrl: live?.transcriptUrl, liveType: live?.transcriptType
                ) {
                    transcript = await TranscriptService.shared.fetchTranscript(url: source.url, type: source.type)
                }
            }
        }
    }
    
    /// Player artwork: follows the current chapter when one has declared art,
    /// falling back to the episode's own artwork otherwise.
    ///
    /// Gated on `ChapterArtworkView.hasAnyDeclaredSource(for:)` — a cheap,
    /// non-IO field check — NOT `ChapterArtworkView.source(for:) != .none`,
    /// which does a synchronous disk read (`ChapterArtworkStore.image(forKey:)`)
    /// plus a 900px decode and an LRU-touch write on a cache miss. `body`
    /// re-evaluates on every position tick (~1/s) via `playerManager
    /// .currentPosition`, so calling `source(for:)` here would repeat that
    /// cost every second — exactly the bug that was removed from the chapter
    /// list row body, at a strictly worse call site. `ChapterArtworkView`
    /// itself still resolves the real image asynchronously via `.task(id:)`.
    @ViewBuilder
    private var mainArtwork: some View {
        switch ChapterArtworkView.selection(forCurrentChapter: chapterCoordinator.currentChapter) {
        case .chapter(let chapter):
            ChapterArtworkView(chapter: chapter, size: 300, cornerRadius: 20)
                .shadow(radius: 20)
                .padding(.top, 32)
                .accessibilityElement()
                .accessibilityLabel("Chapter artwork: \(chapter.title)")
        case .episode:
            episodeArtwork
        }
    }

    @ViewBuilder
    private var episodeArtwork: some View {
        CachedAsyncImage(url: URL(string: item?.artworkUrl ?? "")) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .yourPodsGlassFill(cornerRadius: 20)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(maxWidth: 300, maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 20)
        .padding(.top, 32)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        DurationFormatting.timestamp(seconds)
    }
}

// MARK: - Speed Picker

private struct SpeedPickerView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerManager.self) private var playerManager
    
    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    
    var body: some View {
        VStack {
            Text("Playback Speed")
                .font(.headline)
                .padding(.top)
            
            speedGrid
        }
    }
    
    private var speedGrid: some View {
        let columns = Array(repeating: GridItem(.flexible()), count: 4)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(speeds, id: \.self) { speed in
                speedButton(speed: speed)
            }
        }
        .padding()
    }
    
    private func speedButton(speed: Double) -> some View {
        let isSelected = settings.playbackSpeed == speed
        return Button {
            playerManager.setPlaybackRate(Float(speed))
        } label: {
            Text(DurationFormatting.speed(speed))
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
