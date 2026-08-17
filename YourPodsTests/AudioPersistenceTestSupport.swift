import XCTest
@testable import YourPods

/// Shared cleanup for `AudioManager`'s launch-restore state.
///
/// `AudioManager` persists the current item, queue, position and event time into
/// **standard** `UserDefaults`, and `PlayerManager.init` calls `restoreQueue()` — so a
/// "fresh" `AudioManager()` in one test class is silently seeded by whatever an earlier
/// class left behind. The write is not obvious at the call site: `currentItem` has no
/// `didSet`, but `queue` does, and it calls `persistQueue()`, which writes `currentItem`
/// along with everything else. So `appendToQueue(...)` persists the current episode.
///
/// This surfaced 2026-07-30 as `NowPlayingSyncTests` failing its `XCTAssertNil(currentItem)`
/// with `SleepTimerEndOfEpisodeTests`' episode ("ep1" at 3590s) restored into it. It fit the
/// known real-SQLite flake profile exactly — untouched by the branch, clean in isolation —
/// and it was deterministic pollution, the second instance of that trap in two weeks
/// (`syncConflictStrategy`, fixed in `b267c869`).
///
/// Isolation passing does **not** separate a flake from pollution; both pass alone. What
/// separates them is a mechanism: a resource story for a flake, a *writer* for pollution.
/// Any test class that constructs a `PlayerManager` or touches `AudioManager.queue` should
/// call this in both `setUp` and `tearDown`.
extension XCTestCase {

    func clearAudioPersistenceDefaults() {
        for key in ["savedQueue", "savedCurrentItem", "savedCurrentPosition", "savedPlaybackEventTime"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
