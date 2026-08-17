import SwiftUI

/// Full notes browser. Navigable from Library's toolbar.
///
/// Lists all annotations grouped by episode, sorted newest-first.
/// Supports tag filtering, swipe-to-delete, export (Markdown, Obsidian),
/// and tap-to-edit.
struct NotesView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTag: String? = nil
    @State private var editingAnnotation: Annotation? = nil
    @State private var showExportSheet = false
    @State private var exportURL: URL? = nil
    @State private var isSyncingNextcloud = false
    @State private var nextcloudSyncMessage: String? = nil

    private var annotationService: AnnotationService {
        podcastManager.annotationService
    }

    private var annotations: [Annotation] {
        annotationService.getAllAnnotations(filterTag: selectedTag)
    }

    /// Group annotations by episodeUrl, ordered by most-recent annotation first.
    private var groupedByEpisode: [(episodeUrl: String, episodeTitle: String, podcastTitle: String, artUrl: String?, annotations: [Annotation])] {
        let grouped = Dictionary(grouping: annotations) { $0.episodeUrl }
        return grouped.map { (url, notes) in
            let sorted = notes.sorted { $0.timestampSec < $1.timestampSec }
            let first = sorted.first
            return (
                episodeUrl: url,
                episodeTitle: first?.episodeTitle ?? url,
                podcastTitle: first?.podcastTitle ?? "",
                artUrl: first?.artUrl,
                annotations: sorted
            )
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.annotations.map(\.updatedAt).max() ?? .distantPast
            let rhsDate = rhs.annotations.map(\.updatedAt).max() ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private var allTags: [String] {
        annotationService.getAllTags()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tag filter bar
            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        tagPill(label: "All", tag: nil)
                        ForEach(allTags, id: \.self) { tag in
                            tagPill(label: "#\(tag)", tag: tag)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }

            if annotations.isEmpty {
                ContentUnavailableView(
                    selectedTag != nil ? "No Notes with #\(selectedTag!)" : "No Notes Yet",
                    systemImage: "note.text",
                    description: Text(selectedTag != nil
                        ? "Try removing the tag filter."
                        : "Add a note while listening to an episode.")
                )
            } else {
                List {
                    ForEach(groupedByEpisode, id: \.episodeUrl) { group in
                        Section {
                            ForEach(group.annotations, id: \.annotationId) { annotation in
                                noteRow(annotation)
                            }
                            .onDelete { indexSet in
                                for idx in indexSet {
                                    let annotation = group.annotations[idx]
                                    annotationService.deleteAnnotation(id: annotation.annotationId)
                                }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                if let artUrl = group.artUrl {
                                    CachedAsyncImage(url: URL(string: artUrl)) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                                    }
                                    .frame(width: 24, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }

                                VStack(alignment: .leading, spacing: 0) {
                                    Text(group.episodeTitle)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(group.podcastTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Notes")
        #if os(iOS)
        .inlineNavigationBarTitle()
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        exportMarkdown()
                    } label: {
                        Label("Export Markdown", systemImage: "doc.text")
                    }
                    .disabled(annotations.isEmpty)

                    if NotesExportService.canOpenObsidian() || settings.obsidianExportMode == .shareSheet {
                        Button {
                            openInObsidian()
                        } label: {
                            switch settings.obsidianExportMode {
                            case .perEpisode:
                                Label("Export to Obsidian", systemImage: "link")
                            case .dailyNote:
                                Label("Append to Daily Note", systemImage: "calendar")
                            case .shareSheet:
                                Label("Export .md Files", systemImage: "doc.on.doc")
                            }
                        }
                        .disabled(annotations.isEmpty)
                    }

                    if isNextcloudProfile {
                        Divider()

                        Button {
                            Task { await syncToNextcloud() }
                        } label: {
                            Label(
                                isSyncingNextcloud ? "Syncing…" : "Sync to Nextcloud",
                                systemImage: "cloud.fill"
                            )
                        }
                        .disabled(annotations.isEmpty || isSyncingNextcloud)
                    }
                } label: {
                    if isSyncingNextcloud {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(annotations.isEmpty && !isSyncingNextcloud)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = nextcloudSyncMessage {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityLabel(message)
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { nextcloudSyncMessage = nil }
                        }
                    }
            }
        }
        .sheet(item: $editingAnnotation) { annotation in
            AddEditNoteSheet(
                episodeUrl: annotation.episodeUrl,
                podcastUrl: annotation.podcastUrl,
                episodeGuid: annotation.episodeGuid,
                timestampSec: annotation.timestampSec,
                podcastTitle: annotation.podcastTitle,
                episodeTitle: annotation.episodeTitle,
                artUrl: annotation.artUrl,
                durationSec: annotation.durationSec,
                transcriptUrl: annotation.transcriptUrl,
                chapterTitle: annotation.chapterTitle,
                chapterStartSec: annotation.chapterStartSec,
                transcriptText: annotation.transcriptText,
                transcriptStartSec: annotation.transcriptStartSec,
                transcriptEndSec: annotation.transcriptEndSec,
                existingAnnotation: annotation
            )
            .environment(podcastManager)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showExportSheet) {
            if let url = exportURL {
                ShareSheet(url: url)
            }
        }
    }

    // MARK: - Note Row

    @ViewBuilder
    private func noteRow(_ annotation: Annotation) -> some View {
        Button {
            editingAnnotation = annotation
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Color dot
                if let colorName = annotation.color {
                    Circle()
                        .fill(colorForName(colorName))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(annotation.noteText)
                        .font(.subheadline)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Text(formatTime(annotation.timestampSec))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        if !annotation.tags.isEmpty {
                            Text(annotation.tags.map { "#\($0)" }.joined(separator: " "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        if annotation.isDirty {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("Not synced")
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Note at \(formatTime(annotation.timestampSec)): \(annotation.noteText)")
    }

    // MARK: - Tag Pill

    private func tagPill(label: String, tag: String?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTag = tag
            }
        } label: {
            Text(label)
                .font(.subheadline.weight(selectedTag == tag ? .bold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    selectedTag == tag
                        ? Color.accentColor.opacity(0.15)
                        : Color.gray.opacity(0.1)
                )
                .foregroundColor(selectedTag == tag ? .accentColor : .primary)
                .clipShape(Capsule())
        }
        .accessibilityLabel(tag == nil ? "All notes" : "Filter by tag \(label)")
        .accessibilityAddTraits(selectedTag == tag ? .isSelected : [])
    }

    // MARK: - Export

    private func exportMarkdown() {
        let markdown = NotesExportService.exportAsMarkdown(annotations: annotations)
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("yourpods_notes.md")
        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showExportSheet = true
        } catch {
            // Silently fail
        }
    }

    private func openInObsidian() {
        let vaultName = settings.obsidianVaultName.isEmpty ? "YourPods" : settings.obsidianVaultName

        switch settings.obsidianExportMode {
        case .perEpisode:
            // Open one note per episode (uses first episode in current view)
            if let url = NotesExportService.obsidianPerEpisodeURI(
                notes: annotations,
                vaultName: vaultName
            ) {
                #if os(iOS)
                UIApplication.shared.open(url)
                #endif
            }

        case .dailyNote:
            if let url = NotesExportService.obsidianDailyNoteURI(
                notes: annotations,
                vaultName: vaultName
            ) {
                #if os(iOS)
                UIApplication.shared.open(url)
                #endif
            }

        case .shareSheet:
            let files = NotesExportService.exportPerEpisodeFiles(annotations: annotations)
            guard !files.isEmpty else { return }
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("YourPodsNotes", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            // Write first file and present share sheet
            let first = files[0]
            let fileURL = tempDir.appendingPathComponent(first.filename)
            do {
                try first.content.write(to: fileURL, atomically: true, encoding: .utf8)
                exportURL = fileURL
                showExportSheet = true
            } catch {
                // Silently fail
            }
        }
    }

    // MARK: - Nextcloud Sync

    /// Whether the active profile is a Nextcloud/gPodder type (not gpodder.net, not YourPods Pro).
    private var isNextcloudProfile: Bool {
        settings.activeProfile?.profileType == .gpodder
    }

    private func syncToNextcloud() async {
        guard let profile = settings.activeProfile,
              profile.profileType == .gpodder,
              let baseUrl = profile.baseUrl,
              let username = profile.username,
              let password = KeychainHelper.shared.password(forProfileId: profile.id) else {
            withAnimation { nextcloudSyncMessage = "❌ Nextcloud credentials not found" }
            return
        }

        isSyncingNextcloud = true

        switch settings.nextcloudNotesMode {
        case .webdav:
            let folder = settings.nextcloudNotesFolder
            let result = await NextcloudNotesService.syncToNextcloud(
                annotations: annotations,
                baseUrl: baseUrl,
                username: username,
                password: password,
                folder: folder
            )
            isSyncingNextcloud = false

            withAnimation {
                if result.failed == 0 {
                    nextcloudSyncMessage = String(localized: "notes.sync.nextcloud.success",
                                                  defaultValue: "✅ Synced \(result.uploaded) episodes to Nextcloud",
                                                  comment: "Confirmation after exporting notes to Nextcloud. Plural variations live in the catalog.")
                } else {
                    nextcloudSyncMessage = String(localized: "notes.sync.partialFailure",
                                                  defaultValue: "⚠️ \(result.uploaded) synced, \(result.failed) failed",
                                                  comment: "Result when some note exports failed. First argument is the success count, second the failure count.")
                }
            }

        case .notesApi:
            let result = await NextcloudNotesAPIService.syncToNextcloud(
                annotations: annotations,
                baseUrl: baseUrl,
                username: username,
                password: password
            )
            isSyncingNextcloud = false

            withAnimation {
                let total = result.created + result.updated
                if result.failed == 0 {
                    nextcloudSyncMessage = String(localized: "notes.sync.notesApi.success",
                                                  defaultValue: "✅ Synced \(total) episodes to Nextcloud Notes",
                                                  comment: "Confirmation after syncing notes through the Nextcloud Notes API. Plural variations live in the catalog.")
                } else {
                    nextcloudSyncMessage = String(localized: "notes.sync.partialFailure",
                                                  defaultValue: "⚠️ \(total) synced, \(result.failed) failed",
                                                  comment: "Result when some note exports failed. First argument is the success count, second the failure count.")
                }
            }
        }
    }

    // MARK: - Helpers

    private func colorForName(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "green": return .green
        case "purple": return .purple
        case "yellow": return .yellow
        case "red": return .red
        default: return .gray
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        DurationFormatting.timestamp(seconds)
    }
}

// MARK: - Annotation Identifiable Conformance (for sheet(item:))

extension Annotation: Identifiable {
    public var id: String { annotationId }
}
