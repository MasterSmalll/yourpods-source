import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared test fixture for producing a genuinely decodable PNG, so ImageIO-based
/// tests (downsampling, caching) exercise a real decode path rather than a
/// hand-rolled byte array. Shared between `ChapterArtworkStoreTests` and
/// `ChapterArtworkViewTests` so the two don't duplicate the helper.
enum TestImageFactory {
    /// A solid-color, square, `size` × `size` pixel PNG.
    static func makePNG(size: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let cg = ctx.makeImage()!
        #if canImport(UIKit)
        return UIImage(cgImage: cg).pngData()!
        #else
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])!
        #endif
    }
}
