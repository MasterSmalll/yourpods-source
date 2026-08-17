import XCTest
import UIKit
@testable import YourPods

/// Regression guard for the Home Screen widget "not painting" / redacted bug.
///
/// Widget extensions get a hard (~30MB) memory budget. Decoding a full-resolution
/// podcast artwork (often 1400–3000px) into a `UIImage` blows that budget — the
/// Large widget decodes up to five artworks (now-playing + Up Next) — and the
/// extension is jetsammed mid-render, so WidgetKit falls back to the gray
/// redacted placeholder and the interactive `Button(intent:)` controls never go
/// live (taps fall through to opening the app).
///
/// `WidgetArtworkLoader` must produce a *downsampled* thumbnail via ImageIO so a
/// full-resolution bitmap is never materialized in the widget's address space.
final class WidgetArtworkLoaderTests: XCTestCase {

    private var tempURL: URL?

    override func tearDown() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Render an opaque square JPEG of `side` pixels (scale 1) and write it to a
    /// unique temp file, returning the path.
    private func writeJPEG(side: CGFloat) throws -> String {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { ctx in
                UIColor.systemIndigo.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget_art_test_\(UUID().uuidString).jpg")
        try data.write(to: url)
        tempURL = url
        return url.path
    }

    // MARK: - Tests

    func test_downsampledImage_capsLargestPixelDimensionAtMaxPixelSize() throws {
        // Given a 2000x2000 JPEG (typical full-res podcast artwork)
        let path = try writeJPEG(side: 2000)

        // When the widget loads it downsampled to 270px (90pt @3x)
        let thumb = try XCTUnwrap(WidgetArtworkLoader.downsampledImage(atPath: path, maxPixelSize: 270))

        // Then the decoded bitmap is capped at 270px on its largest side —
        // it never materializes the 2000px source in widget memory.
        let pixelWidth = thumb.size.width * thumb.scale
        let pixelHeight = thumb.size.height * thumb.scale
        let largestSide = Int(max(pixelWidth, pixelHeight).rounded())
        XCTAssertGreaterThan(largestSide, 0)
        XCTAssertLessThanOrEqual(largestSide, 270)
    }

    func test_downsampledImage_doesNotUpscaleSmallSource() throws {
        // Given a source already smaller than the requested cap
        let path = try writeJPEG(side: 120)

        // When asked for a 270px thumbnail
        let thumb = try XCTUnwrap(WidgetArtworkLoader.downsampledImage(atPath: path, maxPixelSize: 270))

        // Then it stays at the source size (no wasteful upscale)
        let largestSide = Int((max(thumb.size.width, thumb.size.height) * thumb.scale).rounded())
        XCTAssertLessThanOrEqual(largestSide, 120)
    }

    func test_downsampledImage_returnsNilForMissingFile() {
        XCTAssertNil(
            WidgetArtworkLoader.downsampledImage(atPath: "/no/such/file.jpg", maxPixelSize: 100)
        )
    }
}
