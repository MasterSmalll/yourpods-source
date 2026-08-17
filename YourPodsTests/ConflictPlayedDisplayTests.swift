import XCTest
@testable import YourPods

/// The conflict sheet must say **Played**, not `1:00:00`, when the server holds the
/// episode as finished — per the sync contract, `serverCompleted` on `GET /sync-conflicts`.
///
/// Observed against the sync server:
///
///   "I marked an episode as played from ios and immediately got a sync conflict with the
///    max time of the episode being the server value and play time on the device being the
///    correct device time. **I'd expect the sync conflict wizard to be aware of marked as
///    played**"
///
/// A completed row stores `position_sec = duration`, and the sheet renders every server
/// value as a timestamp — so "finished" and "paused at the very end" are the same pixels.
/// The user is asked to choose between two numbers when one of them is not a position at
/// all. That is not a cosmetic problem: `1:00:00` invites "use the server", which is the
/// right answer here but for a reason the sheet never states, and the identical display
/// appears when the server genuinely is parked one second from the end.
///
/// `serverCompleted` is **optional on the wire**: the currently-deployed server predates
/// the field (it ships with the corresponding server change). Absent must mean "not known
/// to be played" and render exactly as it does today — never "played".
@MainActor
final class ConflictPlayedDisplayTests: XCTestCase {

    // MARK: - Helpers

    private func conflict(
        serverPosition: Int = 3600,
        serverCompleted: Bool = false,
        localPosition: Int = 828,
        duration: Int? = 3600
    ) -> SyncConflict {
        SyncConflict(
            episodeGuid: "guid-1",
            episodeTitle: "Episode One",
            podcastTitle: "Test Show",
            podcastUrl: "https://feeds.example.com/show.xml",
            artworkUrl: nil,
            audioUrl: "https://cdn.example.com/ep1.mp3",
            localPosition: localPosition,
            serverPosition: serverPosition,
            serverTimestamp: 0,
            totalDuration: duration,
            occurrenceCount: 1,
            serverCompleted: serverCompleted
        )
    }

    // MARK: - The defect

    /// The whole report in one assertion.
    func test_serverSide_completedRow_readsAsPlayed_notAsATimestamp() {
        let display = conflict(serverPosition: 3600, serverCompleted: true).serverSideDisplay

        XCTAssertEqual(
            display, .played,
            "a completed row stores position = duration, so rendering it as a timestamp shows "
            + "1:00:00 and asks the user to compare a position against something that is not one"
        )
    }

    /// The ordinary case is untouched: two real positions still read as two positions.
    func test_serverSide_ordinaryDivergence_staysATimestamp() {
        XCTAssertEqual(conflict(serverPosition: 2167, serverCompleted: false).serverSideDisplay,
                       .position(2167))
    }

    /// The deployed server sends no `serverCompleted`. Absent decodes to `false`, and a
    /// missing field must never be read as "played" — that would relabel every conflict
    /// on production the moment this ships, before the server change that feeds it.
    func test_serverSide_fieldAbsent_isNotPlayed() {
        let c = SyncConflict(
            episodeGuid: "guid-1",
            episodeTitle: nil,
            podcastTitle: nil,
            podcastUrl: nil,
            artworkUrl: nil,
            audioUrl: nil,
            localPosition: 100,
            serverPosition: 200,
            serverTimestamp: 0,
            totalDuration: nil,
            occurrenceCount: 1
        )

        XCTAssertFalse(c.serverCompleted, "absent must default to not-played")
        XCTAssertEqual(c.serverSideDisplay, .position(200))
    }

    /// "Played at 59:59" is a contradiction the sheet must not print. The flag wins over
    /// the number whatever the number is — including a completion the server recorded
    /// with a position short of the duration, which the sync contract's explicit-transition
    /// rule allows.
    func test_serverSide_completedWithAPositionShortOfDuration_stillReadsAsPlayed() {
        XCTAssertEqual(conflict(serverPosition: 2167, serverCompleted: true).serverSideDisplay,
                       .played)
    }

    // MARK: - VoiceOver

    /// The two positions are read as one sentence. When one side is not a position, the
    /// sentence has to change with it — a VoiceOver user gets *only* this string, so a
    /// label that still says "The server is at 1:00:00" hides the very fact the sighted
    /// fix surfaces.
    func test_a11y_completedServerSide_saysPlayed_notATime() {
        let label = conflict(serverPosition: 3600, serverCompleted: true).positionsAccessibilityLabel

        XCTAssertTrue(label.localizedCaseInsensitiveContains("played"),
                      "VoiceOver still described the server side as a position: \(label)")
        XCTAssertFalse(label.contains("1:00:00"),
                       "the duration must not be read out as though it were a position: \(label)")
    }

    /// The device side is still a position and must still be spoken as one — the fix
    /// changes one half of the sentence, not both.
    func test_a11y_completedServerSide_stillNamesTheDevicePosition() {
        let label = conflict(serverCompleted: true, localPosition: 828).positionsAccessibilityLabel

        XCTAssertTrue(label.contains(DurationFormatting.timestamp(828)),
                      "the device's own position vanished from the label: \(label)")
    }

    /// Ordinary conflicts keep the sentence they already had.
    func test_a11y_ordinaryDivergence_readsBothPositions() {
        let label = conflict(serverPosition: 2167, localPosition: 828).positionsAccessibilityLabel

        XCTAssertTrue(label.contains(DurationFormatting.timestamp(828)))
        XCTAssertTrue(label.contains(DurationFormatting.timestamp(2167)))
    }

    /// The button is reached directly by VoiceOver, out of the row's context, so its label
    /// has to carry the same fact. "Use the server's position, 1:00:00" tells a user who
    /// cannot see the row that they are choosing a timestamp.
    func test_a11y_useServerButton_saysWhatItKeeps_whenTheServerIsPlayed() {
        let label = conflict(serverPosition: 3600, serverCompleted: true).useServerAccessibilityLabel

        XCTAssertTrue(label.localizedCaseInsensitiveContains("played"),
                      "the button offered a position for a row that has none: \(label)")
        XCTAssertFalse(label.contains("1:00:00"), label)
    }

    func test_a11y_useServerButton_ordinaryDivergence_namesThePosition() {
        let label = conflict(serverPosition: 2167).useServerAccessibilityLabel

        XCTAssertTrue(label.contains(DurationFormatting.timestamp(2167)), label)
    }

    // MARK: - Carry-through from the wire

    /// The flag has to survive the merge into the local model, or the decode is decoration.
    func test_mergedServerPositionConflicts_carriesServerCompleted() {
        let server = ProServerConflict(
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            podcastUrl: "https://feeds.example.com/show.xml",
            localPosition: 828,
            serverPosition: 3600,
            duration: 3600,
            deviceId: "yourpods-iPhone-a1b2c3d4",
            serverCompleted: true,
            occurrenceCount: 1,
            updatedAt: nil,
            episodeTitle: "Episode One",
            podcastTitle: "Test Show",
            artUrl: nil
        )

        let merged = ProSyncOrchestrator.mergedServerPositionConflicts(local: [], server: [server])

        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].serverCompleted,
                      "decoded and then dropped on the floor — the sheet reads the local model")
        XCTAssertEqual(merged[0].serverSideDisplay, .played)
    }

    /// A row from the deployed server carries no flag; the merge must not invent one.
    func test_mergedServerPositionConflicts_absentFlag_isNotPlayed() {
        let server = ProServerConflict(
            episodeUrl: "https://cdn.example.com/ep1.mp3",
            podcastUrl: nil,
            localPosition: 828,
            serverPosition: 2167,
            duration: 3600,
            deviceId: nil,
            serverCompleted: nil,
            occurrenceCount: 1,
            updatedAt: nil,
            episodeTitle: nil,
            podcastTitle: nil,
            artUrl: nil
        )

        let merged = ProSyncOrchestrator.mergedServerPositionConflicts(local: [], server: [server])

        XCTAssertEqual(merged.count, 1)
        XCTAssertFalse(merged[0].serverCompleted)
        XCTAssertEqual(merged[0].serverSideDisplay, .position(2167))
    }
}
