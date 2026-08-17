import SwiftUI

/// Shows the 10 most recently published unplayed episodes across all subscriptions.
/// Mirrors the iOS HomeView's "Recently Updated" section but optimized for the
/// smaller watch screen — simple list layout, limited to 10 items.
struct WatchRecentlyUpdatedView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var audioManager: WatchAudioManager
    
    var body: some View {
        List {
            if sessionManager.recentEpisodes.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.green)
                    Text("All caught up!")
                        .font(.headline)
                    Text("No new episodes from your subscriptions.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(sessionManager.recentEpisodes) { episode in
                    NavigationLink(destination: PlayerView(episode: episode)) {
                        HStack(spacing: 10) {
                            // Podcast artwork (prefer podcast art for cross-podcast context)
                            AsyncImage(url: URL(string: episode.podcastArtUri ?? episode.artUri ?? "")) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 36, height: 36)
                                        .cornerRadius(6)
                                case .failure(_), .empty:
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.gray.opacity(0.3))
                                        Image(systemName: "waveform")
                                            .foregroundColor(.gray)
                                            .font(.caption2)
                                    }
                                    .frame(width: 36, height: 36)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(episode.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                
                                HStack(spacing: 4) {
                                    if let podcastTitle = episode.podcastTitle {
                                        Text(podcastTitle)
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    
                                    if let pubDate = episode.pubDate {
                                        Text(verbatim: "·")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        Text(relativeDate(pubDate))
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            // Play this episode on the watch
                            audioManager.play(episode: episode)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .tint(.green)
                    }
                    // MARK: VoiceOver
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: episode))
                    .accessibilityAction(named: "Play") {
                        audioManager.play(episode: episode)
                    }
                }
            }
        }
        .navigationTitle("Recent")
        .onAppear {
            sessionManager.requestRecentEpisodes()
        }
    }
    
    // MARK: - Helpers
    
    /// Format a date as a relative string (e.g. "2 hours ago", "3 days ago").
    ///
    /// The four hand-rolled branches this replaces were four English suffixes
    /// ("2h ago", "3d ago") that no catalog entry could reach — German needs
    /// "vor 2 Stunden", a prefix. The system formatter covers every unit in
    /// every language, and is signed, so a future date no longer reads as past.
    private func relativeDate(_ date: Date) -> String {
        DurationFormatting.relative(date)
    }
    
    /// Build a VoiceOver label for an episode row.
    ///
    /// Built as fragments joined by the shared separator rather than by `+=`
    /// with embedded ", " — the separator is a language convention, and a
    /// concatenation fixes the clause order in Swift where no translator can
    /// reach it.
    private func accessibilityLabel(for episode: WatchEpisode) -> String {
        var parts: [String] = [episode.title]
        if let podcastTitle = episode.podcastTitle {
            parts.append(String(localized: "a11y.activity.fromPodcast",
                                defaultValue: "from \(podcastTitle)",
                                comment: "VoiceOver: names the show an episode belongs to. The argument is the podcast title."))
        }
        if let pubDate = episode.pubDate {
            parts.append(relativeDate(pubDate))
        }
        if episode.duration > 0 {
            parts.append(DurationFormatting.spoken(episode.duration))
        }
        return parts.joined(separator: EpisodeAccessibility.listSeparator)
    }
}
