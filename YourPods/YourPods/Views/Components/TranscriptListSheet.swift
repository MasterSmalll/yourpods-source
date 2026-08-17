import SwiftUI

/// Sheet displaying the transcript for the current episode.
/// Highlights the current segment and allows seeking to any segment start.
/// Includes search to find text within the transcript.
struct TranscriptListSheet: View {
    let transcript: Transcript
    let currentPosition: TimeInterval
    let onSeek: (TranscriptItem) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    @State private var searchText = ""
    @State private var currentMatchIndex = 0
    @State private var noteTranscriptItem: TranscriptItem? = nil
    
    /// Index of the segment currently playing.
    private var currentIndex: Int? {
        transcript.items.lastIndex(where: { $0.start <= currentPosition && currentPosition < $0.end })
    }
    
    /// Indices of transcript items matching the search query.
    private var matchingIndices: [Int] {
        TranscriptSearchHelper.findMatches(query: searchText, in: transcript)
    }
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(transcript.items.enumerated()), id: \.element.id) { index, item in
                            let isMatch = matchingIndices.contains(index)
                            let isCurrentMatch = !matchingIndices.isEmpty
                                && currentMatchIndex < matchingIndices.count
                                && matchingIndices[currentMatchIndex] == index
                            
                            transcriptRow(
                                item: item,
                                isCurrent: index == currentIndex,
                                isMatch: isMatch,
                                isCurrentMatch: isCurrentMatch
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: currentIndex) { _, newIndex in
                    // Only auto-scroll to playback position when not searching
                    if searchText.isEmpty, let newIndex, newIndex < transcript.items.count {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(transcript.items[newIndex].id, anchor: .center)
                        }
                    }
                }
                .onChange(of: currentMatchIndex) { _, _ in
                    scrollToCurrentMatch(proxy: proxy)
                }
                .onChange(of: matchingIndices) { _, newMatches in
                    // Reset to first match when search results change
                    currentMatchIndex = 0
                    if !newMatches.isEmpty {
                        scrollToCurrentMatch(proxy: proxy)
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
            .inlineNavigationBarTitle()
            #endif
            .searchable(text: $searchText, prompt: "Search transcript")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                
                // Match navigation — shown when there are search results
                if !matchingIndices.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        HStack(spacing: 8) {
                            Text("\(currentMatchIndex + 1) of \(matchingIndices.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Match \(currentMatchIndex + 1) of \(matchingIndices.count)")
                            
                            Button {
                                currentMatchIndex = TranscriptSearchHelper.previousMatchIndex(
                                    current: currentMatchIndex,
                                    totalMatches: matchingIndices.count
                                )
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.caption.weight(.semibold))
                            }
                            .accessibilityLabel("Previous match")
                            
                            Button {
                                currentMatchIndex = TranscriptSearchHelper.nextMatchIndex(
                                    current: currentMatchIndex,
                                    totalMatches: matchingIndices.count
                                )
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .accessibilityLabel("Next match")
                        }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 450, minHeight: 400)
            #endif
        }
        .sheet(item: $noteTranscriptItem) { item in
            if let queueItem = playerManager.audioManager.currentItem {
                AddEditNoteSheet(
                    episodeUrl: queueItem.audioUrl,
                    podcastUrl: queueItem.podcastUrl,
                    episodeGuid: queueItem.id,
                    timestampSec: item.start,
                    podcastTitle: queueItem.podcastTitle,
                    episodeTitle: queueItem.title,
                    artUrl: queueItem.artworkUrl,
                    durationSec: playerManager.currentDuration > 0 ? playerManager.currentDuration : nil,
                    transcriptUrl: queueItem.transcriptUrl,
                    transcriptText: item.text,
                    transcriptStartSec: item.start,
                    transcriptEndSec: item.end
                )
                .environment(podcastManager)
                .presentationDetents([.medium, .large])
            }
        }
    }
    
    // MARK: - Scroll to Match
    
    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard !matchingIndices.isEmpty,
              currentMatchIndex < matchingIndices.count else { return }
        let itemIndex = matchingIndices[currentMatchIndex]
        guard itemIndex < transcript.items.count else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(transcript.items[itemIndex].id, anchor: .center)
        }
    }
    
    // MARK: - Transcript Row
    
    @ViewBuilder
    private func transcriptRow(item: TranscriptItem, isCurrent: Bool, isMatch: Bool, isCurrentMatch: Bool) -> some View {
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
                    .foregroundStyle(foregroundColor(isCurrent: isCurrent, isMatch: isMatch, isCurrentMatch: isCurrentMatch))
                    .fontWeight(isCurrent || isCurrentMatch ? .semibold : .regular)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isCurrent: isCurrent, isMatch: isMatch, isCurrentMatch: isCurrentMatch))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                noteTranscriptItem = item
            } label: {
                Label("Add Note", systemImage: "note.text.badge.plus")
            }
        }
        .accessibilityLabel(String(localized: "a11y.transcript.cue",
                                   defaultValue: "\(formatTime(item.start)), \(item.text)",
                                   comment: "VoiceOver label for one transcript line. Argument 1 is the timecode it starts at, 2 the spoken text."))
        .accessibilityHint(isCurrentMatch ? "Current search match. Double tap to seek." : isMatch ? "Search match. Double tap to seek." : "Double tap to seek.")
    }
    
    // MARK: - Row Colors
    
    private func foregroundColor(isCurrent: Bool, isMatch: Bool, isCurrentMatch: Bool) -> Color {
        if isCurrentMatch { return .orange }
        if isMatch { return .orange.opacity(0.8) }
        if isCurrent { return .accentColor }
        return .primary
    }
    
    private func backgroundColor(isCurrent: Bool, isMatch: Bool, isCurrentMatch: Bool) -> Color {
        if isCurrentMatch { return .orange.opacity(0.15) }
        if isMatch { return .orange.opacity(0.06) }
        if isCurrent { return .accentColor.opacity(0.08) }
        return .clear
    }
    
    private func formatTime(_ seconds: Double) -> String {
        DurationFormatting.timestamp(seconds)
    }
}
