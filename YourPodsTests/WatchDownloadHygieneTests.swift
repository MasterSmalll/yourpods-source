// YourPodsTests/WatchDownloadHygieneTests.swift
import XCTest
@testable import YourPods

final class WatchDownloadHygieneTests: XCTestCase {

    func test_filename_isDeterministic() {
        let longId = String(repeating: "https://example.com/very/long/guid?", count: 6)
        XCTAssertEqual(WatchDownloadHygiene.filename(forEpisodeId: longId),
                       WatchDownloadHygiene.filename(forEpisodeId: longId))
    }

    func test_filename_shortId_staysHumanReadable() {
        // Short ids keep the legacy sanitized form so existing files stay reachable.
        XCTAssertEqual(WatchDownloadHygiene.filename(forEpisodeId: "abc/123"), "abc_123.mp3")
    }

    func test_filename_longId_isHashedAndBounded() {
        let longId = String(repeating: "x", count: 200)
        let name = WatchDownloadHygiene.filename(forEpisodeId: longId)
        XCTAssertTrue(name.hasPrefix("episode_"))
        XCTAssertTrue(name.hasSuffix(".mp3"))
        XCTAssertLessThan(name.count, 90)
    }

    func test_orphans_returnsUnreferencedFilesOnly() {
        let orphans = WatchDownloadHygiene.orphans(
            existingFiles: ["a.mp3", "b.mp3", "keep.mp3"],
            referenced: ["keep.mp3"])
        XCTAssertEqual(Set(orphans), ["a.mp3", "b.mp3"])
    }

    func test_orphans_neverDeletesNonAudioFiles() {
        // EDGE: the Documents dir also holds the diagnostic log and defaults artifacts.
        let orphans = WatchDownloadHygiene.orphans(
            existingFiles: ["notes.txt", "a.mp3"], referenced: [])
        XCTAssertEqual(orphans, ["a.mp3"])
    }
}
