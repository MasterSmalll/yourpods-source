import SwiftUI
import AVFoundation
import CoreMedia

enum PlaybackSource {
    case local
    case streaming
    case none
}

struct PlayerView: View {
    let episode: WatchEpisode
    @EnvironmentObject var sessionManager: WatchSessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var timer: Timer?
    @State private var statusText: String = "Tap play to start"
    @State private var playbackSource: PlaybackSource = .none
    @State private var hasSetupAudio = false

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
                    switch playbackSource {
                    case .local:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Downloaded")
                            .font(.caption2)
                            .foregroundColor(.green)
                    case .streaming:
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.orange)
                        Text("Will Stream")
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
                
                // Status Text
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                
                // Playback Controls
                HStack(spacing: 20) {
                    Button(action: {
                        seek(seconds: -15)
                    }) {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                    }
                    .disabled(!hasSetupAudio)
                    
                    Button(action: {
                        if hasSetupAudio {
                            togglePlay()
                        } else {
                            setupAndPlay()
                        }
                    }) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.accentColor)
                    }
                    
                    Button(action: {
                        seek(seconds: 30)
                    }) {
                        Image(systemName: "goforward.30")
                            .font(.title2)
                    }
                    .disabled(!hasSetupAudio)
                }
                .padding(.vertical, 4)
                
                Divider()
                    .padding(.vertical, 4)
                
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
        .onAppear {
            determinePlaybackSource()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func determinePlaybackSource() {
        // Check what source we'll use - but don't start playing
        if let localPath = episode.localPath {
            let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = docURL.appendingPathComponent(localPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                playbackSource = .local
                statusText = "Tap play to start"
                return
            }
        }
        
        if episode.streamUrl != nil {
            playbackSource = .streaming
            statusText = "Tap play to stream"
        } else {
            playbackSource = .none
            statusText = "No audio source"
        }
    }
    
    private func setupAndPlay() {
        statusText = "Setting up..."
        var urlToPlay: URL?
        
        // 1. Try Local File
        if let localPath = episode.localPath {
            let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = docURL.appendingPathComponent(localPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                playbackSource = .local
                urlToPlay = fileURL
            }
        }
        
        // 2. Fallback to Stream
        if urlToPlay == nil {
            if let streamUrl = episode.streamUrl, let remote = URL(string: streamUrl) {
                playbackSource = .streaming
                urlToPlay = remote
            } else {
                playbackSource = .none
                statusText = "No audio source"
                return
            }
        }
        
        guard let url = urlToPlay else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playback,
                    mode: .default,
                    policy: .longFormAudio
                )
                try AVAudioSession.sharedInstance().setActive(true)
                
                DispatchQueue.main.async {
                    let item = AVPlayerItem(url: url)
                    self.player = AVPlayer(playerItem: item)
                    self.player?.play()
                    self.isPlaying = true
                    self.hasSetupAudio = true
                    self.startTimer()
                    
                    if self.playbackSource == .streaming {
                        self.statusText = "Streaming..."
                    } else {
                        self.statusText = "Playing"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusText = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func togglePlay() {
        guard let p = player else { return }
        if p.timeControlStatus == .playing {
            p.pause()
            isPlaying = false
            timer?.invalidate()
            statusText = "Paused"
        } else {
            p.play()
            isPlaying = true
            startTimer()
        }
    }
    
    private func seek(seconds: Double) {
        guard let p = player else { return }
        let current = p.currentTime()
        let newTime = CMTimeAdd(current, CMTimeMakeWithSeconds(seconds, preferredTimescale: 1))
        p.seek(to: newTime)
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if let p = player {
                progress = CMTimeGetSeconds(p.currentTime())
                
                if let error = p.currentItem?.error {
                    statusText = "Error: \(error.localizedDescription)"
                } else if p.status == .failed {
                    statusText = "Failed"
                } else if p.timeControlStatus == .playing {
                    let mins = Int(progress) / 60
                    let secs = Int(progress) % 60
                    statusText = playbackSource == .streaming 
                        ? "Streaming \(mins):\(String(format: "%02d", secs))"
                        : "Playing \(mins):\(String(format: "%02d", secs))"
                } else if p.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    statusText = "Buffering..."
                }
            }
        }
    }
}
