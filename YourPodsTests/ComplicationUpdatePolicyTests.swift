import XCTest
@testable import YourPods

final class ComplicationUpdatePolicyTests: XCTestCase {

    private func data(title: String?, playing: Bool, queue: Int) -> ComplicationData {
        ComplicationData(nowPlayingTitle: title, nowPlayingPodcast: nil, isPlaying: playing,
                         upNextTitle: nil, upNextPodcast: nil, queueCount: queue, lastUpdated: Date())
    }

    func test_lastUpdatedAlone_isNotMeaningful() {
        // Reload budget: identical state with a fresh timestamp must NOT trigger a reload.
        XCTAssertFalse(data(title: "A", playing: true, queue: 3)
            .meaningfullyDiffers(from: data(title: "A", playing: true, queue: 3)))
    }

    func test_playStateChange_isMeaningful() {
        XCTAssertTrue(data(title: "A", playing: true, queue: 3)
            .meaningfullyDiffers(from: data(title: "A", playing: false, queue: 3)))
    }

    func test_queueCountChange_isMeaningful() {
        XCTAssertTrue(data(title: "A", playing: true, queue: 3)
            .meaningfullyDiffers(from: data(title: "A", playing: true, queue: 4)))
    }
}
