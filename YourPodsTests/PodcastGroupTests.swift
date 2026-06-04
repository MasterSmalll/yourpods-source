import XCTest
@testable import YourPods

/// TDD tests for PodcastGroup model, persistence, and assignment.
final class PodcastGroupTests: XCTestCase {
    
    private let testProfileId = "test-profile-\(UUID().uuidString)"
    
    override func tearDown() {
        super.tearDown()
        // Clean up UserDefaults for test profile
        UserDefaults.standard.removeObject(forKey: "podcastGroups_\(testProfileId)")
    }
    
    // MARK: - Model Creation
    
    func test_createGroup_hasExpectedDefaults() {
        let group = PodcastGroup(name: "News")
        
        XCTAssertFalse(group.id.isEmpty, "Group should have a non-empty ID")
        XCTAssertEqual(group.name, "News")
        XCTAssertEqual(group.sortOrder, 0)
        XCTAssertEqual(group.iconName, "folder.fill")
        XCTAssertNil(group.colorHex)
    }
    
    func test_createGroup_withCustomProperties() {
        let group = PodcastGroup(
            name: "Tech",
            sortOrder: 2,
            iconName: "desktopcomputer",
            colorHex: "#FF5733"
        )
        
        XCTAssertEqual(group.name, "Tech")
        XCTAssertEqual(group.sortOrder, 2)
        XCTAssertEqual(group.iconName, "desktopcomputer")
        XCTAssertEqual(group.colorHex, "#FF5733")
    }
    
    // MARK: - Codable Round-Trip
    
    func test_codableRoundTrip_preservesAllFields() throws {
        let original = PodcastGroup(
            name: "Comedy",
            sortOrder: 3,
            iconName: "face.smiling",
            colorHex: "#00FF00"
        )
        
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PodcastGroup.self, from: data)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.sortOrder, original.sortOrder)
        XCTAssertEqual(decoded.iconName, original.iconName)
        XCTAssertEqual(decoded.colorHex, original.colorHex)
    }
    
    // MARK: - Persistence (Stubs — these MUST fail in Red phase)
    
    func test_saveAndLoadGroups_roundTrip() {
        let groups = [
            PodcastGroup(name: "News", sortOrder: 0),
            PodcastGroup(name: "Tech", sortOrder: 1),
            PodcastGroup(name: "Comedy", sortOrder: 2)
        ]
        
        PodcastGroup.saveGroups(groups, forProfileId: testProfileId)
        let loaded = PodcastGroup.loadGroups(forProfileId: testProfileId)
        
        // STUB returns [] — this MUST fail
        XCTAssertEqual(loaded.count, 3, "Should load 3 saved groups")
        XCTAssertEqual(loaded[0].name, "News")
        XCTAssertEqual(loaded[1].name, "Tech")
        XCTAssertEqual(loaded[2].name, "Comedy")
    }
    
    func test_loadGroups_returnsEmptyForUnknownProfile() {
        let loaded = PodcastGroup.loadGroups(forProfileId: "nonexistent-profile")
        XCTAssertTrue(loaded.isEmpty, "Unknown profile should return empty array")
    }
    
    func test_deleteGroup_removesFromList() {
        let group1 = PodcastGroup(name: "News", sortOrder: 0)
        let group2 = PodcastGroup(name: "Tech", sortOrder: 1)
        let groups = [group1, group2]
        
        PodcastGroup.saveGroups(groups, forProfileId: testProfileId)
        let updated = PodcastGroup.deleteGroup(id: group1.id, from: groups, forProfileId: testProfileId)
        
        // STUB returns input unchanged — this MUST fail
        XCTAssertEqual(updated.count, 1, "Should have 1 group after deletion")
        XCTAssertEqual(updated[0].name, "Tech")
    }
    
    // MARK: - Podcast Assignment
    
    func test_podcastGroupId_defaultsToNil() {
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        XCTAssertNil(podcast.groupId, "New podcast should have nil groupId (ungrouped)")
    }
    
    func test_podcastGroupId_canBeAssigned() {
        let group = PodcastGroup(name: "Tech")
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        
        podcast.groupId = group.id
        
        XCTAssertEqual(podcast.groupId, group.id)
    }
    
    func test_podcastGroupId_canBeCleared() {
        let group = PodcastGroup(name: "Tech")
        let podcast = Podcast(url: "https://example.com/feed", title: "Test Pod")
        
        podcast.groupId = group.id
        XCTAssertNotNil(podcast.groupId)
        
        podcast.groupId = nil
        XCTAssertNil(podcast.groupId, "Clearing groupId should make podcast ungrouped")
    }
    
    // MARK: - Grouping Logic
    
    func test_groupPodcastsByGroupId() {
        let group1 = PodcastGroup(name: "News", sortOrder: 0)
        let group2 = PodcastGroup(name: "Tech", sortOrder: 1)
        
        let pod1 = Podcast(url: "https://news1.com/feed", title: "News 1")
        pod1.groupId = group1.id
        let pod2 = Podcast(url: "https://news2.com/feed", title: "News 2")
        pod2.groupId = group1.id
        let pod3 = Podcast(url: "https://tech1.com/feed", title: "Tech 1")
        pod3.groupId = group2.id
        let pod4 = Podcast(url: "https://misc.com/feed", title: "Ungrouped")
        // pod4.groupId stays nil
        
        let allPodcasts = [pod1, pod2, pod3, pod4]
        let _ = [group1, group2]
        
        // Group podcasts by groupId
        let grouped = Dictionary(grouping: allPodcasts.filter { $0.groupId != nil }, by: { $0.groupId! })
        let ungrouped = allPodcasts.filter { $0.groupId == nil }
        
        XCTAssertEqual(grouped[group1.id]?.count, 2, "News group should have 2 podcasts")
        XCTAssertEqual(grouped[group2.id]?.count, 1, "Tech group should have 1 podcast")
        XCTAssertEqual(ungrouped.count, 1, "Should have 1 ungrouped podcast")
        XCTAssertEqual(ungrouped[0].title, "Ungrouped")
    }
    
    // MARK: - OPML Group Export/Import
    
    func test_opmlExport_withGroups_producesNestedOutlines() {
        let group = PodcastGroup(name: "News")
        let pod1 = Podcast(url: "https://news.com/feed", title: "The Daily")
        pod1.groupId = group.id
        let pod2 = Podcast(url: "https://misc.com/feed", title: "Serial")
        // pod2 stays ungrouped
        
        let xml = OPMLService.export(podcasts: [pod1, pod2], groups: [group])
        
        // Should contain a nested outline for the group
        XCTAssertTrue(xml.contains("<outline text=\"News\" title=\"News\">"), "Should have group outline element")
        // The grouped podcast should be inside the group
        XCTAssertTrue(xml.contains("xmlUrl=\"https://news.com/feed\""), "Should contain grouped podcast URL")
        // Ungrouped podcast should be at top level
        XCTAssertTrue(xml.contains("xmlUrl=\"https://misc.com/feed\""), "Should contain ungrouped podcast URL")
    }
    
    func test_opmlImport_withNestedOutlines_parsesGroups() {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Test</title></head>
          <body>
            <outline text="News" title="News">
              <outline type="rss" text="The Daily" xmlUrl="https://news.com/feed"/>
            </outline>
            <outline type="rss" text="Serial" xmlUrl="https://misc.com/feed"/>
          </body>
        </opml>
        """
        let data = opml.data(using: .utf8)!
        
        let result = OPMLService.parseWithGroups(from: data)
        
        XCTAssertEqual(result.groups.count, 1, "Should parse 1 group")
        XCTAssertEqual(result.groups.first?.name, "News")
        XCTAssertEqual(result.groupedUrls[result.groups.first?.name ?? ""]?.count, 1, "News group should have 1 URL")
        XCTAssertEqual(result.ungroupedUrls.count, 1, "Should have 1 ungrouped URL")
        XCTAssertEqual(result.ungroupedUrls.first, "https://misc.com/feed")
    }
    
    // MARK: - OPML Enrichment (yourpods: namespace)
    
    func test_opmlExport_includesListeningProfileAttributes() {
        let pod = Podcast(url: "https://example.com/feed", title: "Test Pod")
        pod.settings = PodcastSettings()
        pod.settings?.playbackSpeed = 1.5
        pod.settings?.skipIntroSeconds = 30
        pod.settings?.skipOutroSeconds = 15
        pod.settings?.autoQueueMode = .priority
        pod.settings?.autoDownloadNewEpisodes = true
        
        let xml = OPMLService.export(podcasts: [pod], groups: [])
        
        XCTAssertTrue(xml.contains("yourpods:playbackSpeed=\"1.5\""), "Should include playback speed")
        XCTAssertTrue(xml.contains("yourpods:skipIntro=\"30\""), "Should include skip intro")
        XCTAssertTrue(xml.contains("yourpods:skipOutro=\"15\""), "Should include skip outro")
        XCTAssertTrue(xml.contains("yourpods:autoQueueMode=\"priority\""), "Should include auto queue mode")
        XCTAssertTrue(xml.contains("yourpods:autoDownload=\"true\""), "Should include auto download")
    }
    
    func test_opmlImport_parsesYourPodsAttributes() {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0" xmlns:yourpods="https://yourpods.app/opml">
          <head><title>Test</title></head>
          <body>
            <outline type="rss" text="Test Pod" xmlUrl="https://example.com/feed"
              yourpods:playbackSpeed="1.5"
              yourpods:skipIntro="30"
              yourpods:skipOutro="15"
              yourpods:autoQueueMode="priority"
              yourpods:autoDownload="true"
            />
          </body>
        </opml>
        """
        let data = opml.data(using: .utf8)!
        
        let result = OPMLService.parseWithGroups(from: data)
        let settings = result.podcastSettings["https://example.com/feed"]
        
        XCTAssertNotNil(settings, "Should have parsed settings for the podcast")
        XCTAssertEqual(settings?.playbackSpeed, 1.5)
        XCTAssertEqual(settings?.skipIntroSeconds, 30)
        XCTAssertEqual(settings?.skipOutroSeconds, 15)
        XCTAssertEqual(settings?.autoQueueMode, .priority)
        XCTAssertEqual(settings?.autoDownloadNewEpisodes, true)
    }
}
