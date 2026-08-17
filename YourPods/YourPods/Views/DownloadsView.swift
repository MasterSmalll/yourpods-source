import SwiftUI

/// Shows all downloaded episodes grouped by podcast, with per-podcast and bulk delete.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PodcastManager.self) private var podcastManager
    @State private var showDeleteAllConfirm = false
    
    /// Group downloaded episode GUIDs by their podcast.
    private var groupedDownloads: [(podcast: Podcast, episodes: [Episode])] {
        var result: [(podcast: Podcast, episodes: [Episode])] = []
        
        let downloadedGuids = Set(downloadManager.downloadedFiles.keys)
        
        for podcast in podcastManager.subscriptions {
            let downloaded = podcast.episodes.filter { downloadedGuids.contains($0.guid) }
            if !downloaded.isEmpty {
                result.append((podcast: podcast, episodes: downloaded))
            }
        }
        
        return result.sorted { $0.podcast.title < $1.podcast.title }
    }
    
    /// Orphaned downloads (GUIDs not matching any known episode).
    private var orphanedGuids: [String] {
        let knownGuids = Set(podcastManager.subscriptions.flatMap { $0.episodes.map(\.guid) })
        return downloadManager.downloadedFiles.keys.filter { !knownGuids.contains($0) }.sorted()
    }
    
    var body: some View {
        List {
            if groupedDownloads.isEmpty && orphanedGuids.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloaded episodes will appear here.")
                )
            } else {
                // Summary header
                Section {
                    HStack {
                        Label("Total Size", systemImage: "internaldrive")
                        Spacer()
                        Text(formatSize(downloadManager.totalDownloadSize))
                            .foregroundStyle(.secondary)
                    }
                    
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Label("Delete All Downloads", systemImage: "trash")
                    }
                }
                
                // Per-podcast sections
                ForEach(groupedDownloads, id: \.podcast.id) { group in
                    Section {
                        ForEach(group.episodes) { episode in
                            episodeRow(episode)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        downloadManager.deleteDownload(guid: episode.guid)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text(group.podcast.title)
                            Spacer()
                            Text("\(group.episodes.count) episodes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Button(role: .destructive) {
                            let guids = Set(group.episodes.map(\.guid))
                            downloadManager.deleteDownloads(guids: guids)
                        } label: {
                            Text("Delete All for \(group.podcast.title)")
                                .font(.caption)
                        }
                    }
                }
                
                // Orphaned downloads
                if !orphanedGuids.isEmpty {
                    Section("Unknown Episodes") {
                        ForEach(orphanedGuids, id: \.self) { guid in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(guid)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(formatSize(downloadManager.fileSize(for: guid)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    downloadManager.deleteDownload(guid: guid)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        #if os(iOS)
        .inlineNavigationBarTitle()
        #endif
        .confirmationDialog("Delete All Downloads?", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                downloadManager.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all \(downloadManager.downloadedFiles.count) downloaded episodes and free up \(formatSize(downloadManager.totalDownloadSize)).")
        }
    }
    
    // MARK: - Episode Row
    
    private func episodeRow(_ episode: Episode) -> some View {
        HStack(spacing: 12) {
            let imageUrl = episode.imageUrl ?? episode.podcast?.logoUrl
            CachedAsyncImage(url: URL(string: imageUrl ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.subheadline)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    if let duration = episode.durationSeconds {
                        Text(PlayerManager.formatDuration(TimeInterval(duration)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(formatSize(downloadManager.fileSize(for: episode.guid)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        // MARK: VoiceOver
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.rowAccessibilityLabel(
            title: episode.title,
            spokenDuration: episode.durationSeconds.map { EpisodeAccessibility.spokenDuration($0) },
            size: formatSize(downloadManager.fileSize(for: episode.guid))))
        .accessibilityAction(named: "Delete Download") {
            downloadManager.deleteDownload(guid: episode.guid)
        }
    }
    
    // MARK: - VoiceOver

    /// VoiceOver label for one row of the Downloads list.
    ///
    /// This was assembled in a `{ … }()` closure returning `String`, which
    /// binds the `@_disfavoredOverload` `StringProtocol` overload of
    /// `.accessibilityLabel` — so none of it reached the catalog, including
    /// the hardcoded English word "Downloaded" and the ", " joining the parts.
    /// Whole-sentence templates instead, so a language can reorder the pieces
    /// and punctuate them its own way.
    private static func rowAccessibilityLabel(title: String, spokenDuration: String?, size: String) -> String {
        guard let spokenDuration else {
            return String(localized: "a11y.downloads.row",
                          defaultValue: "\(title), \(size), downloaded",
                          comment: "VoiceOver label for a row in the Downloads list when the episode has no known duration. Argument 1 is the episode title, 2 the size of the file on disk. Every row in this list is a downloaded episode.")
        }
        return String(localized: "a11y.downloads.rowWithDuration",
                      defaultValue: "\(title), \(spokenDuration), \(size), downloaded",
                      comment: "VoiceOver label for a row in the Downloads list. Argument 1 is the episode title, 2 its spoken duration such as '1 hour 5 minutes', 3 the size of the file on disk. Every row in this list is a downloaded episode.")
    }

    // MARK: - Formatting

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
