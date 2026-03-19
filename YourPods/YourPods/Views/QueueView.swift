import SwiftUI

/// "Up Next" queue view with now playing, reorderable queue, episode dates, and % listened.
struct QueueView: View {
    @Environment(PlayerManager.self) private var playerManager
    @AppStorage("hasSeenQueueMessage") private var hasSeenQueueMessage = false
    @State private var showDismissableMessage = true
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // First-time message
                if !hasSeenQueueMessage && showDismissableMessage {
                    QueueInfoBanner {
                        withAnimation {
                            hasSeenQueueMessage = true
                        }
                    }
                }
                
                List {
                    // Now Playing section
                    if let current = playerManager.audioManager.currentItem {
                        Section("Now Playing") {
                            QueueItemRow(
                                item: current,
                                isNowPlaying: true,
                                progress: playerManager.currentDuration > 0
                                    ? playerManager.currentPosition / playerManager.currentDuration
                                    : 0
                            )
                        }
                    }
                    
                    // Up Next section
                    let upcoming = playerManager.audioManager.queue
                    Section("Up Next (\(upcoming.count))") {
                        if upcoming.isEmpty {
                            ContentUnavailableView(
                                "Queue Empty",
                                systemImage: "text.append",
                                description: Text("Add episodes from your library or search.")
                            )
                        } else {
                            ForEach(upcoming) { item in
                                QueueItemRow(item: item)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        Task {
                                            await playerManager.audioManager.playEpisode(
                                                item,
                                                initialPosition: TimeInterval(item.positionSeconds),
                                                preserveCurrent: true
                                            )
                                        }
                                    }
                            }
                            .onDelete { indexSet in
                                // Convert IndexSet to items and remove them
                                for idx in indexSet {
                                    let item = upcoming[idx]
                                    playerManager.audioManager.removeFromQueue(item)
                                }
                            }
                            .onMove { from, to in
                                playerManager.audioManager.moveQueueItems(from: from, to: to)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Up Next")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
    }
}

// MARK: - Queue Info Banner

private struct QueueInfoBanner: View {
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Device-Only Queue")
                    .font(.subheadline.bold())
                Text("This queue exists only on this device. Episode progress will sync to the server if you're using a sync account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Queue Item Row

struct QueueItemRow: View {
    let item: QueueItem
    var isNowPlaying: Bool = false
    var progress: Double = 0
    
    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            AsyncImage(url: URL(string: item.artworkUrl ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.bold())
                    .foregroundColor(isNowPlaying ? .accentColor : .primary)
                    .lineLimit(2)
                
                Text(item.podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    // Publication date
                    if let pubDate = item.pubDate {
                        Text(pubDate, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    
                    // Duration / Remaining
                    if let duration = item.durationSeconds, duration > 0 {
                        if isNowPlaying {
                            let listened = Int(progress * 100)
                            Text("\(listened)% listened")
                                .font(.caption2.bold())
                                .foregroundColor(.accentColor)
                        } else if item.positionSeconds > 0 {
                            let remaining = duration - item.positionSeconds
                            Text("\(PlayerManager.formatDuration(TimeInterval(remaining))) left")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(PlayerManager.formatDuration(TimeInterval(duration)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            
            Spacer()
            
            if isNowPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
