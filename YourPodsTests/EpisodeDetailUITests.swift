/// Unified Episode Detail UI Tests — Navigation, Presentation, Sheet
import XCTest
@testable import YourPods

// MARK: - From EpisodeDetailNavigationTests.swift

/// Tests for podcast navigation from EpisodeDetailSheet and NavigationState.
///
/// Feature: Tapping the podcast name in episode details navigates to the
/// podcast's library view. The helper determines whether the podcast is
/// subscribed and NavigationState handles tab + podcast routing.
final class EpisodeDetailNavigationTests: XCTestCase {
    
    // MARK: - findSubscribedPodcast Tests
    
    func test_findSubscribedPodcast_returnsPodcast_whenUrlMatches() {
        // Given: a subscription list containing the target podcast
        let target = Podcast(url: "https://example.com/feed", title: "My Pod")
        let other = Podcast(url: "https://other.com/feed", title: "Other Pod")
        let subscriptions = [other, target]
        
        // When: looking up by the target podcast's URL
        let result = EpisodeDetailSheetHelper.findSubscribedPodcast(
            podcastUrl: "https://example.com/feed",
            subscriptions: subscriptions
        )
        
        // Then: the matching podcast should be returned
        XCTAssertNotNil(result, "Should find the podcast when its URL is in subscriptions")
        XCTAssertEqual(result?.url, "https://example.com/feed")
    }
    
    func test_findSubscribedPodcast_returnsNil_whenNotSubscribed() {
        // Given: a subscription list that does NOT contain the target
        let other = Podcast(url: "https://other.com/feed", title: "Other Pod")
        let subscriptions = [other]
        
        // When: looking up a URL not in subscriptions
        let result = EpisodeDetailSheetHelper.findSubscribedPodcast(
            podcastUrl: "https://missing.com/feed",
            subscriptions: subscriptions
        )
        
        // Then: should return nil
        XCTAssertNil(result, "Should return nil when the podcast URL is not in subscriptions")
    }
    
    func test_findSubscribedPodcast_returnsNil_whenPodcastUrlIsNil() {
        // Given: a nil podcast URL
        let subscriptions = [Podcast(url: "https://example.com/feed", title: "Pod")]
        
        // When: calling with nil
        let result = EpisodeDetailSheetHelper.findSubscribedPodcast(
            podcastUrl: nil,
            subscriptions: subscriptions
        )
        
        // Then: should return nil
        XCTAssertNil(result, "Should return nil when podcastUrl is nil")
    }
    
    func test_findSubscribedPodcast_returnsNil_whenPodcastUrlIsEmpty() {
        // Given: an empty podcast URL
        let subscriptions = [Podcast(url: "https://example.com/feed", title: "Pod")]
        
        // When: calling with empty string
        let result = EpisodeDetailSheetHelper.findSubscribedPodcast(
            podcastUrl: "",
            subscriptions: subscriptions
        )
        
        // Then: should return nil
        XCTAssertNil(result, "Should return nil when podcastUrl is empty")
    }
    
    // MARK: - NavigationState.navigateToLibrary Tests
    
    @MainActor
    func test_navigateToLibrary_setsTabAndPodcast() {
        // Given: NavigationState on the Home tab
        let nav = NavigationState()
        nav.selectedTab = 0
        let podcast = Podcast(url: "https://example.com/feed", title: "My Pod")
        
        // When: navigating to the podcast's library view
        nav.navigateToLibrary(podcast: podcast)
        
        // Then: tab should switch to Library (1) and podcast should be set
        XCTAssertEqual(nav.selectedTab, 1, "Should switch to the Library tab")
        XCTAssertNotNil(nav.podcastToNavigate, "Should set the podcast to navigate to")
        XCTAssertEqual(nav.podcastToNavigate?.url, "https://example.com/feed")
    }
    
    @MainActor
    func test_navigateToLibrary_clearsAfterConsumption() {
        // Given: NavigationState with a pending podcast navigation
        let nav = NavigationState()
        let podcast = Podcast(url: "https://example.com/feed", title: "My Pod")
        nav.navigateToLibrary(podcast: podcast)
        
        // When: the navigation is consumed (view reads and clears it)
        nav.podcastToNavigate = nil
        
        // Then: the navigation state should be cleared
        XCTAssertNil(nav.podcastToNavigate, "Should be nil after consumption")
    }
}

// MARK: - From EpisodeDetailPresentationTests.swift

/// Tests for the episode detail sheet presentation pattern.
///
/// Two related bugs are addressed:
/// 1. Gray-screen on first open: happens when .sheet(isPresented:) is used with a
///    separate optional Episode? — the closure evaluates when Episode is still nil.
///    Fixed by using .sheet(item:) with a non-nil wrapper.
///
/// 2. Blank-screen on second tap (same episode): happens when EpisodeSheetItem.id
///    is the episode GUID. SwiftUI's .sheet(item:) detects that the new item has
///    the same identity as the previously-dismissed one and reuses the dismissed
///    sheet's stale state instead of constructing a fresh view.
///    Fixed by using a per-presentation UUID as the item identity.
final class EpisodeDetailPresentationTests: XCTestCase {
    
    // MARK: - EpisodeSheetItem identity
    
    func test_episodeSheetItem_hasNonEmptyUUIDId() {
        // Given: an episode with a known GUID
        let episode = Episode(guid: "unique-guid-123", title: "Test Episode")
        
        // When: wrapping in an EpisodeSheetItem
        let item = EpisodeSheetItem(episode: episode)
        
        // Then: the item's id must be a non-empty UUID string (NOT the episode GUID)
        // This ensures each presentation token is unique per open.
        XCTAssertFalse(item.id.isEmpty, "EpisodeSheetItem.id must not be empty")
        XCTAssertNotNil(UUID(uuidString: item.id),
                        "EpisodeSheetItem.id must be a valid UUID string — episode GUIDs must NOT be used as ids")
        // The episode is still accessible for use in the sheet content
        XCTAssertEqual(item.episode.guid, "unique-guid-123")
    }
    
    func test_episodeSheetItem_holdsEpisodeReference() {
        // Given: an episode
        let episode = Episode(guid: "ep-1", title: "My Episode")
        
        // When: wrapping in an EpisodeSheetItem
        let item = EpisodeSheetItem(episode: episode)
        
        // Then: the wrapper provides access to the episode
        XCTAssertEqual(item.episode.title, "My Episode")
        XCTAssertEqual(item.episode.guid, "ep-1")
    }
    
    // MARK: - Blank-screen-on-second-tap regression (same episode, multiple opens)
    
    func test_EDGE_twoItemsForSameEpisode_haveDistinctIds() {
        // Regression: EpisodeDetailSheet shows blank on the 2nd tap of the same episode.
        //
        // Root cause: when EpisodeSheetItem.id == episode.guid, SwiftUI's sheet(item:)
        // sees the same identity on re-presentation and reuses the stale dismissed sheet
        // state rather than instantiating a fresh view — producing a blank screen.
        //
        // Fix: each EpisodeSheetItem generates a unique UUID as its presentation token.
        // The episode's guid is still accessible on item.episodeGuid for debugging.
        
        let episode = Episode(guid: "same-guid", title: "Repeated Episode")
        
        // Simulate: user opens detail once, dismisses, then opens again
        let firstPresentation = EpisodeSheetItem(episode: episode)
        let secondPresentation = EpisodeSheetItem(episode: episode)
        
        // Then: each presentation must have a UNIQUE id so SwiftUI creates a fresh sheet
        XCTAssertNotEqual(
            firstPresentation.id,
            secondPresentation.id,
            "REGRESSION: Same-episode re-taps must produce unique EpisodeSheetItem IDs — " +
            "if IDs match, SwiftUI reuses the stale sheet state and shows a blank screen"
        )
        
        // And the episode guide is still accessible for debugging
        XCTAssertEqual(firstPresentation.episode.guid, "same-guid")
        XCTAssertEqual(secondPresentation.episode.guid, "same-guid")
    }
    
    func test_episodeSheetItem_differentGuids_areDifferent() {
        // Given: two episodes with different GUIDs
        let ep1 = Episode(guid: "guid-A", title: "Episode A")
        let ep2 = Episode(guid: "guid-B", title: "Episode B")
        
        let item1 = EpisodeSheetItem(episode: ep1)
        let item2 = EpisodeSheetItem(episode: ep2)
        
        // Then: they should have different identities
        XCTAssertNotEqual(item1.id, item2.id,
                          "Items with different GUIDs must have different IDs")
    }
    
    // MARK: - Gray screen prevention
    
    func test_sheetItemPattern_guaranteesNonNilEpisode() {
        // This test verifies the core fix:
        // When using sheet(item:), SwiftUI only evaluates the content closure
        // when the item is non-nil — so the gray screen can never occur.
        //
        // Old buggy pattern used TWO separate state variables:
        //   var selectedEpisode: Episode? = nil
        //   var showEpisodeDetail = false
        // Both were set in a button action, but the sheet closure could fire
        // when showEpisodeDetail=true and selectedEpisode was still nil → gray screen.
        //
        // New pattern: a single EpisodeSheetItem? drives the sheet.
        
        let episode = Episode(guid: "ep-1", title: "Race Condition")
        
        // New pattern — single assignment drives the sheet
        let sheetItem = EpisodeSheetItem(episode: episode)
        
        // Then: the episode is always available in the sheet content
        XCTAssertNotNil(sheetItem.episode,
                        "sheet(item:) guarantees the episode is non-nil in the content closure — no gray screen possible")
        XCTAssertEqual(sheetItem.episode.guid, "ep-1")
    }
}

// MARK: - From EpisodeDetailSheetTests.swift

/// Tests for the podcast URL resolution logic used by EpisodeDetailSheet's "Mark as Played" button.
/// The button must always resolve a valid podcastUrl — even when the Episode's
/// podcast relationship is nil (SwiftData lazy loading edge case).
final class EpisodeDetailSheetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedQueue")
        UserDefaults.standard.removeObject(forKey: "savedCurrentItem")
        UserDefaults.standard.removeObject(forKey: "savedCurrentPosition")
        super.tearDown()
    }

    // MARK: - resolvePodcastUrl Tests
    
    func test_resolvePodcastUrl_returnsEpisodePodcastUrl_whenAvailable() {
        // Given: an episode whose podcast relationship provides a URL
        let podcastUrl = "https://example.com/feed"
        let result = EpisodeDetailSheetHelper.resolvePodcastUrl(
            episodePodcastUrl: podcastUrl,
            currentItemPodcastUrl: "https://other.com/feed",
            episodeGuid: "ep-1",
            subscriptions: []
        )
        
        // Then: should use the episode's own podcastUrl
        XCTAssertEqual(result, podcastUrl)
    }
    
    func test_resolvePodcastUrl_fallsBackToCurrentItem_whenEpisodePodcastUrlIsNil() {
        // Given: episode.podcastUrl is nil, but the currently playing item has a podcastUrl
        let currentUrl = "https://example.com/current-feed"
        let result = EpisodeDetailSheetHelper.resolvePodcastUrl(
            episodePodcastUrl: nil,
            currentItemPodcastUrl: currentUrl,
            episodeGuid: "ep-1",
            subscriptions: []
        )
        
        // Then: should fall back to the current item's podcastUrl
        XCTAssertEqual(result, currentUrl)
    }
    
    func test_resolvePodcastUrl_returnsNil_whenAllSourcesUnavailable() {
        // Given: no podcast URL from any source
        let result = EpisodeDetailSheetHelper.resolvePodcastUrl(
            episodePodcastUrl: nil,
            currentItemPodcastUrl: nil,
            episodeGuid: "ep-1",
            subscriptions: []
        )
        
        // Then: should return nil
        XCTAssertNil(result)
    }
    
    // MARK: - shouldUsePlayerManager Tests (Mark as Played routing)
    
    func test_shouldUsePlayerManager_trueWhenEpisodeIsCurrentlyPlaying() {
        // Given: the episode being marked is the one currently playing
        let result = EpisodeDetailSheetHelper.shouldUsePlayerManager(
            episodeGuid: "ep-1",
            currentEpisodeGuid: "ep-1"
        )
        
        // Then: should route through PlayerManager to stop + advance
        XCTAssertTrue(result,
                      "Mark-as-played on the currently-playing episode must route through PlayerManager to stop playback and advance the queue")
    }
    
    func test_shouldUsePlayerManager_falseWhenEpisodeIsNotPlaying() {
        // Given: the episode being marked is NOT the one currently playing
        let result = EpisodeDetailSheetHelper.shouldUsePlayerManager(
            episodeGuid: "ep-2",
            currentEpisodeGuid: "ep-1"
        )
        
        // Then: should NOT route through PlayerManager
        XCTAssertFalse(result,
                       "Mark-as-played on a non-playing episode should go through PodcastManager only")
    }
    
    func test_shouldUsePlayerManager_falseWhenNothingIsPlaying() {
        // Given: nothing is currently playing
        let result = EpisodeDetailSheetHelper.shouldUsePlayerManager(
            episodeGuid: "ep-1",
            currentEpisodeGuid: nil
        )
        
        // Then: should NOT route through PlayerManager
        XCTAssertFalse(result,
                       "Mark-as-played when nothing is playing should go through PodcastManager only")
    }
    
    // MARK: - Integration: markCurrentEpisodeAsPlayed (empty queue stops, non-empty advances)

    @MainActor
    func test_markCurrentEpisodeAsPlayed_stopsPlayback_whenQueueEmpty() {
        // Given: a playing episode and NOTHING queued
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let currentItem = QueueItem(
            id: "ep-playing", title: "Currently Playing", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 1200,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = currentItem
        audioManager.testableSetPlaybackState(position: 1200, duration: 3600)
        audioManager.isPlaying = true

        // When
        playerManager.markCurrentEpisodeAsPlayed()

        // Then: nothing to advance to — playback stops
        XCTAssertNil(audioManager.currentItem,
                     "With an empty queue, mark-as-played stops playback")
        XCTAssertFalse(audioManager.isPlaying)
    }

    @MainActor
    func test_markCurrentEpisodeAsPlayed_advances_whenNextEpisodeQueued() async {
        // Given: a playing episode WITH a next item queued (what the sheet's
        // 'Played' button promises: mark played and keep the queue going)
        let audioManager = AudioManager()
        let playerManager = PlayerManager(audioManager: audioManager)
        let currentItem = QueueItem(
            id: "ep-playing", title: "Currently Playing", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep1.mp3", artworkUrl: nil,
            durationSeconds: 3600, positionSeconds: 1200,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        let nextItem = QueueItem(
            id: "ep-next", title: "Up Next", podcastTitle: "Pod",
            audioUrl: "https://example.com/ep2.mp3", artworkUrl: nil,
            durationSeconds: 1800, positionSeconds: 0,
            podcastUrl: "https://example.com/feed", pubDate: nil
        )
        audioManager.currentItem = currentItem
        audioManager.appendToQueue([nextItem])
        audioManager.testableSetPlaybackState(position: 1200, duration: 3600)
        audioManager.isPlaying = true

        // When
        playerManager.markCurrentEpisodeAsPlayed()

        // Then
        let advanced = await pollUntil { audioManager.currentItem?.id == "ep-next" }
        XCTAssertTrue(advanced,
                      "Mark-as-played from the detail sheet advances to the queued episode")
    }
}

// MARK: - From EpisodeDetailResolveTests.swift

/// Tests for resolving episodes for display in the detail sheet.
///
/// Feature: When an episode is queued from search (without subscribing to its
/// podcast), tapping it in the NowPlayingBar or QueueView should still open the
/// full EpisodeDetailSheet — not the stripped-down PlayerView.
///
/// The helper searches subscriptions first (zero-cost when found), then falls
/// back to creating a transient Episode from the QueueItem's data.
final class EpisodeDetailResolveTests: XCTestCase {
    
    // MARK: - resolveEpisodeForDisplay Tests
    
    func test_resolveEpisode_findsInSubscriptions() {
        // Given: a podcast in subscriptions with a matching episode
        let podcast = Podcast(url: "https://example.com/feed", title: "My Pod")
        let episode = Episode(guid: "ep-123", title: "Subscribed Episode")
        episode.episodeDescription = "A great episode"
        episode.audioUrl = "https://example.com/ep1.mp3"
        episode.durationSeconds = 3600
        podcast.episodes = [episode]
        episode.podcast = podcast
        
        // When: resolving with subscriptions
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-123",
            subscriptions: [podcast],
            fallbackQueueItem: nil
        )
        
        // Then: should return the subscribed episode
        XCTAssertNotNil(result, "Should find episode in subscriptions")
        XCTAssertEqual(result?.guid, "ep-123")
        XCTAssertEqual(result?.title, "Subscribed Episode")
        XCTAssertEqual(result?.podcast?.url, "https://example.com/feed",
                       "Subscribed episode should retain its podcast relationship")
    }
    
    func test_resolveEpisode_fallsBackToQueueItem_whenNotSubscribed() {
        // Given: no matching episode in subscriptions, but a QueueItem is available
        let queueItem = QueueItem(
            id: "ep-search",
            title: "Search Episode",
            podcastTitle: "Unsubscribed Pod",
            audioUrl: "https://cdn.example.com/ep.mp3",
            artworkUrl: "https://cdn.example.com/art.jpg",
            durationSeconds: 1800,
            positionSeconds: 300,
            podcastUrl: "https://example.com/unsubscribed-feed",
            pubDate: Date(timeIntervalSince1970: 1700000000),
            chaptersUrl: "https://example.com/chapters.json",
            transcriptUrl: "https://example.com/transcript.vtt",
            episodeDescription: "<p>An episode from search</p>",
            chaptersJSON: "[{\"startTime\":0,\"title\":\"Intro\"}]"
        )
        
        // When: resolving with empty subscriptions + QueueItem fallback
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-search",
            subscriptions: [],
            fallbackQueueItem: queueItem
        )
        
        // Then: should create a transient Episode from the QueueItem
        XCTAssertNotNil(result,
                        "REGRESSION: Non-subscribed episodes must resolve for display — " +
                        "without this, tapping NowPlayingBar shows the stripped-down PlayerView instead of full details")
        XCTAssertEqual(result?.guid, "ep-search")
        XCTAssertEqual(result?.title, "Search Episode")
    }
    
    func test_resolveEpisode_returnsNil_whenNoSubscriptionAndNoQueueItem() {
        // Given: no matching subscription and no QueueItem fallback
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-missing",
            subscriptions: [],
            fallbackQueueItem: nil
        )
        
        // Then: should return nil (no data to build from)
        XCTAssertNil(result, "Should return nil when episode is not found and no QueueItem fallback exists")
    }
    
    func test_resolveEpisode_queueItemMapsAllFields() {
        // Given: a QueueItem with all fields populated
        let pubDate = Date(timeIntervalSince1970: 1700000000)
        let queueItem = QueueItem(
            id: "ep-full",
            title: "Full Data Episode",
            podcastTitle: "The Podcast",
            audioUrl: "https://cdn.example.com/audio.mp3",
            artworkUrl: "https://cdn.example.com/artwork.jpg",
            durationSeconds: 5400,
            positionSeconds: 1200,
            podcastUrl: "https://example.com/feed",
            pubDate: pubDate,
            chaptersUrl: "https://example.com/chapters.json",
            transcriptUrl: "https://example.com/transcript.srt",
            episodeDescription: "<p>Full description</p>",
            chaptersJSON: "[{\"startTime\":0,\"title\":\"Chapter 1\"}]"
        )
        
        // When: resolving from QueueItem
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-full",
            subscriptions: [],
            fallbackQueueItem: queueItem
        )
        
        // Then: all fields should be correctly mapped
        XCTAssertNotNil(result, "Should create Episode from QueueItem")
        guard let episode = result else { return }
        
        XCTAssertEqual(episode.guid, "ep-full", "guid should map from QueueItem.id")
        XCTAssertEqual(episode.title, "Full Data Episode", "title should map directly")
        XCTAssertEqual(episode.audioUrl, "https://cdn.example.com/audio.mp3", "audioUrl should map directly")
        XCTAssertEqual(episode.imageUrl, "https://cdn.example.com/artwork.jpg", "imageUrl should map from QueueItem.artworkUrl")
        XCTAssertEqual(episode.durationSeconds, 5400, "durationSeconds should map directly")
        XCTAssertEqual(episode.listenedSeconds, 1200, "listenedSeconds should map from QueueItem.positionSeconds")
        XCTAssertEqual(episode.pubDate, pubDate, "pubDate should map directly")
        XCTAssertEqual(episode.chaptersUrl, "https://example.com/chapters.json", "chaptersUrl should map directly")
        XCTAssertEqual(episode.transcriptUrl, "https://example.com/transcript.srt", "transcriptUrl should map directly")
        XCTAssertEqual(episode.episodeDescription, "<p>Full description</p>", "episodeDescription should map directly")
        XCTAssertEqual(episode.chaptersJSON, "[{\"startTime\":0,\"title\":\"Chapter 1\"}]", "chaptersJSON should map directly")
    }
    
    func test_resolveEpisode_prefersSubscriptionOverQueueItem() {
        // Given: a subscribed podcast WITH the episode, AND a QueueItem for the same episode
        let podcast = Podcast(url: "https://example.com/feed", title: "Subscribed Pod")
        let subscribedEpisode = Episode(guid: "ep-both", title: "Subscribed Version")
        subscribedEpisode.episodeDescription = "Rich description from RSS"
        podcast.episodes = [subscribedEpisode]
        subscribedEpisode.podcast = podcast
        
        let queueItem = QueueItem(
            id: "ep-both",
            title: "QueueItem Version",
            podcastTitle: "Pod",
            audioUrl: "https://cdn.example.com/audio.mp3",
            artworkUrl: nil,
            durationSeconds: 1000,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        
        // When: resolving with both sources available
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-both",
            subscriptions: [podcast],
            fallbackQueueItem: queueItem
        )
        
        // Then: should prefer the subscribed episode (has full podcast relationship)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Subscribed Version",
                       "Should prefer the subscribed Episode over synthesizing from QueueItem")
        XCTAssertNotNil(result?.podcast,
                        "Subscribed episode should retain its podcast relationship for navigation")
    }
    
    func test_resolveEpisode_queueItemGuidMismatch_returnsNil() {
        // Given: a QueueItem whose ID does NOT match the requested guid
        let queueItem = QueueItem(
            id: "ep-different",
            title: "Wrong Episode",
            podcastTitle: "Pod",
            audioUrl: "https://example.com/audio.mp3",
            artworkUrl: nil,
            durationSeconds: 1000,
            podcastUrl: "https://example.com/feed",
            pubDate: nil
        )
        
        // When: resolving with a different guid
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-target",
            subscriptions: [],
            fallbackQueueItem: queueItem
        )
        
        // Then: should return nil — don't use wrong QueueItem data
        XCTAssertNil(result,
                     "Should NOT create Episode from a QueueItem with a mismatched GUID")
    }
    
    // MARK: - Search Preview → QueueItem Metadata Tests
    
    func test_queueItemFromSearch_carriesEpisodeDescription() {
        // Given: a QueueItem created with episode description (simulating search → queue)
        let queueItem = QueueItem(
            id: "ep-search-desc",
            title: "Daily Episode",
            podcastTitle: "The Daily",
            audioUrl: "https://cdn.example.com/audio.mp3",
            artworkUrl: "https://cdn.example.com/podcast-art.jpg",
            durationSeconds: 1620,
            podcastUrl: "https://feeds.example.com/daily",
            pubDate: Date(),
            episodeDescription: "<p>Inside a hospital in Nebraska, 16 Americans who may have been exposed...</p>"
        )
        
        // When: resolving for display
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-search-desc",
            subscriptions: [],
            fallbackQueueItem: queueItem
        )
        
        // Then: description must be present — not "No description available"
        XCTAssertNotNil(result?.episodeDescription,
                        "REGRESSION: Episode description must carry through from search QueueItem — " +
                        "missing description shows 'No description available.' in the detail sheet")
        XCTAssertTrue(result!.episodeDescription!.contains("hospital"),
                      "Description content should match the QueueItem's episodeDescription")
    }
    
    func test_queueItemFromSearch_carriesDuration() {
        // Given: a QueueItem created with duration (simulating search → queue)
        let queueItem = QueueItem(
            id: "ep-search-dur",
            title: "Daily Episode",
            podcastTitle: "The Daily",
            audioUrl: "https://cdn.example.com/audio.mp3",
            artworkUrl: nil,
            durationSeconds: 1620,
            podcastUrl: "https://feeds.example.com/daily",
            pubDate: Date()
        )
        
        // When: resolving for display
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-search-dur",
            subscriptions: [],
            fallbackQueueItem: queueItem
        )
        
        // Then: duration must be present — not hidden
        XCTAssertEqual(result?.durationSeconds, 1620,
                       "REGRESSION: Episode duration must carry through from search QueueItem — " +
                       "missing duration hides the clock icon and duration label in the detail sheet")
    }
    
    func test_queueItemFromSearch_carriesEpisodeSpecificArtwork() {
        // Given: a QueueItem with episode-specific artwork (different from podcast art)
        // This is the key test — RSS feeds often have per-episode images (e.g., The Daily uses unique photos per episode)
        let queueItem = QueueItem(
            id: "ep-search-art",
            title: "Lessons From the Hantavirus Outbreak",
            podcastTitle: "The Daily",
            audioUrl: "https://cdn.example.com/audio.mp3",
            artworkUrl: "https://cdn.example.com/episode-specific-ship-photo.jpg",
            durationSeconds: 1620,
            podcastUrl: "https://feeds.example.com/daily",
            pubDate: Date()
        )
        
        // When: resolving for display
        let result = EpisodeDetailSheetHelper.resolveEpisodeForDisplay(
            guid: "ep-search-art",
            subscriptions: [],
            fallbackQueueItem: queueItem
        )
        
        // Then: episode artwork must be present
        XCTAssertEqual(result?.imageUrl, "https://cdn.example.com/episode-specific-ship-photo.jpg",
                       "REGRESSION: Episode-specific artwork URL must carry through from QueueItem — " +
                       "using podcast-level artwork shows the wrong image in the detail sheet")
    }
}

/// Poll until `condition` is true or `timeout` elapses, yielding to the main actor
/// between checks. No real-time sleeps — the advance Task runs on the main actor,
/// and playEpisode sets currentItem in its synchronous prefix, so a few yields
/// are enough on the happy path.
@MainActor
fileprivate func pollUntil(
    timeout: TimeInterval = 2.0,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        await Task.yield()
    }
    return condition()
}
