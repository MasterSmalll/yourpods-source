import SwiftUI

struct WatchPodcastEpisodesView: View {
    let podcast: WatchPodcast
    @EnvironmentObject var sessionManager: WatchSessionManager
    @ObservedObject private var downloadManager = WatchDownloadManager.shared
    
    private var episodes: [WatchEpisode] {
        sessionManager.libraryEpisodes[podcast.feedUrl] ?? []
    }
    
    var body: some View {
        List {
            if episodes.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    ProgressView()
                        .padding(.bottom, 4)
                    Text("Loading episodes...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(episodes) { episode in
                    NavigationLink(destination: PlayerView(episode: episode)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(episode.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                if episode.duration > 0 {
                                    Text(formatDuration(episode.duration))
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            Spacer()
                            
                            episodeStatusView(for: episode)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if episode.localPath == nil && episode.streamUrl != nil && !sessionManager.isDownloading(episodeId: episode.id) {
                            Button {
                                sessionManager.downloadOnWatch(episode: episode)
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            .tint(.blue)
                        } else if episode.localPath != nil {
                            Button(role: .destructive) {
                                sessionManager.deleteLocalFile(for: episode)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(podcast.title)
        .onAppear {
            sessionManager.requestEpisodes(feedUrl: podcast.feedUrl)
        }
    }
    
    @ViewBuilder
    private func episodeStatusView(for episode: WatchEpisode) -> some View {
        if episode.localPath != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        } else if sessionManager.isDownloading(episodeId: episode.id) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    .frame(width: 20, height: 20)
                Circle()
                    .trim(from: 0, to: sessionManager.downloadProgress(episodeId: episode.id))
                    .stroke(Color.blue, lineWidth: 2)
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(-90))
            }
        } else if episode.streamUrl != nil {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(.orange)
                .font(.caption)
        } else {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.gray)
                .font(.caption)
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        if mins >= 60 {
            let hours = mins / 60
            let remainMins = mins % 60
            return "\(hours)h \(remainMins)m"
        }
        return "\(mins)m"
    }
}
