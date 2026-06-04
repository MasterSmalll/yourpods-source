import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var audioManager: WatchAudioManager
    
    var body: some View {
        NavigationView {
            List {
                // MARK: - Now Playing on Watch (local playback)
                if let currentEpisode = audioManager.currentEpisode {
                    Section {
                        NavigationLink(destination: PlayerView(episode: currentEpisode)) {
                            HStack {
                                Image(systemName: audioManager.isPlaying ? "waveform" : "pause.fill")
                                    .foregroundColor(.accentColor)
                                    .font(.title3)
                                    .symbolEffect(.variableColor, isActive: audioManager.isPlaying)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Now Playing")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Text(currentEpisode.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(currentEpisode.album)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Now Playing on Watch, \(currentEpisode.title), \(currentEpisode.album), \(audioManager.isPlaying ? "playing" : "paused")")
                        }
                    }
                }
                
                // MARK: - Now Playing on iPhone (if active)
                if sessionManager.remoteTitle != "Not Playing" && audioManager.currentEpisode == nil {
                    Section {
                        NavigationLink(destination: nowPlayingDestination) {
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
                
                // MARK: - Library
                Section {
                    NavigationLink(destination: WatchLibraryView()) {
                        HStack {
                            Image(systemName: "books.vertical.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                            Text("Library")
                                .font(.headline)
                        }
                    }
                }
                
                // MARK: - Recently Updated
                Section {
                    NavigationLink(destination: WatchRecentlyUpdatedView()) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.orange)
                                .font(.title3)
                            Text("Recently Updated")
                                .font(.headline)
                            
                            Spacer()
                            
                            if !sessionManager.recentEpisodes.isEmpty {
                                Text("\(sessionManager.recentEpisodes.count)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .accessibilityLabel("Recently Updated, \(sessionManager.recentEpisodes.count) episodes")
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
    
    
    /// Routes Now Playing to PlayerView when the episode is available locally
    /// (downloaded file or streamable), otherwise falls back to RemotePlayerView
    /// for iPhone remote control. This prevents stalled playback when the episode
    /// is downloaded on the watch but Now Playing was only sending remote commands.
    @ViewBuilder
    private var nowPlayingDestination: some View {
        if let episode = sessionManager.currentEpisode,
           episode.localPath != nil || episode.streamUrl != nil {
            // Play on watch — PlayerView handles local file + streaming + position resumption
            PlayerView(episode: episode)
        } else {
            // No local episode data — fall back to remote control
            RemotePlayerView()
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
