import XCTest
import UIKit
@testable import YourPods

final class WatchArtworkDownsamplerTests: XCTestCase {

    private func pngData(side: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.pngData()!
    }

    func test_downsample_capsLongestSide() {
        let data = pngData(side: 1200)
        let cg = WatchArtworkDownsampler.downsample(data: data, maxPixelSize: 256)
        XCTAssertNotNil(cg)
        XCTAssertLessThanOrEqual(max(cg!.width, cg!.height), 256)
    }

    func test_downsample_smallImagePassesThrough() {
        let data = pngData(side: 100)
        let cg = WatchArtworkDownsampler.downsample(data: data, maxPixelSize: 256)
        XCTAssertNotNil(cg)
        XCTAssertLessThanOrEqual(max(cg!.width, cg!.height), 256)
    }

    func test_downsample_garbageData_returnsNil() {
        XCTAssertNil(WatchArtworkDownsampler.downsample(data: Data([0x00, 0x01]), maxPixelSize: 256))
    }
}
