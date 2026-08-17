import XCTest

/// Regression test for the Sleep Timer sheet overlap bug.
///
/// **Root cause:** The SleepTimerSheet is presented from NowPlayingBar, which
/// lives in a ZStack overlay on top of the TabView. When using the `.medium`
/// detent, the default translucent sheet background lets the underlying queue
/// content bleed through, creating a visually cluttered overlap.
///
/// **Fix:** Add `.presentationBackground(.regularMaterial)` to the
/// SleepTimerSheet presentation so the backdrop is opaque enough to prevent
/// content bleed-through.
final class SleepTimerSheetOverlapTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YourPodsTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The `lineCount` lines starting at the first line containing `marker`.
    private func window(after marker: String, in source: String, lineCount: Int = 15) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        return lines[idx..<min(idx + lineCount, lines.count)].joined(separator: "\n")
    }

    /// The SleepTimerSheet's `.sheet` presentation in NowPlayingBar must include
    /// `.presentationBackground` to prevent queue content from bleeding through
    /// the translucent sheet backdrop.
    func test_sleepTimerSheet_hasPresentationBackground() throws {
        let src = try source("YourPods/YourPods/Views/Components/NowPlayingBar.swift")
        guard let block = window(after: "SleepTimerSheet()", in: src) else {
            return XCTFail("SleepTimerSheet presentation not found in NowPlayingBar")
        }
        XCTAssertTrue(block.contains(".presentationBackground"),
            "SleepTimerSheet must have .presentationBackground to prevent overlap with underlying content")
    }
}
