import XCTest
@testable import YourPods

/// Guards the data-driven tracker list: a snapshot refresh must not silently drop a
/// required host or reintroduce a DAI stitcher, and the generic extractor must not
/// false-strip audio-extension segments.
final class TrackerSnapshotTests: XCTestCase {

    private func matchesSomePattern(_ host: String) -> Bool {
        TrackingURLStripper.patterns.contains { $0.matches(host: host) }
    }

    // MARK: - Drift guard

    /// Required tracker hosts must remain covered after any snapshot refresh.
    func test_requiredHosts_covered() {
        let required = [
            "dts.podtrac.com", "www.podtrac.com", "chrt.fm", "pdst.fm", "op3.dev",
            "mgln.ai", "pscrb.fm", "suprefix.fm", "claritaspod.com", "clrtpod.com",
            "arttrk.com", "media.blubrry.com", "t.glystn.com", "pdcds.co",
            "p.podderapp.com", "growx.podkite.com", "a.pdcst.to", "2.gum.fm",
        ]
        for host in required {
            XCTAssertTrue(matchesSomePattern(host), "Required tracker host no longer covered: \(host)")
        }
    }

    /// DAI stitcher hosts must NOT be in the strip list (they serve the audio directly).
    func test_daiHosts_excluded() {
        for host in ["traffic.megaphone.fm", "dcs.megaphone.fm", "adswizz.com", "pcm.adswizz.com"] {
            XCTAssertFalse(matchesSomePattern(host), "DAI host must not be stripped: \(host)")
        }
    }

    /// Curated supplemental extras (not in OPAWG) must survive a snapshot refresh.
    func test_supplementalExtras_covered() {
        for host in ["veritonic.com", "backtracks.fm", "pfx.vpixl.com", "swap.fm"] {
            XCTAssertTrue(matchesSomePattern(host), "Supplemental extra missing: \(host)")
        }
    }

    // MARK: - False-strip adversarial

    /// `redirect.mp3` / `redirect.m4a` are NOT mistaken for the embedded host.
    func test_extractor_ignoresAudioExtensionSegment() {
        let a = TrackingURLStripper.strip("https://dts.podtrac.com/redirect.mp3/cdn.example.com/ep.mp3")
        XCTAssertEqual(a.url, "https://cdn.example.com/ep.mp3")
        let b = TrackingURLStripper.strip("https://dts.podtrac.com/redirect.m4a/cdn.example.com/ep.m4a")
        XCTAssertEqual(b.url, "https://cdn.example.com/ep.m4a")
    }

    /// A tracker host with no embedded domain passes through unchanged (no mangling).
    func test_extractor_noEmbeddedDomain_passthrough() {
        let input = "https://op3.dev/e/somefile.mp3"
        let result = TrackingURLStripper.strip(input)
        XCTAssertEqual(result.url, input)
        XCTAssertFalse(result.wasModified)
    }

    /// Numeric-TLD ID segments are not treated as domains.
    func test_extractor_numericTLDNotDomain() {
        let result = TrackingURLStripper.strip("https://chrt.fm/track/campaign.2024/cdn.example.com/ep.mp3")
        XCTAssertEqual(result.url, "https://cdn.example.com/ep.mp3")
    }
}
