import SwiftUI

struct WatchLibraryView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    
    var body: some View {
        List {
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
                ForEach(sessionManager.library) { podcast in
                    NavigationLink(destination: WatchPodcastEpisodesView(podcast: podcast)) {
                        HStack(spacing: 10) {
                            // Podcast artwork
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
        .navigationTitle("Library")
        .onAppear {
            // Request library if empty and phone is reachable
            if sessionManager.library.isEmpty {
                sessionManager.requestLibrary()
            }
        }
    }
}
