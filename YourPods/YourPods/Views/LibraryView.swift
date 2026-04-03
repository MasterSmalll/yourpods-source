import SwiftUI

/// Library screen showing all subscribed podcasts with reorder, filter, and management.
struct LibraryView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(NavigationState.self) private var navigationState
    @State private var searchText = ""
    @State private var filterMode: LibraryFilter = .all
    @State private var isEditing = false
    
    enum LibraryFilter: String, CaseIterable {
        case all = "All"
        case downloaded = "Downloaded"
        case unplayed = "Unplayed"
        case inProgress = "In Progress"
    }
    
    var filteredSubscriptions: [Podcast] {
        var podcasts = podcastManager.subscriptions
        
        // Text search
        if !searchText.isEmpty {
            podcasts = podcasts.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        
        // Category filter
        switch filterMode {
        case .all:
            break
        case .downloaded:
            podcasts = podcasts.filter { podcast in
                podcast.episodes.contains { downloadManager.isDownloaded($0.guid) }
            }
        case .unplayed:
            podcasts = podcasts.filter { podcast in
                let markedBefore = podcast.effectiveSettings.markedPlayedBefore
                return podcast.episodes.contains { ep in
                    guard !ep.isPlayed else { return false }
                    guard let pubDate = ep.pubDate else { return false }
                    if let markedBefore { return pubDate > markedBefore }
                    return true
                }
            }
        case .inProgress:
            podcasts = podcasts.filter { podcast in
                // Podcasts with episodes that have partial progress
                podcast.episodes.contains { ep in
                    podcastManager.getLatestAction(for: ep.guid) != nil
                }
            }
        }
        
        return podcasts
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibraryFilter.allCases, id: \.self) { filter in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    filterMode = filter
                                }
                            } label: {
                                Text(filter.rawValue)
                                    .font(.subheadline.weight(filterMode == filter ? .bold : .regular))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        filterMode == filter
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.gray.opacity(0.1)
                                    )
                                    .foregroundColor(filterMode == filter ? .accentColor : .primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                
                List {
                    ForEach(filteredSubscriptions) { podcast in
                        NavigationLink(value: podcast) {
                            PodcastRow(podcast: podcast, unplayedCount: unplayedCount(podcast))
                        }
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            let podcast = filteredSubscriptions[idx]
                            Task { await podcastManager.removeSubscription(podcast) }
                        }
                    }
                    .onMove { from, to in
                        podcastManager.reorderSubscriptions(from: from, to: to, filteredList: filteredSubscriptions)
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(isEditing ? .active : .inactive))
                .refreshable {
                    _ = await podcastManager.refreshAllFeeds()
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search podcasts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigationState.switchToAddPodcasts()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        isEditing.toggle()
                    } label: {
                        Label(isEditing ? "Done" : "Reorder", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .navigationDestination(for: Podcast.self) { podcast in
                PodcastDetailView(podcast: podcast)
            }
            .overlay {
                if podcastManager.subscriptions.isEmpty {
                    ContentUnavailableView(
                        "No Podcasts",
                        systemImage: "waveform",
                        description: Text("Tap + to search and add podcasts.")
                    )
                }
            }
        }
    }
    
    /// Count unplayed episodes since markedPlayedBefore.
    private func unplayedCount(_ podcast: Podcast) -> Int {
        let markedBefore = podcast.effectiveSettings.markedPlayedBefore
        return podcast.episodes.filter { ep in
            guard !ep.isPlayed else { return false }
            guard let pubDate = ep.pubDate else { return false }
            if let markedBefore { return pubDate > markedBefore }
            return true
        }.count
    }
}

// MARK: - Subviews

private struct PodcastRow: View {
    let podcast: Podcast
    let unplayedCount: Int
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: podcast.logoUrl ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        .overlay {
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                if podcast.requiresAuth {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Color.orange, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(podcast.title)
                        .font(.body.bold())
                        .lineLimit(1)
                    
                    if podcast.explicit == true {
                        Text("E")
                            .font(.system(size: 8, weight: .black))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.12))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    
                    if podcast.isComplete {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    
                    if unplayedCount > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
                
                if let author = podcast.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                HStack(spacing: 4) {
                    if unplayedCount > 0 {
                        Text("\(unplayedCount) unplayed")
                            .foregroundStyle(Color.accentColor)
                        Text("•")
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(podcast.episodes.count) total")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 4)
    }
}
