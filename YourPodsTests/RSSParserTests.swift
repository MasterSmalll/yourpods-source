import XCTest
@testable import YourPods

// MARK: - RSS Parser Tests

final class RSSParserTests: XCTestCase {
    
    // MARK: - Chapters & Transcripts with proper namespace
    
    func test_parseChaptersAndTranscript_withProperNamespace() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"
             xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
             xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode 1</title>
              <guid>ep1</guid>
              <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" />
              <podcast:chapters url="https://example.com/chapters.json" type="application/json+chapters" />
              <podcast:transcript url="https://example.com/transcript.srt" type="application/x-subrip" />
            </item>
          </channel>
        </rss>
        """
        let data = Data(xml.utf8)
        let (_, episodes) = try RSSService.parseFeedData(data)
        
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].chaptersUrl, "https://example.com/chapters.json")
        XCTAssertEqual(episodes[0].transcriptUrl, "https://example.com/transcript.srt")
    }
    
    // MARK: - Chapters & Transcripts without namespace URI (bare prefix)
    
    func test_parseChaptersAndTranscript_withoutNamespaceURI() throws {
        // Some feeds use podcast: prefix without declaring the namespace URI
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode 1</title>
              <guid>ep1</guid>
              <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" />
              <podcast:chapters url="https://example.com/chapters.json" type="application/json+chapters" />
              <podcast:transcript url="https://example.com/transcript.srt" type="application/x-subrip" />
            </item>
          </channel>
        </rss>
        """
        let data = Data(xml.utf8)
        let (_, episodes) = try RSSService.parseFeedData(data)
        
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].chaptersUrl, "https://example.com/chapters.json",
                       "Should parse chapters even without proper namespace URI")
        XCTAssertEqual(episodes[0].transcriptUrl, "https://example.com/transcript.srt",
                       "Should parse transcript even without proper namespace URI")
    }
    
    // MARK: - Multiple transcripts — prefer SRT
    
    func test_multipleTranscripts_prefersSRT() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"
             xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode 1</title>
              <guid>ep1</guid>
              <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" />
              <podcast:transcript url="https://example.com/transcript.json" type="application/json" />
              <podcast:transcript url="https://example.com/transcript.vtt" type="text/vtt" />
              <podcast:transcript url="https://example.com/transcript.srt" type="application/x-subrip" />
            </item>
          </channel>
        </rss>
        """
        let data = Data(xml.utf8)
        let (_, episodes) = try RSSService.parseFeedData(data)
        
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].transcriptUrl, "https://example.com/transcript.srt",
                       "Should prefer SRT transcript when multiple formats are available")
    }
    
    // MARK: - content:encoded preferred over description
    
    func test_contentEncoded_preferredOverDescription() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode 1</title>
              <guid>ep1</guid>
              <description>Plain text description</description>
              <content:encoded><![CDATA[<p>Rich <b>HTML</b> description</p>]]></content:encoded>
              <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let data = Data(xml.utf8)
        let (_, episodes) = try RSSService.parseFeedData(data)
        
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].description, "<p>Rich <b>HTML</b> description</p>",
                       "content:encoded should be preferred over description")
    }
    
    // MARK: - itunes:image without namespace URI
    
    func test_itunesImage_withoutNamespaceURI() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Test Podcast</title>
            <itunes:image href="https://example.com/podcast.jpg" />
            <item>
              <title>Episode 1</title>
              <guid>ep1</guid>
              <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" />
              <itunes:image href="https://example.com/ep1.jpg" />
            </item>
          </channel>
        </rss>
        """
        let data = Data(xml.utf8)
        let (podcast, episodes) = try RSSService.parseFeedData(data)
        
        XCTAssertEqual(podcast.logoUrl, "https://example.com/podcast.jpg",
                       "Should parse itunes:image even without namespace URI")
        XCTAssertEqual(episodes[0].imageUrl, "https://example.com/ep1.jpg",
                       "Should parse episode itunes:image even without namespace URI")
    }
    // MARK: - Text/plain transcript parsed from RSS
    
    func test_parseTextPlainTranscript() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"
             xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode 1</title>
              <guid>ep1</guid>
              <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg" />
              <podcast:transcript url="https://example.com/transcript.txt" type="text/plain" />
            </item>
          </channel>
        </rss>
        """
        let data = Data(xml.utf8)
        let (_, episodes) = try RSSService.parseFeedData(data)
        
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].transcriptUrl, "https://example.com/transcript.txt",
                       "Should parse text/plain transcript URL from RSS feed")
    }
}

// MARK: - HTML Stripping Tests

final class HTMLStrippingTests: XCTestCase {
    
    func test_strippingHTML_removesTags() {
        let html = "<p>Hello <b>world</b></p>"
        let result = html.strippingHTML()
        XCTAssertEqual(result, "Hello world")
    }
    
    func test_strippingHTML_decodesEntities() {
        let html = "Tom &amp; Jerry &lt;3"
        let result = html.strippingHTML()
        XCTAssertEqual(result, "Tom & Jerry <3")
    }
    
    func test_strippingHTML_convertsLineBreaks() {
        let html = "Line 1<br>Line 2<br/>Line 3"
        let result = html.strippingHTML()
        XCTAssertTrue(result.contains("Line 1"))
        XCTAssertTrue(result.contains("Line 2"))
        XCTAssertTrue(result.contains("Line 3"))
    }
    
    func test_strippingHTML_handlesPlainText() {
        let text = "Just plain text with no HTML"
        let result = text.strippingHTML()
        XCTAssertEqual(result, text)
    }
    
    func test_strippingHTML_handlesNestedTags() {
        let html = "<div><ul><li>Item 1</li><li>Item 2</li></ul></div>"
        let result = html.strippingHTML()
        XCTAssertTrue(result.contains("Item 1"))
        XCTAssertTrue(result.contains("Item 2"))
    }
}

// MARK: - Description Chapter Parser Tests

final class DescriptionChapterParserTests: XCTestCase {
    
    func test_parsesHHMMSSFormat() {
        let description = """
        Some intro text.
        Time Stamps:
        (00:00:00) Debate origins and the current global state.
        (00:02:44) Personality distributions and their societal impacts.
        (00:10:00) Why the US healthcare system resists change.
        Support the pod: https://example.com
        """
        let chapters = ChapterService.parseChaptersFromDescription(description)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[0].title, "Debate origins and the current global state.")
        XCTAssertEqual(chapters[1].startTime, 164)  // 2*60 + 44
        XCTAssertEqual(chapters[2].startTime, 600)   // 10*60
    }
    
    func test_parsesMMSSFormat() {
        let description = """
        Time Stamps:
        (00:00) Intro: The "Edge Collider" format
        (05:48) The Science of Open Source tDCS
        (08:42) Motivation: Why build neurological tech?
        """
        let chapters = ChapterService.parseChaptersFromDescription(description)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[0].title, "Intro: The \"Edge Collider\" format")
        XCTAssertEqual(chapters[1].startTime, 348)   // 5*60 + 48
        XCTAssertEqual(chapters[2].startTime, 522)   // 8*60 + 42
    }
    
    func test_parsesMixedFormats() {
        let description = """
        (00:00) Intro
        (01:02:24) Career wisdom: Always build in public
        """
        let chapters = ChapterService.parseChaptersFromDescription(description)
        
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[1].startTime, 3744)  // 1*3600 + 2*60 + 24
    }
    
    func test_noTimestamps_returnsEmpty() {
        let description = "Just a regular description with no timestamps."
        let chapters = ChapterService.parseChaptersFromDescription(description)
        XCTAssertTrue(chapters.isEmpty)
    }
    
    func test_parsesHyphenSeparatedFormat() {
        // Some podcasts use "00:00 - Title" format
        let description = """
        00:00 - Intro
        05:30 - Main Topic
        10:15 - Wrap Up
        """
        let chapters = ChapterService.parseChaptersFromDescription(description)
        
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "Intro")
        XCTAssertEqual(chapters[1].startTime, 330)  // 5*60 + 30
        XCTAssertEqual(chapters[2].title, "Wrap Up")
    }
    
    func test_parsesHTMLWrappedTimestamps() {
        // The actual format from 3reate podcast — timestamps in <p> tags
        let html = """
        <p>Some intro text about the episode.</p>
        <p>Time Stamps:</p>
        <p>(00:00:00) Debate origins and the current global state. </p>
        <p>(00:02:44) Personality distributions and their societal impacts. </p>
        <p>(00:10:00) Why the US healthcare system resists change. </p>
        <p>Support the pod: https://example.com</p>
        """
        let chapters = ChapterService.parseChaptersFromDescription(html)
        
        XCTAssertEqual(chapters.count, 3, "Should parse timestamps from HTML-wrapped description")
        XCTAssertEqual(chapters[0].startTime, 0)
        XCTAssertEqual(chapters[0].title, "Debate origins and the current global state.")
        XCTAssertEqual(chapters[1].startTime, 164)
        XCTAssertEqual(chapters[2].startTime, 600)
    }
    
    // MARK: - iTunes Explicit
    
    func test_parseExplicit_yesNoValues() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Explicit Show</title>
            <itunes:explicit>yes</itunes:explicit>
            <item>
              <title>Clean Episode</title>
              <guid>ep1</guid>
              <itunes:explicit>no</itunes:explicit>
            </item>
            <item>
              <title>Explicit Episode</title>
              <guid>ep2</guid>
              <itunes:explicit>true</itunes:explicit>
            </item>
          </channel>
        </rss>
        """
        let (podcast, episodes) = try RSSService.parseFeedData(Data(xml.utf8))
        
        XCTAssertEqual(podcast.explicit, true, "Channel explicit=yes → true")
        XCTAssertEqual(episodes[0].explicit, false, "Episode explicit=no → false")
        XCTAssertEqual(episodes[1].explicit, true, "Episode explicit=true → true")
    }
    
    // MARK: - iTunes Show Type
    
    func test_parseShowType_episodicSerial() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Serial Show</title>
            <itunes:type>Serial</itunes:type>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertEqual(podcast.showType, "serial")
    }
    
    // MARK: - Season & Episode Numbers
    
    func test_parseSeasonEpisodeNumbers() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Numbered Show</title>
            <item>
              <title>S2E5</title>
              <guid>ep1</guid>
              <itunes:season>2</itunes:season>
              <itunes:episode>5</itunes:episode>
              <itunes:episodeType>full</itunes:episodeType>
            </item>
          </channel>
        </rss>
        """
        let (_, episodes) = try RSSService.parseFeedData(Data(xml.utf8))
        
        XCTAssertEqual(episodes[0].seasonNumber, 2)
        XCTAssertEqual(episodes[0].episodeNumber, 5.0)
        XCTAssertEqual(episodes[0].episodeType, "full")
    }
    
    // MARK: - Episode Type
    
    func test_parseEpisodeType_fullTrailerBonus() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Show</title>
            <item>
              <title>Trailer</title>
              <guid>t1</guid>
              <itunes:episodeType>Trailer</itunes:episodeType>
            </item>
            <item>
              <title>Bonus</title>
              <guid>b1</guid>
              <itunes:episodeType>Bonus</itunes:episodeType>
            </item>
          </channel>
        </rss>
        """
        let (_, episodes) = try RSSService.parseFeedData(Data(xml.utf8))
        
        XCTAssertEqual(episodes[0].episodeType, "trailer")
        XCTAssertEqual(episodes[1].episodeType, "bonus")
    }
    
    // MARK: - iTunes Category (with subcategory)
    
    func test_parseCategory() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Tech Show</title>
            <itunes:category text="Technology">
              <itunes:category text="Podcasting" />
            </itunes:category>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        
        XCTAssertEqual(podcast.categories, ["Technology"])
        XCTAssertEqual(podcast.subcategory, "Podcasting")
    }
    
    // MARK: - New Feed URL
    
    func test_parseNewFeedUrl() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Migrating Show</title>
            <itunes:new-feed-url>https://newhost.com/feed.xml</itunes:new-feed-url>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertEqual(podcast.newFeedUrl, "https://newhost.com/feed.xml")
    }
    
    // MARK: - iTunes Complete
    
    func test_parseComplete() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Finished Show</title>
            <itunes:complete>Yes</itunes:complete>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertTrue(podcast.isComplete)
    }
    
    // MARK: - Podcast GUID
    
    func test_parsePodcastGuid() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>GUID Show</title>
            <podcast:guid>917393e3-1b1e-5cef-ace4-edaa54e1f11a</podcast:guid>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertEqual(podcast.podcastGuid, "917393e3-1b1e-5cef-ace4-edaa54e1f11a")
    }
    
    // MARK: - Funding
    
    func test_parseFundingUrl() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Funded Show</title>
            <podcast:funding url="https://paypal.me/myshow">Support on PayPal</podcast:funding>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertEqual(podcast.fundingUrl, "https://paypal.me/myshow")
        XCTAssertEqual(podcast.fundingLabel, "Support on PayPal")
    }
    
    // MARK: - Value4Value Presence
    
    func test_parseValue4ValuePresence() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>V4V Show</title>
            <podcast:value type="lightning" method="keysend">
              <podcast:valueRecipient name="host" type="node" address="abc" split="100" />
            </podcast:value>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertTrue(podcast.supportsValue4Value)
    }
    
    // MARK: - Live Item Presence
    
    func test_parseLiveItemPresence() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Live Show</title>
            <podcast:liveItem status="live" start="2024-09-26T07:30:00.000-0600" end="2024-09-26T09:30:00.000-0600">
              <title>Live Stream</title>
              <guid>live-ep-1</guid>
              <enclosure url="https://example.com/live.mp3" type="audio/mpeg" length="0" />
              <podcast:contentLink href="https://example.com/live">Watch Live</podcast:contentLink>
            </podcast:liveItem>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertTrue(podcast.hasLiveItem)
        XCTAssertEqual(podcast.liveItemStatus, "live")
        XCTAssertNotNil(podcast.liveItemStart)
        XCTAssertEqual(podcast.liveItemContentLink, "https://example.com/live")
    }
    
    // MARK: - Language & Copyright
    
    func test_parseLanguageAndCopyright() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Intl Show</title>
            <language>en-us</language>
            <copyright>© 2024 MyShow LLC</copyright>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertEqual(podcast.language, "en-us")
        XCTAssertEqual(podcast.copyright, "© 2024 MyShow LLC")
    }
    
    // MARK: - Podcasting 2.0 Season/Episode with attributes
    
    func test_parsePodcast2SeasonEpisode() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>PC2.0 Show</title>
            <item>
              <title>Season Premiere</title>
              <guid>ep1</guid>
              <podcast:season name="The Beginning">1</podcast:season>
              <podcast:episode display="S1E1">1</podcast:episode>
            </item>
          </channel>
        </rss>
        """
        let (_, episodes) = try RSSService.parseFeedData(Data(xml.utf8))
        
        XCTAssertEqual(episodes[0].seasonNumber, 1)
        XCTAssertEqual(episodes[0].seasonName, "The Beginning")
        XCTAssertEqual(episodes[0].episodeNumber, 1.0)
        XCTAssertEqual(episodes[0].episodeDisplay, "S1E1")
    }
    
    // MARK: - Publisher
    
    func test_parsePublisher() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Published Show</title>
            <podcast:publisher>Podcast Network Inc.</podcast:publisher>
            <item><title>Ep</title><guid>ep1</guid></item>
          </channel>
        </rss>
        """
        let (podcast, _) = try RSSService.parseFeedData(Data(xml.utf8))
        XCTAssertEqual(podcast.publisher, "Podcast Network Inc.")
    }
    
    // MARK: - Podlove Simple Chapters
    
    func test_parsePodloveSimpleChapters_withNamespace() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"
             xmlns:podcast="https://podcastindex.org/namespace/1.0"
             xmlns:psc="http://podlove.org/simple-chapters">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode with Chapters</title>
              <guid>ep-chapters</guid>
              <enclosure url="https://example.com/ep.mp3" type="audio/mpeg" />
              <psc:chapters>
                <psc:chapter start="00:00:00.000" title="Intro" />
                <psc:chapter start="00:05:30.000" title="Main Topic" href="https://example.com/topic" />
                <psc:chapter start="01:02:15.500" title="Wrap Up" image="https://example.com/img.jpg" />
              </psc:chapters>
            </item>
          </channel>
        </rss>
        """
        let (_, episodes) = try RSSService.parseFeedData(Data(xml.utf8))
        
        XCTAssertEqual(episodes.count, 1)
        let chapters = episodes[0].inlineChapters
        XCTAssertNotNil(chapters, "Should parse inline Podlove chapters")
        XCTAssertEqual(chapters?.count, 3, "Should have 3 chapters")
        
        // Chapter 1: Intro at 0s
        XCTAssertEqual(chapters?[0].startTime, 0.0)
        XCTAssertEqual(chapters?[0].title, "Intro")
        XCTAssertNil(chapters?[0].href)
        
        // Chapter 2: Main Topic at 5:30
        XCTAssertEqual(chapters?[1].startTime, 330.0)
        XCTAssertEqual(chapters?[1].title, "Main Topic")
        XCTAssertEqual(chapters?[1].href, "https://example.com/topic")
        
        // Chapter 3: Wrap Up at 1:02:15.5
        XCTAssertEqual(chapters![2].startTime, 3735.5, accuracy: 0.01)
        XCTAssertEqual(chapters?[2].title, "Wrap Up")
        XCTAssertEqual(chapters?[2].image, "https://example.com/img.jpg")
    }
    
    func test_parsePodloveSimpleChapters_withBarePrefix() throws {
        // Some feeds use psc: prefix without declaring the namespace URI
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Test Podcast</title>
            <item>
              <title>Episode</title>
              <guid>ep1</guid>
              <enclosure url="https://example.com/ep.mp3" type="audio/mpeg" />
              <psc:chapters>
                <psc:chapter start="00:00:00" title="Start" />
                <psc:chapter start="00:10:00" title="Middle" />
              </psc:chapters>
            </item>
          </channel>
        </rss>
        """
        let (_, episodes) = try RSSService.parseFeedData(Data(xml.utf8))
        
        let chapters = episodes[0].inlineChapters
        XCTAssertNotNil(chapters, "Should parse chapters even without namespace URI")
        XCTAssertEqual(chapters?.count, 2)
        XCTAssertEqual(chapters?[0].title, "Start")
        XCTAssertEqual(chapters?[1].startTime, 600.0) // 10 minutes
    }
    
    func test_podloveChapters_coexistWithPodcasting2Url() throws {
        // Both podcast:chapters (JSON URL) and psc:chapters (inline) present
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"
             xmlns:podcast="https://podcastindex.org/namespace/1.0"
             xmlns:psc="http://podlove.org/simple-chapters">
          <channel>
            <title>Test</title>
            <item>
              <title>Both</title>
              <guid>ep1</guid>
              <enclosure url="https://example.com/ep.mp3" type="audio/mpeg" />
              <podcast:chapters url="https://example.com/chapters.json" type="application/json+chapters" />
              <psc:chapters>
                <psc:chapter start="00:00:00" title="Inline Intro" />
              </psc:chapters>
            </item>
          </channel>
        </rss>
        """
        let (_, episodes) = try RSSService.parseFeedData(Data(xml.utf8))
        
        // Both should be preserved — UI will prioritize URL-based
        XCTAssertEqual(episodes[0].chaptersUrl, "https://example.com/chapters.json")
        XCTAssertEqual(episodes[0].inlineChapters?.count, 1)
        XCTAssertEqual(episodes[0].inlineChapters?[0].title, "Inline Intro")
    }
    
    func test_parseInlineChaptersJSON_decodesCorrectly() {
        let json = """
        [{"startTime":0.0,"title":"Intro","img":null,"url":null},{"startTime":330.5,"title":"Topic","img":"https://img.jpg","url":"https://link.com"}]
        """
        let chapters = ChapterService.parseInlineChaptersJSON(json)
        
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].startTime, 0.0)
        XCTAssertEqual(chapters[0].title, "Intro")
        XCTAssertNil(chapters[0].img)
        XCTAssertEqual(chapters[1].startTime, 330.5)
        XCTAssertEqual(chapters[1].title, "Topic")
        XCTAssertEqual(chapters[1].img, "https://img.jpg")
        XCTAssertEqual(chapters[1].url, "https://link.com")
    }
    
    func test_parseInlineChaptersJSON_returnsEmpty_forInvalidJSON() {
        XCTAssertTrue(ChapterService.parseInlineChaptersJSON("not json").isEmpty)
        XCTAssertTrue(ChapterService.parseInlineChaptersJSON("").isEmpty)
    }
}
