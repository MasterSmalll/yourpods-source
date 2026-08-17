import XCTest
@testable import YourPods

/// Tests for `NotesExportService` — Markdown format, Obsidian URI, and time formatting.
final class NotesExportServiceTests: XCTestCase {

    // MARK: - Markdown Export

    func test_exportAsMarkdown_emptyAnnotations_returnsEmpty() {
        let result = NotesExportService.exportAsMarkdown(annotations: [])
        XCTAssertEqual(result, "")
    }

    func test_exportAsMarkdown_includesYAMLFrontmatter() {
        let annotations = [
            makeAnnotation(
                episodeUrl: "https://example.com/ep.mp3",
                podcastUrl: "https://example.com/feed.xml",
                timestampSec: 125.5,
                noteText: "Great point",
                tags: ["idea", "research"],
                podcastTitle: "Test Pod",
                episodeTitle: "Episode 1",
                durationSec: 3600
            )
        ]

        let md = NotesExportService.exportAsMarkdown(annotations: annotations)

        XCTAssertTrue(md.contains("---\n"), "Should have YAML frontmatter delimiters")
        XCTAssertTrue(md.contains("podcast: Test Pod"))
        XCTAssertTrue(md.contains("episode: Episode 1"))
        XCTAssertTrue(md.contains("duration: 1:00:00"))
        XCTAssertTrue(md.contains("feed: https://example.com/feed.xml"))
        XCTAssertTrue(md.contains("audio: https://example.com/ep.mp3"))
        XCTAssertTrue(md.contains("tags: idea, research"))
    }

    func test_exportAsMarkdown_includesTimestampAndNote() {
        let annotations = [
            makeAnnotation(
                episodeUrl: "https://example.com/ep.mp3",
                podcastUrl: "https://example.com/feed.xml",
                timestampSec: 125.5,
                noteText: "Important insight"
            )
        ]

        let md = NotesExportService.exportAsMarkdown(annotations: annotations)

        XCTAssertTrue(md.contains("**[2:05]**"))
        XCTAssertTrue(md.contains("Important insight"))
    }

    func test_exportAsMarkdown_includesTranscriptAsBlockquote() {
        let annotations = [
            makeAnnotation(
                episodeUrl: "https://example.com/ep.mp3",
                podcastUrl: "https://example.com/feed.xml",
                timestampSec: 30,
                noteText: "Note about this",
                transcriptText: "The speaker said something"
            )
        ]

        let md = NotesExportService.exportAsMarkdown(annotations: annotations)
        XCTAssertTrue(md.contains("> \"The speaker said something\""))
    }

    func test_exportAsMarkdown_includesChapterTitle() {
        let annotations = [
            makeAnnotation(
                episodeUrl: "https://example.com/ep.mp3",
                podcastUrl: "https://example.com/feed.xml",
                timestampSec: 30,
                noteText: "Note",
                chapterTitle: "Chapter 3: Testing"
            )
        ]

        let md = NotesExportService.exportAsMarkdown(annotations: annotations)
        XCTAssertTrue(md.contains("· Chapter 3: Testing"))
    }

    func test_exportAsMarkdown_includesHashtags() {
        let annotations = [
            makeAnnotation(
                episodeUrl: "https://example.com/ep.mp3",
                podcastUrl: "https://example.com/feed.xml",
                timestampSec: 30,
                noteText: "Note",
                tags: ["idea", "quote"]
            )
        ]

        let md = NotesExportService.exportAsMarkdown(annotations: annotations)
        XCTAssertTrue(md.contains("#idea"))
        XCTAssertTrue(md.contains("#quote"))
    }

    func test_exportAsMarkdown_multipleNotesHaveSeparator() {
        let annotations = [
            makeAnnotation(
                episodeUrl: "https://example.com/ep.mp3",
                podcastUrl: "https://example.com/feed.xml",
                timestampSec: 10,
                noteText: "First"
            ),
            makeAnnotation(
                episodeUrl: "https://example.com/ep.mp3",
                podcastUrl: "https://example.com/feed.xml",
                timestampSec: 20,
                noteText: "Second"
            )
        ]

        let md = NotesExportService.exportAsMarkdown(annotations: annotations)
        // Should have separator between notes but not after the last one
        let separatorCount = md.components(separatedBy: "---\n\n").count - 1
        // YAML frontmatter uses "---" too, but the note separator is "---\n\n"
        XCTAssertTrue(separatorCount >= 1, "Should have separators between notes")
    }

    func test_exportAsMarkdown_excludesDeletedAnnotations() {
        let deleted = makeAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 10,
            noteText: "Deleted note"
        )
        deleted.deleted = true

        let kept = makeAnnotation(
            episodeUrl: "https://example.com/ep.mp3",
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 20,
            noteText: "Kept note"
        )

        let md = NotesExportService.exportAsMarkdown(annotations: [deleted, kept])
        XCTAssertFalse(md.contains("Deleted note"))
        XCTAssertTrue(md.contains("Kept note"))
    }

    // MARK: - Obsidian URI

    func test_obsidianURI_returnsNilForEmptyVault() {
        let url = NotesExportService.obsidianURI(markdown: "# Test", vaultName: "")
        XCTAssertNil(url)
    }

    func test_obsidianURI_buildsCorrectScheme() {
        let url = NotesExportService.obsidianURI(markdown: "# Notes", vaultName: "MyVault")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "obsidian")
    }

    func test_obsidianURI_includesVaultName() {
        let url = NotesExportService.obsidianURI(markdown: "# Notes", vaultName: "MyVault")
        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("vault=MyVault"), "URI should include vault name")
    }

    func test_obsidianURI_includesNotePath() {
        let url = NotesExportService.obsidianURI(markdown: "# Notes", vaultName: "MyVault")
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("name=YourPods"), "URI should include 'YourPods Notes' path")
    }

    func test_obsidianURI_includesContent() {
        let url = NotesExportService.obsidianURI(markdown: "Hello World", vaultName: "V")
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("content="), "URI should include content parameter")
    }

    // MARK: - Time Formatting

    func test_formatTime_minutesAndSeconds() {
        XCTAssertEqual(NotesExportService.formatTime(125.5), "2:05")
        XCTAssertEqual(NotesExportService.formatTime(0), "0:00")
        XCTAssertEqual(NotesExportService.formatTime(59), "0:59")
        XCTAssertEqual(NotesExportService.formatTime(60), "1:00")
    }

    func test_formatTime_hours() {
        XCTAssertEqual(NotesExportService.formatTime(3600), "1:00:00")
        XCTAssertEqual(NotesExportService.formatTime(3661), "1:01:01")
        XCTAssertEqual(NotesExportService.formatTime(7200), "2:00:00")
    }

    // MARK: - Nextcloud Markdown Export

    func test_nextcloudMarkdownExport_returnsNilForEmpty() {
        let result = NotesExportService.exportAsNextcloudMarkdown(annotations: [])
        XCTAssertNil(result)
    }

    func test_nextcloudMarkdownExport_returnsDataForAnnotations() {
        let annotations = [
            makeAnnotation(
                episodeUrl: "https://example.com/ep.mp3",
                podcastUrl: "https://example.com/feed.xml",
                timestampSec: 30,
                noteText: "A note"
            )
        ]
        let result = NotesExportService.exportAsNextcloudMarkdown(annotations: annotations)
        XCTAssertNotNil(result)
        let content = String(data: result!, encoding: .utf8)!
        XCTAssertTrue(content.contains("A note"))
        XCTAssertFalse(content.contains("podcast:"), "No YAML frontmatter")
    }

    // MARK: - Helpers

    // MARK: - EDGE: untitled-episode collision

    /// Two untitled episodes of the same podcast must not resolve to the same
    /// Obsidian path. They did, and the export writes with overwrite=true, so
    /// the second export silently destroyed the first.
    func test_obsidianPerEpisodeURI_doesNotCollide_forTwoUntitledEpisodesOfSamePodcast() throws {
        let a = Annotation(episodeUrl: "https://example.com/ep-a.mp3",
                           podcastUrl: "https://example.com/feed.xml",
                           timestampSec: 10, noteText: "note a",
                           podcastTitle: "The Show", episodeTitle: nil)
        let b = Annotation(episodeUrl: "https://example.com/ep-b.mp3",
                           podcastUrl: "https://example.com/feed.xml",
                           timestampSec: 20, noteText: "note b",
                           podcastTitle: "The Show", episodeTitle: nil)

        let urlA = try XCTUnwrap(NotesExportService.obsidianPerEpisodeURI(notes: [a], vaultName: "V"))
        let urlB = try XCTUnwrap(NotesExportService.obsidianPerEpisodeURI(notes: [b], vaultName: "V"))

        let nameA = try XCTUnwrap(URLComponents(url: urlA, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "name" })?.value)
        let nameB = try XCTUnwrap(URLComponents(url: urlB, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "name" })?.value)

        XCTAssertNotEqual(nameA, nameB,
            "two untitled episodes of the same podcast collided on '\(nameA)' — with overwrite=true the second export destroys the first")
    }

    /// A titled episode's path must not change. This is the regression guard
    /// on the fix above: the fallback may only affect the nil-title case.
    func test_obsidianPerEpisodeURI_isUnchanged_forTitledEpisode() throws {
        let a = Annotation(episodeUrl: "https://example.com/ep-a.mp3",
                           podcastUrl: "https://example.com/feed.xml",
                           timestampSec: 10, noteText: "note a",
                           podcastTitle: "The Show", episodeTitle: "Episode One")
        let url = try XCTUnwrap(NotesExportService.obsidianPerEpisodeURI(notes: [a], vaultName: "V"))
        let name = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "name" })?.value)

        XCTAssertEqual(name, "YourPods Notes/The Show/Episode One",
            "the path for a titled episode must not change")
    }

    private func makeAnnotation(
        episodeUrl: String,
        podcastUrl: String,
        timestampSec: Double,
        noteText: String,
        chapterTitle: String? = nil,
        transcriptText: String? = nil,
        color: String? = nil,
        tags: [String] = [],
        podcastTitle: String? = nil,
        episodeTitle: String? = nil,
        durationSec: Double? = nil
    ) -> Annotation {
        Annotation(
            episodeUrl: episodeUrl,
            podcastUrl: podcastUrl,
            timestampSec: timestampSec,
            noteText: noteText,
            chapterTitle: chapterTitle,
            transcriptText: transcriptText,
            color: color,
            tags: tags,
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle,
            durationSec: durationSec
        )
    }
}
