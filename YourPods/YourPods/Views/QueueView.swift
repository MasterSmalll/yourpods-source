import SwiftUI

/// "Up Next" queue view with now playing, reorderable queue, episode dates, and % listened.
struct QueueView: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(PodcastManager.self) private var podcastManager
    @AppStorage("hasSeenQueueMessage") private var hasSeenQueueMessage = false
    @State private var showDismissableMessage = true
    @State private var itemToRemove: QueueItem?
    @State private var showRemovalDialog = false
    @State private var rememberChoice = false
    @State private var showSettings = false
    @State private var selectedEpisode: Episode?
    @State private var showRemoveAllConfirmation = false
    
    /// Resolve the Episode model from a QueueItem GUID (same pattern as NowPlayingBar).
    private func resolveEpisode(for item: QueueItem) -> Episode? {
        for podcast in podcastManager.subscriptions {
            if let ep = podcast.episodes.first(where: { $0.guid == item.id }) {
                return ep
            }
        }
        return nil
    }
    
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
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let ep = resolveEpisode(for: current) {
                                    selectedEpisode = ep
                                }
                            }
                            .contextMenu {
                                Button {
                                    if let ep = resolveEpisode(for: current) {
                                        selectedEpisode = ep
                                    }
                                } label: {
                                    Label("Details", systemImage: "info.circle")
                                }
                                Divider()
                                Button {
                                    playerManager.markCurrentEpisodeAsPlayed()
                                } label: {
                                    Label("Mark as Played", systemImage: "checkmark.circle")
                                }
                            }
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
                                    .contextMenu {
                                        Button {
                                            Task {
                                                await playerManager.audioManager.playEpisode(
                                                    item,
                                                    initialPosition: TimeInterval(item.positionSeconds),
                                                    preserveCurrent: true
                                                )
                                            }
                                        } label: {
                                            Label("Play", systemImage: "play.fill")
                                        }
                                        Button {
                                            playerManager.audioManager.moveToTop(item)
                                        } label: {
                                            Label("Play Next", systemImage: "text.insert")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            handleRemoveItem(item)
                                        } label: {
                                            Label("Remove from Queue", systemImage: "minus.circle")
                                        }
                                        Button {
                                            playerManager.markQueuedEpisodeAsPlayed(item)
                                        } label: {
                                            Label("Mark as Played", systemImage: "checkmark.circle")
                                        }
                                    }
                            }
                            .onDelete { indexSet in
                                // Convert IndexSet to items and handle removal
                                for idx in indexSet {
                                    let item = upcoming[idx]
                                    handleRemoveItem(item)
                                }
                            }
                            .onMove { from, to in
                                playerManager.audioManager.moveQueueItems(from: from, to: to)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    _ = await podcastManager.refreshAllFeeds()
                }
            }
            .navigationTitle("Up Next")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
                ToolbarItem(placement: .secondaryAction) {
                    if !playerManager.audioManager.queue.isEmpty {
                        Button(role: .destructive) {
                            showRemoveAllConfirmation = true
                        } label: {
                            Label("Remove All", systemImage: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Queue Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    QueueSettingsSheet()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
            .sheet(item: $selectedEpisode) { episode in
                EpisodeDetailSheet(episode: episode)
            }
            .confirmationDialog(
                "Remove from Queue",
                isPresented: $showRemovalDialog,
                titleVisibility: .visible
            ) {
                Button("Remove") {
                    if let item = itemToRemove {
                        playerManager.audioManager.removeFromQueue(item)
                        if rememberChoice {
                            settingsManager.queueRemovalAction = .removeOnly
                            settingsManager.hasChosenQueueRemovalAction = true
                        }
                    }
                    itemToRemove = nil
                    rememberChoice = false
                }
                Button("Remove & Mark as Played") {
                    if let item = itemToRemove {
                        playerManager.audioManager.removeFromQueue(item)
                        podcastManager.markEpisodeAsPlayed(
                            podcastUrl: item.podcastUrl,
                            episodeGuid: item.id
                        )
                        if rememberChoice {
                            settingsManager.queueRemovalAction = .removeAndMarkPlayed
                            settingsManager.hasChosenQueueRemovalAction = true
                        }
                    }
                    itemToRemove = nil
                    rememberChoice = false
                }
                Button("Cancel", role: .cancel) {
                    itemToRemove = nil
                    rememberChoice = false
                }
            } message: {
                if !settingsManager.hasChosenQueueRemovalAction {
                    Text("What would you like to do? Your choice will be remembered. You can change this later in Settings → Queue Management.")
                } else {
                    Text("What would you like to do with this episode?")
                }
            }
            .confirmationDialog(
                "Remove All Episodes",
                isPresented: $showRemoveAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove All", role: .destructive) {
                    playerManager.audioManager.clearQueue()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all episodes from your Up Next queue. The currently playing episode will not be affected.")
            }
        }
    }
    
    /// Handle removing an item based on the user's queue removal preference.
    private func handleRemoveItem(_ item: QueueItem) {
        switch settingsManager.queueRemovalAction {
        case .removeOnly:
            playerManager.audioManager.removeFromQueue(item)
        case .removeAndMarkPlayed:
            playerManager.audioManager.removeFromQueue(item)
            podcastManager.markEpisodeAsPlayed(
                podcastUrl: item.podcastUrl,
                episodeGuid: item.id
            )
        case .ask:
            itemToRemove = item
            showRemovalDialog = true
        }
    }
}

// MARK: - Queue Settings Sheet

private struct QueueSettingsSheet: View {
    @Environment(SettingsManager.self) private var settings
    
    var body: some View {
        Form {
            Section {
                Picker("On Queue Removal", selection: Binding(
                    get: { settings.queueRemovalAction },
                    set: { settings.queueRemovalAction = $0 }
                )) {
                    Text("Just Remove").tag(QueueRemovalAction.removeOnly)
                    Text("Remove & Mark Played").tag(QueueRemovalAction.removeAndMarkPlayed)
                    Text("Always Ask").tag(QueueRemovalAction.ask)
                }
            } header: {
                Label("Queue Management", systemImage: "list.bullet")
            } footer: {
                Text("Choose what happens when you remove an episode from the Up Next queue.")
            }
        }
        .navigationTitle("Queue Settings")
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
