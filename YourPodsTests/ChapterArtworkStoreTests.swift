import XCTest
import CoreGraphics
@testable import YourPods

final class ChapterArtworkStoreTests: XCTestCase {

    /// Every `store()` call below writes a real JPEG into the simulator's
    /// Caches directory under a UUID-unique key, so nothing is ever
    /// overwritten and `trimDiskCacheIfNeeded()` never runs to reclaim it.
    /// Tests that call `store()` append the returned key here for teardown.
    private var keysToCleanUp: [String] = []

    override func tearDown() {
        for key in keysToCleanUp {
            ImageCacheStore.shared.removeFromDisk(key: key)
        }
        keysToCleanUp = []
        super.tearDown()
    }

    // MARK: - Key derivation

    func test_cacheKey_isStableForSameInputs() {
        let a = ChapterArtworkStore.cacheKey(audioUrl: "https://e.g/ep1.mp3", index: 3)
        let b = ChapterArtworkStore.cacheKey(audioUrl: "https://e.g/ep1.mp3", index: 3)

        XCTAssertEqual(a, b)
    }

    /// `test_cacheKey_isStableForSameInputs` only proves stability *within one
    /// process* — Swift's `String.hashValue` is also stable within a process
    /// (its seed is fixed once at launch), so that test alone would keep passing
    /// even if `stableHash` were swapped for `.hashValue`, which reseeds every
    /// relaunch and would silently orphan every disk-cached chapter image. A
    /// pinned golden value fails immediately (and non-deterministically across
    /// runs) the moment the hash stops being process-independent.
    func test_cacheKey_matchesKnownHash_forFixedInput() {
        let key = ChapterArtworkStore.cacheKey(audioUrl: "https://e.g/ep1.mp3", index: 3)

        XCTAssertEqual(key, "chapterart:feeb824c2240c31d:3")
    }

    func test_cacheKey_differsByIndex() {
        let a = ChapterArtworkStore.cacheKey(audioUrl: "https://e.g/ep1.mp3", index: 0)
        let b = ChapterArtworkStore.cacheKey(audioUrl: "https://e.g/ep1.mp3", index: 1)

        XCTAssertNotEqual(a, b)
    }

    func test_cacheKey_differsByAudioUrl() {
        let a = ChapterArtworkStore.cacheKey(audioUrl: "https://e.g/ep1.mp3", index: 0)
        let b = ChapterArtworkStore.cacheKey(audioUrl: "https://e.g/ep2.mp3", index: 0)

        XCTAssertNotEqual(a, b)
    }

    func test_cacheKey_isNamespaced() {
        let key = ChapterArtworkStore.cacheKey(audioUrl: "https://e.g/ep1.mp3", index: 0)

        XCTAssertTrue(key.hasPrefix("chapterart:"), "namespace prevents collision with artwork URL keys")
    }

    // MARK: - Store / retrieve

    func test_storesAndRetrievesImage() throws {
        let url = "https://e.g/store-\(UUID().uuidString).mp3"

        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 64),
                                                          audioUrl: url, index: 0))
        keysToCleanUp.append(key)
        let image = ChapterArtworkStore.image(forKey: key)

        XCTAssertNotNil(image)
    }

    /// The OOM guard: a large source image must be downsampled, not stored at
    /// full resolution. 2.75 MB chapter images exist in the wild.
    func test_downsamplesLargeImage() throws {
        let url = "https://e.g/large-\(UUID().uuidString).mp3"
        let large = TestImageFactory.makePNG(size: 2000)

        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: large, audioUrl: url, index: 0))
        keysToCleanUp.append(key)
        let image = try XCTUnwrap(ChapterArtworkStore.image(forKey: key))

        let maxDimension = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(Int(maxDimension), ChapterArtworkStore.maxPixelSize,
                                 "chapter art must be downsampled before caching")
    }

    /// `store()` populates both the memory cache and disk, and `image(forKey:)`
    /// checks memory first — so every test above that stores-then-immediately-
    /// retrieves only ever exercises the NSCache hit path. Evicting the memory
    /// entry forces the `loadFromDisk` fallback (and its JPEG re-encode) to
    /// actually run, confirms the downsampled size survives that round trip,
    /// and confirms the disk hit promotes the image back into the memory
    /// cache (the behavior `image(forKey:)`'s doc comment advertises).
    func test_imageForKey_fallsBackToDisk_afterMemoryEviction() throws {
        let url = "https://e.g/disk-\(UUID().uuidString).mp3"
        let large = TestImageFactory.makePNG(size: 2000)

        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: large, audioUrl: url, index: 0))
        keysToCleanUp.append(key)
        ImageCacheStore.shared.cache.removeObject(forKey: key as NSString)

        let image = try XCTUnwrap(ChapterArtworkStore.image(forKey: key))

        let maxDimension = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(Int(maxDimension), ChapterArtworkStore.maxPixelSize,
                                 "downsampled dimensions must survive the disk round trip")
        XCTAssertNotNil(ImageCacheStore.shared.cache.object(forKey: key as NSString),
                         "a disk hit must promote the image back into the memory cache")
    }

    /// The concrete shape of the "eviction costs a re-extract" contract that
    /// justifies keys being re-derivable from (audioUrl, index):
    /// `test_imageForKey_returnsNil_whenNothingStored` only covers a key that
    /// was *never* populated. This covers a key that WAS stored and then
    /// evicted from both layers — the actual path that must tell a caller to
    /// re-extract rather than surface stale/missing art silently.
    func test_imageForKey_returnsNil_afterFullEviction() throws {
        let url = "https://e.g/evicted-\(UUID().uuidString).mp3"

        let key = try XCTUnwrap(ChapterArtworkStore.store(imageData: TestImageFactory.makePNG(size: 64),
                                                          audioUrl: url, index: 0))
        ImageCacheStore.shared.cache.removeObject(forKey: key as NSString)
        ImageCacheStore.shared.removeFromDisk(key: key)

        XCTAssertNil(ChapterArtworkStore.image(forKey: key))
    }

    func test_returnsNil_forUndecodableData() {
        let url = "https://e.g/bad-\(UUID().uuidString).mp3"

        XCTAssertNil(ChapterArtworkStore.store(imageData: Data([0x00, 0x01, 0x02]),
                                               audioUrl: url, index: 0))
    }

    func test_imageForKey_returnsNil_whenNothingStored() {
        XCTAssertNil(ChapterArtworkStore.image(forKey: "chapterart:never-stored-\(UUID().uuidString):0"))
    }
}
