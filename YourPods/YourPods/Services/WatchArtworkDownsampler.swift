import Foundation
import ImageIO
import CoreGraphics

/// ImageIO thumbnail decoding with bounded memory — full-resolution UIImage(data:)
/// decodes of podcast covers are the widget-extension OOM crash class; the watch
/// app has the same constraint. Mirrors WidgetArtworkLoader (iOS).
enum WatchArtworkDownsampler {
    static func downsample(data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}
