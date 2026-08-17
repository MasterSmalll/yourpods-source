import XCTest
import SwiftData
@testable import YourPods

// MARK: - LibrarySearchService Tests

final class LibrarySearchServiceTests: XCTestCase {
    
    private var container: ModelContainer!
    private var context: ModelContext!
    
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Podcast.self, Episode.self, configurations: config)
        context = ModelContext(container)
    }
    
    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }
    
    // MARK: - Helpers
    
    private func makePodcast(
        url: String = "https://example.com/feed",
        title: String = "Test Podcast"
    ) -> Podcast {
        let podcast = Podcast(url: url, title: title)
        context.insert(podcast)
        return podcast
    }
    
    private func makeEpisode(
        guid: String = UUID().uuidString,
        title: String = "Test Episode",
        description: String? = nil,
        pubDate: Date? = Date(),
        podcast: Podcast? = nil,
        isStale: Bool = false
    ) -> Episode {
        let ep = Episode(
            guid: guid,
            title: title,
            episodeDescription: description,
            pubDate: pubDate,
            podcast: podcast
        )
        ep.isStale = isStale
        context.insert(ep)
        return ep
    }
    
    // MARK: - Title Search
    
    func test_titleSearch_matchesExactTitle() {
        let podcast = makePodcast()
        _ = makeEpisode(title: "The Swift Programming Language", podcast: podcast)
        _ = makeEpisode(title: "Unrelated Episode", podcast: podcast)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Swift Programming",
            subscriptions: [podcast]
        )
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.episode.title, "The Swift Programming Language")
        XCTAssertEqual(results.first?.matchType, .title)
    }
    
    func test_titleSearch_caseInsensitive() {
        let podcast = makePodcast()
        _ = makeEpisode(title: "BUILDING WITH SWIFTUI", podcast: podcast)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "building with swiftui",
            subscriptions: [podcast]
        )
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.episode.title, "BUILDING WITH SWIFTUI")
    }
    
    func test_titleSearch_partialMatch() {
        let podcast = makePodcast()
        _ = makeEpisode(title: "Understanding Concurrency in Swift", podcast: podcast)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Concurrency",
            subscriptions: [podcast]
        )
        
        XCTAssertEqual(results.count, 1)
    }
    
    func test_titleSearch_excludesStaleEpisodes() {
        let podcast = makePodcast()
        _ = makeEpisode(title: "Stale Swift Episode", podcast: podcast, isStale: true)
        _ = makeEpisode(title: "Active Swift Episode", podcast: podcast, isStale: false)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Swift Episode",
            subscriptions: [podcast]
        )
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.episode.title, "Active Swift Episode")
    }
    
    func test_titleSearch_sortedByPubDateDescending() {
        let podcast = makePodcast()
        let older = makeEpisode(
            title: "Swift Update 1",
            pubDate: Date(timeIntervalSince1970: 1000),
            podcast: podcast
        )
        let newer = makeEpisode(
            title: "Swift Update 2",
            pubDate: Date(timeIntervalSince1970: 2000),
            podcast: podcast
        )
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Swift Update",
            subscriptions: [podcast]
        )
        
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].episode.guid, newer.guid, "Newer episode should come first")
        XCTAssertEqual(results[1].episode.guid, older.guid, "Older episode should come second")
    }
    
    // MARK: - Description Search
    
    func test_descriptionSearch_disabledByDefault() {
        let podcast = makePodcast()
        _ = makeEpisode(
            title: "Unrelated Title",
            description: "We talk about Swift concurrency patterns",
            podcast: podcast
        )
        
        let results = LibrarySearchService.searchEpisodes(
            query: "concurrency patterns",
            subscriptions: [podcast],
            includeDescriptions: false
        )
        
        XCTAssertEqual(results.count, 0, "Should not search descriptions when disabled")
    }
    
    func test_descriptionSearch_findsPartialMatch() {
        let podcast = makePodcast()
        _ = makeEpisode(
            title: "Episode 42",
            description: "Today we discuss advanced Swift concurrency patterns and async/await.",
            podcast: podcast
        )
        
        let results = LibrarySearchService.searchEpisodes(
            query: "concurrency patterns",
            subscriptions: [podcast],
            includeDescriptions: true
        )
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.matchType, .description)
    }
    
    func test_descriptionSearch_returnsSnippet() {
        let podcast = makePodcast()
        _ = makeEpisode(
            title: "Episode 42",
            description: "Today we discuss advanced Swift concurrency patterns and async/await best practices for modern iOS apps.",
            podcast: podcast
        )
        
        let results = LibrarySearchService.searchEpisodes(
            query: "concurrency patterns",
            subscriptions: [podcast],
            includeDescriptions: true
        )
        
        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results.first?.snippet, "Description match should include a snippet")
        XCTAssertTrue(results.first!.snippet!.contains("concurrency"), "Snippet should contain the matched text")
    }
    
    func test_descriptionSearch_stripsHTMLFromSnippet() {
        let podcast = makePodcast()
        _ = makeEpisode(
            title: "Episode 42",
            description: "<p>Today we discuss <b>Swift concurrency</b> patterns.</p>",
            podcast: podcast
        )
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Swift concurrency",
            subscriptions: [podcast],
            includeDescriptions: true
        )
        
        XCTAssertEqual(results.count, 1)
        if let snippet = results.first?.snippet {
            XCTAssertFalse(snippet.contains("<"), "Snippet should not contain HTML tags")
            XCTAssertFalse(snippet.contains(">"), "Snippet should not contain HTML tags")
        }
    }
    
    func test_descriptionSearch_titleMatchesRankAboveDescriptionMatches() {
        let podcast = makePodcast()
        _ = makeEpisode(
            title: "Episode about Kubernetes",
            description: "In this episode we cover Swift patterns for backend development",
            podcast: podcast
        )
        _ = makeEpisode(
            title: "Swift patterns deep dive",
            description: "An unrelated description",
            podcast: podcast
        )
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Swift patterns",
            subscriptions: [podcast],
            includeDescriptions: true
        )
        
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].matchType, .title, "Title match should rank above description match")
        XCTAssertEqual(results[1].matchType, .description, "Description match should rank below title match")
    }
    
    // MARK: - Result Capping
    
    func test_maxResults_capsAtLimit() {
        let podcast = makePodcast()
        for i in 0..<30 {
            _ = makeEpisode(title: "Swift Episode \(i)", podcast: podcast)
        }
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Swift Episode",
            subscriptions: [podcast],
            maxResults: 10
        )
        
        XCTAssertEqual(results.count, 10, "Should cap results at maxResults")
    }
    
    // MARK: - Edge Cases
    
    func test_shortQuery_returnsNoResults() {
        let podcast = makePodcast()
        _ = makeEpisode(title: "AB", podcast: podcast)
        _ = makeEpisode(title: "ABC", podcast: podcast)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "AB",
            subscriptions: [podcast]
        )
        
        XCTAssertEqual(results.count, 0, "Query shorter than minimum length should return no results")
    }
    
    func test_emptyQuery_returnsNoResults() {
        let podcast = makePodcast()
        _ = makeEpisode(title: "Test Episode", podcast: podcast)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "",
            subscriptions: [podcast]
        )
        
        XCTAssertEqual(results.count, 0)
    }
    
    func test_EDGE_specialCharactersInQuery_handledGracefully() {
        let podcast = makePodcast()
        _ = makeEpisode(title: "What's new in Swift?", podcast: podcast)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "What's new",
            subscriptions: [podcast]
        )
        
        // Should not crash — result count depends on whether the match succeeds
        XCTAssertTrue(results.count <= 1)
    }
    
    func test_EDGE_podcastWithNoEpisodes_doesNotCrash() {
        let podcast = makePodcast()
        // No episodes added
        
        let results = LibrarySearchService.searchEpisodes(
            query: "anything",
            subscriptions: [podcast]
        )
        
        XCTAssertEqual(results.count, 0)
    }
    
    func test_EDGE_episodeWithNilDescription_doesNotCrash() {
        let podcast = makePodcast()
        _ = makeEpisode(title: "No Description", description: nil, podcast: podcast)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "No Description",
            subscriptions: [podcast],
            includeDescriptions: true
        )
        
        // Should find by title, not crash on nil description
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.matchType, .title)
    }
    
    // MARK: - Snippet Extraction
    
    func test_extractSnippet_centersOnMatch() {
        let text = "This is a long piece of text where we eventually talk about Swift concurrency and how it changed everything in modern iOS development."
        let snippet = LibrarySearchService.extractSnippet(from: text, query: "Swift concurrency")
        
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.contains("Swift concurrency"))
    }
    
    func test_extractSnippet_stripsHTML() {
        let text = "<p>Discussing <b>Swift concurrency</b> in depth.</p>"
        let snippet = LibrarySearchService.extractSnippet(from: text, query: "Swift concurrency")
        
        XCTAssertNotNil(snippet)
        XCTAssertFalse(snippet!.contains("<"))
    }
    
    func test_extractSnippet_noMatch_returnsNil() {
        let text = "This text does not contain the search term."
        let snippet = LibrarySearchService.extractSnippet(from: text, query: "nonexistent")
        
        XCTAssertNil(snippet)
    }
    
    // MARK: - Multi-podcast search
    
    func test_searchAcrossMultiplePodcasts() {
        let podcast1 = makePodcast(url: "https://example.com/feed1", title: "Podcast One")
        let podcast2 = makePodcast(url: "https://example.com/feed2", title: "Podcast Two")
        _ = makeEpisode(title: "Swift on the Server", podcast: podcast1)
        _ = makeEpisode(title: "Server-Side Swift", podcast: podcast2)
        _ = makeEpisode(title: "Unrelated Topic", podcast: podcast2)
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Swift",
            subscriptions: [podcast1, podcast2]
        )
        
        XCTAssertEqual(results.count, 2)
    }
    
    // MARK: - Deduplication: title match should not also appear as description match
    
    func test_titleAndDescriptionMatch_onlyCountedOnce() {
        let podcast = makePodcast()
        _ = makeEpisode(
            title: "Swift concurrency deep dive",
            description: "A detailed look at Swift concurrency including actors and async/await.",
            podcast: podcast
        )
        
        let results = LibrarySearchService.searchEpisodes(
            query: "Swift concurrency",
            subscriptions: [podcast],
            includeDescriptions: true
        )
        
        XCTAssertEqual(results.count, 1, "Episode matching both title and description should appear once as a title match")
        XCTAssertEqual(results.first?.matchType, .title)
    }
}
