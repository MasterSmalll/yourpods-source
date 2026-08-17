import SwiftUI

/// Modal sheet for creating or editing an annotation (note).
///
/// Presented from PlayerView (add), ChapterListSheet (add w/ chapter context),
/// TranscriptListSheet (add w/ transcript context), and NotesView (edit).
struct AddEditNoteSheet: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - Input Context

    /// Episode metadata — required for creating a new note.
    let episodeUrl: String
    let podcastUrl: String
    var episodeGuid: String?
    var timestampSec: Double
    var podcastTitle: String?
    var episodeTitle: String?
    var artUrl: String?
    var durationSec: Double?
    var transcriptUrl: String?

    /// Pre-filled context from chapters or transcript.
    var chapterTitle: String?
    var chapterStartSec: Double?
    var transcriptText: String?
    var transcriptStartSec: Double?
    var transcriptEndSec: Double?

    /// Existing annotation to edit (nil = create new).
    var existingAnnotation: Annotation?

    // MARK: - State

    @State private var noteText: String = ""
    @State private var selectedColor: String? = nil
    @State private var tagsText: String = ""

    /// `name` is the **stored** colour identifier — it is compared against
    /// `selectedColor` and persisted with the note, so it must never be
    /// localized (same rule as `WireString`). The spoken label is a separate
    /// value; see `colorLabel(for:)`.
    private let colorOptions: [(name: String, color: Color)] = [
        ("blue", .blue),
        ("green", .green),
        ("purple", .purple),
        ("yellow", .yellow),
        ("red", .red),
    ]

    /// VoiceOver name for a note colour.
    ///
    /// Previously the stored identifier was used directly as the
    /// accessibility label, so VoiceOver read the lowercase wire value
    /// ("blue") and it could never be translated. The identifier stays as it
    /// is on disk; only what is spoken changes.
    private static func colorLabel(for name: String) -> String {
        switch name {
        case "blue":   return String(localized: "a11y.note.color.blue",   defaultValue: "Blue",   comment: "VoiceOver name of a note highlight colour.")
        case "green":  return String(localized: "a11y.note.color.green",  defaultValue: "Green",  comment: "VoiceOver name of a note highlight colour.")
        case "purple": return String(localized: "a11y.note.color.purple", defaultValue: "Purple", comment: "VoiceOver name of a note highlight colour.")
        case "yellow": return String(localized: "a11y.note.color.yellow", defaultValue: "Yellow", comment: "VoiceOver name of a note highlight colour.")
        case "red":    return String(localized: "a11y.note.color.red",    defaultValue: "Red",    comment: "VoiceOver name of a note highlight colour.")
        default:       return name
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Context header
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if let episodeTitle {
                            Text(episodeTitle)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                        }
                        Text(formatTime(timestampSec))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                // Chapter / Transcript context
                if chapterTitle != nil || transcriptText != nil {
                    Section {
                        if let chapterTitle {
                            Label(chapterTitle, systemImage: "book.pages")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let transcriptText {
                            // Feed-supplied transcript text — quoted, never translated.
                            Text(verbatim: transcriptText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                    } header: {
                        Text("Context")
                    }
                }

                // Note text
                Section {
                    TextEditor(text: $noteText)
                        .frame(minHeight: 100)
                        .accessibilityLabel("Note text")
                } header: {
                    Text("Note")
                }

                // Color
                Section {
                    HStack(spacing: 12) {
                        // "None" option
                        Button {
                            selectedColor = nil
                        } label: {
                            Circle()
                                .strokeBorder(selectedColor == nil ? Color.primary : Color.gray.opacity(0.3), lineWidth: 2)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if selectedColor == nil {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("No color")

                        ForEach(colorOptions, id: \.name) { option in
                            Button {
                                selectedColor = option.name
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if selectedColor == option.name {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Self.colorLabel(for: option.name))
                            .accessibilityAddTraits(selectedColor == option.name ? .isSelected : [])
                        }
                    }
                } header: {
                    Text("Color")
                }

                // Tags
                Section {
                    TextField("tag1, tag2, tag3", text: $tagsText)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .accessibilityLabel("Tags")
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Comma-separated. Tags are normalized to lowercase.")
                }

                // Clip range — stubbed
                Section {
                    HStack {
                        Label("Clip Range", systemImage: "waveform.badge.minus")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Coming Soon")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle(existingAnnotation != nil ? "Edit Note" : "Add Note")
            #if os(iOS)
            .inlineNavigationBarTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveNote()
                        dismiss()
                    }
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let existing = existingAnnotation {
                    noteText = existing.noteText
                    selectedColor = existing.color
                    tagsText = existing.tags.joined(separator: ", ")
                }
            }
        }
    }

    // MARK: - Save

    private func saveNote() {
        let trimmedText = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let parsedTags = tagsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let service = podcastManager.annotationService else { return }

        if let existing = existingAnnotation {
            service.updateAnnotation(
                id: existing.annotationId,
                noteText: trimmedText,
                color: selectedColor,
                tags: parsedTags
            )
        } else {
            _ = service.createAnnotation(
                episodeUrl: episodeUrl,
                podcastUrl: podcastUrl,
                episodeGuid: episodeGuid,
                timestampSec: timestampSec,
                noteText: trimmedText,
                chapterTitle: chapterTitle,
                chapterStartSec: chapterStartSec,
                transcriptText: transcriptText,
                transcriptStartSec: transcriptStartSec,
                transcriptEndSec: transcriptEndSec,
                color: selectedColor,
                tags: parsedTags,
                podcastTitle: podcastTitle,
                episodeTitle: episodeTitle,
                artUrl: artUrl,
                durationSec: durationSec,
                transcriptUrl: transcriptUrl
            )
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        DurationFormatting.timestamp(seconds)
    }
}
