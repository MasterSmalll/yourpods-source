import SwiftUI

/// Full-screen Now Playing view with artwork, progress, and controls.
/// Full-screen Now Playing view.
struct PlayerView: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var showSpeedPicker = false
    @State private var showChapters = false
    @State private var showTranscript = false
    @State private var chapters: [Chapter] = []
    @State private var transcript: Transcript?
    
    var item: QueueItem? { playerManager.audioManager.currentItem }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let item {
                    // Artwork
                    CachedAsyncImage(url: URL(string: item.artworkUrl ?? "")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
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
                        .accessibilityValue({
                            let pos = Int(isSeeking ? seekPosition : playerManager.currentPosition)
                            let dur = Int(playerManager.currentDuration)
                            guard dur > 0 else { return "" }
                            return "\(EpisodeAccessibility.spokenDuration(pos)) of \(EpisodeAccessibility.spokenDuration(dur))"
                        }())
                        
                        HStack {
                            Text(formatTime(isSeeking ? seekPosition : playerManager.currentPosition))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            Text("-\(formatTime(max(0, playerManager.currentDuration - (isSeeking ? seekPosition : playerManager.currentPosition))))")
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
                        .accessibilityLabel("Restart episode")
                        
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
                        .accessibilityLabel("Next episode")
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 20)
                    
                    // Bottom actions
                    HStack(spacing: 32) {
                        Button { showSpeedPicker.toggle() } label: {
                            Text("\(settings.playbackSpeed, specifier: "%.1f")×")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel("Playback speed, \(settings.playbackSpeed, specifier: "%.1f") times")
                        
                        Spacer()
                        
                        if !chapters.isEmpty {
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
                    chapters: chapters,
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
            .task(id: playerManager.currentEpisodeGuid) {
                chapters = []
                transcript = nil
                guard let item = playerManager.audioManager.currentItem else { return }
                
                // Fetch chapters from URL, inline JSON, or parse from description as fallback
                chapters = await ChapterService.shared.fetchAllChapters(
                    chaptersUrl: item.chaptersUrl,
                    chaptersJSON: item.chaptersJSON,
                    description: item.episodeDescription
                )
                
                // Fetch transcript
                if let transcriptUrl = item.transcriptUrl, !transcriptUrl.isEmpty {
                    transcript = await TranscriptService.shared.fetchTranscript(url: transcriptUrl)
                }
            }
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
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
