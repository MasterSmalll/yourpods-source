import SwiftUI

/// Blocking sheet shown on first auto-hide activation.
/// Shows per-podcast progress bar, current podcast title, and running count of hidden episodes.
struct AutoHideProgressSheet: View {
    let isComplete: Bool
    let currentPodcastTitle: String
    let currentIndex: Int
    let totalPodcasts: Int
    let hiddenCount: Int
    
    @Environment(\.dismiss) private var dismiss
    
    private var progress: Double {
        guard totalPodcasts > 0 else { return 0 }
        return Double(isComplete ? totalPodcasts : currentIndex) / Double(totalPodcasts)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "eye.slash.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(isComplete ? .green : .blue)
                .symbolEffect(.bounce, value: isComplete)
            
            Text(isComplete ? "Auto-Hide Complete" : "Scanning Library…")
                .font(.headline)
            
            if !isComplete {
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                    
                    Text("Processing podcast \(currentIndex + 1) of \(totalPodcasts)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if !currentPodcastTitle.isEmpty {
                        Text(currentPodcastTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    
                    if hiddenCount > 0 {
                        Text("\(hiddenCount) episodes auto-hidden so far")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if hiddenCount > 0 {
                    Text("Auto-hid \(hiddenCount) unplayed episodes. You can restore them from each podcast's detail page or from Settings → Auto-Hidden Episodes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("No episodes needed hiding — your library is already fresh!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isComplete ? "Auto-Hide Complete" : "Scanning library for old episodes")
        .presentationDetents([.medium])
        .interactiveDismissDisabled(!isComplete)
    }
}
