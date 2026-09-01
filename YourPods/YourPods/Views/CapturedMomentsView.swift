import SwiftUI

/// Phone history for hands-free podcast moments captured on Apple Watch.
struct CapturedMomentsView: View {
    @ObservedObject private var store = CapturedMomentStore.shared
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if store.moments.isEmpty {
                    ContentUnavailableView(
                        "No Captured Moments",
                        systemImage: "bookmark",
                        description: Text("Triple-tap your headphones while Podcast Marker is playing on Apple Watch. Captures sync here automatically when the Watch can reach this iPhone.")
                    )
                } else {
                    List(store.moments) { moment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(moment.podcastTitle)
                                .font(.headline)
                            Text(moment.episodeTitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            HStack(spacing: 12) {
                                Label(formatTimestamp(moment.timestampSec), systemImage: "clock")
                                Text(moment.capturedAt, format: .dateTime.day().month().hour().minute())
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("Moments")
            .toolbar {
                if !store.moments.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete all captured moments from this iPhone?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    store.clearAll()
                }
            }
        }
    }

    private func formatTimestamp(_ value: Double) -> String {
        let total = max(0, Int(value.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
