import SwiftUI

struct WatchLibraryView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    private static let markerTestEpisode = WatchEpisode(
        id: "podcast-marker-test-episode",
        title: "Marker Test Audio",
        album: "Podcast Marker Test",
        artist: "Podcast Marker",
        duration: 3600,
        localPath: nil,
        streamUrl: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3",
        artUri: nil,
        isAvailableOnPhone: false,
        chapters: nil,
        position: 0,
        podcastTitle: "Podcast Marker Test"
    )
    
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
                            Text("Test Mark Moment + AirPods triple press")
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
            if sessionManager.library.isEmpty {
                sessionManager.requestLibrary()
            }
        }
    }
}
