import SwiftUI

struct RemotePlayerView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @ObservedObject private var downloadManager = WatchDownloadManager.shared
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Spacer()
                
                Text(sessionManager.remoteTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Text(sessionManager.remoteArtist)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Spacer()
                
                // Playback Controls
                HStack(spacing: 30) {
                    Button(action: {
                        sessionManager.sendRemoteCommand("skipBackward")
                    }) {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                    }
                    
                    Button(action: {
                        sessionManager.sendRemoteCommand(sessionManager.remoteIsPlaying ? "pause" : "play")
                    }) {
                        Image(systemName: sessionManager.remoteIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                    }
                    
                    Button(action: {
                        sessionManager.sendRemoteCommand("skipForward")
                    }) {
                        Image(systemName: "goforward.30")
                            .font(.title2)
                    }
                }
                .padding(.bottom, 8)
                
                Divider()
                    .padding(.vertical, 4)
                
                // MARK: - Episode Actions
                if let episode = sessionManager.currentEpisode {
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
                    }
                    .font(.caption)
                }
                
                Spacer()
            }
            .padding(.horizontal)
        }
        .navigationTitle("Now Playing")
    }
}
