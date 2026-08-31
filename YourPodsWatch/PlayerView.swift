import SwiftUI
import AVFoundation
import CoreMedia

enum PlaybackSource: Sendable {
    case local
    case streaming
    case none
}

extension PlaybackSource: Equatable {
    nonisolated static func == (lhs: PlaybackSource, rhs: PlaybackSource) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local), (.streaming, .streaming), (.none, .none):
            return true
        default:
            return false
        }
    }
}

struct PlayerView: View {
    let episode: WatchEpisode
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var audioManager: WatchAudioManager
    @Environment(\.dismiss) private var dismiss
    @State private var chaptersExpanded = false
    @State private var showingSleepTimerOptions = false
    
    /// Whether this view's episode is currently playing in the audio manager
    private var isCurrentEpisode: Bool {
        audioManager.currentEpisode?.id == episode.id
    }

    private var capturedMomentsForEpisode: [CapturedMoment] {
        audioManager.capturedMoments.filter { $0.episodeId == episode.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Cover Art
                AsyncImage(url: URL(string: episode.artUri ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 100, height: 100)
                            .cornerRadius(12)
                    case .failure(_), .empty:
                        // Fallback placeholder
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.3))
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        }
                        .frame(width: 100, height: 100)
                    @unknown default:
                        EmptyView()
                    }
                }
                .padding(.top, 8)
                
                // Episode Info
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                Text(episode.album)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Source Indicator
                HStack(spacing: 4) {
                    if isCurrentEpisode {
                        // Show live playback source from the audio manager
                        sourceIndicator(for: audioManager.playbackSource)
                    } else {
                        // Show what source would be used
                        sourceIndicator(for: determinePlaybackSource())
                    }
                }
                .accessibilityElement(children: .combine)
                
                // Status Text
                Text(isCurrentEpisode ? audioManager.statusText : statusTextForIdle())
                    .font(.system(size: 10))
                    .foregroundColor(.gray)

                // Prototype verification: show how many hands-free moments were
                // captured for this episode and the most recent timestamp.
                if let lastMoment = capturedMomentsForEpisode.last {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark.fill")
                        Text("\(capturedMomentsForEpisode.count) · \(formatChapterTime(lastMoment.timestampSec))")
                    }
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .accessibilityLabel("\(capturedMomentsForEpisode.count) captured moments. Latest at \(formatChapterTime(lastMoment.timestampSec))")
                }
                
                // Playback Controls
                HStack(spacing: 20) {
                    Button(action: {
                        audioManager.seek(by: -Double(sessionManager.skipBackwardSeconds))
                    }) {
                        Image(systemName: WatchSkipIntervals.symbolName(for: sessionManager.skipBackwardSeconds, direction: .backward))
                            .font(.title2)
                    }
                    .disabled(!isCurrentEpisode || !audioManager.hasSetupAudio)
                    .accessibilityLabel("Skip back \(sessionManager.skipBackwardSeconds) seconds")
                    
                    Button(action: {
                        if isCurrentEpisode {
                            audioManager.togglePlayPause()
                        } else {
                            audioManager.play(episode: episode)
                        }
                    }) {
                        Image(systemName: (isCurrentEpisode && audioManager.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityLabel((isCurrentEpisode && audioManager.isPlaying) ? "Pause" : "Play \(episode.title)")
                    
                    Button(action: {
                        audioManager.seek(by: Double(sessionManager.skipForwardSeconds))
                    }) {
                        Image(systemName: WatchSkipIntervals.symbolName(for: sessionManager.skipForwardSeconds, direction: .forward))
                            .font(.title2)
                    }
                    .disabled(!isCurrentEpisode || !audioManager.hasSetupAudio)
                    .accessibilityLabel("Skip forward \(sessionManager.skipForwardSeconds) seconds")
                }
                .padding(.vertical, 4)

                // Manual fallback for first-device testing. The AirPods gesture
                // calls the same captureCurrentMoment() method.
                Button(action: {
                    _ = audioManager.captureCurrentMoment()
                }) {
                    Label("Mark Moment", systemImage: "bookmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(!isCurrentEpisode || !audioManager.hasSetupAudio)

                // Playback speed (watch-local override; long-press to follow iPhone)
                Button(action: {
                    audioManager.setSpeedOverride(WatchSpeedPolicy.next(after: audioManager.currentEffectiveSpeed))
                }) {
                    Text(String(format: "%g×", audioManager.currentEffectiveSpeed))
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .simultaneousGesture(LongPressGesture().onEnded { _ in
                    audioManager.setSpeedOverride(nil)
                })
                .accessibilityLabel("Playback Speed")
                .accessibilityValue(DurationFormatting.spokenSpeed(audioManager.currentEffectiveSpeed))
                .accessibilityHint("Double tap to change speed. Long press to match iPhone speed.")

                // Sleep timer
                // NOTE: SwiftUI's `Menu` is unavailable on watchOS (SDK-enforced —
                // `@available(watchOS, unavailable)`), so the options list is
                // presented via `.confirmationDialog` instead, watchOS's
                // idiomatic replacement (available watchOS 8+).
                Button(action: { showingSleepTimerOptions = true }) {
                    Label(sleepTimerLabel, systemImage: "moon.zzz")
                        .font(.caption)
                }
                .accessibilityLabel("Sleep Timer")
                .accessibilityValue(sleepTimerLabel)
                .confirmationDialog("Sleep Timer", isPresented: $showingSleepTimerOptions, titleVisibility: .visible) {
                    Button("15 minutes") { audioManager.setSleepTimer(.duration(minutes: 15, startedAt: Date())) }
                    Button("30 minutes") { audioManager.setSleepTimer(.duration(minutes: 30, startedAt: Date())) }
                    Button("1 hour") { audioManager.setSleepTimer(.duration(minutes: 60, startedAt: Date())) }
                    Button("End of episode") { audioManager.setSleepTimer(.endOfEpisode) }
                    if audioManager.sleepTimer != nil {
                        Button("Cancel Timer", role: .destructive) { audioManager.setSleepTimer(nil) }
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                // MARK: - Chapters (if available)
                if let chapters = episode.chapters, !chapters.isEmpty {
                    Button(action: {
                        withAnimation { chaptersExpanded.toggle() }
                    }) {
                        HStack {
                            Image(systemName: "list.bullet")
                                .foregroundColor(.accentColor)
                            Text("Chapters (\(chapters.count))")
                                .font(.caption)
                            Spacer()
                            Image(systemName: chaptersExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if chaptersExpanded {
                        ForEach(chapters) { chapter in
                            Button(action: {
                                if !isCurrentEpisode {
                                    audioManager.play(episode: episode)
                                }
                                audioManager.seek(to: chapter.startTime)
                            }) {
                                HStack {
                                    Text(chapter.title)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Text(formatChapterTime(chapter.startTime))
                                        .font(.caption2)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Chapter: \(chapter.title)")
                            // Spoken, not read off the clock: VoiceOver renders
                            // "12:34" as digits and a colon.
                            .accessibilityValue(EpisodeAccessibility.spokenDuration(Int(chapter.startTime)))
                            .accessibilityHint("Double tap to jump to this chapter")
                        }
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                }
                
                // MARK: - Episode Actions
                VStack(spacing: 8) {
                    // Download / Delete Download
                    if episode.localPath != nil {
                        Button(action: {
                            sessionManager.deleteLocalFile(for: episode)
                        }) {
                            Label("Delete Download", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else if sessionManager.isDownloading(episodeId: episode.id) {
                        VStack(spacing: 4) {
                            ProgressView(value: sessionManager.downloadProgress(episodeId: episode.id))
                                .progressViewStyle(LinearProgressViewStyle())
                            Button(action: {
                                sessionManager.cancelOnWatchDownload(episodeId: episode.id)
                            }) {
                                Label("Cancel", systemImage: "xmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if episode.streamUrl != nil {
                        Button(action: {
                            sessionManager.downloadOnWatch(episode: episode)
                        }) {
                            Label("Download to Watch", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                    
                    // Remove from Queue
                    Button(action: {
                        // Stop if this episode is playing
                        if isCurrentEpisode {
                            audioManager.stop()
                        }
                        sessionManager.removeFromQueue(for: episode.id)
                        dismiss()
                    }) {
                        Label("Remove from Queue", systemImage: "minus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    
                    // Mark as Played
                    Button(action: {
                        if isCurrentEpisode {
                            audioManager.stop()
                        }
                        sessionManager.markAsPlayed(for: episode.id)
                        dismiss()
                    }) {
                        Label("Mark as Played", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }
                .font(.caption)
            }
            .padding(.horizontal)
        }
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Helpers

    /// Both the button's title and its VoiceOver value, so its literals are
    /// user-facing twice over and were extracted neither time — a `String`
    /// helper feeding `Label(_:systemImage:)` and `.accessibilityValue(_:)`
    /// binds the non-localizing overload at both call sites.
    private var sleepTimerLabel: String {
        guard let timer = audioManager.sleepTimer else { return Self.sleepTimerIdleLabel }
        if timer.stopsAtTrackEnd {
            return String(localized: "watch.sleepTimer.untilEpisodeEnds",
                          defaultValue: "Until episode ends",
                          comment: "Watch sleep-timer button when the timer is set to stop at the end of the current episode.")
        }
        if let mins = timer.remainingMinutes(at: Date()) {
            return DurationFormatting.remaining(TimeInterval(mins * 60))
        }
        return Self.sleepTimerIdleLabel
    }

    private static var sleepTimerIdleLabel: String {
        String(localized: "watch.sleepTimer.idle",
               defaultValue: "Sleep Timer",
               comment: "Watch sleep-timer button when no timer is set.")
    }

    private func determinePlaybackSource() -> PlaybackSource {
        if let localPath = episode.localPath {
            let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = docURL.appendingPathComponent(localPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return .local
            }
        }
        if episode.streamUrl != nil {
            return .streaming
        }
        return .none
    }
    
    private func statusTextForIdle() -> String {
        switch determinePlaybackSource() {
        case .local: return "Tap play to start"
        case .streaming: return "Tap play to stream"
        case .none: return "No audio source"
        }
    }
    
    @ViewBuilder
    private func sourceIndicator(for source: PlaybackSource) -> some View {
        switch source {
        case .local:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(String(localized: "player.source.downloaded",
                        defaultValue: "Downloaded",
                        comment: "Status showing this episode's audio is already on the device. A completed STATE, not an instruction to download."))
                .font(.caption2)
                .foregroundColor(.green)
        case .streaming:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(.orange)
            Text(isCurrentEpisode
                 ? String(localized: "player.source.streaming",
                          defaultValue: "Streaming",
                          comment: "Status showing this episode is playing from the network right now.")
                 : String(localized: "player.source.willStream",
                          defaultValue: "Will Stream",
                          comment: "Status showing this episode is not downloaded, so playing it will stream from the network."))
                .font(.caption2)
                .foregroundColor(.orange)
        case .none:
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.red)
            Text("No Source")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }
    
    /// The fourteenth private clock formatter, missed by W2's sweep of the
    /// other thirteen because it is spelled with an interpolation rather than
    /// a single `String(format:)`.
    ///
    /// It also never rolled over to hours, so a chapter starting at 1:05:00
    /// was listed as `65:00`. `timestamp` is what the iOS chapter list uses.
    private func formatChapterTime(_ seconds: Double) -> String {
        DurationFormatting.timestamp(seconds)
    }
}
