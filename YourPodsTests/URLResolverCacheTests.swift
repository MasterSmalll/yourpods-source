import XCTest
@testable import YourPods

// MARK: - URL Resolver Cache Tests

/// Tests URLResolver cache entry TTL logic.
final class URLResolverCacheTests: XCTestCase {
    
    func test_cacheEntry_notExpired_withinTTL() {
        let entry = URLResolver.CacheEntry(
            resolvedUrl: "https://cdn.example.com/audio.mp3",
            resolvedAt: Date()
        )
        XCTAssertFalse(entry.isExpired(ttl: 7200),
                       "Entry created just now should not be expired with 2h TTL")
    }
    
    func test_cacheEntry_expired_afterTTL() {
        let entry = URLResolver.CacheEntry(
            resolvedUrl: "https://cdn.example.com/audio.mp3",
            resolvedAt: Date().addingTimeInterval(-7201)  // 2h + 1s ago
        )
        XCTAssertTrue(entry.isExpired(ttl: 7200),
                      "Entry older than TTL should be expired")
    }
    
    func test_cacheEntry_notExpired_atExactTTL() {
        let entry = URLResolver.CacheEntry(
            resolvedUrl: "https://cdn.example.com/audio.mp3",
            resolvedAt: Date().addingTimeInterval(-7199)  // Just under 2h
        )
        XCTAssertFalse(entry.isExpired(ttl: 7200),
                       "Entry at TTL boundary should not be expired")
    }
}
