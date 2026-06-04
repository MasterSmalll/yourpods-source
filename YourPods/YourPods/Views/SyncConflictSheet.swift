import SwiftUI

/// Sheet that presents unresolved sync conflicts for user resolution.
/// Shown when the sync conflict strategy is set to "Ask".
struct SyncConflictSheet: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    
    @Environment(\.dismiss) private var dismiss
    
    /// Whether any conflict has been seen more than once (triggers the info banner).
    private var hasRecurringConflicts: Bool {
        playerManager.pendingConflicts.contains { $0.occurrenceCount > 1 }
    }
    
    private var hasPositionConflicts: Bool {
        !playerManager.pendingConflicts.isEmpty
    }
    
    private var hasUrlRewrites: Bool {
        !playerManager.pendingUrlRewrites.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Position conflicts
                if hasPositionConflicts {
                    Section {
                        Text("Your device and server have different playback positions for these episodes. Choose which position to keep.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    
                    // Show info banner when conflicts keep reappearing
                    if hasRecurringConflicts {
                        Section {
                            Label {
                                Text("Recurring conflicts are usually caused by other podcast clients (e.g. gPodder) updating the same server. Each client writes its own position, causing repeated mismatches.")
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                            .listRowBackground(Color.blue.opacity(0.08))
                        }
                    }
                    
                    ForEach(playerManager.pendingConflicts) { conflict in
                        ConflictRow(conflict: conflict) { resolution in
                            resolveConflict(conflict, resolution: resolution)
                        }
                    }
                }
                
                // URL rewrite conflicts
                if hasUrlRewrites {
                    Section {
                        Text("The server has rewritten these feed URLs. Accept to update locally, or keep your current URLs.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    
                    ForEach(playerManager.pendingUrlRewrites) { rewrite in
                        URLRewriteRow(rewrite: rewrite) { accepted in
                            resolveUrlRewrite(rewrite, accepted: accepted)
                        }
                    }
                }
            }
            .navigationTitle("Sync Conflicts")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") { dismiss() }
                }
                if hasPositionConflicts {
                    #if os(iOS)
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            resolveAll(resolution: .device)
                        } label: {
                            Label("Use All Device", systemImage: "iphone")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        Spacer()
                        Button {
                            resolveAll(resolution: .server)
                        } label: {
                            Label("Use All Server", systemImage: "cloud")
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                    }
                    #else
                    ToolbarItemGroup(placement: .automatic) {
                        Button {
                            resolveAll(resolution: .device)
                        } label: {
                            Label("Use All Device", systemImage: "iphone")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        Button {
                            resolveAll(resolution: .server)
                        } label: {
                            Label("Use All Server", systemImage: "cloud")
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                    }
                    #endif
                }
            }
            #if os(macOS)
            .frame(minWidth: 550, minHeight: 450)
            #endif
        }
    }
    
    private func resolveConflict(_ conflict: SyncConflict, resolution: ConflictResolution) {
        let position: Int
        switch resolution {
        case .device:
            position = conflict.localPosition
        case .server:
            position = conflict.serverPosition
        }
        
        // Resolve via PodcastManager — updates local model, actionMap, AND uploads to server
        podcastManager.resolveConflict(conflict, chosenPosition: position)
        
        // If the resolved episode is currently playing, seek the player to the chosen position
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: position)
        
        // Also resolve for queue items — updates QueueItem position and pushes to server
        playerManager.resolveQueueConflict(conflict, chosenPosition: position)
        
        // Remove from pending list
        playerManager.pendingConflicts.removeAll { $0.id == conflict.id }
        
        if playerManager.pendingConflicts.isEmpty && playerManager.pendingUrlRewrites.isEmpty {
            dismiss()
        }
    }
    
    private func resolveAll(resolution: ConflictResolution) {
        for conflict in playerManager.pendingConflicts {
            let position: Int
            switch resolution {
            case .device:
                position = conflict.localPosition
            case .server:
                position = conflict.serverPosition
            }
            
            podcastManager.resolveConflict(conflict, chosenPosition: position)
            
            // If the resolved episode is currently playing, seek the player to the chosen position
            playerManager.resolveConflictIfPlaying(conflict, chosenPosition: position)
            
            // Also resolve for queue items
            playerManager.resolveQueueConflict(conflict, chosenPosition: position)
        }
        
        playerManager.pendingConflicts.removeAll()
        if playerManager.pendingUrlRewrites.isEmpty {
            dismiss()
        }
    }
    
    private func resolveUrlRewrite(_ rewrite: URLRewriteConflict, accepted: Bool) {
        if accepted {
            podcastManager.acceptUrlRewrite(rewrite)
        } else {
            podcastManager.rejectUrlRewrite(rewrite)
        }
        
        playerManager.pendingUrlRewrites.removeAll { $0.id == rewrite.id }
        
        if playerManager.pendingConflicts.isEmpty && playerManager.pendingUrlRewrites.isEmpty {
            dismiss()
        }
    }
}

// MARK: - Conflict Resolution Type

enum ConflictResolution {
    case device
    case server
}

// MARK: - Conflict Row

private struct ConflictRow: View {
    let conflict: SyncConflict
    let onResolve: (ConflictResolution) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Episode info with album art
            HStack(alignment: .top, spacing: 12) {
                // Album art
                CachedAsyncImage(url: URL(string: conflict.artworkUrl ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tertiary)
                        }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 3) {
                    if let title = conflict.episodeTitle {
                        Text(title)
                            .font(.headline)
                            .lineLimit(2)
                    } else {
                        Text(conflict.episodeGuid)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let podcast = conflict.podcastTitle {
                        Text(podcast)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    // Occurrence count badge
                    if conflict.occurrenceCount > 1 {
                        Text("Seen \(conflict.occurrenceCount) times")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            
            // Position comparison
            HStack(spacing: 0) {
                // Device position
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Device")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(formatDuration(conflict.localPosition))
                            .font(.subheadline.monospacedDigit().weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                // Server position
                HStack(spacing: 6) {
                    Image(systemName: "cloud")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Server")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(formatDuration(conflict.serverPosition))
                            .font(.subheadline.monospacedDigit().weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Resolution buttons
            HStack(spacing: 10) {
                Button {
                    onResolve(.device)
                } label: {
                    Label("Use Device", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .controlSize(.small)
                
                Button {
                    onResolve(.server)
                } label: {
                    Label("Use Server", systemImage: "cloud")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - URL Rewrite Row

private struct URLRewriteRow: View {
    let rewrite: URLRewriteConflict
    let onResolve: (Bool) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CachedAsyncImage(url: URL(string: rewrite.artworkUrl ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "link")
                                .foregroundStyle(.tertiary)
                        }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    if let title = rewrite.podcastTitle {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    
                    Label {
                        Text("Server rewrote feed URL")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Old:")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(rewrite.oldUrl)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("New:")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                    Text(rewrite.newUrl)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                }
            }
            
            HStack(spacing: 10) {
                Button {
                    onResolve(true)
                } label: {
                    Label("Accept", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
                
                Button {
                    onResolve(false)
                } label: {
                    Label("Keep Local", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}
