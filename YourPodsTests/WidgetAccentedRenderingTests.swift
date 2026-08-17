import XCTest
@testable import YourPods

/// TDD tests for iOS 26 widget accented-rendering compatibility.
///
/// iOS 26 Liquid Glass introduces an "accented rendering mode" that tints
/// widget content and replaces backgrounds with glass effects. Without
/// explicit `widgetAccentedRenderingMode(.fullColor)` on artwork images,
/// the system desaturates/tints them into solid blobs. This test suite
/// verifies the data layer supports the information needed for correct
/// rendering (artwork paths, up-next items) and that the rendering-
/// critical model defaults are set correctly.
///
/// The actual SwiftUI rendering is verified visually on-device; these
/// tests gate the data contracts that the views depend on.
final class WidgetAccentedRenderingTests: XCTestCase {

    // MARK: - Artwork path preservation (rendering depends on non-nil artwork)

    /// Table-driven: the widget artworkImage helper shows a placeholder blob
    /// when artworkPath is nil. Verify the data pipeline preserves paths for
    /// both now-playing and up-next items so artwork renders full-color.
    func test_artworkPaths_preservedThroughEncodeDecode() throws {
        let cases: [(label: String, nowArt: String?, upNextArt: [String?])] = [
            ("both present",   "/tmp/now.jpg",  ["/tmp/up1.jpg", nil]),
            ("now nil",        nil,             ["/tmp/up1.jpg"]),
            ("all nil",        nil,             []),
        ]

        for c in cases {
            let upNext = c.upNextArt.enumerated().map {
                WidgetUpNextItem(title: "E\($0.offset)", podcastTitle: "P", artworkPath: $0.element)
            }
            let data = ComplicationData(
                nowPlayingTitle: "T", nowPlayingPodcast: "P",
                isPlaying: true, upNextTitle: nil, upNextPodcast: nil,
                queueCount: upNext.count, lastUpdated: Date(),
                artworkPath: c.nowArt, positionSeconds: 0, durationSeconds: 100,
                upNextItems: upNext
            )

            let encoded = try JSONEncoder().encode(data)
            let decoded = try JSONDecoder().decode(ComplicationData.self, from: encoded)

            XCTAssertEqual(decoded.artworkPath, c.nowArt,
                           "\(c.label): nowPlaying artworkPath round-trip failed")
            XCTAssertEqual(decoded.upNextItems.count, upNext.count,
                           "\(c.label): upNextItems count mismatch")
            for (i, item) in decoded.upNextItems.enumerated() {
                XCTAssertEqual(item.artworkPath, c.upNextArt[i],
                               "\(c.label): upNextItems[\(i)] artworkPath mismatch")
            }
        }
    }

    /// Placeholder data must have reasonable values — the widget previews and
    /// Xcode canvas render it, and on iOS 26 the accented mode processes it.
    // TODO: ComplicationData.placeholder was removed — restore or delete this test
    /*
    func test_placeholder_hasPopulatedFields() {
        let p = ComplicationData.placeholder
        XCTAssertNotNil(p.nowPlayingTitle, "Placeholder needs a title for the widget to render text")
        XCTAssertNotNil(p.nowPlayingPodcast, "Placeholder needs a podcast name")
        XCTAssertTrue(p.isPlaying, "Placeholder should show playing state (pause icon)")
        XCTAssertGreaterThan(p.durationSeconds, 0, "Placeholder needs a nonzero duration for the progress bar")
        XCTAssertGreaterThan(p.positionSeconds, 0, "Placeholder needs a nonzero position for the progress bar")
        XCTAssertFalse(p.upNextItems.isEmpty, "Placeholder needs up-next items for the large widget")
    }
    */

    /// Empty data should produce the empty-state view (no blobs). Verify
    /// all fields are nil/false/zero.
    func test_empty_hasNilFields() {
        let e = ComplicationData.empty
        XCTAssertNil(e.nowPlayingTitle)
        XCTAssertNil(e.nowPlayingPodcast)
        XCTAssertFalse(e.isPlaying)
        XCTAssertEqual(e.positionSeconds, 0)
        XCTAssertEqual(e.durationSeconds, 0)
        XCTAssertTrue(e.upNextItems.isEmpty)
        XCTAssertNil(e.artworkPath)
    }
}
