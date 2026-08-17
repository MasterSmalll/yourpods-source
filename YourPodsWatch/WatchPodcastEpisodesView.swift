import SwiftUI

struct WatchPodcastEpisodesView: View {
    let podcast: WatchPodcast
    @EnvironmentObject var sessionManager: WatchSessionManager
    @ObservedObject private var downloadManager = WatchDownloadManager.shared
    
    private var episodes: [WatchEpisode] {
        sessionManager.libraryEpisodes[podcast.feedUrl] ?? []
    }

    /// True once the phone has replied for this feed (even with zero episodes) —
    /// distinguishes "reply arrived, feed is empty" from "no reply yet".
    private var replyArrived: Bool {
        sessionManager.libraryEpisodes[podcast.feedUrl] != nil
    }

    private var requestFailed: Bool {
        sessionManager.episodeRequestFailed.contains(podcast.feedUrl)
    }

    var body: some View {
        List {
            if episodes.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    if replyArrived {
                        Image(systemName: "tray")
                            .font(.largeTitle).foregroundColor(.gray)
                        Text("No Episodes")
                            .font(.headline)
                        Text("This podcast has no episodes on your iPhone.")
                            .font(.caption2).foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    } else if requestFailed {
                        Image(systemName: "exclamationmark.arrow.circlepath")
                            .font(.largeTitle).foregroundColor(.gray)
                        Text("Couldn't Load Episodes")
                            .font(.headline)
                        Text("Tap to try again.")
                            .font(.caption2).foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    } else if sessionManager.isPhoneReachable {
                        ProgressView().padding(.bottom, 4)
                        Text("Loading episodes...")
                            .font(.caption).foregroundColor(.gray)
                    } else {
                        Image(systemName: "iphone.slash")
                            .font(.largeTitle).foregroundColor(.gray)
                        Text("iPhone Not Reachable")
                            .font(.headline)
                        Text("Open YourPods on your iPhone to browse episodes.")
                            .font(.caption2).foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Retry via the existing request path — no new plumbing.
                    if requestFailed {
                        sessionManager.requestEpisodes(feedUrl: podcast.feedUrl)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(requestFailed ? .isButton : [])
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
        DurationFormatting.compact(TimeInterval(seconds))
    }
}
