import XCTest
import SwiftData
@testable import YourPods

/// Direct unit tests of the one mapper both refresh paths use.
final class FeedMetadataMapperTests: XCTestCase {

    /// Counts setter calls, which is the only thing that matters: Core Data
    /// dirties a row on ANY setter call, even one assigning an identical value.
    /// Reading the property back cannot distinguish "guarded" from "assigned the
    /// same value" — only observing the write can.
    private final class WriteProbe {
        private(set) var writes = 0
        var value: String = "initial" { didSet { writes += 1 } }
    }

    func test_setIfChanged_doesNotWrite_whenValueIsIdentical() {
        let probe = WriteProbe()

        setIfChanged(probe, \.value, "initial")

        XCTAssertEqual(probe.writes, 0,
                       "Assigning an identical value must not touch the setter — the setter call " +
                       "is what dirties the row, and dirty rows are the 0xDEAD10CC blast radius")
    }

    func test_setIfChanged_writesOnce_whenValueDiffers() {
        let probe = WriteProbe()

        setIfChanged(probe, \.value, "changed")

        XCTAssertEqual(probe.writes, 1, "A genuine change must still assign")
        XCTAssertEqual(probe.value, "changed")
    }

    func test_appliesEpisodeMetadata_includingFeedItemIndex() {
        let episode = Episode(guid: "g", title: "T")
        var parsed = ParsedEpisode(guid: "g", title: "T")
        parsed.seasonNumber = 2
        parsed.episodeNumber = 7
        parsed.episodeType = "full"
        parsed.explicit = true
        parsed.feedItemIndex = 4

        FeedMetadataMapper.apply(parsed, to: episode)

        XCTAssertEqual(episode.seasonNumber, 2)
        XCTAssertEqual(episode.episodeNumber, 7)
        XCTAssertEqual(episode.episodeType, "full")
        XCTAssertEqual(episode.explicit, true)
        XCTAssertEqual(episode.feedItemIndex, 4, "feedItemIndex must be part of the shared mapper")
    }

    func test_appliesTranscriptUrlAndType_together() {
        let episode = Episode(guid: "g", title: "T")
        var parsed = ParsedEpisode(guid: "g", title: "T")
        parsed.transcriptUrl = "https://cdn.example.com/t.html"
        parsed.transcriptType = "text/html"

        FeedMetadataMapper.apply(parsed, to: episode)

        XCTAssertEqual(episode.transcriptUrl, "https://cdn.example.com/t.html")
        XCTAssertEqual(episode.transcriptType, "text/html")
    }

    func test_EDGE_doesNotClobberTranscript_whenFeedOmitsIt() {
        let episode = Episode(guid: "g", title: "T")
        episode.transcriptUrl = "https://cdn.example.com/existing.html"
        let parsed = ParsedEpisode(guid: "g", title: "T")  // no transcript

        FeedMetadataMapper.apply(parsed, to: episode)

        XCTAssertEqual(episode.transcriptUrl, "https://cdn.example.com/existing.html",
                       "Preserves today's additive-only behavior — clearing is tracked separately")
    }

    func test_appliesPodcastMetadata() {
        let podcast = Podcast(url: "https://example.com/f", title: "P")
        var parsed = ParsedPodcast(title: "P")
        parsed.language = "en"
        parsed.explicit = true

        FeedMetadataMapper.apply(parsed, to: podcast)

        XCTAssertEqual(podcast.language, "en")
        XCTAssertEqual(podcast.explicit, true)
    }
}
