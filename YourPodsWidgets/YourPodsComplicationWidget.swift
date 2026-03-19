import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

@available(iOSApplicationExtension 14.0, watchOS 9.0, *)
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let data: ComplicationData
}

// MARK: - Timeline Provider

@available(iOSApplicationExtension 14.0, watchOS 9.0, *)
struct ComplicationTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), data: .empty)
    }
    
    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        let data = ComplicationDataStore.shared.read()
        completion(ComplicationEntry(date: Date(), data: data))
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let data = ComplicationDataStore.shared.read()
        let entry = ComplicationEntry(date: Date(), data: data)
        // No future entries — timeline reloads are driven by
        // WidgetCenter.shared.reloadAllTimelines() in WatchSessionManager.
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Complication Views

/// Helper: shows the complication icon.
/// Uses the app icon image from the asset catalog ("ComplicationIcon") and
/// falls back to an SF Symbol if the image fails to load.
@available(iOSApplicationExtension 16.0, watchOS 9.0, *)
struct YourPodsIconView: View {
    var size: CGFloat? = nil
    
    var body: some View {
        Image(systemName: "headphones.circle.fill")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .widgetAccentable()
    }
}

/// Circular complication: YourPods icon with a play/pause badge.
@available(iOSApplicationExtension 16.0, watchOS 9.0, *)
struct CircularComplicationView: View {
    let data: ComplicationData
    
    var body: some View {
        ZStack {
            YourPodsIconView()
                .clipShape(Circle())
            
            // Play/pause badge in bottom-trailing corner
            if data.nowPlayingTitle != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: data.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .padding(3)
            }
        }
    }
}

/// Corner complication: curved episode title with a small icon.
/// Note: accessoryCorner is only available on watchOS.
#if os(watchOS)
@available(watchOS 9.0, *)
struct CornerComplicationView: View {
    let data: ComplicationData
    
    var body: some View {
        YourPodsIconView()
            .clipShape(Circle())
            .widgetLabel {
                if let title = data.nowPlayingTitle {
                    Text(data.isPlaying ? "\u{25B6} \(title)" : "\u{23F8} \(title)")
                } else if let upNext = data.upNextTitle {
                    Text(upNext)
                } else {
                    Text("YourPods")
                }
            }
    }
}
#endif

/// Inline complication: single line of text.
@available(iOSApplicationExtension 14.0, watchOS 9.0, *)
struct InlineComplicationView: View {
    let data: ComplicationData
    
    var body: some View {
        if let title = data.nowPlayingTitle {
            Label(title, systemImage: data.isPlaying ? "play.fill" : "pause.fill")
        } else if let upNext = data.upNextTitle {
            Label(upNext, systemImage: "list.bullet")
        } else {
            Label("YourPods", systemImage: "headphones")
        }
    }
}

/// Rectangular complication: episode title, podcast name, and play state.
@available(iOSApplicationExtension 14.0, watchOS 9.0, *)
struct RectangularComplicationView: View {
    let data: ComplicationData
    
    var body: some View {
        if let title = data.nowPlayingTitle {
            // Now playing state
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: data.isPlaying ? "play.circle.fill" : "pause.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let podcast = data.nowPlayingPodcast {
                        Text(podcast)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } else if let upNext = data.upNextTitle {
            // Up next state
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.title2)
                    .foregroundColor(.purple)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("Up Next")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(upNext)
                        .font(.headline)
                        .lineLimit(1)
                    if let podcast = data.upNextPodcast {
                        Text(podcast)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            // Empty / idle state
            HStack(alignment: .center, spacing: 6) {
                YourPodsIconView(size: 28)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("YourPods")
                        .font(.headline)
                    Text("No episodes queued")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Widget Definition

@available(iOSApplicationExtension 16.0, watchOS 9.0, *)
struct YourPodsComplicationWidget: Widget {
    let kind: String = "YourPodsComplication"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComplicationTimelineProvider()) { entry in
            ComplicationContentView(data: entry.data)
                .containerBackground(Color.blue, for: .widget)
        }
        .configurationDisplayName("YourPods")
        .description("Now playing and up next from your podcast queue.")
        #if os(watchOS)
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular,
        ])
        #else
        .supportedFamilies([
            .accessoryCircular,
            .accessoryInline,
            .accessoryRectangular,
        ])
        #endif
    }
}

/// Reads `widgetFamily` from the environment and dispatches to the
/// correct complication view.
@available(iOSApplicationExtension 16.0, watchOS 9.0, *)
struct ComplicationContentView: View {
    @Environment(\.widgetFamily) var family
    let data: ComplicationData
    
    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularComplicationView(data: data)
        case .accessoryInline:
            InlineComplicationView(data: data)
        case .accessoryRectangular:
            RectangularComplicationView(data: data)
        default:
            CircularComplicationView(data: data)
        }
    }
}

// MARK: - Previews

#if DEBUG
@available(iOSApplicationExtension 16.0, watchOS 9.0, *)
#Preview("Circular — Playing", as: .accessoryCircular) {
    YourPodsComplicationWidget()
} timeline: {
    ComplicationEntry(date: Date(), data: ComplicationData(
        nowPlayingTitle: "The State of AI in 2026",
        nowPlayingPodcast: "Lex Fridman Podcast",
        isPlaying: true,
        upNextTitle: nil,
        upNextPodcast: nil,
        queueCount: 3,
        lastUpdated: Date()
    ))
}

@available(iOSApplicationExtension 16.0, watchOS 9.0, *)
#Preview("Rectangular — Up Next", as: .accessoryRectangular) {
    YourPodsComplicationWidget()
} timeline: {
    ComplicationEntry(date: Date(), data: ComplicationData(
        nowPlayingTitle: nil,
        nowPlayingPodcast: nil,
        isPlaying: false,
        upNextTitle: "Episode 42: The Answer",
        upNextPodcast: "No Agenda Show",
        queueCount: 5,
        lastUpdated: Date()
    ))
}

@available(iOSApplicationExtension 16.0, watchOS 9.0, *)
#Preview("Inline — Idle", as: .accessoryInline) {
    YourPodsComplicationWidget()
} timeline: {
    ComplicationEntry(date: Date(), data: .empty)
}
#endif
