import XCTest
@testable import YourPods

/// The conflict sheet must name **whose** position it is offering.
///
/// Both sheets rendered `localPosition` under an unconditional "This Device". That held
/// only while the device reading the sheet was the one that wrote the row, and it stopped
/// holding the moment CAS rows started being authored: a row is written by whichever
/// client pushes a stale `baseVersion`, and any *other* device that opens the sheet then
/// reads "📱 This Device 13:48" for someone else's position while its own sits under
/// "☁️ Server".
///
/// Resolution is authoritative under the sync contract, so tapping the mislabelled side
/// writes it everywhere — the exact erase this workstream exists to prevent, reached
/// through the UI instead of the merge predicate.
///
/// The server half ships in current server releases (`sync_conflicts.device_id`, null for
/// bridge-written rows because no device authored those). The web client shipped its half
/// with three labels, and this is iOS matching them so the two clients cannot describe the
/// same row differently:
///
/// | `deviceId` | label |
/// |---|---|
/// | matches this install | **This Device** |
/// | differs | **Other Device** |
/// | absent | **YourPods** — bridge-written; the local side is the service's own stored position |
final class ConflictSideLabelTests: XCTestCase {

    private let thisInstall = "yourpods-iPhone-a1b2c3d4"

    // MARK: - The three cases

    func test_matchingDeviceId_isThisDevice() {
        XCTAssertEqual(
            ConflictSideLabel.local(deviceId: thisInstall, installId: thisInstall),
            .thisDevice
        )
    }

    /// The defect. A row authored by the phone, opened on the iPad.
    func test_differentDeviceId_isOtherDevice() {
        XCTAssertEqual(
            ConflictSideLabel.local(deviceId: "yourpods-iPad-99887766", installId: thisInstall),
            .otherDevice,
            "labelling another device's position 'This Device' invites the user to keep it, and "
            + "the server-side authoritative resolve then writes that choice everywhere"
        )
    }

    /// A web-authored row is still "another device" from the phone's point of view — the
    /// label is about authorship, not about platform.
    func test_webDeviceId_isOtherDevice() {
        XCTAssertEqual(
            ConflictSideLabel.local(deviceId: "yourpods-web-1a2b3c4d", installId: thisInstall),
            .otherDevice
        )
    }

    /// Bridge-written rows carry no device because none authored them: the "local" side is
    /// YourPods' own stored position, facing a remote gPodder host. Calling that "Other
    /// Device" would invent an author; calling it "This Device" is the original bug.
    func test_absentDeviceId_isTheService() {
        XCTAssertEqual(ConflictSideLabel.local(deviceId: nil, installId: thisInstall), .service)
    }

    /// An empty string is absence in a `TEXT` column that has been through
    /// `COALESCE(source, '')`-shaped handling on the way out. Treat it as absence rather
    /// than as an id that matches nothing, which would read as "Other Device".
    func test_emptyDeviceId_isTheService() {
        XCTAssertEqual(ConflictSideLabel.local(deviceId: "", installId: thisInstall), .service)
    }

    /// Comparison is exact. `InstallIdentity` mints one id per install and stores it
    /// verbatim; loosening this to a prefix would make every iPhone in the account read as
    /// this one.
    func test_sameDeviceKindDifferentInstall_isStillOtherDevice() {
        XCTAssertEqual(
            ConflictSideLabel.local(deviceId: "yourpods-iPhone-ffffffff", installId: thisInstall),
            .otherDevice
        )
    }

    // MARK: - Wiring

    /// The label is derived from the row, so a conflict carrying no device must not be
    /// silently attributed to this install by a nil-coalescing default somewhere upstream.
    func test_syncConflict_carriesTheAuthoringDevice() {
        let conflict = SyncConflict(
            episodeGuid: "guid-1", episodeTitle: nil, podcastTitle: nil, podcastUrl: nil,
            artworkUrl: nil, audioUrl: nil,
            localPosition: 828, serverPosition: 2167, serverTimestamp: 0,
            totalDuration: 3600, occurrenceCount: 1,
            deviceId: "yourpods-iPad-99887766"
        )

        XCTAssertEqual(conflict.deviceId, "yourpods-iPad-99887766")
        XCTAssertEqual(conflict.localSideLabel(installId: thisInstall), .otherDevice)
    }

    func test_syncConflict_deviceIdDefaultsToAbsent() {
        let conflict = SyncConflict(
            episodeGuid: "guid-1", episodeTitle: nil, podcastTitle: nil, podcastUrl: nil,
            artworkUrl: nil, audioUrl: nil,
            localPosition: 828, serverPosition: 2167, serverTimestamp: 0,
            totalDuration: 3600, occurrenceCount: 1
        )

        XCTAssertNil(conflict.deviceId,
                     "a locally-detected conflict has no server-recorded author")
        XCTAssertEqual(conflict.localSideLabel(installId: thisInstall), .service)
    }

    /// Carried through the merge, or the decode is decoration — the same failure mode as
    /// `serverCompleted` before it.
    @MainActor
    func test_mergedServerPositionConflicts_carriesTheDeviceId() {
        let server = ProServerConflict(
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            podcastUrl: nil,
            localPosition: 828,
            serverPosition: 2167,
            duration: 3600,
            deviceId: "yourpods-iPad-99887766",
            serverCompleted: nil,
            occurrenceCount: 1,
            updatedAt: nil,
            episodeTitle: nil,
            podcastTitle: nil,
            artUrl: nil
        )

        let merged = ProSyncOrchestrator.mergedServerPositionConflicts(local: [], server: [server])

        XCTAssertEqual(merged.first?.deviceId, "yourpods-iPad-99887766")
    }
}
