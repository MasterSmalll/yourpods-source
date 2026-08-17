import XCTest
@testable import YourPods

/// Tests for `NextcloudNotesService` — Markdown generation, filename sanitization,
/// and WebDAV URL construction. Network operations are tested via format validation only.
final class NextcloudNotesServiceTests: XCTestCase {

    // MARK: - Markdown Generation

    func test_generateEpisodeMarkdown_emptyNotes_returnsEmpty() {
        let result = NextcloudNotesService.generateEpisodeMarkdown(notes: [])
        XCTAssertEqual(result, "")
    }

    func test_generateEpisodeMarkdown_noYAMLFrontmatter() {
        let notes = [makeAnnotation(noteText: "Test note")]
        let md = NextcloudNotesService.generateEpisodeMarkdown(notes: notes)

        // Nextcloud format has NO YAML frontmatter (no "---" at start)
        XCTAssertFalse(md.hasPrefix("---"), "Nextcloud markdown should not have YAML frontmatter")
        XCTAssertFalse(md.contains("podcast:"), "Should not have YAML podcast key")
        XCTAssertFalse(md.contains("feed:"), "Should not have YAML feed key")
    }

    func test_generateEpisodeMarkdown_includesHeading() {
        let notes = [makeAnnotation(noteText: "A note", episodeTitle: "My Episode", podcastTitle: "My Pod")]
        let md = NextcloudNotesService.generateEpisodeMarkdown(notes: notes)

        XCTAssertTrue(md.contains("# My Episode"))
        XCTAssertTrue(md.contains("**My Pod**"))
    }

    func test_generateEpisodeMarkdown_includesTimestampAndNote() {
        let notes = [makeAnnotation(timestampSec: 125.5, noteText: "Important insight")]
        let md = NextcloudNotesService.generateEpisodeMarkdown(notes: notes)

        XCTAssertTrue(md.contains("**[2:05]**"))
        XCTAssertTrue(md.contains("Important insight"))
    }

    func test_generateEpisodeMarkdown_includesChapterTitle() {
        let notes = [makeAnnotation(noteText: "Note", chapterTitle: "Chapter 3")]
        let md = NextcloudNotesService.generateEpisodeMarkdown(notes: notes)

        XCTAssertTrue(md.contains("· Chapter 3"))
    }

    func test_generateEpisodeMarkdown_includesTranscriptAsBlockquote() {
        let notes = [makeAnnotation(noteText: "About this", transcriptText: "Speaker said this")]
        let md = NextcloudNotesService.generateEpisodeMarkdown(notes: notes)

        XCTAssertTrue(md.contains("> \"Speaker said this\""))
    }

    func test_generateEpisodeMarkdown_includesTags() {
        let notes = [makeAnnotation(noteText: "Note", tags: ["idea", "quote"])]
        let md = NextcloudNotesService.generateEpisodeMarkdown(notes: notes)

        XCTAssertTrue(md.contains("#idea"))
        XCTAssertTrue(md.contains("#quote"))
    }

    func test_generateEpisodeMarkdown_multipleNotesHaveSeparator() {
        let notes = [
            makeAnnotation(timestampSec: 10, noteText: "First"),
            makeAnnotation(timestampSec: 20, noteText: "Second")
        ]
        let md = NextcloudNotesService.generateEpisodeMarkdown(notes: notes)

        XCTAssertTrue(md.contains("First"))
        XCTAssertTrue(md.contains("Second"))
        XCTAssertTrue(md.contains("---\n\n"), "Should have separator between notes")
    }

    func test_generateEpisodeMarkdown_noTrailingSeparator() {
        let notes = [
            makeAnnotation(timestampSec: 10, noteText: "First"),
            makeAnnotation(timestampSec: 20, noteText: "Last")
        ]
        let md = NextcloudNotesService.generateEpisodeMarkdown(notes: notes)

        // The content after "Last" should NOT end with "---"
        let lastNoteIndex = md.range(of: "Last")!.upperBound
        let trailing = String(md[lastNoteIndex...])
        XCTAssertFalse(trailing.contains("---"), "Should not have separator after last note")
    }

    // MARK: - Filename Sanitization

    func test_sanitizeFilename_removesInvalidChars() {
        let result = NextcloudNotesService.sanitizeFilename("Episode: \"The Best\" <Part 1>")
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("\""))
        XCTAssertFalse(result.contains("<"))
        XCTAssertFalse(result.contains(">"))
        XCTAssertTrue(result.contains("Episode"))
        XCTAssertTrue(result.contains("The Best"))
    }

    func test_sanitizeFilename_removsSlashes() {
        let result = NextcloudNotesService.sanitizeFilename("path/to\\file")
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains("\\"))
    }

    func test_sanitizeFilename_collapsesWhitespace() {
        let result = NextcloudNotesService.sanitizeFilename("Episode   with    spaces")
        XCTAssertEqual(result, "Episode with spaces")
    }

    func test_sanitizeFilename_emptyString_returnsUntitled() {
        let result = NextcloudNotesService.sanitizeFilename("")
        XCTAssertEqual(result, "Untitled")
    }

    func test_sanitizeFilename_onlyInvalidChars_returnsUntitled() {
        let result = NextcloudNotesService.sanitizeFilename(":<>|")
        XCTAssertEqual(result, "Untitled")
    }

    func test_sanitizeFilename_truncatesLongNames() {
        let longName = String(repeating: "A", count: 300)
        let result = NextcloudNotesService.sanitizeFilename(longName)
        XCTAssertLessThanOrEqual(result.count, 200)
    }

    // MARK: - SyncResult

    func test_syncToNextcloud_emptyAnnotations_returnsZero() async {
        // Empty annotations should return immediately with no uploads
        let result = await NextcloudNotesService.syncToNextcloud(
            annotations: [],
            baseUrl: "https://cloud.example.com",
            username: "user",
            password: "pass"
        )
        XCTAssertEqual(result.uploaded, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func test_syncToNextcloud_skipsDeletedAnnotations() async {
        let deleted = makeAnnotation(noteText: "Deleted")
        deleted.deleted = true

        let result = await NextcloudNotesService.syncToNextcloud(
            annotations: [deleted],
            baseUrl: "https://cloud.example.com",
            username: "user",
            password: "pass"
        )
        // All annotations are deleted — should return zero, not attempt upload
        XCTAssertEqual(result.uploaded, 0)
        XCTAssertEqual(result.failed, 0)
    }

    // MARK: - Default Folder

    func test_defaultFolder() {
        XCTAssertEqual(NextcloudNotesService.defaultFolder, "Notes/YourPods")
    }

    // MARK: - Error Descriptions

    func test_errorDescriptions() {
        XCTAssertNotNil(NextcloudNotesService.NextcloudError.invalidURL("/bad").errorDescription)
        XCTAssertNotNil(NextcloudNotesService.NextcloudError.mkcolFailed(path: "/dir", status: 500).errorDescription)
        XCTAssertNotNil(NextcloudNotesService.NextcloudError.putFailed(status: 403).errorDescription)
        XCTAssertNotNil(NextcloudNotesService.NextcloudError.missingCredentials.errorDescription)
    }

    // MARK: - Helpers

    // MARK: - EDGE: untitled-episode note identity

    /// The Nextcloud note title is the create-vs-update identity key. Two
    /// untitled episodes of the same podcast both produced "Untitled" in the
    /// same category, so the second PUT overwrote the first note's content.
    func test_buildNoteJSON_producesDistinctTitles_forTwoUntitledEpisodes() throws {
        let a = Annotation(episodeUrl: "https://example.com/ep-a.mp3",
                           podcastUrl: "https://example.com/feed.xml",
                           timestampSec: 10, noteText: "note a",
                           podcastTitle: "The Show", episodeTitle: nil)
        let b = Annotation(episodeUrl: "https://example.com/ep-b.mp3",
                           podcastUrl: "https://example.com/feed.xml",
                           timestampSec: 20, noteText: "note b",
                           podcastTitle: "The Show", episodeTitle: nil)

        let cat = NextcloudNotesAPIService.category(for: "The Show")
        let jsonA = try XCTUnwrap(NextcloudNotesAPIService.buildNoteJSON(notes: [a], category: cat))
        let jsonB = try XCTUnwrap(NextcloudNotesAPIService.buildNoteJSON(notes: [b], category: cat))

        let titleA = try XCTUnwrap(jsonA["title"] as? String)
        let titleB = try XCTUnwrap(jsonB["title"] as? String)

        XCTAssertNotEqual(titleA, titleB,
            "both untitled episodes produced title '\(titleA)' in category '\(cat)' — the second PUT overwrites the first note")
    }

    /// A titled episode's note title must not change — existing notes on the
    /// user's server are matched by it.
    func test_buildNoteJSON_isUnchanged_forTitledEpisode() throws {
        let a = Annotation(episodeUrl: "https://example.com/ep-a.mp3",
                           podcastUrl: "https://example.com/feed.xml",
                           timestampSec: 10, noteText: "note a",
                           podcastTitle: "The Show", episodeTitle: "Episode One")
        let json = try XCTUnwrap(NextcloudNotesAPIService.buildNoteJSON(
            notes: [a], category: NextcloudNotesAPIService.category(for: "The Show")))
        XCTAssertEqual(json["title"] as? String, "Episode One",
            "the note title for a titled episode must not change")
    }

    private func makeAnnotation(
        timestampSec: Double = 30,
        noteText: String,
        chapterTitle: String? = nil,
        transcriptText: String? = nil,
        tags: [String] = [],
        episodeTitle: String? = "Test Episode",
        podcastTitle: String? = "Test Podcast"
    ) -> Annotation {
        Annotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: timestampSec,
            noteText: noteText,
            chapterTitle: chapterTitle,
            transcriptText: transcriptText,
            tags: tags,
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle
        )
    }
}
