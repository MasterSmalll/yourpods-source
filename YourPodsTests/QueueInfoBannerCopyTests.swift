import XCTest
@testable import YourPods

/// The Up Next info banner is a one-time educational banner shown to *every*
/// account type, so its copy must explain how each treats the queue:
/// gPodder/Nextcloud don't sync it, YourPods Pro syncs it across devices and
/// the web, and Vault Mode keeps it on-device. Copy is a `LocalizedStringResource`
/// (English-as-key), so `.key` is the English source string these assertions target.
final class QueueInfoBannerCopyTests: XCTestCase {

    func test_message_explainsQueueSyncPerAccountType() {
        let msg = QueueInfoBanner.message.key
        XCTAssertTrue(msg.contains("gPodder"),
                      "banner must name gPodder as not syncing the queue")
        XCTAssertTrue(msg.contains("Nextcloud"),
                      "banner must name Nextcloud as not syncing the queue")
        XCTAssertTrue(msg.contains("YourPods Pro"),
                      "banner must credit YourPods Pro with cross-device queue sync")
        XCTAssertTrue(msg.contains("web"),
                      "banner must mention that Pro syncs the queue to the web")
        XCTAssertTrue(msg.contains("Vault Mode"),
                      "banner must state Vault Mode keeps the queue on-device")
    }

    /// The old copy claimed the queue "exists only on this device" for everyone,
    /// which is wrong for Pro users (whose queue does sync). Guard the regression.
    func test_message_doesNotClaimQueueIsAlwaysDeviceOnly() {
        let msg = QueueInfoBanner.message.key
        XCTAssertFalse(msg.contains("exists only on this device"),
                       "the queue is not device-only for YourPods Pro users")
    }

    func test_title_isNonEmptyLocalizedStringResource() {
        XCTAssertFalse(QueueInfoBanner.title.key.isEmpty,
                       "banner title must be a non-empty catalog key")
    }
}
