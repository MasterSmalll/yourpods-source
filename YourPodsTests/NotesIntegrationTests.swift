import XCTest
@testable import YourPods

/// Tests for improved Obsidian integration — per-episode URIs, daily note append,
/// and bulk file export. Also covers Nextcloud Notes API service.
final class NotesIntegrationTests: XCTestCase {

    // MARK: - Per-Episode Obsidian URI

    func test_obsidianPerEpisodeURI_buildsCorrectPath() {
        let notes = [makeAnnotation(noteText: "Test note", episodeTitle: "Ep 42", podcastTitle: "My Pod")]
        let url = NotesExportService.obsidianPerEpisodeURI(
            notes: notes,
            vaultName: "MyVault"
        )
        XCTAssertNotNil(url)
        let urlStr = url!.absoluteString
        XCTAssertEqual(url?.scheme, "obsidian")
        XCTAssertTrue(urlStr.contains("vault=MyVault"))
        // Path should be YourPods Notes/<Podcast>/<Episode>
        XCTAssertTrue(urlStr.contains("YourPods%20Notes"), "Path should contain YourPods Notes folder")
    }

    func test_obsidianPerEpisodeURI_returnsNilForEmptyVault() {
        let notes = [makeAnnotation(noteText: "Note")]
        let url = NotesExportService.obsidianPerEpisodeURI(notes: notes, vaultName: "")
        XCTAssertNil(url)
    }

    func test_obsidianPerEpisodeURI_returnsNilForEmptyNotes() {
        let url = NotesExportService.obsidianPerEpisodeURI(notes: [], vaultName: "V")
        XCTAssertNil(url)
    }

    func test_obsidianPerEpisodeURI_includesYAMLFrontmatter() {
        let notes = [makeAnnotation(noteText: "Note", episodeTitle: "Ep", podcastTitle: "Pod")]
        let url = NotesExportService.obsidianPerEpisodeURI(notes: notes, vaultName: "V")
        XCTAssertNotNil(url)
        let urlStr = url!.absoluteString
        XCTAssertTrue(urlStr.contains("content="), "URI should contain note content")
    }

    // MARK: - Advanced URI Daily Note

    func test_obsidianDailyNoteURI_buildsAdvancedURIScheme() {
        let notes = [makeAnnotation(noteText: "Daily insight")]
        let url = NotesExportService.obsidianDailyNoteURI(
            notes: notes,
            vaultName: "MyVault"
        )
        XCTAssertNotNil(url)
        let urlStr = url!.absoluteString
        XCTAssertTrue(urlStr.contains("advanced-uri"), "Should use advanced-uri host")
        XCTAssertTrue(urlStr.contains("daily=true"), "Should target daily note")
        XCTAssertTrue(urlStr.contains("mode=append"), "Should append")
    }

    func test_obsidianDailyNoteURI_returnsNilForEmptyNotes() {
        let url = NotesExportService.obsidianDailyNoteURI(notes: [], vaultName: "V")
        XCTAssertNil(url)
    }

    func test_obsidianDailyNoteURI_returnsNilForEmptyVault() {
        let notes = [makeAnnotation(noteText: "Note")]
        let url = NotesExportService.obsidianDailyNoteURI(notes: notes, vaultName: "")
        XCTAssertNil(url)
    }

    // MARK: - Bulk Per-Episode File Export

    func test_exportPerEpisodeFiles_createsOneFilePerEpisode() {
        let annotations = [
            makeAnnotation(episodeUrl: "https://a.com/ep1.mp3", noteText: "N1", episodeTitle: "Ep1", podcastTitle: "Pod"),
            makeAnnotation(episodeUrl: "https://a.com/ep1.mp3", noteText: "N2", episodeTitle: "Ep1", podcastTitle: "Pod"),
            makeAnnotation(episodeUrl: "https://a.com/ep2.mp3", noteText: "N3", episodeTitle: "Ep2", podcastTitle: "Pod"),
        ]
        let files = NotesExportService.exportPerEpisodeFiles(annotations: annotations)
        XCTAssertEqual(files.count, 2, "Should produce one file per unique episode")
    }

    func test_exportPerEpisodeFiles_filenamesAreMarkdown() {
        let annotations = [makeAnnotation(noteText: "Note", episodeTitle: "Test Ep")]
        let files = NotesExportService.exportPerEpisodeFiles(annotations: annotations)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files.first!.filename.hasSuffix(".md"))
    }

    func test_exportPerEpisodeFiles_contentHasYAMLFrontmatter() {
        let annotations = [makeAnnotation(noteText: "Note", episodeTitle: "Ep", podcastTitle: "Pod")]
        let files = NotesExportService.exportPerEpisodeFiles(annotations: annotations)
        let content = files.first!.content
        XCTAssertTrue(content.hasPrefix("---\n"), "Per-episode export should have YAML frontmatter")
    }

    func test_exportPerEpisodeFiles_excludesDeleted() {
        let kept = makeAnnotation(noteText: "Kept")
        let deleted = makeAnnotation(noteText: "Deleted")
        deleted.deleted = true
        let files = NotesExportService.exportPerEpisodeFiles(annotations: [kept, deleted])
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files.first!.content.contains("Deleted"))
    }

    func test_exportPerEpisodeFiles_emptyReturnsEmpty() {
        let files = NotesExportService.exportPerEpisodeFiles(annotations: [])
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - Nextcloud Notes API Service

    func test_noteJSON_buildsCorrectPayload() {
        let notes = [makeAnnotation(noteText: "Note text", episodeTitle: "Ep", podcastTitle: "My Pod")]
        let json = NextcloudNotesAPIService.buildNoteJSON(
            notes: notes,
            category: "YourPods/My Pod"
        )
        XCTAssertNotNil(json)
        XCTAssertEqual(json!["category"] as? String, "YourPods/My Pod")
        XCTAssertNotNil(json!["content"] as? String)
        let content = json!["content"] as! String
        XCTAssertTrue(content.contains("Note text"))
    }

    func test_noteJSON_titleFromEpisode() {
        let notes = [makeAnnotation(noteText: "N", episodeTitle: "My Episode 42")]
        let json = NextcloudNotesAPIService.buildNoteJSON(notes: notes, category: "YourPods")
        XCTAssertEqual(json!["title"] as? String, "My Episode 42")
    }

    func test_noteJSON_returnsNilForEmpty() {
        let json = NextcloudNotesAPIService.buildNoteJSON(notes: [], category: "YourPods")
        XCTAssertNil(json)
    }

    func test_categoryFromPodcastTitle() {
        XCTAssertEqual(NextcloudNotesAPIService.category(for: "My Great Podcast"), "YourPods/My Great Podcast")
        XCTAssertEqual(NextcloudNotesAPIService.category(for: nil), "YourPods")
    }

    // MARK: - Obsidian Export Mode Enum

    func test_obsidianExportMode_rawValues() {
        XCTAssertEqual(ObsidianExportMode.perEpisode.rawValue, "perEpisode")
        XCTAssertEqual(ObsidianExportMode.dailyNote.rawValue, "dailyNote")
        XCTAssertEqual(ObsidianExportMode.shareSheet.rawValue, "shareSheet")
    }

    // MARK: - Nextcloud Notes Mode Enum

    func test_nextcloudNotesMode_rawValues() {
        XCTAssertEqual(NextcloudNotesMode.webdav.rawValue, "webdav")
        XCTAssertEqual(NextcloudNotesMode.notesApi.rawValue, "notesApi")
    }

    // MARK: - Helpers

    private func makeAnnotation(
        episodeUrl: String = "https://example.com/ep.mp3",
        noteText: String,
        chapterTitle: String? = nil,
        transcriptText: String? = nil,
        tags: [String] = [],
        episodeTitle: String? = "Test Episode",
        podcastTitle: String? = "Test Podcast"
    ) -> Annotation {
        Annotation(
            episodeUrl: episodeUrl,
            podcastUrl: "https://example.com/feed.xml",
            timestampSec: 30,
            noteText: noteText,
            chapterTitle: chapterTitle,
            transcriptText: transcriptText,
            tags: tags,
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle
        )
    }
}
