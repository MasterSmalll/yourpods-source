import SwiftUI
import Foundation

struct WatchLibraryView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    /// Network-free test episode. The WAV file is generated locally on the Watch
    /// the first time this view is rendered, so marker testing never depends on
    /// Wi-Fi, cellular, redirects, CDN range support, or an external MP3 host.
    private static var markerTestEpisode: WatchEpisode {
        WatchEpisode(
            id: "podcast-marker-test-episode",
            title: "Marker Test Audio",
            album: "Podcast Marker Test",
            artist: "Podcast Marker",
            duration: MarkerTestAudio.duration,
            localPath: MarkerTestAudio.ensureLocalFile(),
            streamUrl: nil,
            artUri: nil,
            isAvailableOnPhone: false,
            chapters: nil,
            position: 0,
            podcastTitle: "Podcast Marker Test"
        )
    }
    
    var body: some View {
        List {
            Section("Prototype Test") {
                NavigationLink(destination: PlayerView(episode: Self.markerTestEpisode)) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Marker Test Audio")
                                .font(.headline)
                            Text("Local test · no network required")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if sessionManager.library.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("No Podcasts")
                        .font(.headline)
                    Text("Your library will appear here when synced from the iPhone app.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                Section("Library") {
                    ForEach(sessionManager.library) { podcast in
                        NavigationLink(destination: WatchPodcastEpisodesView(podcast: podcast)) {
                            HStack(spacing: 10) {
                                AsyncImage(url: URL(string: podcast.artUri ?? "")) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 40, height: 40)
                                            .cornerRadius(8)
                                    case .failure(_), .empty:
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.gray.opacity(0.3))
                                            Image(systemName: "mic.fill")
                                                .foregroundColor(.gray)
                                                .font(.caption)
                                        }
                                        .frame(width: 40, height: 40)
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(podcast.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if !podcast.author.isEmpty {
                                        Text(podcast.author)
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .onAppear {
            // A failed library request must never block the local marker test.
            if sessionManager.library.isEmpty {
                sessionManager.requestLibrary()
            }
        }
    }
}

/// Creates a small PCM WAV directly in the Watch app's Documents directory.
/// A quiet alternating tone makes it obvious that playback is advancing while
/// keeping the fixture tiny (~720 KB). The file is generated once and reused.
private enum MarkerTestAudio {
    static let filename = "podcast-marker-local-test.wav"
    static let duration: Int = 45
    private static let sampleRate = 8_000
    private static let channels: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16

    static func ensureLocalFile() -> String? {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: url.path) {
            return filename
        }

        let sampleCount = duration * sampleRate
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataByteCount = sampleCount * Int(channels) * bytesPerSample
        let byteRate = UInt32(sampleRate * Int(channels) * bytesPerSample)
        let blockAlign = UInt16(Int(channels) * bytesPerSample)

        var wav = Data()
        wav.reserveCapacity(44 + dataByteCount)

        appendASCII("RIFF", to: &wav)
        appendUInt32(UInt32(36 + dataByteCount), to: &wav)
        appendASCII("WAVE", to: &wav)
        appendASCII("fmt ", to: &wav)
        appendUInt32(16, to: &wav)               // PCM fmt chunk size
        appendUInt16(1, to: &wav)                // PCM
        appendUInt16(channels, to: &wav)
        appendUInt32(UInt32(sampleRate), to: &wav)
        appendUInt32(byteRate, to: &wav)
        appendUInt16(blockAlign, to: &wav)
        appendUInt16(bitsPerSample, to: &wav)
        appendASCII("data", to: &wav)
        appendUInt32(UInt32(dataByteCount), to: &wav)

        // Alternate between two quiet tones every two seconds so the fixture
        // sounds less like a stuck oscillator and makes timeline movement clear.
        for sampleIndex in 0..<sampleCount {
            let t = Double(sampleIndex) / Double(sampleRate)
            let frequency = Int(t / 2).isMultiple(of: 2) ? 440.0 : 660.0
            let value = sin(2.0 * .pi * frequency * t) * 0.12
            var sample = Int16(value * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { bytes in
                wav.append(contentsOf: bytes)
            }
        }

        do {
            try wav.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private static func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
