/// Per-episode CAS baseline persistence — per the sync contract (iOS side).
///
/// The store answers one question: "what `version` did this device last *agree* with
/// the server on for this episode?" Everything about the CAS protocol hangs off that
/// answer being right, and every way of getting it wrong is silent:
///
/// - Advance on receipt of a conflict rather than on an ack and the client claims
///   agreement on a value the server does not hold; the next push matches, the write
///   lands, and "each device keeps its own value" becomes last-write-wins churn.
/// - Normalize the key and the ack maps to nothing; the row stays dirty forever and
///   re-conflicts every cycle.
/// - Share one file across profiles and a version from one account silently authorizes
///   a write in another.
///
/// None of those produce an error, a log line, or a failed request. They produce wrong
/// numbers on the user's screen weeks later, which is why this is tested at the level of
/// "what did you store" rather than "did the call succeed".
import XCTest
@testable import YourPods

@MainActor
final class PlaybackBaselineStoreTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-store-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("playbackBaselines.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        fileURL = nil
        super.tearDown()
    }

    private func makeStore() -> PlaybackBaselineStore {
        PlaybackBaselineStore(fileURL: fileURL)
    }

    // MARK: - Reading

    func test_baseline_isNil_forEpisodeNeverSynced() {
        let store = makeStore()
        XCTAssertNil(store.baseline(for: "https://cdn.example.com/ep1.mp3"))
    }

    func test_recordAgreement_storesVersionAndCompleted() {
        let store = makeStore()
        store.recordAgreement(episodeUrl: "https://cdn.example.com/ep1.mp3", version: 42, completed: false)

        let baseline = store.baseline(for: "https://cdn.example.com/ep1.mp3")
        XCTAssertEqual(baseline?.syncedVersion, 42)
        XCTAssertEqual(baseline?.syncedCompleted, false)
    }

    func test_recordAgreement_overwritesEarlierAgreementForSameEpisode() {
        let store = makeStore()
        store.recordAgreement(episodeUrl: "https://cdn.example.com/ep1.mp3", version: 42, completed: false)
        store.recordAgreement(episodeUrl: "https://cdn.example.com/ep1.mp3", version: 43, completed: true)

        XCTAssertEqual(store.baseline(for: "https://cdn.example.com/ep1.mp3")?.syncedVersion, 43)
        XCTAssertEqual(store.baseline(for: "https://cdn.example.com/ep1.mp3")?.syncedCompleted, true)
    }

    // MARK: - Key identity (the server's echo rule)

    /// The server echoes `episodeUrl` back byte-for-byte and the client has no other key
    /// to map an ack by. Any normalization here — percent decoding, host case folding, a
    /// dropped query — means the ack lands on a key nothing pushed, the real row keeps its
    /// stale baseline, and it re-conflicts on every subsequent cycle with no error anywhere.
    func test_EDGE_baselineKeys_areVerbatim_notNormalized() {
        let store = makeStore()
        let encoded = "https://cdn.example.com/ep%20one.mp3"
        let decoded = "https://cdn.example.com/ep one.mp3"
        let upperHost = "https://CDN.example.com/ep1.mp3"
        let lowerHost = "https://cdn.example.com/ep1.mp3"

        store.recordAgreement(episodeUrl: encoded, version: 1, completed: false)
        store.recordAgreement(episodeUrl: upperHost, version: 2, completed: false)

        XCTAssertEqual(store.baseline(for: encoded)?.syncedVersion, 1)
        XCTAssertNil(store.baseline(for: decoded), "percent-encoding must not be folded")
        XCTAssertEqual(store.baseline(for: upperHost)?.syncedVersion, 2)
        XCTAssertNil(store.baseline(for: lowerHost), "host case must not be folded")
    }

    func test_EDGE_emptyEpisodeUrl_isNotStored() {
        let store = makeStore()
        store.recordAgreement(episodeUrl: "", version: 7, completed: false)
        XCTAssertNil(store.baseline(for: ""), "an empty key would collide across every episode missing a URL")
    }

    // MARK: - Persistence

    func test_baselines_surviveAcrossStoreInstances() {
        let store = makeStore()
        store.recordAgreement(episodeUrl: "https://cdn.example.com/ep1.mp3", version: 42, completed: true)
        store.persist()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.baseline(for: "https://cdn.example.com/ep1.mp3")?.syncedVersion, 42)
        XCTAssertEqual(reloaded.baseline(for: "https://cdn.example.com/ep1.mp3")?.syncedCompleted, true)
    }

    /// A baseline that only exists in memory is worse than no baseline: the next launch
    /// pushes `0` ("I believe no row exists"), the server conflicts, and step (0) resolves
    /// it by legacy semantics — so an un-persisted store degrades the CAS path back to
    /// legacy last-write-wins on every cold start while looking like it works in a
    /// single session.
    func test_persistedFile_isReadableAsJSON() throws {
        let store = makeStore()
        store.recordAgreement(episodeUrl: "https://cdn.example.com/ep1.mp3", version: 9, completed: false)
        store.persist()

        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["https://cdn.example.com/ep1.mp3"])
    }

    func test_missingFile_loadsEmpty_withoutThrowing() {
        let store = makeStore()
        XCTAssertEqual(store.count, 0)
    }

    func test_corruptFile_loadsEmpty_ratherThanCrashing() throws {
        try Data("{not json".utf8).write(to: fileURL)
        let store = makeStore()
        XCTAssertEqual(store.count, 0, "a corrupt baseline file must degrade to legacy LWW, never crash the sync")
    }

    // MARK: - Profile isolation

    /// Versions are per-account row counters. A version learned under one profile is a
    /// meaningless integer under another, and if it happens to match it authorizes a write
    /// the client never agreed to. `actionMap` is profile-scoped for the same reason.
    func test_fileURL_isProfileScoped() {
        let global = PlaybackBaselineStore.fileURL(forProfile: nil)
        let alsoGlobal = PlaybackBaselineStore.fileURL(forProfile: "global")
        let named = PlaybackBaselineStore.fileURL(forProfile: "work")

        XCTAssertEqual(global, alsoGlobal)
        XCTAssertNotEqual(global, named)
        XCTAssertTrue(named.lastPathComponent.contains("work"))
    }

    // MARK: - Clearing

    func test_clear_removesEveryBaseline_andPersists() {
        let store = makeStore()
        store.recordAgreement(episodeUrl: "https://cdn.example.com/ep1.mp3", version: 42, completed: false)
        store.persist()

        store.clear()
        XCTAssertEqual(store.count, 0)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.count, 0, "sign-out must not leave versions that outlive the account")
    }
}
