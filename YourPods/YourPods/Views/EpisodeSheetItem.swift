import Foundation

/// Lightweight wrapper around an `Episode` reference for safe `.sheet(item:)` presentation.
///
/// **Why this exists:**
/// Using `.sheet(isPresented:)` with a separate `selectedEpisode: Episode?` state
/// causes a gray screen bug — SwiftUI evaluates the sheet content builder when
/// `isPresented` becomes `true`, but the optional Episode may still be `nil`
/// on the first render pass (state propagation race condition).
///
/// `.sheet(item:)` guarantees the item is non-nil in the content closure,
/// eliminating the gray screen entirely.
///
/// **Why UUID (not episode.guid) is the identity:**
/// SwiftUI's `.sheet(item:)` compares the item's `Identifiable.id` each time the
/// binding changes. If the id doesn't change between a dismiss and a re-tap of the
/// **same** episode, SwiftUI reuses the dismissed sheet's stale state — causing a
/// blank screen on every subsequent open of the same episode.
///
/// Using a fresh `UUID()` per construction guarantees SwiftUI always sees a new
/// identity and reconstructs the sheet from scratch.
struct EpisodeSheetItem: Identifiable {
    let episode: Episode

    /// A unique presentation token. Generated fresh each time, so that re-tapping
    /// the same episode produces a new identity and forces SwiftUI to build a
    /// fresh sheet view rather than reusing a stale dismissed one.
    let id: String

    init(episode: Episode) {
        self.episode = episode
        self.id = UUID().uuidString
    }
}
