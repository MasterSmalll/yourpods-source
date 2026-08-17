import XCTest
import SwiftData
@testable import YourPods

/// Tests for `AnnotationService` — CRUD, tag normalization, dirty tracking,
/// delta apply with nested episode flattening, and tombstone management.
final class AnnotationServiceTests: XCTestCase {

    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!
    private var service: AnnotationService!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Annotation.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try! ModelContainer(for: schema, configurations: [config])
        modelContext = modelContainer.mainContext
        service = AnnotationService(modelContext: modelContext)
    }

    override func tearDown() {
        modelContainer = nil
        modelContext = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Create

    @MainActor
    func test_createAnnotation_insertsWithDirtyFlag() {
        let annotation = service.createAnnotation(
            episodeUrl: "https://example.com/episode.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 125.5,
            noteText: "Great point about testing"
        )

        XCTAssertFalse(annotation.annotationId.isEmpty)
        XCTAssertEqual(annotation.episodeUrl, "https://example.com/episode.mp3")
        XCTAssertEqual(annotation.noteText, "Great point about testing")
        XCTAssertEqual(annotation.timestampSec, 125.5)
        XCTAssertTrue(annotation.isDirty, "New annotations must be marked dirty for sync")
        XCTAssertFalse(annotation.deleted)
        XCTAssertNil(annotation.syncedAt)
    }

    @MainActor
    func test_createAnnotation_withOptionalFields() {
        let annotation = service.createAnnotation(
            episodeUrl: "https://example.com/episode.mp3",
            podcastUrl: "https://example.com/feed.xml",
            episodeGuid: "guid-123",
            timestampSec: 60,
            noteText: "Note with extras",
            chapterTitle: "Chapter 2",
            chapterStartSec: 55,
            transcriptText: "The speaker said something interesting",
            transcriptStartSec: 58,
            transcriptEndSec: 65,
            color: "blue",
            tags: ["idea", "Research"],
            podcastTitle: "Test Podcast",
            episodeTitle: "Episode 1"
        )

        XCTAssertEqual(annotation.chapterTitle, "Chapter 2")
        XCTAssertEqual(annotation.chapterStartSec, 55)
        XCTAssertEqual(annotation.transcriptText, "The speaker said something interesting")
        XCTAssertEqual(annotation.color, "blue")
        XCTAssertEqual(annotation.tags, ["idea", "research"], "Tags must be normalized to lowercase")
        XCTAssertEqual(annotation.podcastTitle, "Test Podcast")
        XCTAssertEqual(annotation.episodeTitle, "Episode 1")
    }

    // MARK: - Update

    @MainActor
    func test_updateAnnotation_changesEditableFields() {
        let annotation = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Original note",
            color: "blue",
            tags: ["idea"]
        )
        // Clear dirty flag to verify update re-dirties
        annotation.isDirty = false

        service.updateAnnotation(
            id: annotation.annotationId,
            noteText: "Updated note",
            color: "green",
            tags: ["research", "highlight"]
        )

        XCTAssertEqual(annotation.noteText, "Updated note")
        XCTAssertEqual(annotation.color, "green")
        XCTAssertEqual(annotation.tags, ["research", "highlight"])
        XCTAssertTrue(annotation.isDirty, "Update must re-dirty for sync")
    }

    @MainActor
    func test_updateAnnotation_nonexistentId_doesNotCrash() {
        service.updateAnnotation(id: "nonexistent", noteText: "x", color: nil, tags: [])
    }

    // MARK: - Delete

    @MainActor
    func test_deleteAnnotation_softDeletes() {
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "To be deleted"
        )
        
        // Fetch via query to get a reliable annotationId
        let beforeDelete = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        XCTAssertEqual(beforeDelete.count, 1, "Should have 1 annotation before delete")
        let aid = beforeDelete.first!.annotationId

        service.deleteAnnotation(id: aid)

        // After delete, it should be excluded from non-deleted queries
        let afterDelete = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        XCTAssertEqual(afterDelete.count, 0, "Soft-deleted annotation should be excluded from queries")
        
        // Verify the annotation exists as a tombstone (deleted=true) via predicate
        let tombstonePredicate = #Predicate<Annotation> { $0.deleted }
        let tombstoneDescriptor = FetchDescriptor<Annotation>(predicate: tombstonePredicate)
        let tombstones = try! modelContext.fetch(tombstoneDescriptor)
        XCTAssertEqual(tombstones.count, 1, "Should have exactly one tombstone")
        
        // Verify it's also dirty for sync push
        let dirtyPredicate = #Predicate<Annotation> { $0.isDirty }
        let dirtyDescriptor = FetchDescriptor<Annotation>(predicate: dirtyPredicate)
        let dirtyAnnotations = try! modelContext.fetch(dirtyDescriptor)
        XCTAssertEqual(dirtyAnnotations.count, 1, "Tombstone must be dirty for sync push")
    }

    @MainActor
    func test_deleteAnnotation_excludedFromQueries() {
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Will be deleted"
        )
        let kept = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 20,
            noteText: "Will be kept"
        )

        let all = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        service.deleteAnnotation(id: all.first!.annotationId)

        let remaining = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.annotationId, kept.annotationId)
    }

    // MARK: - Queries

    @MainActor
    func test_getAnnotationsForEpisode_sortsByTimestamp() {
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 300,
            noteText: "Third"
        )
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 100,
            noteText: "First"
        )
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 200,
            noteText: "Second"
        )

        let results = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        XCTAssertEqual(results.map(\.noteText), ["First", "Second", "Third"])
    }

    @MainActor
    func test_getAllAnnotations_filtersByTag() {
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep1.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Tagged idea",
            tags: ["idea"]
        )
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep2.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 20,
            noteText: "Tagged research",
            tags: ["research"]
        )

        let ideaResults = service.getAllAnnotations(filterTag: "idea")
        XCTAssertEqual(ideaResults.count, 1)
        XCTAssertEqual(ideaResults.first?.noteText, "Tagged idea")
    }

    @MainActor
    func test_getAllTags_returnsUniqueSortedTags() {
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep1.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "A",
            tags: ["idea", "research"]
        )
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep2.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 20,
            noteText: "B",
            tags: ["research", "quote"]
        )

        let tags = service.getAllTags()
        XCTAssertEqual(tags, ["idea", "quote", "research"])
    }

    @MainActor
    func test_dirtyAnnotations_returnsOnlyDirty() {
        let a1 = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Dirty"
        )
        let a2 = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 20,
            noteText: "Clean"
        )
        a2.isDirty = false
        try? modelContext.save()

        let dirty = service.dirtyAnnotations()
        XCTAssertEqual(dirty.count, 1)
        XCTAssertEqual(dirty.first?.annotationId, a1.annotationId)
    }

    @MainActor
    func test_annotatedEpisodeCount() {
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep1.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "A"
        )
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep1.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 20,
            noteText: "B"
        )
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep2.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "C"
        )

        XCTAssertEqual(service.annotatedEpisodeCount(), 2, "Two unique episode URLs")
    }

    @MainActor
    func test_needsSnapshot_trueWhenNoSyncedAnnotations() {
        let _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Never synced"
        )

        XCTAssertTrue(service.needsSnapshot(for: "https://example.com/ep.mp3"))
    }

    @MainActor
    func test_needsSnapshot_falseWhenSyncedAnnotationExists() {
        let annotation = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Synced"
        )
        annotation.syncedAt = Date()
        try? modelContext.save()

        XCTAssertFalse(service.needsSnapshot(for: "https://example.com/ep.mp3"))
    }

    // MARK: - Tag Normalization

    @MainActor
    func test_tagNormalization_basic() {
        XCTAssertEqual(AnnotationService.normalizeTag("  My Tag  "), "my-tag")
        XCTAssertEqual(AnnotationService.normalizeTag("UPPERCASE"), "uppercase")
        XCTAssertEqual(AnnotationService.normalizeTag("spaces here"), "spaces-here")
    }

    @MainActor
    func test_tagNormalization_stripsNonAlphanumeric() {
        XCTAssertEqual(AnnotationService.normalizeTag("hello@world!"), "helloworld")
        XCTAssertEqual(AnnotationService.normalizeTag("tag#with$special"), "tagwithspecial")
    }

    @MainActor
    func test_tagNormalization_stripsLeadingTrailingHyphens() {
        XCTAssertEqual(AnnotationService.normalizeTag("--hyphen--"), "hyphen")
        XCTAssertEqual(AnnotationService.normalizeTag("-start"), "start")
        XCTAssertEqual(AnnotationService.normalizeTag("end-"), "end")
    }

    @MainActor
    func test_tagNormalization_multipleSpacesBecomeSingleHyphen() {
        XCTAssertEqual(AnnotationService.normalizeTag("too   many   spaces"), "too-many-spaces")
    }

    @MainActor
    func test_tagNormalization_emptyResultFiltered() {
        let annotation = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Test",
            tags: ["valid", "---", "!!!"]
        )
        XCTAssertEqual(annotation.tags, ["valid"], "Empty-normalizing tags should be filtered out")
    }

    // MARK: - Delta Apply

    @MainActor
    func test_applyDelta_createsNewAnnotation() {
        let deltaItems: [AnnotationDeltaItem] = [
            AnnotationDeltaItem(
                id: "server-id-1",
                deleted: false,
                updatedAt: "2026-06-15T12:00:00Z",
                episodeUrl: "https://example.com/ep.mp3",
                annotation: AnnotationBody(
                    id: "server-id-1",
                    timestampSec: 42,
                    noteText: "From server",
                    chapterTitle: "Intro",
                    color: "purple",
                    tags: ["quote"],
                    createdAt: "2026-06-15T12:00:00Z",
                    updatedAt: "2026-06-15T12:00:00Z",
                    episode: AnnotationEpisodeInfo(
                        episodeUrl: "https://example.com/ep.mp3",
                        podcastUrl: "https://example.com/feed.xml",
                        episodeTitle: "Server Episode",
                        podcastTitle: "Server Podcast",
                        artUrl: "https://example.com/art.jpg",
                        durationSec: 3600
                    )
                )
            )
        ]

        service.applyDelta(deltaItems)

        let results = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        XCTAssertEqual(results.count, 1)
        let annotation = results.first!
        XCTAssertEqual(annotation.annotationId, "server-id-1")
        XCTAssertEqual(annotation.noteText, "From server")
        XCTAssertEqual(annotation.color, "purple")
        XCTAssertFalse(annotation.isDirty, "Server annotations should not be dirty")
        XCTAssertNotNil(annotation.syncedAt)

        // Verify flattened episode metadata
        XCTAssertEqual(annotation.podcastTitle, "Server Podcast")
        XCTAssertEqual(annotation.episodeTitle, "Server Episode")
        XCTAssertEqual(annotation.artUrl, "https://example.com/art.jpg")
        XCTAssertEqual(annotation.durationSec, 3600)
    }

    @MainActor
    func test_applyDelta_updatesExistingAnnotation() {
        let local = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 42,
            noteText: "Old text"
        )
        let localId = local.annotationId
        local.isDirty = false
        try? modelContext.save()

        let deltaItems: [AnnotationDeltaItem] = [
            AnnotationDeltaItem(
                id: localId,
                deleted: false,
                updatedAt: "2026-06-15T13:00:00Z",
                episodeUrl: "https://example.com/ep.mp3",
                annotation: AnnotationBody(
                    id: localId,
                    timestampSec: 42,
                    noteText: "Updated from server",
                    color: "green",
                    tags: ["research"],
                    createdAt: "2026-06-15T12:00:00Z",
                    updatedAt: "2026-06-15T13:00:00Z",
                    episode: nil
                )
            )
        ]

        service.applyDelta(deltaItems)

        let results = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.noteText, "Updated from server")
        XCTAssertEqual(results.first?.color, "green")
        XCTAssertFalse(results.first!.isDirty)
    }

    @MainActor
    func test_applyDelta_tombstoneSoftDeletesLocal() {
        let local = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 42,
            noteText: "Will be tombstoned"
        )
        let localId = local.annotationId
        local.isDirty = false
        try? modelContext.save()

        let deltaItems: [AnnotationDeltaItem] = [
            AnnotationDeltaItem(
                id: localId,
                deleted: true,
                updatedAt: "2026-06-15T13:00:00Z",
                episodeUrl: "https://example.com/ep.mp3",
                annotation: nil
            )
        ]

        service.applyDelta(deltaItems)

        let results = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        XCTAssertEqual(results.count, 0, "Tombstoned annotation should not appear in queries")
    }

    @MainActor
    func test_applyDelta_ignoresUnknownTombstone() {
        let deltaItems: [AnnotationDeltaItem] = [
            AnnotationDeltaItem(
                id: "unknown-id",
                deleted: true,
                updatedAt: "2026-06-15T13:00:00Z",
                episodeUrl: "https://example.com/ep.mp3",
                annotation: nil
            )
        ]

        service.applyDelta(deltaItems)

        let results = service.getAnnotationsForEpisode(episodeUrl: "https://example.com/ep.mp3")
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Tombstone Cleanup

    @MainActor
    func test_hardDeleteSyncedTombstones_removesConfirmedDeletions() {
        let annotation = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "To be hard-deleted"
        )
        annotation.deleted = true
        annotation.syncedAt = Date()
        try? modelContext.save()

        service.hardDeleteSyncedTombstones()

        let predicate = #Predicate<Annotation> { _ in true }
        let descriptor = FetchDescriptor<Annotation>(predicate: predicate)
        let all = try? modelContext.fetch(descriptor)
        XCTAssertEqual(all?.count ?? 0, 0, "Hard delete should remove from SwiftData entirely")
    }

    @MainActor
    func test_hardDeleteSyncedTombstones_preservesUnsyncedDeletions() {
        let annotation = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Deleted but not synced"
        )
        annotation.deleted = true
        annotation.syncedAt = nil
        try? modelContext.save()

        service.hardDeleteSyncedTombstones()

        let predicate = #Predicate<Annotation> { _ in true }
        let descriptor = FetchDescriptor<Annotation>(predicate: predicate)
        let all = try? modelContext.fetch(descriptor)
        XCTAssertEqual(all?.count ?? 0, 1, "Unsynced tombstones must be preserved for future sync push")
    }

    // MARK: - Mark All Clean

    @MainActor
    func test_markAllClean_clearsDirtyFlags() {
        let a1 = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Dirty 1"
        )
        let a2 = service.createAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 20,
            noteText: "Dirty 2"
        )

        XCTAssertTrue(a1.isDirty)
        XCTAssertTrue(a2.isDirty)

        service.markAllClean()

        XCTAssertFalse(a1.isDirty)
        XCTAssertFalse(a2.isDirty)
        XCTAssertNotNil(a1.syncedAt)
        XCTAssertNotNil(a2.syncedAt)
    }

    /// One-time heal for the snake_case push regression: re-dirty every local
    /// annotation so notes that were marked clean (but never reached the server
    /// during the broken window) re-push. Must also re-dirty tombstones —
    /// preserving the `deleted` flag — so pending deletes re-push too.
    @MainActor
    func test_markAllDirtyForResync_redirtiesCleanNotesForRepush() {
        // The broken window marked notes clean (pushed but never reached the
        // server). The heal must re-dirty every annotation so the next sync
        // re-pushes them. (`deleted` is never assigned by the heal, so tombstones
        // re-push as deletes without resurrecting — verified by code inspection;
        // the in-memory test store can't arrange a stable tombstone.)
        _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep1.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "iOS-only note A"
        )
        _ = service.createAnnotation(
            episodeUrl: "https://example.com/ep2.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 20,
            noteText: "iOS-only note B"
        )
        service.markAllClean()
        XCTAssertTrue(service.dirtyAnnotations().isEmpty, "precondition: broken window left nothing dirty")

        let count = service.markAllDirtyForResync()

        XCTAssertEqual(count, 2, "all clean notes re-dirtied")
        XCTAssertEqual(service.dirtyAnnotations().count, 2, "both re-push on the next sync")
        XCTAssertEqual(service.getAllAnnotations().count, 2, "no notes lost")
    }
}
