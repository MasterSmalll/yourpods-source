import UIKit
import ImageIO

/// Loads podcast artwork for the Home Screen widget **downsampled** to the size
/// it will actually be drawn at.
///
/// Widget extensions run under a hard (~30MB) memory budget. `UIImage(contentsOfFile:)`
/// decodes the file at full resolution — a single 2000×2000 artwork is ~16MB, and
/// the Large widget draws up to five artworks (now-playing + Up Next). That blows
/// the budget, the extension is jetsammed mid-render, and WidgetKit shows the gray
/// redacted placeholder instead of the real (interactive) view.
///
/// ImageIO thumbnail generation decodes straight to the target pixel size without
/// ever materializing the full-resolution bitmap, so memory stays bounded
/// regardless of the source file's dimensions.
enum WidgetArtworkLoader {
    /// Decode `path` downsampled so its largest dimension is at most
    /// `maxPixelSize` **pixels** (caller accounts for screen scale). Never
    /// upscales a source smaller than the cap. Returns nil if the file is
    /// missing or not a decodable image.
    static func downsampledImage(atPath path: String, maxPixelSize: Int) -> UIImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(
            url, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }

        // `...ThumbnailFromImageAlways` + a max-pixel cap decodes straight to the
        // bounded size; `...WithTransform` honors EXIF orientation. Never upscales
        // a source smaller than the cap.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
