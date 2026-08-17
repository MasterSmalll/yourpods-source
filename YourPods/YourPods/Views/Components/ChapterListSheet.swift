import SwiftUI

/// Sheet displaying the chapter list for the current episode.
/// Highlights the current chapter and allows seeking to any chapter start.
struct ChapterListSheet: View {
    let chapters: [Chapter]
    let currentPosition: TimeInterval
    let onSeek: (Chapter) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @State private var noteChapter: Chapter? = nil
    
    /// Index of the chapter currently playing.
    private var currentIndex: Int? {
        chapters.lastIndex(where: { $0.startTime <= currentPosition })
    }
    
    /// Whether any row's artwork slot should be reserved at all. Checked
    /// once per `body` evaluation (below), not per row: reading it from
    /// inside `chapterRow`/`chapterImage` instead would re-scan the whole
    /// `chapters` array once per row, turning one O(n) scan into O(n²).
    ///
    /// Checks raw `Chapter` fields rather than `ChapterArtworkView.
    /// source(for:)` deliberately — `source(for:)` calls
    /// `ChapterArtworkStore.image(forKey:)`, the same synchronous
    /// disk-touching store lookup `ChapterArtworkView` moved off its own
    /// `body` path (see its doc comments) to avoid repeating it on every
    /// re-evaluation. Calling it here, once per chapter, on every
    /// `ChapterListSheet` body evaluation (which happens on every
    /// position-tick while this sheet is open, since `currentIndex` reads
    /// `currentPosition`) would reintroduce that same class of cost, just
    /// relocated up a level. A metadata-only check — does this chapter have
    /// *any* image field set — is sufficient for a layout decision and
    /// never touches the cache or disk.
    ///
    /// Not `private`, and `static`: it reads no instance state (only its
    /// `chapters` parameter), and `ChapterArtworkViewTests` exercises it
    /// directly with literal chapter arrays to pin the layout decision
    /// without needing to render `ChapterListSheet` itself (which would
    /// need `PodcastManager`/`PlayerManager` injected — see the wiring
    /// tests' doc comment).
    static func anyChapterHasArt(in chapters: [Chapter]) -> Bool {
        chapters.contains { $0.embeddedImageKey != nil || !($0.img ?? "").isEmpty }
    }

    var body: some View {
        // Computed once here, not inside chapterRow/chapterImage — see
        // anyChapterHasArt's doc comment.
        let showsArtSlot = Self.anyChapterHasArt(in: chapters)
        NavigationStack {
            List {
                // `id: \.offset`, not `\.element.id` — `Chapter.id` is
                // `startTime`, and two chapters can legitimately share a
                // start time (the extractor has an explicit tie-break for
                // this case; see ChapterCoordinatorTests
                // .test_currentIndex_tieBreaksTowardLaterDeclaredChapter_whenStartTimesMatch).
                // Equal-`id` rows collide as ForEach identities. The array
                // index is unique per render and carries no other meaning,
                // so it's a safe substitute here.
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    chapterRow(chapter: chapter, isCurrent: index == currentIndex, showsArtSlot: showsArtSlot)
                }
            }
            .navigationTitle("Chapters")
            #if os(iOS)
            .inlineNavigationBarTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if os(macOS)
            .frame(minWidth: 450, minHeight: 400)
            #endif
        }
        .sheet(item: $noteChapter) { chapter in
            if let item = playerManager.audioManager.currentItem {
                AddEditNoteSheet(
                    episodeUrl: item.audioUrl,
                    podcastUrl: item.podcastUrl,
                    episodeGuid: item.id,
                    timestampSec: chapter.startTime,
                    podcastTitle: item.podcastTitle,
                    episodeTitle: item.title,
                    artUrl: item.artworkUrl,
                    durationSec: playerManager.currentDuration > 0 ? playerManager.currentDuration : nil,
                    transcriptUrl: item.transcriptUrl,
                    chapterTitle: chapter.title,
                    chapterStartSec: chapter.startTime
                )
                .environment(podcastManager)
                .presentationDetents([.medium, .large])
            }
        }
    }
    
    // MARK: - Chapter Row
    
    @ViewBuilder
    private func chapterRow(chapter: Chapter, isCurrent: Bool, showsArtSlot: Bool) -> some View {
        Button {
            onSeek(chapter)
        } label: {
            HStack(spacing: 12) {
                if showsArtSlot {
                    chapterImage(chapter: chapter)
                }

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
        .contextMenu {
            Button {
                noteChapter = chapter
            } label: {
                Label("Add Note", systemImage: "note.text.badge.plus")
            }
        }
    }
    
    @ViewBuilder
    private func chapterImage(chapter: Chapter) -> some View {
        ChapterArtworkView(chapter: chapter, size: 40, cornerRadius: 4)
            // Decorative here: the row's title and timestamp already carry
            // the information, so a label would make VoiceOver read it
            // twice. The standalone player artwork gets a real label.
            .accessibilityHidden(true)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        DurationFormatting.timestamp(seconds)
    }
}
