import XCTest

/// Light structural guards for the macOS-only environment-trap fixes
/// (glass environment-trap audit follow-up).
///
/// On macOS, `.sheet` / `.fullScreenCover` open *separate windows* that do NOT
/// inherit `@Observable` environments (see `AppEnvironmentModifier.swift`). A
/// presentation must therefore inject every manager its content reads, or the
/// first `@Environment(Manager.self)` read traps (`EXC_BREAKPOINT`). These traps
/// are not reproducible on the iOS simulator (iOS sheets inherit), so the
/// call-site invariant is asserted structurally — same approach as
/// `StartupOverlayEnvironmentTests`.
final class MacSheetEnvironmentInjectionTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YourPodsTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The `lineCount` lines starting at the first line containing `marker`.
    private func window(after marker: String, in source: String, lineCount: Int = 10) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        return lines[idx..<min(idx + lineCount, lines.count)].joined(separator: "\n")
    }

    func test_libraryView_episodeDetailSheet_injectsRequiredManagers() throws {
        let src = try source("YourPods/YourPods/Views/LibraryView.swift")
        guard let block = window(after: ".sheet(item: $episodeDetailItem)", in: src) else {
            return XCTFail("EpisodeDetailSheet presentation not found in LibraryView")
        }
        for inj in [".environment(settingsManager)", ".environment(playerManager)",
                    ".environment(podcastManager)", ".environment(downloadManager)",
                    ".environment(navigationState)"] {
            XCTAssertTrue(block.contains(inj),
                "LibraryView's EpisodeDetailSheet must inject \(inj) — macOS sheets don't inherit @Observable env")
        }
    }

    func test_libraryView_moveToGroupSheets_injectPodcastManager() throws {
        let src = try source("YourPods/YourPods/Views/LibraryView.swift")
        for marker in ["MoveToGroupSheet(podcast:", "BulkMoveToGroupSheet("] {
            guard let block = window(after: marker, in: src, lineCount: 12) else {
                return XCTFail("\(marker) presentation not found in LibraryView")
            }
            XCTAssertTrue(block.contains(".environment(podcastManager)"),
                "\(marker) must inject podcastManager — read at the sheet root on macOS")
        }
    }

    func test_nowPlayingBar_sleepTimerSheet_injectsSettings() throws {
        let src = try source("YourPods/YourPods/Views/Components/NowPlayingBar.swift")
        guard let block = window(after: "SleepTimerSheet()", in: src) else {
            return XCTFail("SleepTimerSheet presentation not found in NowPlayingBar")
        }
        XCTAssertTrue(block.contains(".environment(settings)"),
            "SleepTimerSheet presentation must inject settings (its glass capsules + future direct reads) for macOS")
    }
}
