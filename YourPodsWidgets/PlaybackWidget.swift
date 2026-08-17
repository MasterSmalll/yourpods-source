import WidgetKit
import SwiftUI
import AppIntents
import OSLog

// MARK: - Availability-guarded accented rendering helpers (iOS 18+, deployment target iOS 17)

private extension Image {
    /// Preserve full color for artwork images in iOS 18+ accented widget mode.
    /// Falls through unchanged on iOS 17.
    @ViewBuilder
    func accentedFullColor() -> some View {
        if #available(iOS 18.0, *) {
            self.widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
    }

    /// Desaturate SF Symbols to blend with accented widget tint in iOS 18+.
    /// Falls through unchanged on iOS 17.
    @ViewBuilder
    func accentedDesaturated() -> some View {
        if #available(iOS 18.0, *) {
            self.widgetAccentedRenderingMode(.accentedDesaturated)
        } else {
            self
        }
    }

    /// Desaturate placeholder icons in iOS 18+ accented widget mode.
    /// Falls through unchanged on iOS 17.
    @ViewBuilder
    func accentedDesat() -> some View {
        if #available(iOS 18.0, *) {
            self.widgetAccentedRenderingMode(.desaturated)
        } else {
            self
        }
    }
}

// MARK: - Timeline Entry

struct PlaybackEntry: TimelineEntry {
    let date: Date
    let data: ComplicationData
}

// MARK: - Timeline Provider

struct PlaybackTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaybackEntry {
        PlaybackEntry(date: Date(), data: .placeholder)
    }
    
    func getSnapshot(in context: Context, completion: @escaping (PlaybackEntry) -> Void) {
        let data = ComplicationDataStore.shared.read()
        completion(PlaybackEntry(date: Date(), data: data))
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaybackEntry>) -> Void) {
        // DIAGNOSTIC (temporary): proves the running widget-EXTENSION binary is the
        // expected build. The button wiring (Button(intent:)) is compiled into THIS
        // binary, so a stale cached .appex would keep old behavior even if the app is
        // fresh — pair this with ⟦app-init⟧ build= to confirm BOTH binaries before
        // interpreting a widget tap.
        Logger(subsystem: "com.yourpods", category: "widget").notice(
            "⟦widget-render⟧ build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0", privacy: .public)")

        let data = ComplicationDataStore.shared.read()
        
        if data.isPlaying, data.durationSeconds > 0 {
            // When playing, project progress forward so the widget shows
            // the progress bar advancing without needing constant reloads.
            // Generate entries every 30 seconds for the next 12 minutes.
            var entries: [PlaybackEntry] = []
            let now = Date()
            let intervalSeconds = 30
            let maxEntries = 24
            
            for i in 0..<maxEntries {
                let futureDate = now.addingTimeInterval(Double(i * intervalSeconds))
                var projected = data
                let projectedPosition = data.positionSeconds + (i * intervalSeconds)
                projected.positionSeconds = min(projectedPosition, data.durationSeconds)
                entries.append(PlaybackEntry(date: futureDate, data: projected))
                
                // Stop projecting past the end of the episode
                if projectedPosition >= data.durationSeconds { break }
            }
            
            // .atEnd: WidgetKit will request a new timeline when the last
            // entry expires, or sooner if reloadTimelines is called.
            let timeline = Timeline(entries: entries, policy: .atEnd)
            completion(timeline)
        } else {
            // Not playing — single entry, reload only when app pushes.
            let entry = PlaybackEntry(date: Date(), data: data)
            let timeline = Timeline(entries: [entry], policy: .never)
            completion(timeline)
        }
    }
}

// MARK: - Placeholder Data

extension ComplicationData {
    static let placeholder = ComplicationData(
        nowPlayingTitle: "The State of AI in 2026",
        nowPlayingPodcast: "Lex Fridman Podcast",
        isPlaying: true,
        upNextTitle: "Episode 42: The Answer",
        upNextPodcast: "No Agenda Show",
        queueCount: 3,
        lastUpdated: Date(),
        artworkPath: nil,
        positionSeconds: 1234,
        durationSeconds: 5400,
        upNextItems: [
            WidgetUpNextItem(title: "Episode 42: The Answer", podcastTitle: "No Agenda Show", artworkPath: nil),
            WidgetUpNextItem(title: "Building in Public", podcastTitle: "Indie Hackers", artworkPath: nil),
            WidgetUpNextItem(title: "Deep Work", podcastTitle: "Cal Newport", artworkPath: nil),
        ]
    )
}

// MARK: - Helper: Format Time

private func formatTime(_ totalSeconds: Int) -> String {
    DurationFormatting.timestamp(TimeInterval(totalSeconds))
}

private func progressFraction(_ data: ComplicationData) -> Double {
    guard data.durationSeconds > 0 else { return 0 }
    return min(max(Double(data.positionSeconds) / Double(data.durationSeconds), 0), 1)
}

// MARK: - Small Widget View

struct SmallPlaybackView: View {
    let data: ComplicationData
    @Environment(\.widgetRenderingMode) var renderingMode
    
    var body: some View {
        if let title = data.nowPlayingTitle {
            ZStack(alignment: .bottomLeading) {
                // Artwork background — preserve full color in accented mode
                artworkImage(path: data.artworkPath, size: nil)
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .black.opacity(renderingMode == .accented ? 0.6 : 0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                
                // Episode info
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Image(systemName: data.isPlaying ? "pause.fill" : "play.fill")
                            .accentedDesaturated()
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                        
                        Text(title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .foregroundStyle(.white)
                    }
                    
                    if let podcast = data.nowPlayingPodcast {
                        Text(podcast)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    
                    // Progress bar
                    ProgressView(value: progressFraction(data))
                        .tint(.green)
                        .scaleEffect(y: 0.6)
                }
                .padding(12)
            }
        } else {
            // Empty state
            VStack(spacing: 8) {
                Image(systemName: "headphones.circle.fill")
                    .accentedDesaturated()
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                
                Text("YourPods")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                Text("Nothing Playing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Medium Widget View

struct MediumPlaybackView: View {
    let data: ComplicationData
    var entryDate: Date = Date()
    
    var body: some View {
        if let title = data.nowPlayingTitle {
            HStack(spacing: 12) {
                // Artwork — preserve full color in accented mode
                artworkImage(path: data.artworkPath, size: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // Info + controls
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    
                    if let podcast = data.nowPlayingPodcast {
                        Text(podcast)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    // Progress
                    VStack(spacing: 2) {
                        ProgressView(value: progressFraction(data))
                            .tint(.green)
                        
                        HStack {
                            if data.isPlaying, data.durationSeconds > 0 {
                                // Live-updating elapsed time (same mechanism as Dynamic Island).
                                // Start the interval at (entryDate - positionSeconds) so the
                                // timer displays the current position and counts up from there.
                                let playbackStart = entryDate.addingTimeInterval(-Double(data.positionSeconds))
                                let playbackEnd = playbackStart.addingTimeInterval(Double(data.durationSeconds))
                                Text(timerInterval: playbackStart...playbackEnd, countsDown: false)
                                    .font(.system(size: 9))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(formatTime(data.positionSeconds))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatTime(data.durationSeconds))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Controls — Button(intent:) with PLAIN labels (no
                    // accentedDesaturated). widgetAccentedRenderingMode on a
                    // Button/Link label silently disables the interactive region
                    // and the tap falls through to open-app (FB15152620,
                    // DTS-acknowledged). Every device build with dead buttons
                    // carried the modifier here; an earlier working release
                    // did not. Keep these labels modifier-free.
                    // Fallback if dispatch still fails on device: swap each
                    // Button(intent:) for Link(destination: yourpods://action/…)
                    // — same plain labels — which opens the app AND performs
                    // the action via .onOpenURL → LiveActivityService.handleURL.
                    HStack(spacing: 16) {
                        Button(intent: WidgetSkipBackwardIntent()) {
                            Image(systemName: "gobackward.15")
                                .font(.title3)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 36, minHeight: 36)
                        .accessibilityLabel("Skip back 15 seconds")

                        Button(intent: WidgetTogglePlayIntent()) {
                            Image(systemName: data.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title)
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(data.isPlaying ? "Pause" : "Play")

                        Button(intent: WidgetSkipForwardIntent()) {
                            Image(systemName: "goforward.30")
                                .font(.title3)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 36, minHeight: 36)
                        .accessibilityLabel("Skip forward 30 seconds")
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(12)
        } else {
            // Empty state
            HStack(spacing: 12) {
                Image(systemName: "headphones.circle.fill")
                    .accentedDesaturated()
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("YourPods")
                        .font(.headline)
                    Text("No episodes queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Open YourPods to start listening")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
            }
            .padding(12)
        }
    }
}

// MARK: - Large Widget View

struct LargePlaybackView: View {
    let data: ComplicationData
    var entryDate: Date = Date()
    
    var body: some View {
        VStack(spacing: 0) {
            // Top: now playing (reuse medium layout)
            MediumPlaybackView(data: data, entryDate: entryDate)
            
            if !data.upNextItems.isEmpty {
                Divider()
                    .padding(.horizontal, 12)
                
                // Bottom: Up Next queue
                VStack(alignment: .leading, spacing: 0) {
                    Text("Up Next")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    
                    ForEach(Array(data.upNextItems.prefix(4).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            artworkImage(path: item.artworkPath, size: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(item.podcastTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            } else if data.nowPlayingTitle != nil {
                Divider()
                    .padding(.horizontal, 12)
                
                VStack {
                    Spacer()
                    Text("Queue is empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Artwork Helper

@ViewBuilder
private func artworkImage(path: String?, size: CGFloat?) -> some View {
    // Decode downsampled to the on-screen pixel size (~3x for retina widgets) so
    // the widget never materializes a full-resolution bitmap and blows its memory
    // budget. nil size = full-bleed small-widget background; 600px covers it.
    let maxPixels = size.map { Int(($0 * 3).rounded()) } ?? 600
    if let path, let uiImage = WidgetArtworkLoader.downsampledImage(atPath: path, maxPixelSize: maxPixels) {
        if let size {
            Image(uiImage: uiImage)
                .resizable()
                .accentedFullColor()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
        } else {
            Image(uiImage: uiImage)
                .resizable()
                .accentedFullColor()
                .aspectRatio(contentMode: .fill)
        }
    } else {
        if let size {
            ZStack {
                RoundedRectangle(cornerRadius: size > 40 ? 10 : 4)
                    .fill(Color.gray.opacity(0.2))
                Image(systemName: "music.note")
                    .accentedDesat()
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.gray)
            }
            .frame(width: size, height: size)
        } else {
            ZStack {
                Color.gray.opacity(0.2)
                Image(systemName: "music.note")
                    .accentedDesat()
                    .font(.title)
                    .foregroundStyle(.gray)
            }
        }
    }
}

// MARK: - Widget Definition

struct PlaybackWidget: Widget {
    let kind: String = "YourPodsPlayback"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaybackTimelineProvider()) { entry in
            PlaybackContentView(data: entry.data, entryDate: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("Control podcast playback and see your Up Next queue.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Dispatches to the correct view based on widget family.
struct PlaybackContentView: View {
    @Environment(\.widgetFamily) var family
    let data: ComplicationData
    var entryDate: Date = Date()
    
    var body: some View {
        switch family {
        case .systemSmall:
            SmallPlaybackView(data: data)
        case .systemMedium:
            MediumPlaybackView(data: data, entryDate: entryDate)
        case .systemLarge:
            LargePlaybackView(data: data, entryDate: entryDate)
        default:
            MediumPlaybackView(data: data, entryDate: entryDate)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Small — Playing", as: .systemSmall) {
    PlaybackWidget()
} timeline: {
    PlaybackEntry(date: Date(), data: .placeholder)
}

#Preview("Small — Empty", as: .systemSmall) {
    PlaybackWidget()
} timeline: {
    PlaybackEntry(date: Date(), data: .empty)
}

#Preview("Medium — Playing", as: .systemMedium) {
    PlaybackWidget()
} timeline: {
    PlaybackEntry(date: Date(), data: .placeholder)
}

#Preview("Medium — Empty", as: .systemMedium) {
    PlaybackWidget()
} timeline: {
    PlaybackEntry(date: Date(), data: .empty)
}

#Preview("Large — Playing", as: .systemLarge) {
    PlaybackWidget()
} timeline: {
    PlaybackEntry(date: Date(), data: .placeholder)
}

#Preview("Large — Empty", as: .systemLarge) {
    PlaybackWidget()
} timeline: {
    PlaybackEntry(date: Date(), data: .empty)
}
#endif
