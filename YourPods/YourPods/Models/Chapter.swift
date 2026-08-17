import Foundation

struct Chapter: Codable, Identifiable, Hashable {
    /// HAZARD: two chapters sharing a `startTime` — unusual but not
    /// impossible in a malformed feed, and deterministically resolvable at
    /// the `ChapterCoordinator` level (see `ChapterCoordinatorTests
    /// .test_currentIndex_tieBreaksTowardLaterDeclaredChapter_whenStartTimesMatch`)
    /// — collide on `id` here. A `ForEach(chapters, id: \.id)` over such a
    /// list would either crash or silently misrender depending on SwiftUI's
    /// diffing. `ChapterListSheet` re-derives a collision-safe id
    /// from the array index instead of trusting this one
    /// (`ForEach(..., id: \.offset)`) — any future `ForEach` over `[Chapter]`
    /// must do the same rather than keying off `\.id`/`\.element.id`.
    var id: Double { startTime }

    let startTime: Double  // seconds
    let title: String
    let img: String?       // optional chapter image URL (feed-supplied)
    let url: String?       // optional link

    /// Cache key for artwork extracted from the audio file itself, resolved
    /// against `ImageCacheStore`. Format: "chapterart:<audioUrlHash>:<index>".
    /// Re-derivable, so eviction costs a re-extract rather than a permanent loss.
    let embeddedImageKey: String?

    /// ID3 CTOC semantics: a CHAP frame not referenced by the table of contents
    /// is hidden. Hidden chapters stay in the array so time lookups resolve;
    /// they are filtered for display only.
    let isHidden: Bool

    init(startTime: Double,
         title: String,
         img: String? = nil,
         url: String? = nil,
         embeddedImageKey: String? = nil,
         isHidden: Bool = false) {
        self.startTime = startTime
        self.title = title
        self.img = img
        self.url = url
        self.embeddedImageKey = embeddedImageKey
        self.isHidden = isHidden
    }

    /// `Chapter` is a value type, so callers rebuild rather than mutate in place.
    func unhidden() -> Chapter {
        Chapter(startTime: startTime, title: title, img: img, url: url,
                embeddedImageKey: embeddedImageKey, isHidden: false)
    }

    // Hand-rolled decoding: chaptersJSON persisted before embeddedImageKey and
    // isHidden existed must still decode. Synthesized Codable would throw.
    enum CodingKeys: String, CodingKey {
        case startTime, title, img, url, embeddedImageKey, isHidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try c.decode(Double.self, forKey: .startTime)
        title = try c.decode(String.self, forKey: .title)
        img = try c.decodeIfPresent(String.self, forKey: .img)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        embeddedImageKey = try c.decodeIfPresent(String.self, forKey: .embeddedImageKey)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}
