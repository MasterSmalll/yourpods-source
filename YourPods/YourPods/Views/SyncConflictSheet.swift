import SwiftUI

/// Sheet that presents unresolved sync conflicts for user resolution.
/// Shown when the sync conflict strategy is set to "Ask".
struct SyncConflictSheet: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your device and server have different playback positions for these episodes. Choose which position to keep.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                
                ForEach(playerManager.pendingConflicts) { conflict in
                    ConflictRow(conflict: conflict) { resolution in
                        resolveConflict(conflict, resolution: resolution)
                    }
                }
            }
            .navigationTitle("Sync Conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Use All Device") {
                        resolveAll(resolution: .device)
                    }
                    Spacer()
                    Button("Use All Server") {
                        resolveAll(resolution: .server)
                    }
                }
            }
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
        
        // Update episode progress
        podcastManager.updateEpisodeProgressByGuid(
            episodeGuid: conflict.episodeGuid,
            position: position
        )
        
        // Remove from pending list
        playerManager.pendingConflicts.removeAll { $0.id == conflict.id }
        
        if playerManager.pendingConflicts.isEmpty {
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
            
            podcastManager.updateEpisodeProgressByGuid(
                episodeGuid: conflict.episodeGuid,
                position: position
            )
        }
        
        playerManager.pendingConflicts.removeAll()
        dismiss()
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
        VStack(alignment: .leading, spacing: 8) {
            if let title = conflict.episodeTitle {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
            }
            
            if let podcast = conflict.podcastTitle {
                Text(podcast)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(formatDuration(conflict.localPosition))
                        .font(.subheadline.monospacedDigit())
                }
                
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.tertiary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(formatDuration(conflict.serverPosition))
                        .font(.subheadline.monospacedDigit())
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button {
                        onResolve(.device)
                    } label: {
                        Image(systemName: "iphone")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        onResolve(.server)
                    } label: {
                        Image(systemName: "cloud")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
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
