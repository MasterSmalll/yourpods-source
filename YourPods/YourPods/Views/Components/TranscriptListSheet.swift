import SwiftUI

/// Sheet displaying the transcript for the current episode.
/// Highlights the current segment and allows seeking to any segment start.
struct TranscriptListSheet: View {
    let transcript: Transcript
    let currentPosition: TimeInterval
    let onSeek: (TranscriptItem) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    /// Index of the segment currently playing.
    private var currentIndex: Int? {
        transcript.items.lastIndex(where: { $0.start <= currentPosition && currentPosition < $0.end })
    }
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(transcript.items.enumerated()), id: \.element.id) { index, item in
                            transcriptRow(item: item, isCurrent: index == currentIndex)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: currentIndex) { _, newIndex in
                    if let newIndex, newIndex < transcript.items.count {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(transcript.items[newIndex].id, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    if let currentIndex, currentIndex < transcript.items.count {
                        proxy.scrollTo(transcript.items[currentIndex].id, anchor: .center)
                    }
                }
            }
            .navigationTitle("Transcript")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - Transcript Row
    
    @ViewBuilder
    private func transcriptRow(item: TranscriptItem, isCurrent: Bool) -> some View {
        Button {
            onSeek(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(formatTime(item.start))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 50, alignment: .trailing)
                
                Text(item.text)
                    .font(.subheadline)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }
}
