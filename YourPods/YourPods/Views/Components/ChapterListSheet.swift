import SwiftUI

/// Sheet displaying the chapter list for the current episode.
/// Highlights the current chapter and allows seeking to any chapter start.
struct ChapterListSheet: View {
    let chapters: [Chapter]
    let currentPosition: TimeInterval
    let onSeek: (Chapter) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    /// Index of the chapter currently playing.
    private var currentIndex: Int? {
        chapters.lastIndex(where: { $0.startTime <= currentPosition })
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    chapterRow(chapter: chapter, isCurrent: index == currentIndex)
                }
            }
            .navigationTitle("Chapters")
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
    
    // MARK: - Chapter Row
    
    @ViewBuilder
    private func chapterRow(chapter: Chapter, isCurrent: Bool) -> some View {
        Button {
            onSeek(chapter)
        } label: {
            HStack(spacing: 12) {
                chapterImage(chapter: chapter)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title)
                        .font(.subheadline)
                        .fontWeight(isCurrent ? .bold : .regular)
                        .foregroundColor(isCurrent ? .accentColor : .primary)
                        .lineLimit(2)
                    
                    Text(formatTime(chapter.startTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
    }
    
    @ViewBuilder
    private func chapterImage(chapter: Chapter) -> some View {
        if let imgUrl = chapter.img {
            AsyncImage(url: URL(string: imgUrl)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
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
