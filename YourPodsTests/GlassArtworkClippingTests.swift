import XCTest

/// Regression guard: artwork images using `.fill` content mode must also use
/// `.clipped()` so their overflow is invisible under Liquid Glass compositing.
///
/// On pre-iOS-26, `.clipShape(RoundedRectangle(...))` was sufficient because
/// the material background hid any pixel overflow. With `.glassEffect` the
/// overflow bleeds through the translucent glass, producing a visible "ghost
/// square" above the card (user-reported bug).
final class GlassArtworkClippingTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YourPodsTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Extracts a window of lines around every occurrence of `marker`.
    /// Returns an array of (lineIndex, windowString) tuples.
    private func windows(around marker: String, in source: String, radius: Int = 5) -> [(Int, String)] {
        let lines = source.components(separatedBy: "\n")
        var results: [(Int, String)] = []
        for (idx, line) in lines.enumerated() where line.contains(marker) {
            let lo = max(0, idx - radius)
            let hi = min(lines.count, idx + radius + 1)
            results.append((idx, lines[lo..<hi].joined(separator: "\n")))
        }
        return results
    }

    // MARK: - NowPlayingCard artwork

    /// The NowPlayingCard artwork uses `.aspectRatio(contentMode: .fill)`.
    /// That image MUST be followed by `.clipped()` (before or after `.clipShape`)
    /// so the oversized pixels don't leak through Liquid Glass.
    func test_nowPlayingCard_artworkIsClipped() throws {
        let src = try source("YourPods/YourPods/Views/HomeView.swift")
        let hits = windows(around: "contentMode: .fill", in: src, radius: 6)

        // There should be at least one hit inside the NowPlayingCard struct.
        // Look for hits that are near "artworkSize" (the NowPlayingCard constant).
        let nowPlayingHits = hits.filter { $0.1.contains("artworkSize") || $0.1.contains("Album art") }
        XCTAssertFalse(nowPlayingHits.isEmpty,
            "Expected to find .fill artwork in NowPlayingCard — did the layout change?")

        for (lineIdx, window) in nowPlayingHits {
            XCTAssertTrue(window.contains(".clipped()"),
                "NowPlayingCard artwork (line ~\(lineIdx + 1)) uses .fill but is missing " +
                ".clipped() — image overflow leaks through Liquid Glass (iOS 26).")
        }
    }

    // MARK: - RecentEpisodeCard artwork

    /// The RecentEpisodeCard artwork also uses `.fill` — same clipping requirement.
    func test_recentEpisodeCard_artworkIsClipped() throws {
        let src = try source("YourPods/YourPods/Views/HomeView.swift")
        let hits = windows(around: "contentMode: .fill", in: src, radius: 12)

        // RecentEpisodeCard uses a fixed 110×110 frame.
        let recentHits = hits.filter { $0.1.contains("110") && !$0.1.contains("artworkSize") }
        XCTAssertFalse(recentHits.isEmpty,
            "Expected to find .fill artwork in RecentEpisodeCard — did the layout change?")

        for (lineIdx, window) in recentHits {
            XCTAssertTrue(window.contains(".clipped()"),
                "RecentEpisodeCard artwork (line ~\(lineIdx + 1)) uses .fill but is missing " +
                ".clipped() — image overflow may leak through Liquid Glass (iOS 26).")
        }
    }
}
