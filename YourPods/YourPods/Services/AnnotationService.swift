import Foundation
import SwiftData
import os

/// Core service for annotation (note) CRUD and sync orchestration.
///
/// All users get local notes. Pro users get cloud sync via
/// `POST /annotations/sync` + `GET /annotations?since=`.
@MainActor
final class AnnotationService {
    private let logger = Logger(subsystem: "com.yourpods", category: "annotations")
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - CRUD

    /// Create a new annotation. Marks as dirty for future sync push.
    func createAnnotation(
        episodeUrl: String,
        podcastUrl: String,
        episodeGuid: String? = nil,
        timestampSec: Double,
        noteText: String,
        chapterTitle: String? = nil,
        chapterStartSec: Double? = nil,
        transcriptText: String? = nil,
        transcriptStartSec: Double? = nil,
        transcriptEndSec: Double? = nil,
        color: String? = nil,
        tags: [String] = [],
        podcastTitle: String? = nil,
        episodeTitle: String? = nil,
        artUrl: String? = nil,
        episodeDescription: String? = nil,
        durationSec: Double? = nil,
        transcriptUrl: String? = nil
    ) -> Annotation {
        let annotation = Annotation(
            episodeUrl: episodeUrl,
            podcastUrl: podcastUrl,
            episodeGuid: episodeGuid,
            timestampSec: timestampSec,
            noteText: noteText,
            chapterTitle: chapterTitle,
            chapterStartSec: chapterStartSec,
            transcriptText: transcriptText,
            transcriptStartSec: transcriptStartSec,
            transcriptEndSec: transcriptEndSec,
            color: color,
            tags: tags.map { Self.normalizeTag($0) }.filter { !$0.isEmpty },
            isDirty: true,
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle,
            artUrl: artUrl,
            episodeDescription: episodeDescription,
            durationSec: durationSec,
            transcriptUrl: transcriptUrl
        )
        modelContext.insert(annotation)
        try? modelContext.save()
        logger.info("Created annotation \(annotation.annotationId) for episode \(episodeUrl)")
        return annotation
    }

    /// Update editable fields. Only `noteText`, `color`, and `tags` are
    /// editable — matches server PATCH behavior. Timestamp changes go
    /// through the batch sync push path (mark dirty → push).
    func updateAnnotation(id: String, noteText: String, color: String?, tags: [String]) {
        guard let annotation = fetchAnnotation(id: id) else {
            logger.warning("updateAnnotation: annotation \(id) not found")
            return
        }
        annotation.noteText = noteText
        annotation.color = color
        annotation.tags = tags.map { Self.normalizeTag($0) }.filter { !$0.isEmpty }
        annotation.updatedAt = Date()
        annotation.isDirty = true
        try? modelContext.save()
        logger.info("Updated annotation \(id)")
    }

    /// Soft-delete for tombstone propagation. The annotation remains in the
    /// store until sync confirms deletion, then `hardDeleteSyncedTombstones()`
    /// cleans it up.
    func deleteAnnotation(id: String) {
        guard let annotation = fetchAnnotation(id: id) else {
            logger.warning("deleteAnnotation: annotation \(id) not found")
            return
        }
        annotation.deleted = true
        annotation.isDirty = true
        annotation.updatedAt = Date()
        try? modelContext.save()
        logger.info("Soft-deleted annotation \(id)")
    }

    // MARK: - Queries

    /// All non-deleted annotations for a specific episode, sorted by timestamp.
    func getAnnotationsForEpisode(episodeUrl: String) -> [Annotation] {
        let predicate = #Predicate<Annotation> {
            $0.episodeUrl == episodeUrl && !$0.deleted
        }
        let descriptor = FetchDescriptor<Annotation>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestampSec)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// All non-deleted annotations, with optional tag filter, sorted by creation date (newest first).
    func getAllAnnotations(filterTag: String? = nil) -> [Annotation] {
        let predicate = #Predicate<Annotation> { !$0.deleted }
        let descriptor = FetchDescriptor<Annotation>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        var results = (try? modelContext.fetch(descriptor)) ?? []
        if let filterTag {
            results = results.filter { $0.tags.contains(filterTag) }
        }
        return results
    }

    /// All unique tags across non-deleted annotations.
    func getAllTags() -> [String] {
        let annotations = getAllAnnotations()
        var tagSet = Set<String>()
        for annotation in annotations {
            for tag in annotation.tags {
                tagSet.insert(tag)
            }
        }
        return tagSet.sorted()
    }

    /// Annotations that need sync push (`isDirty == true`).
    func dirtyAnnotations() -> [Annotation] {
        let predicate = #Predicate<Annotation> { $0.isDirty }
        let descriptor = FetchDescriptor<Annotation>(predicate: predicate)
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Count of unique episode URLs with annotations (for 100-episode limit display).
    func annotatedEpisodeCount() -> Int {
        let annotations = getAllAnnotations()
        return Set(annotations.map(\.episodeUrl)).count
    }

    /// Whether this is the first annotation for the given episode (no prior synced annotations).
    /// Determines whether to include a snapshot in the sync push.
    func needsSnapshot(for episodeUrl: String) -> Bool {
        let predicate = #Predicate<Annotation> {
            $0.episodeUrl == episodeUrl && $0.syncedAt != nil
        }
        let descriptor = FetchDescriptor<Annotation>(predicate: predicate)
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        return count == 0
    }

    // MARK: - Sync

    /// Apply a server delta response to the local store.
    /// Flattens `annotation.episode.*` into the denormalized snapshot fields.
    /// Tombstones (`deleted=true`, `annotation=nil`) trigger local soft-delete.
    func applyDelta(_ items: [AnnotationDeltaItem]) {
        var inserted = 0, updated = 0, tombstoned = 0, skippedNilBody = 0
        for item in items {
            if let existing = fetchAnnotation(id: item.id) {
                if item.deleted {
                    // Server tombstone → local soft-delete
                    existing.deleted = true
                    existing.isDirty = false
                    existing.syncedAt = Date()
                    tombstoned += 1
                } else if let body = item.annotation {
                    // Update existing annotation from server
                    existing.timestampSec = body.timestampSec
                    existing.noteText = body.noteText
                    existing.chapterTitle = body.chapterTitle
                    existing.chapterStartSec = body.chapterStartSec
                    existing.transcriptText = body.transcriptText
                    existing.transcriptStartSec = body.transcriptStartSec
                    existing.transcriptEndSec = body.transcriptEndSec
                    existing.color = body.color
                    existing.tags = body.tags ?? []
                    existing.isDirty = false
                    existing.syncedAt = Date()

                    // Flatten nested episode metadata
                    if let ep = body.episode {
                        if let url = ep.episodeUrl { existing.episodeUrl = url }
                        if let url = ep.podcastUrl { existing.podcastUrl = url }
                        existing.episodeTitle = ep.episodeTitle
                        existing.podcastTitle = ep.podcastTitle
                        existing.artUrl = ep.artUrl
                        existing.durationSec = ep.durationSec
                        existing.transcriptUrl = ep.transcriptUrl
                    }
                    updated += 1
                } else {
                    skippedNilBody += 1
                }
            } else if !item.deleted, let body = item.annotation {
                // New annotation from server
                let annotation = Annotation(
                    annotationId: body.id,
                    episodeUrl: item.episodeUrl ?? body.episode?.episodeUrl ?? "",
                    podcastUrl: body.episode?.podcastUrl ?? "",
                    timestampSec: body.timestampSec,
                    noteText: body.noteText,
                    chapterTitle: body.chapterTitle,
                    chapterStartSec: body.chapterStartSec,
                    transcriptText: body.transcriptText,
                    transcriptStartSec: body.transcriptStartSec,
                    transcriptEndSec: body.transcriptEndSec,
                    color: body.color,
                    tags: body.tags ?? [],
                    deleted: false,
                    isDirty: false,
                    syncedAt: Date(),
                    podcastTitle: body.episode?.podcastTitle,
                    episodeTitle: body.episode?.episodeTitle,
                    artUrl: body.episode?.artUrl,
                    durationSec: body.episode?.durationSec,
                    transcriptUrl: body.episode?.transcriptUrl
                )
                modelContext.insert(annotation)
                inserted += 1
            } else {
                skippedNilBody += 1
            }
            // Ignore tombstones for annotations we don't have locally
        }
        try? modelContext.save()
        logger.info("Applied \(items.count) annotation delta items (inserted=\(inserted) updated=\(updated) tombstoned=\(tombstoned))")
    }

    /// Remove locally-deleted annotations that have been confirmed synced.
    func hardDeleteSyncedTombstones() {
        let predicate = #Predicate<Annotation> { $0.deleted && $0.syncedAt != nil }
        let descriptor = FetchDescriptor<Annotation>(predicate: predicate)
        guard let tombstones = try? modelContext.fetch(descriptor) else { return }
        for tombstone in tombstones {
            modelContext.delete(tombstone)
        }
        if !tombstones.isEmpty {
            try? modelContext.save()
            logger.info("Hard-deleted \(tombstones.count) synced tombstones")
        }
    }

    /// One-time heal for the snake_case push regression (notes never reached
    /// the server but got marked clean). Re-dirties every annotation — live and
    /// tombstoned — so the next sync re-pushes them. Preserves `deleted` so
    /// pending deletes re-push rather than resurrecting. Returns the count
    /// re-dirtied. Pair with resetting the pull cursor so the full-state push
    /// response re-imports any server notes that were locally hard-deleted.
    @discardableResult
    func markAllDirtyForResync() -> Int {
        let descriptor = FetchDescriptor<Annotation>()
        guard let all = try? modelContext.fetch(descriptor), !all.isEmpty else { return 0 }
        let now = Date()
        for annotation in all {
            annotation.isDirty = true
            annotation.updatedAt = now
        }
        try? modelContext.save()
        logger.info("Re-dirtied \(all.count) annotations for one-time resync heal")
        return all.count
    }

    /// Mark all dirty annotations as synced (after a successful push).
    func markAllClean() {
        let dirty = dirtyAnnotations()
        let now = Date()
        for annotation in dirty {
            annotation.isDirty = false
            annotation.syncedAt = now
        }
        try? modelContext.save()
    }

    // MARK: - Tag Normalization

    /// Normalize a tag to match the web's format exactly:
    /// lowercase, trim, spaces→hyphens, strip non-alphanumeric/hyphen, strip leading/trailing hyphens.
    static func normalizeTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacing(/\s+/, with: "-")
            .replacing(/[^a-z0-9-]/, with: "")
            .replacing(/^-+|-+$/, with: "")
    }

    // MARK: - Private

    private func fetchAnnotation(id annotationId: String) -> Annotation? {
        let predicate = #Predicate<Annotation> { $0.annotationId == annotationId }
        let descriptor = FetchDescriptor<Annotation>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }
}
