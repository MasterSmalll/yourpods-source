import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    
    var body: some View {
        NavigationView {
            List {
                // MARK: - Now Playing on iPhone (if active)
                if sessionManager.remoteTitle != "Not Playing" {
                    Section {
                        NavigationLink(destination: RemotePlayerView()) {
                            HStack {
                                Image(systemName: sessionManager.remoteIsPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .foregroundColor(.green)
                                    .font(.title3)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Now Playing")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                    Text(sessionManager.remoteTitle)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(sessionManager.remoteArtist)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                
                // MARK: - Quick Actions
                Section {
                    Button(action: {
                        sessionManager.sendPlayQueue()
                    }) {
                        HStack {
                            Image(systemName: "play.circle.fill")
                                .foregroundColor(.purple)
                                .font(.title3)
                            Text("Play Queue")
                                .font(.headline)
                        }
                    }
                }
                
                // MARK: - Episode Queue
                if sessionManager.episodes.isEmpty {
                    Section {
                        VStack(alignment: .center, spacing: 8) {
                            Image(systemName: "applewatch.radiowaves.left.and.right")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                            Text("No Episodes")
                                .font(.headline)
                            Text("Sync episodes from the iPhone app.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                } else {
                    Section(header: Text("Queue")) {
                        ForEach(sessionManager.episodes) { episode in
                            NavigationLink(destination: PlayerView(episode: episode)) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(episode.title)
                                            .font(.headline)
                                            .lineLimit(2)
                                        Text(episode.album)
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                    
                                    Spacer()
                                    
                                    episodeStatusView(for: episode)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    sessionManager.sendPlayLatest(podcastName: episode.album)
                                } label: {
                                    Label("Play Latest", systemImage: "sparkles")
                                }
                                .tint(.purple)
                            }
                        }
                    }
                }
            }
            .navigationTitle("YourPods")
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
        } else {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.gray)
        }
    }
}
